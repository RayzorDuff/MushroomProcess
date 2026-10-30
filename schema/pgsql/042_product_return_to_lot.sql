-- 042_product_return_to_lot.sql
-- Issue #57 Phase 1: audit-safe Product -> returned Lot transition foundation.

SET search_path = public, pg_catalog;

BEGIN;

ALTER TABLE public.lots
  ADD COLUMN IF NOT EXISTS source_product_id bigint;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint c
    WHERE c.conname = 'fk_lots_source_product_id'
      AND c.conrelid = 'public.lots'::regclass
  ) THEN
    ALTER TABLE public.lots
      ADD CONSTRAINT fk_lots_source_product_id
      FOREIGN KEY (source_product_id)
      REFERENCES public.products(nocopk)
      DEFERRABLE INITIALLY DEFERRED;
  END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS ix_lots_source_product_id
  ON public.lots(source_product_id);

CREATE UNIQUE INDEX IF NOT EXISTS uq_lots_source_product_id_nonnull
  ON public.lots(source_product_id)
  WHERE source_product_id IS NOT NULL;

-- Keep the canonical scalar FK compatible with the repository's retained
-- NocoDB-style single-record junction pattern.  The scalar FK remains
-- authoritative; this junction is derived and may be rebuilt at any time.
CREATE TABLE IF NOT EXISTS public._m2m_lots_products_source_product_id (
  lots_id bigint NOT NULL,
  products_id bigint NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS _m2m_lots_products_source_product_id_lots_id_uniq
  ON public._m2m_lots_products_source_product_id(lots_id);
CREATE INDEX IF NOT EXISTS _m2m_lots_products_source_product_id_products_id_idx
  ON public._m2m_lots_products_source_product_id(products_id);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'fk_m2m_lots_products_source_product_id_lot'
      AND conrelid = 'public._m2m_lots_products_source_product_id'::regclass
  ) THEN
    ALTER TABLE public._m2m_lots_products_source_product_id
      ADD CONSTRAINT fk_m2m_lots_products_source_product_id_lot
      FOREIGN KEY (lots_id) REFERENCES public.lots(nocopk)
      ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'fk_m2m_lots_products_source_product_id_product'
      AND conrelid = 'public._m2m_lots_products_source_product_id'::regclass
  ) THEN
    ALTER TABLE public._m2m_lots_products_source_product_id
      ADD CONSTRAINT fk_m2m_lots_products_source_product_id_product
      FOREIGN KEY (products_id) REFERENCES public.products(nocopk)
      DEFERRABLE INITIALLY DEFERRED;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.sync_lots_source_product_id_to_m2m()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM public._m2m_lots_products_source_product_id
    WHERE lots_id = OLD.nocopk;
    RETURN OLD;
  END IF;

  DELETE FROM public._m2m_lots_products_source_product_id
  WHERE lots_id = NEW.nocopk;

  IF NEW.source_product_id IS NOT NULL THEN
    INSERT INTO public._m2m_lots_products_source_product_id(lots_id, products_id)
    VALUES (NEW.nocopk, NEW.source_product_id)
    ON CONFLICT (lots_id) DO UPDATE
      SET products_id = EXCLUDED.products_id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_lots_source_product_id_to_m2m ON public.lots;
CREATE TRIGGER trg_lots_source_product_id_to_m2m
AFTER INSERT OR UPDATE OF source_product_id OR DELETE ON public.lots
FOR EACH ROW EXECUTE FUNCTION public.sync_lots_source_product_id_to_m2m();

INSERT INTO public._m2m_lots_products_source_product_id(lots_id, products_id)
SELECT l.nocopk, l.source_product_id
FROM public.lots l
WHERE l.source_product_id IS NOT NULL
ON CONFLICT (lots_id) DO UPDATE
  SET products_id = EXCLUDED.products_id;

/*
 * Centralized eligibility contract for Issue #57.
 *
 * Category capability is intentionally narrow for the first implementation:
 *   grain      -> may return and be an inoculation target
 *   substrate  -> may return and be a Spawn-to-Bulk substrate input
 *   lc_syringe -> may return and be an inoculation source
 *
 * A Product is unavailable when it is expired, in a terminal product state or
 * location, already linked to an ecommerce order, lacks explicit origin-lot
 * lineage, or has already been returned to Lot inventory.
 */
