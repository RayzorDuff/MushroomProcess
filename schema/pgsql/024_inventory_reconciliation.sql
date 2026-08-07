-- 024_inventory_reconciliation.sql
-- Product inventory reconciliation for GitHub issue #78.
--
-- The Appsmith workflow captures a point-in-time list of products expected at
-- a physical location and a list of products physically found there. This
-- function performs the final reconciliation in one database transaction:
--   * found products currently elsewhere are moved to the reconciled location;
--   * expected products not found are moved to "Missing or Lost" only when
--     they are still assigned to the reconciled location at commit time;
--   * newer location changes are never overwritten;
--   * products in terminal lifecycle states are not silently resurrected;
--   * Shipped-location corrections require an explicit override and notes;
--   * every mutation receives a ProductInventoryReconciled audit event and a
--     summary InventoryReconciliation event is recorded for the operation.

CREATE OR REPLACE FUNCTION public.mp_reconcile_products_location(
  p_location_id bigint,
  p_expected_product_ids bigint[] DEFAULT ARRAY[]::bigint[],
  p_found_product_ids bigint[] DEFAULT ARRAY[]::bigint[],
  p_allow_shipped_correction boolean DEFAULT false,
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
  v_product_id bigint;
  v_product_code text;
  v_current_location_id bigint;
  v_current_location_name text;
  v_current_location_norm text;
  v_tray_state text;
  v_tray_state_norm text;
  v_event_id bigint;
  v_summary_event_id bigint;

  v_expected_count integer := 0;
  v_found_count integer := 0;
  v_already_correct integer := 0;
  v_moved_in integer := 0;
  v_shipped_corrected integer := 0;
  v_marked_missing integer := 0;
  v_skipped_expected integer := 0;

  v_unknown_ids bigint[];
  v_blocked_found text;
  v_shipped_found text;
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
    FROM unnest(COALESCE(p_expected_product_ids, ARRAY[]::bigint[])) AS u(x)
    WHERE u.x IS NOT NULL
  ) AS d;

  SELECT COALESCE(array_agg(x ORDER BY x), ARRAY[]::bigint[])
  INTO v_found
  FROM (
    SELECT DISTINCT u.x
    FROM unnest(COALESCE(p_found_product_ids, ARRAY[]::bigint[])) AS u(x)
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
    -- Lock all products in deterministic order so finalization reads one
    -- coherent current state and cannot race a concurrent product move.
    PERFORM 1
    FROM public.products p
    WHERE p.nocopk = ANY(v_all)
    ORDER BY p.nocopk
    FOR UPDATE;

    SELECT array_agg(u.x ORDER BY u.x)
    INTO v_unknown_ids
    FROM unnest(v_all) AS u(x)
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.products p
      WHERE p.nocopk = u.x
    );

    IF v_unknown_ids IS NOT NULL THEN
      RAISE EXCEPTION 'One or more products no longer exists: %', array_to_string(v_unknown_ids, ', ');
    END IF;
  END IF;

  -- Found products in terminal lifecycle states are blocked. Reconciliation is
  -- intentionally a location correction workflow, not an unconsume/unexpire/
  -- unretire workflow.
  SELECT string_agg(COALESCE(p.product_id, p.nocopk::text), ', ' ORDER BY COALESCE(p.product_id, p.nocopk::text))
  INTO v_blocked_found
  FROM public.products p
  LEFT JOIN public.locations l ON l.nocopk = p.storage_location_id
  WHERE p.nocopk = ANY(v_found)
    AND (
      regexp_replace(lower(btrim(COALESCE(l.name, ''))), '[^a-z0-9]', '', 'g') IN (
        'consumed', 'expired', 'compost', 'retired'
      )
      OR regexp_replace(lower(btrim(COALESCE(p.tray_state, ''))), '[^a-z0-9]', '', 'g') IN (
        'emptytray', 'compost', 'composted', 'spoiled', 'retired', 'expired', 'consumed', 'shipped'
      )
    );

  IF NULLIF(v_blocked_found, '') IS NOT NULL THEN
    RAISE EXCEPTION 'Found product(s) are in terminal lifecycle states and require separate investigation: %', v_blocked_found;
  END IF;

  SELECT string_agg(COALESCE(p.product_id, p.nocopk::text), ', ' ORDER BY COALESCE(p.product_id, p.nocopk::text))
  INTO v_shipped_found
  FROM public.products p
  LEFT JOIN public.locations l ON l.nocopk = p.storage_location_id
  WHERE p.nocopk = ANY(v_found)
    AND regexp_replace(lower(btrim(COALESCE(l.name, ''))), '[^a-z0-9]', '', 'g') = 'shipped';

  IF NULLIF(v_shipped_found, '') IS NOT NULL AND NOT COALESCE(p_allow_shipped_correction, false) THEN
    RAISE EXCEPTION 'Found product(s) are currently recorded as Shipped. Enable shipped correction and provide notes before finalizing: %', v_shipped_found;
  END IF;

  IF NULLIF(v_shipped_found, '') IS NOT NULL
     AND COALESCE(p_allow_shipped_correction, false)
     AND v_notes IS NULL THEN
    RAISE EXCEPTION 'Notes are required when correcting a product currently recorded as Shipped.';
  END IF;

  -- First move every physically found product into the reconciled location.
  FOREACH v_product_id IN ARRAY v_found LOOP
    SELECT
      p.product_id,
      p.storage_location_id,
      l.name,
      regexp_replace(lower(btrim(COALESCE(l.name, ''))), '[^a-z0-9]', '', 'g'),
      p.tray_state,
      regexp_replace(lower(btrim(COALESCE(p.tray_state, ''))), '[^a-z0-9]', '', 'g')
    INTO
      v_product_code,
      v_current_location_id,
      v_current_location_name,
      v_current_location_norm,
      v_tray_state,
      v_tray_state_norm
    FROM public.products p
    LEFT JOIN public.locations l ON l.nocopk = p.storage_location_id
    WHERE p.nocopk = v_product_id;

    IF v_current_location_id = p_location_id THEN
      v_already_correct := v_already_correct + 1;
      CONTINUE;
    END IF;

    PERFORM public.mp_product_set_storage_location(v_product_id, p_location_id);

    IF v_current_location_norm = 'shipped' THEN
      v_shipped_corrected := v_shipped_corrected + 1;
    END IF;
    v_moved_in := v_moved_in + 1;

    v_event_id := public.mp_events_insert(
      p_lot_id => NULL::bigint,
      p_product_id => v_product_id,
      p_type => 'ProductInventoryReconciled',
      p_timestamp => v_timestamp,
      p_operator => v_operator,
      p_station => v_station,
      p_fields_json => jsonb_build_object(
        'action', CASE WHEN v_current_location_norm = 'shipped' THEN 'correct_shipped_to_found_location' ELSE 'move_found_to_location' END,
        'workflow', 'mp_reconcile_products_location',
        'reconciliation_id', v_reconciliation_id,
        'product_nocopk', v_product_id,
        'product_id', v_product_code,
        'previous_storage_location_id', v_current_location_id,
        'previous_storage_location', v_current_location_name,
        'new_storage_location_id', p_location_id,
        'new_storage_location', v_target_name,
        'tray_state', v_tray_state,
        'operator', v_operator,
        'notes', v_notes
      )
    );
    PERFORM public.mp_events_link_product(v_event_id, v_product_id);

    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'product_nocopk', v_product_id,
      'product_id', v_product_code,
      'action', CASE WHEN v_current_location_norm = 'shipped' THEN 'Correct Shipped' ELSE 'Move Found' END,
      'from_location_id', v_current_location_id,
      'from_location', v_current_location_name,
      'to_location_id', p_location_id,
      'to_location', v_target_name
    ));
  END LOOP;

  -- Then move snapshot products that were not physically found to Missing or
  -- Lost, but only if they are STILL assigned to the reconciled location.
  -- Anything changed by a newer workflow since the snapshot is skipped.
  FOREACH v_product_id IN ARRAY v_expected LOOP
    IF v_product_id = ANY(v_found) THEN
      CONTINUE;
    END IF;

    SELECT
      p.product_id,
      p.storage_location_id,
      l.name,
      regexp_replace(lower(btrim(COALESCE(l.name, ''))), '[^a-z0-9]', '', 'g'),
      p.tray_state,
      regexp_replace(lower(btrim(COALESCE(p.tray_state, ''))), '[^a-z0-9]', '', 'g')
    INTO
      v_product_code,
      v_current_location_id,
      v_current_location_name,
      v_current_location_norm,
      v_tray_state,
      v_tray_state_norm
    FROM public.products p
    LEFT JOIN public.locations l ON l.nocopk = p.storage_location_id
    WHERE p.nocopk = v_product_id;

    IF v_current_location_id <> p_location_id OR v_current_location_id IS NULL THEN
      v_skipped_expected := v_skipped_expected + 1;
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
        'product_nocopk', v_product_id,
        'product_id', v_product_code,
        'reason', 'location_changed_after_snapshot',
        'snapshot_location_id', p_location_id,
        'current_location_id', v_current_location_id,
        'current_location', v_current_location_name
      ));
      CONTINUE;
    END IF;

    IF v_tray_state_norm IN ('emptytray', 'compost', 'composted', 'spoiled', 'retired', 'expired', 'consumed', 'shipped') THEN
      v_skipped_expected := v_skipped_expected + 1;
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
        'product_nocopk', v_product_id,
        'product_id', v_product_code,
        'reason', 'terminal_tray_state_after_snapshot',
        'snapshot_location_id', p_location_id,
        'current_location_id', v_current_location_id,
        'current_location', v_current_location_name,
        'tray_state', v_tray_state
      ));
      CONTINUE;
    END IF;

    PERFORM public.mp_product_set_storage_location(v_product_id, v_missing_id);
    v_marked_missing := v_marked_missing + 1;

    v_event_id := public.mp_events_insert(
      p_lot_id => NULL::bigint,
      p_product_id => v_product_id,
      p_type => 'ProductInventoryReconciled',
      p_timestamp => v_timestamp,
      p_operator => v_operator,
      p_station => v_station,
      p_fields_json => jsonb_build_object(
        'action', 'mark_missing',
        'workflow', 'mp_reconcile_products_location',
        'reconciliation_id', v_reconciliation_id,
        'product_nocopk', v_product_id,
        'product_id', v_product_code,
        'previous_storage_location_id', p_location_id,
        'previous_storage_location', v_target_name,
        'new_storage_location_id', v_missing_id,
        'new_storage_location', v_missing_name,
        'tray_state', v_tray_state,
        'operator', v_operator,
        'notes', v_notes
      )
    );
    PERFORM public.mp_events_link_product(v_event_id, v_product_id);

    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'product_nocopk', v_product_id,
      'product_id', v_product_code,
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
      'workflow', 'mp_reconcile_products_location',
      'reconciliation_id', v_reconciliation_id,
      'target_location_id', p_location_id,
      'target_location', v_target_name,
      'missing_location_id', v_missing_id,
      'missing_location', v_missing_name,
      'expected_product_ids', to_jsonb(v_expected),
      'found_product_ids', to_jsonb(v_found),
      'expected_count', v_expected_count,
      'found_count', v_found_count,
      'already_correct_count', v_already_correct,
      'moved_in_count', v_moved_in,
      'shipped_corrected_count', v_shipped_corrected,
      'marked_missing_count', v_marked_missing,
      'skipped_expected_count', v_skipped_expected,
      'changes', v_changes,
      'skipped', v_skipped,
      'allow_shipped_correction', COALESCE(p_allow_shipped_correction, false),
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
  shipped_corrected_count := v_shipped_corrected;
  marked_missing_count := v_marked_missing;
  skipped_expected_count := v_skipped_expected;
  changes_json := v_changes;
  skipped_json := v_skipped;

  RETURN NEXT;
END;
$$;
