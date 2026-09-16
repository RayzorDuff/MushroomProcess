\set ON_ERROR_STOP on

-- Issue #57 Phase 2: contextual Product -> Lot cultivation workflows.
--
-- This migration keeps Product deproductization inside the same PostgreSQL
-- transaction as inoculation / Spawn-to-Bulk. Appsmith may display eligible
-- packaged Products alongside Lots, but it never has to create an intermediate
-- returned Lot itself.

BEGIN;

CREATE OR REPLACE VIEW public.v_product_cultivation_candidates AS
WITH product_rows AS (
  SELECT
    p.nocopk AS product_nocopk,
    p.product_id,
    p.item_id,
    COALESCE(NULLIF(btrim(p.name_mat), ''), NULLIF(btrim(i.name), '')) AS item_name_mat,
    COALESCE(NULLIF(btrim(p.item_category_mat), ''), NULLIF(btrim(i.category), '')) AS item_category_mat,
    COALESCE(p.strain_id, origin.strain_id) AS strain_id,
    COALESCE(NULLIF(btrim(s.species_strain), ''), NULLIF(btrim(origin.strain_species_strain_mat), '')) AS strain_species_strain_mat,
    COALESCE(NULLIF(btrim(origin.vendor_name_mat), ''), NULLIF(btrim(origin.vendor_name), '')) AS vendor_name_mat,
    p.storage_location_id AS location_id,
    loc.name AS storage_location,
    p.process_type_mat,
    p.pack_date,
    p.use_by AS product_use_by,
    p.net_weight_g,
    p.net_weight_oz,
    p.net_volume_ml,
    p.nc_created_at,
    origin.nocopk AS origin_lot_nocopk,
    origin.lot_id AS origin_lot_id,
    origin.recipe_id,
    origin.created_at AS origin_created_at,
    origin.sterilized_at,
    origin.received_date,
    origin.use_by AS origin_use_by,
    origin.process_type_mat AS origin_process_type_mat,
    origin.source_type AS origin_source_type,
    origin.label_template AS origin_label_template,
    e.eligible_for_return,
    e.can_inoculate_target,
    e.can_inoculate_source,
    e.can_spawn_substrate,
    e.ineligibility_reason
  FROM public.products p
  LEFT JOIN public.items i ON i.nocopk = p.item_id
  LEFT JOIN public.locations loc ON loc.nocopk = p.storage_location_id
  LEFT JOIN LATERAL (
    SELECT l.*
    FROM public._m2m_products_lots_origin_lots x
    JOIN public.lots l ON l.nocopk = x.lots_id
    WHERE x.products_id = p.nocopk
    ORDER BY l.nocopk
    LIMIT 1
  ) origin ON true
  LEFT JOIN public.strains s ON s.nocopk = COALESCE(p.strain_id, origin.strain_id)
  CROSS JOIN LATERAL public.mp_product_cultivation_eligibility(p.nocopk, CURRENT_DATE) e
)
SELECT
  'product'::text AS inventory_kind,
  ('product:' || pr.product_nocopk::text) AS row_key,
  NULL::bigint AS nocopk,
  pr.product_nocopk,
  pr.product_id,
  ('PRODUCT · ' || pr.product_id) AS lot_id,
  pr.item_id,
  pr.item_name_mat,
  pr.item_category_mat,
  pr.item_category_mat AS item_category,
  pr.strain_id,
  pr.strain_species_strain_mat,
  pr.vendor_name_mat,
  'Packaged Product'::text AS status,
  1::numeric AS qty,
  CASE
    WHEN regexp_replace(lower(COALESCE(pr.item_category_mat, '')), '[^a-z0-9]', '', 'g') = 'lcsyringe'
      THEN pr.net_volume_ml
    WHEN COALESCE(pr.net_weight_g, 0) > 0
      THEN pr.net_weight_g / 453.59237
    WHEN COALESCE(pr.net_weight_oz, 0) > 0
      THEN pr.net_weight_oz / 16.0
    ELSE NULL
  END AS unit_size,
  COALESCE(pr.pack_date::timestamp without time zone, pr.nc_created_at, pr.origin_created_at) AS created_at,
  pr.sterilized_at,
  pr.received_date,
  NULL::timestamp without time zone AS inoculated_at,
  NULL::timestamp without time zone AS spawned_at,
  pr.net_volume_ml AS remaining_volume_ml,
  pr.net_volume_ml AS total_volume_ml,
  NULL::numeric AS lc_volume_ml,
  NULL::numeric AS plate_count,
  pr.location_id,
  pr.storage_location,
  COALESCE(NULLIF(btrim(pr.process_type_mat), ''), pr.origin_process_type_mat) AS process_type_mat,
  pr.recipe_id,
  LEAST(pr.product_use_by, pr.origin_use_by) AS use_by,
  CASE
    WHEN s2.regulated IS NULL THEN ARRAY[FALSE]::boolean[]
    ELSE ARRAY[s2.regulated]::boolean[]
  END AS regulated_from_strain_id,
  COALESCE(s2.regulated, false) AS is_regulated,
  pr.origin_lot_nocopk,
  pr.origin_lot_id,
  pr.origin_source_type,
  pr.origin_label_template,
  pr.eligible_for_return,
  pr.can_inoculate_target,
  pr.can_inoculate_source,
  pr.can_spawn_substrate,
  pr.ineligibility_reason