CREATE OR REPLACE FUNCTION public.mp_product_cultivation_eligibility(
  p_product_id bigint,
  p_as_of date DEFAULT CURRENT_DATE
)
RETURNS TABLE (
  product_nocopk bigint,
  product_id text,
  item_category text,
  eligible_for_return boolean,
  can_inoculate_target boolean,
  can_inoculate_source boolean,
  can_spawn_substrate boolean,
  ineligibility_reason text
)
LANGUAGE sql
STABLE
AS $$
WITH product_row AS (
  SELECT
    p.nocopk,
    p.product_id,
    regexp_replace(
      lower(COALESCE(NULLIF(btrim(p.item_category_mat), ''), NULLIF(btrim(i.category), ''), '')),
      '[^a-z0-9]', '', 'g'
    ) AS category_norm,
    p.use_by,
    p.tray_state,
    p.strain_id AS product_strain_id,
    p.net_volume_ml,
    loc.name AS storage_location,
    EXISTS (
      SELECT 1
      FROM public.lots returned
      WHERE returned.source_product_id = p.nocopk
    ) AS already_returned,
    EXISTS (
      SELECT 1
      FROM public._m2m_products_ecommerce_orders_ecommerce_orders x
      WHERE x.products_id = p.nocopk
    ) OR EXISTS (
      SELECT 1
      FROM public._m2m_ecommerce_orders_products_products x
      WHERE x.products_id = p.nocopk
    ) AS linked_order,
    origin.origin_count,
    origin.origin_strain_id,
    origin.origin_inoculated_at
  FROM public.products p
  LEFT JOIN public.items i ON i.nocopk = p.item_id
  LEFT JOIN public.locations loc ON loc.nocopk = p.storage_location_id
  LEFT JOIN LATERAL (
    SELECT
      count(*)::bigint AS origin_count,
      max(l.strain_id) AS origin_strain_id,
      max(l.inoculated_at) AS origin_inoculated_at
    FROM public._m2m_products_lots_origin_lots x
    JOIN public.lots l ON l.nocopk = x.lots_id
    WHERE x.products_id = p.nocopk
  ) origin ON true
  WHERE p.nocopk = p_product_id
), classified AS (
  SELECT
    pr.*,
    regexp_replace(lower(COALESCE(pr.storage_location, '')), '[^a-z0-9]', '', 'g') AS location_norm,
    regexp_replace(lower(COALESCE(pr.tray_state, '')), '[^a-z0-9]', '', 'g') AS state_norm,
    pr.category_norm IN ('grain', 'substrate', 'lcsyringe') AS category_supported
  FROM product_row pr
), reasoned AS (
  SELECT
    c.*,
    CASE
      WHEN NOT c.category_supported THEN 'Product category is not eligible for cultivation return.'
      WHEN c.use_by IS NOT NULL AND c.use_by < COALESCE(p_as_of, CURRENT_DATE) THEN 'Product is expired.'
      WHEN c.already_returned THEN 'Product has already been returned to Lot inventory.'
      WHEN c.linked_order THEN 'Product is linked to an ecommerce order.'
      WHEN COALESCE(c.origin_count, 0) <> 1 THEN 'Product must have exactly one explicit origin Lot.'
      WHEN c.location_norm IN ('shipped','consumed','expired','retired','compost','composted','missing','missingorlost')
        THEN 'Product is in a terminal or unavailable storage location.'
      WHEN c.state_norm IN ('emptytray','compost','composted','spoiled','retired','expired','consumed','shipped','deproductized')
        THEN 'Product is in a terminal lifecycle state.'
      WHEN c.category_norm IN ('grain', 'substrate')
        AND (c.product_strain_id IS NOT NULL OR c.origin_strain_id IS NOT NULL OR c.origin_inoculated_at IS NOT NULL)
        THEN 'Packaged grain/substrate is already inoculated and cannot be reused as sterile production input.'
      WHEN c.category_norm = 'lcsyringe'
        AND COALESCE(c.product_strain_id, c.origin_strain_id) IS NULL
        THEN 'LC syringe Product has no strain lineage and cannot be used as an inoculation source.'
      WHEN c.category_norm = 'lcsyringe' AND COALESCE(c.net_volume_ml, 0) <= 0
        THEN 'LC syringe Product has no usable volume.'
      ELSE NULL
    END AS reason
  FROM classified c
)
SELECT
  r.nocopk,
  r.product_id,
  r.category_norm,
  r.reason IS NULL AS eligible_for_return,
  r.reason IS NULL AND r.category_norm = 'grain' AS can_inoculate_target,
  r.reason IS NULL AND r.category_norm = 'lcsyringe' AS can_inoculate_source,
  r.reason IS NULL AND r.category_norm = 'substrate' AS can_spawn_substrate,
  r.reason
FROM reasoned r;
$$;

