\set ON_ERROR_STOP on

-- 048_product_inoculate_product_target_storage.sql
-- Product-backed inoculation targets must receive the selected inoculation
-- storage location when they are returned to Lot inventory.  The packaged
-- Product may legitimately have no storage_location_id.
--
-- The returned target Lot is immediately consumed by the same inoculation
-- operation, so this migration supplies the destination location before the
-- call to mp_lots_inoculate_multiple_result().

BEGIN;

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
SET TimeZone TO 'America/Denver'
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
      -- A Product grain is returned directly into the same destination that
      -- the inoculation operation will use. This is required even when the
      -- packaged Product itself has no storage_location_id.
      p_storage_location_id => p_storage_location_id
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
  'Issue #57 atomic inoculation wrapper. Accepts Lot/Product source and target inventory, deproductizes eligible Products transactionally, returns Product targets at the selected inoculation storage location, caps returned-grain expiration, and prints a replacement LC syringe Lot label only when source volume remains.';

COMMIT;