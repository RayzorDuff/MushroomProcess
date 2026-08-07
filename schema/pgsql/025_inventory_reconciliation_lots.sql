-- 025_inventory_reconciliation_lots.sql
-- Lot inventory reconciliation for GitHub issue #78.
--
-- This is the lot counterpart to mp_reconcile_products_location() from 024.
-- The Appsmith Inventory - Reconcile page can reconcile Products and Lots in
-- the same physical-location session. The final Appsmith query invokes both
-- functions in one PostgreSQL statement, so either both scopes commit or the
-- entire reconciliation rolls back.
--
-- Lot rules:
--   * physically found lots currently elsewhere move to the reconciled location;
--   * snapshot lots not found move to "Missing or Lost" only if they are still
--     assigned to the reconciled location at commit time;
--   * newer lot-location changes are preserved and reported as skipped;
--   * terminal lot locations/statuses are never silently resurrected;
--   * every lot mutation receives a LotInventoryReconciled event and the lot
--     scope receives an InventoryReconciliation summary event.

CREATE OR REPLACE FUNCTION public.mp_reconcile_lots_location(
  p_location_id bigint,
  p_expected_lot_ids bigint[] DEFAULT ARRAY[]::bigint[],
  p_found_lot_ids bigint[] DEFAULT ARRAY[]::bigint[],
  p_operator text DEFAULT 'system',
  p_station text DEFAULT 'Inventory Reconcile',
  p_notes text DEFAULT NULL,
  p_timestamp timestamp without time zone DEFAULT NULL
)
RETURNS TABLE(
  reconciliation_id text,
  summary_event_id bigint,
  target_location_id bigint,
  target_location text,
  missing_location_id bigint,
  missing_location text,
  expected_count integer,
  found_count integer,
  already_correct_count integer,
  moved_in_count integer,
  shipped_corrected_count integer,
  marked_missing_count integer,
  skipped_expected_count integer,
  changes_json jsonb,
  skipped_json jsonb
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_reconciliation_id text := gen_random_uuid()::text;
  v_timestamp timestamp without time zone := COALESCE(p_timestamp, clock_timestamp()::timestamp without time zone);
  v_operator text := COALESCE(NULLIF(btrim(p_operator), ''), 'system');
  v_station text := COALESCE(NULLIF(btrim(p_station), ''), 'Inventory Reconcile');
  v_notes text := NULLIF(btrim(COALESCE(p_notes, '')), '');

  v_target_name text;
  v_target_name_norm text;
  v_missing_id bigint;
  v_missing_name text;

  v_expected bigint[] := ARRAY[]::bigint[];
  v_found bigint[] := ARRAY[]::bigint[];
  v_all bigint[] := ARRAY[]::bigint[];
  v_lot_nocopk bigint;
  v_lot_code text;
  v_current_location_id bigint;
  v_current_location_name text;
  v_current_location_norm text;
  v_status text;
  v_status_norm text;
  v_event_id bigint;
  v_summary_event_id bigint;

  v_expected_count integer := 0;
  v_found_count integer := 0;
  v_already_correct integer := 0;
  v_moved_in integer := 0;
  v_marked_missing integer := 0;
  v_skipped_expected integer := 0;

  v_unknown_ids bigint[];
  v_blocked_found text;
  v_changes jsonb := '[]'::jsonb;
  v_skipped jsonb := '[]'::jsonb;
BEGIN
  IF p_location_id IS NULL THEN
    RAISE EXCEPTION 'Select a storage location before finalizing reconciliation.';
  END IF;

  SELECT l.name
  INTO v_target_name
  FROM public.locations l
  WHERE l.nocopk = p_location_id
  FOR UPDATE;

  IF v_target_name IS NULL THEN
    RAISE EXCEPTION 'Storage location not found for nocopk: %', p_location_id;
  END IF;

  v_target_name_norm := regexp_replace(lower(btrim(v_target_name)), '[^a-z0-9]', '', 'g');

  IF v_target_name_norm IN ('missingorlost', 'shipped', 'consumed', 'expired', 'compost', 'retired') THEN
    RAISE EXCEPTION 'Location "%" is a terminal/exception location and cannot be reconciled as a physical inventory location.', v_target_name;
  END IF;

  SELECT l.nocopk, l.name
  INTO v_missing_id, v_missing_name
  FROM public.locations l
  WHERE regexp_replace(lower(btrim(COALESCE(l.name, ''))), '[^a-z0-9]', '', 'g') = 'missingorlost'
  ORDER BY CASE WHEN COALESCE(l.active, false) THEN 0 ELSE 1 END, l.nocopk
  LIMIT 1;

  IF v_missing_id IS NULL THEN
    RAISE EXCEPTION 'The required "Missing or Lost" location was not found.';
  END IF;

  SELECT COALESCE(array_agg(x ORDER BY x), ARRAY[]::bigint[])
  INTO v_expected
  FROM (
    SELECT DISTINCT u.x
    FROM unnest(COALESCE(p_expected_lot_ids, ARRAY[]::bigint[])) AS u(x)
    WHERE u.x IS NOT NULL
  ) AS d;

  SELECT COALESCE(array_agg(x ORDER BY x), ARRAY[]::bigint[])
  INTO v_found
  FROM (
    SELECT DISTINCT u.x
    FROM unnest(COALESCE(p_found_lot_ids, ARRAY[]::bigint[])) AS u(x)
    WHERE u.x IS NOT NULL
  ) AS d;

  SELECT COALESCE(array_agg(x ORDER BY x), ARRAY[]::bigint[])
  INTO v_all
  FROM (
    SELECT DISTINCT u.x
    FROM unnest(v_expected || v_found) AS u(x)
    WHERE u.x IS NOT NULL
  ) AS d;

  v_expected_count := cardinality(v_expected);
  v_found_count := cardinality(v_found);

  IF cardinality(v_all) > 0 THEN
    -- Lock all lots in deterministic order so the final reconciliation reads
    -- one coherent current state and cannot race another lot-location move.
    PERFORM 1
    FROM public.lots l
    WHERE l.nocopk = ANY(v_all)
    ORDER BY l.nocopk
    FOR UPDATE;

    SELECT array_agg(u.x ORDER BY u.x)
    INTO v_unknown_ids
    FROM unnest(v_all) AS u(x)
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.lots l
      WHERE l.nocopk = u.x
    );

    IF v_unknown_ids IS NOT NULL THEN
      RAISE EXCEPTION 'One or more lots no longer exists: %', array_to_string(v_unknown_ids, ', ');
    END IF;
  END IF;

  -- Reconciliation corrects physical location only. A lot already recorded in
  -- a terminal lifecycle state/location requires a lifecycle correction rather
  -- than being silently restored by inventory reconciliation.
  SELECT string_agg(COALESCE(lot.lot_id, lot.nocopk::text), ', ' ORDER BY COALESCE(lot.lot_id, lot.nocopk::text))
  INTO v_blocked_found
  FROM public.lots lot
  LEFT JOIN public.locations loc ON loc.nocopk = lot.location_id
  WHERE lot.nocopk = ANY(v_found)
    AND (
      regexp_replace(lower(btrim(COALESCE(loc.name, ''))), '[^a-z0-9]', '', 'g') IN (
        'shipped', 'consumed', 'expired', 'compost', 'retired'
      )
      OR regexp_replace(lower(btrim(COALESCE(lot.status, ''))), '[^a-z0-9]', '', 'g') IN (
        'consumed', 'retired', 'expired', 'compost', 'composted'
      )
    );

  IF NULLIF(v_blocked_found, '') IS NOT NULL THEN
    RAISE EXCEPTION 'Found lot(s) are in terminal lifecycle states and require separate investigation: %', v_blocked_found;
  END IF;

  -- First move every physically found lot into the reconciled location.
  FOREACH v_lot_nocopk IN ARRAY v_found LOOP
    SELECT
      lot.lot_id,
      lot.location_id,
      loc.name,
      regexp_replace(lower(btrim(COALESCE(loc.name, ''))), '[^a-z0-9]', '', 'g'),
      lot.status,
      regexp_replace(lower(btrim(COALESCE(lot.status, ''))), '[^a-z0-9]', '', 'g')
    INTO
      v_lot_code,
      v_current_location_id,
      v_current_location_name,
      v_current_location_norm,
      v_status,
      v_status_norm
    FROM public.lots lot
    LEFT JOIN public.locations loc ON loc.nocopk = lot.location_id
    WHERE lot.nocopk = v_lot_nocopk;

    IF v_current_location_id = p_location_id THEN
      v_already_correct := v_already_correct + 1;
      CONTINUE;
    END IF;

    PERFORM public.mp_lot_set_location(v_lot_nocopk, p_location_id);
    v_moved_in := v_moved_in + 1;

    v_event_id := public.mp_events_insert(
      p_lot_id => v_lot_nocopk,
      p_product_id => NULL::bigint,
      p_type => 'LotInventoryReconciled',
      p_timestamp => v_timestamp,
      p_operator => v_operator,
      p_station => v_station,
      p_fields_json => jsonb_build_object(
        'action', 'move_found_to_location',
        'workflow', 'mp_reconcile_lots_location',
        'reconciliation_id', v_reconciliation_id,
        'lot_nocopk', v_lot_nocopk,
        'lot_id', v_lot_code,
        'previous_location_id', v_current_location_id,
        'previous_location', v_current_location_name,
        'new_location_id', p_location_id,
        'new_location', v_target_name,
        'status', v_status,
        'operator', v_operator,
        'notes', v_notes
      )
    );
    PERFORM public.mp_events_link_lot(v_event_id, v_lot_nocopk);

    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'inventory_type', 'Lot',
      'lot_nocopk', v_lot_nocopk,
      'lot_id', v_lot_code,
      'inventory_id', v_lot_code,
      'action', 'Move Found',
      'from_location_id', v_current_location_id,
      'from_location', v_current_location_name,
      'to_location_id', p_location_id,
      'to_location', v_target_name
    ));
  END LOOP;

  -- Then move snapshot lots not physically found to Missing or Lost, but only
  -- when they are STILL assigned to the reconciled location. Newer workflow
  -- changes and terminal lifecycle changes are preserved rather than overwritten.
  FOREACH v_lot_nocopk IN ARRAY v_expected LOOP
    IF v_lot_nocopk = ANY(v_found) THEN
      CONTINUE;
    END IF;

    SELECT
      lot.lot_id,
      lot.location_id,
      loc.name,
      regexp_replace(lower(btrim(COALESCE(loc.name, ''))), '[^a-z0-9]', '', 'g'),
      lot.status,
      regexp_replace(lower(btrim(COALESCE(lot.status, ''))), '[^a-z0-9]', '', 'g')
    INTO
      v_lot_code,
      v_current_location_id,
      v_current_location_name,
      v_current_location_norm,
      v_status,
      v_status_norm
    FROM public.lots lot
    LEFT JOIN public.locations loc ON loc.nocopk = lot.location_id
    WHERE lot.nocopk = v_lot_nocopk;

    IF v_current_location_id <> p_location_id OR v_current_location_id IS NULL THEN
      v_skipped_expected := v_skipped_expected + 1;
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
        'inventory_type', 'Lot',
        'lot_nocopk', v_lot_nocopk,
        'lot_id', v_lot_code,
        'inventory_id', v_lot_code,
        'reason', 'location_changed_after_snapshot',
        'snapshot_location_id', p_location_id,
        'current_location_id', v_current_location_id,
        'current_location', v_current_location_name,
        'status', v_status
      ));
      CONTINUE;
    END IF;

    IF v_status_norm IN ('consumed', 'retired', 'expired', 'compost', 'composted') THEN
      v_skipped_expected := v_skipped_expected + 1;
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
        'inventory_type', 'Lot',
        'lot_nocopk', v_lot_nocopk,
        'lot_id', v_lot_code,
        'inventory_id', v_lot_code,
        'reason', 'terminal_status_after_snapshot',
        'snapshot_location_id', p_location_id,
        'current_location_id', v_current_location_id,
        'current_location', v_current_location_name,
        'status', v_status
      ));
      CONTINUE;
    END IF;

    PERFORM public.mp_lot_set_location(v_lot_nocopk, v_missing_id);
    v_marked_missing := v_marked_missing + 1;

    v_event_id := public.mp_events_insert(
      p_lot_id => v_lot_nocopk,
      p_product_id => NULL::bigint,
      p_type => 'LotInventoryReconciled',
      p_timestamp => v_timestamp,
      p_operator => v_operator,
      p_station => v_station,
      p_fields_json => jsonb_build_object(
        'action', 'mark_missing',
        'workflow', 'mp_reconcile_lots_location',
        'reconciliation_id', v_reconciliation_id,
        'lot_nocopk', v_lot_nocopk,
        'lot_id', v_lot_code,
        'previous_location_id', p_location_id,
        'previous_location', v_target_name,
        'new_location_id', v_missing_id,
        'new_location', v_missing_name,
        'status', v_status,
        'operator', v_operator,
        'notes', v_notes
      )
    );
    PERFORM public.mp_events_link_lot(v_event_id, v_lot_nocopk);

    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'inventory_type', 'Lot',
      'lot_nocopk', v_lot_nocopk,
      'lot_id', v_lot_code,
      'inventory_id', v_lot_code,
      'action', 'Mark Missing',
      'from_location_id', p_location_id,
      'from_location', v_target_name,
      'to_location_id', v_missing_id,
      'to_location', v_missing_name
    ));
  END LOOP;

  v_summary_event_id := public.mp_events_insert(
    p_lot_id => NULL::bigint,
    p_product_id => NULL::bigint,
    p_type => 'InventoryReconciliation',
    p_timestamp => v_timestamp,
    p_operator => v_operator,
    p_station => v_station,
    p_fields_json => jsonb_build_object(
      'scope', 'Lots',
      'workflow', 'mp_reconcile_lots_location',
      'reconciliation_id', v_reconciliation_id,
      'target_location_id', p_location_id,
      'target_location', v_target_name,
      'missing_location_id', v_missing_id,
      'missing_location', v_missing_name,
      'expected_lot_ids', to_jsonb(v_expected),
      'found_lot_ids', to_jsonb(v_found),
      'expected_count', v_expected_count,
      'found_count', v_found_count,
      'already_correct_count', v_already_correct,
      'moved_in_count', v_moved_in,
      'shipped_corrected_count', 0,
      'marked_missing_count', v_marked_missing,
      'skipped_expected_count', v_skipped_expected,
      'changes', v_changes,
      'skipped', v_skipped,
      'operator', v_operator,
      'notes', v_notes
    )
  );

  reconciliation_id := v_reconciliation_id;
  summary_event_id := v_summary_event_id;
  target_location_id := p_location_id;
  target_location := v_target_name;
  missing_location_id := v_missing_id;
  missing_location := v_missing_name;
  expected_count := v_expected_count;
  found_count := v_found_count;
  already_correct_count := v_already_correct;
  moved_in_count := v_moved_in;
  shipped_corrected_count := 0;
  marked_missing_count := v_marked_missing;
  skipped_expected_count := v_skipped_expected;
  changes_json := v_changes;
  skipped_json := v_skipped;

  RETURN NEXT;
END;
$$;