COMMENT ON FUNCTION public.mp_product_cultivation_eligibility(bigint, date) IS
  'Issue #57 canonical Product eligibility/capability contract used by Show Eligible Products and deproductization.';

/*
 * Return one eligible packaged Product to a new Lot while preserving the
 * Product as an immutable historical inventory state.
 *
 * The Product is moved to Consumed so every existing sales/fulfillment path
 * stops treating it as sellable.  The returned Lot points back through
 * lots.source_product_id; the Product keeps its explicit origin-lot link.
 * Together those edges preserve Lot -> Product -> Lot genealogy.
 *
 * p_label_type is deliberately caller-controlled and defaults to NULL.  A raw
 * Product -> Lot transition therefore never invents an intermediate label.
 * Contextual operations in Phase 2 will rely on their normal output label
 * (for example Grain_Inoculated or Bulk_Created) and only request a replacement
 * LC-syringe Lot label when usable volume remains after inoculation.
 */
CREATE OR REPLACE FUNCTION public.mp_product_return_to_lot(
  p_product_id bigint,
  p_operator text DEFAULT 'system',
  p_station text DEFAULT 'Products',
  p_timestamp timestamp without time zone DEFAULT NULL,
  p_note text DEFAULT NULL,
  p_label_type text DEFAULT NULL,
  p_storage_location_id bigint DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  v_ts timestamp without time zone := COALESCE(p_timestamp, now());
  v_product record;
  v_origin record;
  v_elig record;
  v_returned_lot_id bigint;
  v_event_id bigint;
  v_category text;
  v_status text;
  v_unit_size numeric;
  v_total_volume_ml numeric;
  v_remaining_volume_ml numeric;
  v_use_by date;
  v_location_id bigint;
  v_consumed_location_id bigint;
  v_item_name text;
  v_species_strain text;
  v_return_strain_id bigint;
  v_component record;
  v_new_component_id bigint;
BEGIN
  IF p_product_id IS NULL THEN
    RAISE EXCEPTION 'Product is required.';
  END IF;

  SELECT
    p.*,
    i.name AS resolved_item_name,
    i.category AS resolved_item_category,
    s.species_strain AS resolved_species_strain
  INTO v_product
  FROM public.products p
  LEFT JOIN public.items i ON i.nocopk = p.item_id
  LEFT JOIN public.strains s ON s.nocopk = p.strain_id
  WHERE p.nocopk = p_product_id
  FOR UPDATE OF p;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found: %', p_product_id;
  END IF;

  SELECT * INTO v_elig
  FROM public.mp_product_cultivation_eligibility(p_product_id, v_ts::date);

  IF NOT COALESCE(v_elig.eligible_for_return, false) THEN
    RAISE EXCEPTION 'Product % cannot be returned to Lot inventory: %',
      COALESCE(v_product.product_id, p_product_id::text),
      COALESCE(v_elig.ineligibility_reason, 'unknown eligibility failure');
  END IF;

  SELECT l.*
  INTO v_origin
  FROM public._m2m_products_lots_origin_lots j
  JOIN public.lots l ON l.nocopk = j.lots_id
  WHERE j.products_id = p_product_id
  ORDER BY l.nocopk
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product % has no explicit origin Lot.', COALESCE(v_product.product_id, p_product_id::text);
  END IF;

  v_category := regexp_replace(
    lower(COALESCE(NULLIF(btrim(v_product.item_category_mat), ''), NULLIF(btrim(v_product.resolved_item_category), ''), '')),
    '[^a-z0-9]', '', 'g'
  );

  v_status := CASE
    WHEN v_category = 'grain' THEN 'Sterilized'
    WHEN v_category = 'substrate' AND lower(COALESCE(v_product.process_type_mat, v_origin.process_type_mat, '')) LIKE '%pasteur%'
      THEN 'Pasteurized'
    WHEN v_category = 'substrate' THEN 'Sterilized'
    WHEN v_category = 'lcsyringe' THEN 'Fridge'
    ELSE NULL
  END;

  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Unsupported Product category for return: %', v_category;
  END IF;

  IF v_product.item_id IS NULL THEN
    RAISE EXCEPTION 'Product % is missing its canonical item link.', COALESCE(v_product.product_id, p_product_id::text);
  END IF;

  IF v_category IN ('grain', 'substrate') THEN
    v_unit_size := COALESCE(
      CASE WHEN COALESCE(v_product.net_weight_g, 0) > 0 THEN v_product.net_weight_g / 453.59237 END,
      CASE WHEN COALESCE(v_product.net_weight_oz, 0) > 0 THEN v_product.net_weight_oz / 16.0 END,
      NULLIF(v_origin.unit_size, 0)
    );
    IF v_unit_size IS NULL OR v_unit_size <= 0 THEN
      RAISE EXCEPTION 'Product % has no usable packaged weight.', COALESCE(v_product.product_id, p_product_id::text);
    END IF;
  ELSE
    v_total_volume_ml := COALESCE(NULLIF(v_product.net_volume_ml, 0), NULLIF(v_origin.total_volume_ml, 0), NULLIF(v_origin.remaining_volume_ml, 0));
    v_remaining_volume_ml := v_total_volume_ml;
    v_unit_size := v_total_volume_ml;
    IF v_total_volume_ml IS NULL OR v_total_volume_ml <= 0 THEN
      RAISE EXCEPTION 'LC syringe Product % has no usable packaged volume.', COALESCE(v_product.product_id, p_product_id::text);
    END IF;
  END IF;

  SELECT min(d)
  INTO v_use_by
  FROM (VALUES (v_product.use_by), (v_origin.use_by)) AS dates(d)
  WHERE d IS NOT NULL;

  v_location_id := COALESCE(p_storage_location_id, v_product.storage_location_id);
  IF v_location_id IS NULL THEN
    RAISE EXCEPTION 'A storage location is required for returned Product %.', COALESCE(v_product.product_id, p_product_id::text);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.locations l
    WHERE l.nocopk = v_location_id AND COALESCE(l.active, false)
  ) THEN
    RAISE EXCEPTION 'Returned Lot storage location % is missing or inactive.', v_location_id;
  END IF;

  v_item_name := COALESCE(NULLIF(btrim(v_product.resolved_item_name), ''), NULLIF(btrim(v_product.name_mat), ''), v_origin.item_name_mat);
  v_return_strain_id := COALESCE(v_product.strain_id, v_origin.strain_id);
  SELECT s.species_strain
  INTO v_species_strain
  FROM public.strains s
  WHERE s.nocopk = v_return_strain_id;
  v_species_strain := COALESCE(
    NULLIF(btrim(v_species_strain), ''),
    NULLIF(btrim(v_product.resolved_species_strain), ''),
    NULLIF(btrim(v_origin.strain_species_strain_mat), '')
  );

  INSERT INTO public.lots (
    item_id,
    item_name_mat,
    recipe_id,
    strain_id,
    qty,
    unit_size,
    status,
    parents_json,
    steri_run_id,
    location_id,
    operator,
    created_at,
    use_by,
    item_category_mat,
    process_type_mat,
    strain_species_strain_mat,
    vendor_name_mat,
    total_volume_ml,
    remaining_volume_ml,
    source_type,
    vendor_name,
    vendor_batch,
    received_date,
    sterilized_at,
    source_product_id,
    label_template,
    notes
  )
  VALUES (
    v_product.item_id,
    v_item_name,
    v_origin.recipe_id,
    v_return_strain_id,
    1,
    v_unit_size,
    v_status,
    v_product.origin_lot_ids_json,
    v_origin.steri_run_id,
    v_location_id,
    p_operator,
    v_ts,
    v_use_by,
    COALESCE(NULLIF(v_product.item_category_mat, ''), NULLIF(v_product.resolved_item_category, ''), v_origin.item_category_mat),
    COALESCE(NULLIF(v_product.process_type_mat, ''), v_origin.process_type_mat),
    v_species_strain,
    COALESCE(NULLIF(btrim(v_origin.vendor_name_mat), ''), NULLIF(btrim(v_origin.vendor_name), '')),
    v_total_volume_ml,
    v_remaining_volume_ml,
    CASE WHEN v_category = 'lcsyringe' THEN 'ReturnedProduct' ELSE v_origin.source_type END,
    v_origin.vendor_name,
    v_origin.vendor_batch,
    CASE WHEN v_category = 'lcsyringe' THEN COALESCE(v_product.pack_date, v_origin.received_date) ELSE v_origin.received_date END,
    v_origin.sterilized_at,
    p_product_id,
    NULLIF(btrim(COALESCE(p_label_type, '')), ''),
    concat_ws(E'\n', NULLIF(btrim(COALESCE(v_origin.notes, '')), ''), NULLIF(btrim(COALESCE(p_note, '')), ''))
  )
  RETURNING nocopk INTO v_returned_lot_id;

  PERFORM public.mp_link_lot_item(v_returned_lot_id, v_product.item_id);
  IF v_origin.recipe_id IS NOT NULL THEN
    PERFORM public.mp_link_lot_recipe(v_returned_lot_id, v_origin.recipe_id);
  END IF;
  IF v_return_strain_id IS NOT NULL THEN
    BEGIN
      INSERT INTO public._m2m_lots_strains_strain_id(lots_id, strains_id)
      VALUES (v_returned_lot_id, v_return_strain_id)
      ON CONFLICT DO NOTHING;
    EXCEPTION WHEN undefined_table THEN NULL;
    END;
    BEGIN
      INSERT INTO public._m2m_strains_lots_lots(strains_id, lots_id)
      VALUES (v_return_strain_id, v_returned_lot_id)
      ON CONFLICT DO NOTHING;
    EXCEPTION WHEN undefined_table THEN NULL;
    END;
  END IF;
  IF v_origin.steri_run_id IS NOT NULL AND v_category IN ('grain', 'substrate') THEN
    PERFORM public.mp_link_sterilization_run_lot(v_origin.steri_run_id, v_returned_lot_id);
  END IF;
  PERFORM public.mp_lot_set_location(v_returned_lot_id, v_location_id);

  -- Preserve recipe-component history so a returned substrate/grain behaves
  -- identically to its pre-package Lot in Spawn-to-Bulk accounting.
  IF v_category IN ('grain', 'substrate') THEN
    FOR v_component IN
      SELECT *
      FROM public.lot_recipe_components lrc
      WHERE lrc.lot_id = v_origin.nocopk
      ORDER BY COALESCE(lrc.sort_order, 0), lrc.nocopk
    LOOP
      INSERT INTO public.lot_recipe_components (
        lot_id,
        item_id,
        recipe_id,
        source_item_recipe_component_id,
        component_role,
        component_weight_lb,
        component_percent,
        sort_order,
        notes
      )
      VALUES (
        v_returned_lot_id,
        v_component.item_id,
        v_component.recipe_id,
        v_component.source_item_recipe_component_id,
        v_component.component_role,
        v_component.component_weight_lb,
        v_component.component_percent,
        v_component.sort_order,
        concat_ws(' ', NULLIF(btrim(COALESCE(v_component.notes, '')), ''), '[preserved through Product return]')
      )
      RETURNING nocopk INTO v_new_component_id;

      PERFORM public.mp_link_lot_recipe_component(
        v_new_component_id,
        v_returned_lot_id,
        v_component.item_id,
        v_component.recipe_id,
        v_component.source_item_recipe_component_id
      );
    END LOOP;
  END IF;

  SELECT l.nocopk
  INTO v_consumed_location_id
  FROM public.locations l
  WHERE regexp_replace(lower(btrim(l.name)), '[^a-z0-9]', '', 'g') = 'consumed'
  ORDER BY CASE WHEN COALESCE(l.active, false) THEN 0 ELSE 1 END, l.nocopk
  LIMIT 1;

  IF v_consumed_location_id IS NULL THEN
    RAISE EXCEPTION 'Consumed location is required to remove returned Product % from sellable inventory.', COALESCE(v_product.product_id, p_product_id::text);
  END IF;

  PERFORM public.mp_product_set_storage_location(p_product_id, v_consumed_location_id);

  v_event_id := public.mp_events_insert(
    v_returned_lot_id,
    p_product_id,
    'ReturnedToLotInventory',
    v_ts,
    p_operator,
    p_station,
    jsonb_strip_nulls(jsonb_build_object(
      'product_id', COALESCE(v_product.product_id, p_product_id::text),
      'product_nocopk', p_product_id,
      'returned_lot_nocopk', v_returned_lot_id,
      'origin_lot_nocopk', v_origin.nocopk,
      'origin_lot_id', v_origin.lot_id,
      'item_category', v_category,
      'preserved_use_by', v_use_by,
      'label_type', NULLIF(btrim(COALESCE(p_label_type, '')), ''),
      'note', NULLIF(btrim(COALESCE(p_note, '')), '')
    ))
  );
  PERFORM public.mp_events_link_lot(v_event_id, v_returned_lot_id);
  PERFORM public.mp_events_link_product(v_event_id, p_product_id);

  IF NULLIF(btrim(COALESCE(p_label_type, '')), '') IS NOT NULL THEN
    PERFORM public.mp_print_queue_enqueue(
      'lot',
      NULLIF(btrim(p_label_type), ''),
      v_returned_lot_id,
      NULL,
      NULL,
      'Queued'
    );
  END IF;

  RETURN v_returned_lot_id;
END;
$$;

COMMENT ON FUNCTION public.mp_product_return_to_lot(bigint, text, text, timestamp without time zone, text, text, bigint) IS
  'Issue #57 audit-safe Product -> new Lot transition. Preserves Product/origin history, expiration, recipe components, and only queues a label when the caller supplies an explicit supported label type.';

COMMIT;