FROM product_rows pr
LEFT JOIN public.strains s2 ON s2.nocopk = pr.strain_id
WHERE pr.eligible_for_return
  AND (LEAST(pr.product_use_by, pr.origin_use_by) IS NULL
       OR LEAST(pr.product_use_by, pr.origin_use_by) >= CURRENT_DATE);

COMMENT ON VIEW public.v_product_cultivation_candidates IS
  'Issue #57 UI contract: currently eligible packaged grain, substrate, and LC syringe Products shaped like cultivation inventory rows. Product rows are explicitly identified by inventory_kind/product_nocopk and must be consumed through contextual wrapper functions.';


CREATE OR REPLACE FUNCTION public.mp_inoculate_with_products_result(
  p_source_lot_id bigint DEFAULT NULL,
  p_source_product_id bigint DEFAULT NULL,
  p_target_lot_ids bigint[] DEFAULT ARRAY[]::bigint[],
  p_target_product_ids bigint[] DEFAULT ARRAY[]::bigint[],
  p_storage_location_id bigint DEFAULT NULL,
  p_lc_volume_ml numeric DEFAULT NULL,
  p_override_inoc_time timestamp without time zone DEFAULT NULL,
  p_operator text DEFAULT 'system',
  p_station text DEFAULT 'Inoculation',
  p_timestamp timestamp without time zone DEFAULT NULL,
  p_note text DEFAULT NULL
)
RETURNS TABLE(
  inoculated_count integer,
  diagnostic text,
  returned_source_lot_id bigint,
  returned_target_lot_ids bigint[]
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_ts timestamp without time zone := COALESCE(p_override_inoc_time, p_timestamp, now());
  v_source_lot_id bigint := p_source_lot_id;
  v_target_lot_ids bigint[] := COALESCE(p_target_lot_ids, ARRAY[]::bigint[]);
  v_target_product_ids bigint[] := COALESCE(p_target_product_ids, ARRAY[]::bigint[]);
  v_returned_targets bigint[] := ARRAY[]::bigint[];
  v_returned_target bigint;
  v_product_id bigint;
  v_elig record;
  v_result record;
  v_fridge_location_id bigint;
  v_remaining_ml numeric;
  v_source_status text;
  v_replacement_label text;
BEGIN
  IF (p_source_lot_id IS NULL) = (p_source_product_id IS NULL) THEN
    RAISE EXCEPTION 'Select exactly one inoculation source: Lot or eligible Product.';
  END IF;

  IF cardinality(v_target_lot_ids) + cardinality(v_target_product_ids) < 1 THEN
    RAISE EXCEPTION 'Select at least one inoculation target Lot or eligible Product.';
  END IF;

  IF cardinality(v_target_product_ids) <> (
    SELECT count(DISTINCT x) FROM unnest(v_target_product_ids) AS u(x)
  ) THEN
    RAISE EXCEPTION 'Target Product IDs must be unique.';
  END IF;

  IF p_source_product_id IS NOT NULL THEN
    SELECT * INTO v_elig
    FROM public.mp_product_cultivation_eligibility(p_source_product_id, v_ts::date);

    IF NOT COALESCE(v_elig.can_inoculate_source, false) THEN
      RAISE EXCEPTION 'Product % is not eligible as an inoculation source: %',
        p_source_product_id,
        COALESCE(v_elig.ineligibility_reason, 'wrong Product capability');
    END IF;

    SELECT l.nocopk
    INTO v_fridge_location_id
    FROM public.locations l
    WHERE COALESCE(l.active, false)
      AND regexp_replace(lower(btrim(l.name)), '[^a-z0-9]', '', 'g') IN ('fridge', 'refrigerator', 'refrigeratedstorage')
    ORDER BY l.nocopk
    LIMIT 1;

    IF v_fridge_location_id IS NULL THEN
      RAISE EXCEPTION 'An active Fridge location is required before an LC syringe Product can return to cultivation.';
    END IF;

    v_source_lot_id := public.mp_product_return_to_lot(
      p_product_id => p_source_product_id,
      p_operator => p_operator,
      p_station => p_station,
      p_timestamp => v_ts,
      p_note => p_note,
      p_label_type => NULL,
      p_storage_location_id => v_fridge_location_id
    );

    returned_source_lot_id := v_source_lot_id;
  END IF;

  FOREACH v_product_id IN ARRAY v_target_product_ids LOOP
    SELECT * INTO v_elig
    FROM public.mp_product_cultivation_eligibility(v_product_id, v_ts::date);

    IF NOT COALESCE(v_elig.can_inoculate_target, false) THEN
      RAISE EXCEPTION 'Product % is not eligible as an inoculation target: %',
        v_product_id,
        COALESCE(v_elig.ineligibility_reason, 'wrong Product capability');
    END IF;

    v_returned_target := public.mp_product_return_to_lot(
      p_product_id => v_product_id,
      p_operator => p_operator,
      p_station => p_station,
      p_timestamp => v_ts,
      p_note => p_note,
      p_label_type => NULL,
      p_storage_location_id => NULL
    );

    v_returned_targets := array_append(v_returned_targets, v_returned_target);
  END LOOP;

  returned_target_lot_ids := v_returned_targets;
  v_target_lot_ids := v_target_lot_ids || v_returned_targets;

  SELECT * INTO v_result
  FROM public.mp_lots_inoculate_multiple_result(
    p_source_lot_id => v_source_lot_id,
    p_target_lot_ids => v_target_lot_ids,
    p_storage_location_id => p_storage_location_id,
    p_lc_volume_ml => p_lc_volume_ml,
    p_override_inoc_time => p_override_inoc_time,
    p_operator => p_operator,
    p_station => p_station,
    p_timestamp => p_timestamp,
    p_note => p_note
  );

  inoculated_count := COALESCE(v_result.inoculated_count, 0);
  diagnostic := NULLIF(btrim(COALESCE(v_result.diagnostic, '')), '');

  -- If any Product was deproductized, a downstream validation failure must
  -- abort the whole SQL call so the Product remains sellable and no returned
  -- Lot survives on its own.
  IF inoculated_count <= 0 AND (
    p_source_product_id IS NOT NULL OR cardinality(v_target_product_ids) > 0
  ) THEN
    RAISE EXCEPTION '%', COALESCE(diagnostic, 'Inoculation failed after Product return validation. No Product or Lot changes were committed.');
  END IF;

  -- Inoculation normally assigns a fresh 3-month use-by to grain. Returned
  -- packaged grain may be older, so cap it at the preserved Product/origin
  -- expiration after the normal lifecycle update. The queued label resolves
  -- from the Lot at print time and therefore sees this capped date.
  IF cardinality(v_returned_targets) > 0 THEN
    UPDATE public.lots target
    SET use_by = caps.preserved_use_by,
        nc_updated_at = now()
    FROM (
      SELECT
        returned.nocopk,
        min(dates.d) AS preserved_use_by
      FROM public.lots returned
      JOIN public.products p ON p.nocopk = returned.source_product_id
      LEFT JOIN public._m2m_products_lots_origin_lots x ON x.products_id = p.nocopk
      LEFT JOIN public.lots origin ON origin.nocopk = x.lots_id
      CROSS JOIN LATERAL (
        VALUES (returned.use_by), (p.use_by), (origin.use_by)
      ) AS dates(d)
      WHERE returned.nocopk = ANY(v_returned_targets)
        AND dates.d IS NOT NULL
      GROUP BY returned.nocopk
    ) caps
    WHERE target.nocopk = caps.nocopk
      AND caps.preserved_use_by IS NOT NULL
      AND (target.use_by IS NULL OR caps.preserved_use_by < target.use_by);
  END IF;

  -- A packaged LC syringe stops being a Product as soon as it is opened.
  -- If inoculation leaves usable volume, its returned Lot needs a replacement
  -- syringe label. If the syringe is depleted, no label is useful.
  IF p_source_product_id IS NOT NULL AND inoculated_count > 0 THEN
    SELECT l.remaining_volume_ml, l.status
    INTO v_remaining_ml, v_source_status
    FROM public.lots l
    WHERE l.nocopk = v_source_lot_id;

    IF COALESCE(v_remaining_ml, 0) > 0
       AND regexp_replace(lower(COALESCE(v_source_status, '')), '[^a-z0-9]', '', 'g') <> 'consumed' THEN
      SELECT CASE
        WHEN origin.label_template = 'LC_Syringe_Received'
          OR regexp_replace(lower(COALESCE(origin.source_type, '')), '[^a-z0-9]', '', 'g') LIKE '%purchas%'
          THEN 'LC_Syringe_Received'
        ELSE 'LC_Syringe_Drawn'
      END
      INTO v_replacement_label
      FROM public._m2m_products_lots_origin_lots x
      JOIN public.lots origin ON origin.nocopk = x.lots_id
      WHERE x.products_id = p_source_product_id
      ORDER BY origin.nocopk
      LIMIT 1;

      v_replacement_label := COALESCE(v_replacement_label, 'LC_Syringe_Drawn');

      UPDATE public.lots
      SET label_template = v_replacement_label,
          nc_updated_at = now()
      WHERE nocopk = v_source_lot_id;

      PERFORM public.mp_print_queue_enqueue(
        'lot'::text,
        v_replacement_label,
        v_source_lot_id,
        NULL::bigint,
        NULL::bigint,
        'Queued'::text
      );
    END IF;
  END IF;

  RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION public.mp_inoculate_with_products_result(
  bigint, bigint, bigint[], bigint[], bigint, numeric,
  timestamp without time zone, text, text, timestamp without time zone, text
) IS
  'Issue #57 atomic inoculation wrapper. Accepts Lot/Product source and target inventory, deproductizes eligible Products transactionally, caps returned-grain expiration, and prints a replacement LC syringe Lot label only when source volume remains.';


CREATE OR REPLACE FUNCTION public.mp_spawn_to_bulk_with_products(
  p_grain_lot_ids bigint[],
  p_substrate_lot_ids bigint[] DEFAULT ARRAY[]::bigint[],
  p_substrate_product_ids bigint[] DEFAULT ARRAY[]::bigint[],
  p_output_count integer DEFAULT NULL,
  p_output_plan_json jsonb DEFAULT '[]'::jsonb,
  p_storage_location_id bigint DEFAULT NULL,
  p_override_spawn_time timestamp without time zone DEFAULT NULL,
  p_operator text DEFAULT 'system',
  p_station text DEFAULT 'Spawn to Bulk',
  p_timestamp timestamp without time zone DEFAULT NULL,
  p_note text DEFAULT NULL,
  p_fruiting_goal text DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
  v_ts timestamp without time zone := COALESCE(p_override_spawn_time, p_timestamp, now());
  v_substrate_lot_ids bigint[] := COALESCE(p_substrate_lot_ids, ARRAY[]::bigint[]);
  v_substrate_product_ids bigint[] := COALESCE(p_substrate_product_ids, ARRAY[]::bigint[]);
  v_returned_substrates bigint[] := ARRAY[]::bigint[];
  v_returned_substrate bigint;
  v_product_id bigint;
  v_elig record;
  v_created_count integer;
  v_preserved_use_by date;
BEGIN
  IF p_grain_lot_ids IS NULL OR cardinality(p_grain_lot_ids) < 1 THEN
    RAISE EXCEPTION 'Select at least one colonized grain source Lot.';
  END IF;

  IF cardinality(v_substrate_lot_ids) + cardinality(v_substrate_product_ids) < 1 THEN
    RAISE EXCEPTION 'Select at least one substrate Lot or eligible Product.';
  END IF;

  IF cardinality(v_substrate_product_ids) <> (
    SELECT count(DISTINCT x) FROM unnest(v_substrate_product_ids) AS u(x)
  ) THEN
    RAISE EXCEPTION 'Substrate Product IDs must be unique.';
  END IF;

  FOREACH v_product_id IN ARRAY v_substrate_product_ids LOOP
    SELECT * INTO v_elig
    FROM public.mp_product_cultivation_eligibility(v_product_id, v_ts::date);

    IF NOT COALESCE(v_elig.can_spawn_substrate, false) THEN
      RAISE EXCEPTION 'Product % is not eligible as a Spawn-to-Bulk substrate: %',
        v_product_id,
        COALESCE(v_elig.ineligibility_reason, 'wrong Product capability');
    END IF;

    v_returned_substrate := public.mp_product_return_to_lot(
      p_product_id => v_product_id,
      p_operator => p_operator,
      p_station => p_station,
      p_timestamp => v_ts,
      p_note => p_note,
      p_label_type => NULL,
      p_storage_location_id => NULL
    );

    v_returned_substrates := array_append(v_returned_substrates, v_returned_substrate);
  END LOOP;

  v_substrate_lot_ids := v_substrate_lot_ids || v_returned_substrates;

  v_created_count := public.mp_lots_spawn_to_bulk(
    p_grain_lot_ids => p_grain_lot_ids,
    p_substrate_lot_ids => v_substrate_lot_ids,
    p_output_count => p_output_count,
    p_output_plan_json => p_output_plan_json,
    p_storage_location_id => p_storage_location_id,
    p_override_spawn_time => p_override_spawn_time,
    p_operator => p_operator,
    p_station => p_station,
    p_timestamp => p_timestamp,
    p_note => p_note,
    p_fruiting_goal => p_fruiting_goal
  );

  IF COALESCE(v_created_count, 0) <= 0 AND cardinality(v_returned_substrates) > 0 THEN
    RAISE EXCEPTION 'Spawn to Bulk failed after Product return validation. No Product or Lot changes were committed.';
  END IF;

  IF cardinality(v_returned_substrates) > 0 THEN
    SELECT min(l.use_by)
    INTO v_preserved_use_by
    FROM public.lots l
    WHERE l.nocopk = ANY(v_returned_substrates)
      AND l.use_by IS NOT NULL;

    IF v_preserved_use_by IS NOT NULL THEN
      UPDATE public.lots output
      SET use_by = v_preserved_use_by,
          nc_updated_at = now()
      WHERE output.nocopk IN (
        SELECT DISTINCT link.lots_id
        FROM public._m2m_lots_lots_substrate_inputs link
        WHERE link.lots1_id = ANY(v_returned_substrates)
      )
        AND output.spawned_at = v_ts
        AND (output.use_by IS NULL OR v_preserved_use_by < output.use_by);
    END IF;
  END IF;

  RETURN v_created_count;
END;
$$;

COMMENT ON FUNCTION public.mp_spawn_to_bulk_with_products(
  bigint[], bigint[], bigint[], integer, jsonb, bigint,
  timestamp without time zone, text, text, timestamp without time zone, text, text
) IS
  'Issue #57 atomic Spawn-to-Bulk wrapper. Eligible substrate Products are returned to Lots inside the same transaction, no intermediate substrate labels are queued, and output use-by is capped by preserved packaged-substrate expiration.';

COMMIT;
