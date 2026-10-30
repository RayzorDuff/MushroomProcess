-- 047_product_spawn_storage_fallback.sql
-- Issue #57: Product-backed Spawn-to-Bulk must provide a storage location
-- for the temporary returned substrate Lot even when the packaged Product
-- has no storage_location_id.

SET search_path = public, pg_catalog;

BEGIN;

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
  v_return_storage_location_id bigint;
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

  -- A returned substrate Lot is an intermediate production record and must
  -- have a real active location. Prefer the selected Spawn-to-Bulk location;
  -- otherwise use the same Dark Room default as the underlying operation.
  -- This intentionally does not require the packaged Product itself to have
  -- a storage_location_id: older/market inventory may lack that field.
  v_return_storage_location_id := COALESCE(
    p_storage_location_id,
    (
      SELECT l.nocopk
      FROM public.locations l
      WHERE COALESCE(l.active, false)
        AND regexp_replace(lower(btrim(l.name)), '[^a-z0-9]', '', 'g') = 'darkroom'
      ORDER BY l.nocopk
      LIMIT 1
    )
  );

  IF v_return_storage_location_id IS NULL THEN
    RAISE EXCEPTION 'A storage location is required for Product-backed Spawn-to-Bulk substrate return; no active Dark Room location was found.';
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
      p_storage_location_id => v_return_storage_location_id
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
  'Issue #57 atomic Spawn-to-Bulk wrapper. Product-backed substrate returns use the selected Spawn-to-Bulk storage location, falling back to active Dark Room when the Product has no storage location. No intermediate substrate labels are queued.';

COMMIT;
