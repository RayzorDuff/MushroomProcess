\set ON_ERROR_STOP on

-- Transactional smoke test for Lot inventory reconciliation, GitHub #78.
-- Run after 005_helpers.sql, 024_inventory_reconciliation.sql, and
-- 025_inventory_reconciliation_lots.sql. All fixtures and outputs are rolled back.
BEGIN;

DO $$
DECLARE
  v_target_id bigint;
  v_other_id bigint;
  v_missing_id bigint;
  v_consumed_id bigint;

  v_correct_id bigint;
  v_missing_expected_id bigint;
  v_elsewhere_id bigint;
  v_restore_missing_id bigint;
  v_concurrent_id bigint;
  v_terminal_expected_id bigint;
  v_terminal_found_id bigint;

  v_result record;
  v_failed boolean := false;
  v_summary_fields jsonb;
BEGIN
  INSERT INTO public.locations(name, active, type, notes)
  VALUES ('RC78 Lot Reconcile Target', true, 'test', 'Rollback-only Lot reconciliation fixture')
  RETURNING nocopk INTO v_target_id;

  INSERT INTO public.locations(name, active, type, notes)
  VALUES ('RC78 Lot Other Location', true, 'test', 'Rollback-only Lot reconciliation fixture')
  RETURNING nocopk INTO v_other_id;

  SELECT nocopk INTO v_missing_id
  FROM public.locations
  WHERE regexp_replace(lower(btrim(COALESCE(name, ''))), '[^a-z0-9]', '', 'g') = 'missingorlost'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  SELECT nocopk INTO v_consumed_id
  FROM public.locations
  WHERE regexp_replace(lower(btrim(COALESCE(name, ''))), '[^a-z0-9]', '', 'g') = 'consumed'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  IF v_missing_id IS NULL OR v_consumed_id IS NULL THEN
    RAISE EXCEPTION 'Lot reconciliation smoke test requires Missing or Lost and Consumed locations.';
  END IF;

  INSERT INTO public.lots(lot_id, item_name_mat, item_category_mat, status, location_id, notes)
  VALUES ('LOT-RC78-CORRECT', 'RC78 Lot Correct', 'test_lot', 'Colonizing', v_target_id, 'RC78 fixture')
  RETURNING nocopk INTO v_correct_id;

  INSERT INTO public.lots(lot_id, item_name_mat, item_category_mat, status, location_id, notes)
  VALUES ('LOT-RC78-MISSING', 'RC78 Lot Missing', 'test_lot', 'Colonizing', v_target_id, 'RC78 fixture')
  RETURNING nocopk INTO v_missing_expected_id;

  INSERT INTO public.lots(lot_id, item_name_mat, item_category_mat, status, location_id, notes)
  VALUES ('LOT-RC78-ELSEWHERE', 'RC78 Lot Elsewhere', 'test_lot', 'Colonizing', v_other_id, 'RC78 fixture')
  RETURNING nocopk INTO v_elsewhere_id;

  INSERT INTO public.lots(lot_id, item_name_mat, item_category_mat, status, location_id, notes)
  VALUES ('LOT-RC78-RESTORE', 'RC78 Lot Restore', 'test_lot', 'Colonizing', v_missing_id, 'RC78 fixture')
  RETURNING nocopk INTO v_restore_missing_id;

  INSERT INTO public.lots(lot_id, item_name_mat, item_category_mat, status, location_id, notes)
  VALUES ('LOT-RC78-CONCURRENT', 'RC78 Lot Concurrent', 'test_lot', 'Colonizing', v_target_id, 'RC78 fixture')
  RETURNING nocopk INTO v_concurrent_id;

  INSERT INTO public.lots(lot_id, item_name_mat, item_category_mat, status, location_id, notes)
  VALUES ('LOT-RC78-TERMINAL-EXPECTED', 'RC78 Lot Terminal Expected', 'test_lot', 'Retired', v_target_id, 'RC78 fixture')
  RETURNING nocopk INTO v_terminal_expected_id;

  INSERT INTO public.lots(lot_id, item_name_mat, item_category_mat, status, location_id, notes)
  VALUES ('LOT-RC78-TERMINAL-FOUND', 'RC78 Lot Terminal Found', 'test_lot', 'Consumed', v_consumed_id, 'RC78 fixture')
  RETURNING nocopk INTO v_terminal_found_id;

  -- Synchronize scalar and legacy relationship rows before exercising the helper.
  PERFORM public.mp_lot_set_location(v_correct_id, v_target_id);
  PERFORM public.mp_lot_set_location(v_missing_expected_id, v_target_id);
  PERFORM public.mp_lot_set_location(v_elsewhere_id, v_other_id);
  PERFORM public.mp_lot_set_location(v_restore_missing_id, v_missing_id);
  PERFORM public.mp_lot_set_location(v_concurrent_id, v_target_id);
  PERFORM public.mp_lot_set_location(v_terminal_expected_id, v_target_id);
  PERFORM public.mp_lot_set_location(v_terminal_found_id, v_consumed_id);

  -- Simulate a legitimate newer workflow after Appsmith captured the snapshot.
  PERFORM public.mp_lot_set_location(v_concurrent_id, v_other_id);

  SELECT * INTO v_result
  FROM public.mp_reconcile_lots_location(
    p_location_id => v_target_id,
    p_expected_lot_ids => ARRAY[v_correct_id, v_missing_expected_id, v_concurrent_id, v_terminal_expected_id],
    p_found_lot_ids => ARRAY[v_correct_id, v_elsewhere_id, v_restore_missing_id, v_elsewhere_id],
    p_operator => 'RC78 Lot inventory reconciliation smoke test',
    p_station => 'Inventory Reconcile',
    p_notes => 'Main Lot reconciliation smoke path'
  );

  IF v_result.expected_count <> 4
     OR v_result.found_count <> 3
     OR v_result.already_correct_count <> 1
     OR v_result.moved_in_count <> 2
     OR v_result.shipped_corrected_count <> 0
     OR v_result.marked_missing_count <> 1
     OR v_result.skipped_expected_count <> 2 THEN
    RAISE EXCEPTION 'Unexpected Lot reconciliation counts: %', row_to_json(v_result);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.lots
    WHERE nocopk = v_correct_id AND location_id = v_target_id
  ) THEN
    RAISE EXCEPTION 'Expected-and-found Lot moved unexpectedly.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.lots
    WHERE nocopk = v_missing_expected_id AND location_id = v_missing_id
  ) THEN
    RAISE EXCEPTION 'Expected-but-not-found Lot did not move to Missing or Lost.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.lots
    WHERE nocopk IN (v_elsewhere_id, v_restore_missing_id)
      AND location_id = v_target_id
    GROUP BY location_id
    HAVING count(*) = 2
  ) THEN
    RAISE EXCEPTION 'Found Lots from another/Missing location did not move to the target.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.lots
    WHERE nocopk = v_concurrent_id AND location_id = v_other_id
  ) THEN
    RAISE EXCEPTION 'A newer post-snapshot Lot move was overwritten.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.lots
    WHERE nocopk = v_terminal_expected_id AND location_id = v_target_id AND status = 'Retired'
  ) THEN
    RAISE EXCEPTION 'Terminal expected Lot should have been skipped rather than moved to Missing or Lost.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public._m2m_lots_locations_location_id m
    WHERE m.lots_id = v_missing_expected_id
      AND m.locations_id = v_missing_id
  ) OR NOT EXISTS (
    SELECT 1
    FROM public._m2m_lots_locations_location_id m
    WHERE m.lots_id = v_elsewhere_id
      AND m.locations_id = v_target_id
  ) THEN
    RAISE EXCEPTION 'Lot reconciliation did not synchronize Lot-location relationship rows.';
  END IF;

  IF jsonb_array_length(v_result.changes_json) <> 3
     OR jsonb_array_length(v_result.skipped_json) <> 2 THEN
    RAISE EXCEPTION 'Unexpected Lot changes/skipped JSON payload: changes %, skipped %', v_result.changes_json, v_result.skipped_json;
  END IF;

  SELECT e.fields_json::jsonb
  INTO v_summary_fields
  FROM public.events e
  WHERE e.nocopk = v_result.summary_event_id;

  IF v_summary_fields ->> 'workflow' <> 'mp_reconcile_lots_location'
     OR v_summary_fields ->> 'scope' <> 'Lots'
     OR v_summary_fields ->> 'reconciliation_id' <> v_result.reconciliation_id
     OR (v_summary_fields ->> 'marked_missing_count')::integer <> 1
     OR (v_summary_fields ->> 'skipped_expected_count')::integer <> 2 THEN
    RAISE EXCEPTION 'Lot InventoryReconciliation summary event is incomplete: %', v_summary_fields;
  END IF;

  IF (
    SELECT count(*)
    FROM public.events e
    WHERE e.operator = 'RC78 Lot inventory reconciliation smoke test'
      AND e.type = 'LotInventoryReconciled'
      AND e.fields_json::jsonb ->> 'reconciliation_id' = v_result.reconciliation_id
  ) <> 3 THEN
    RAISE EXCEPTION 'Expected one LotInventoryReconciled event for each changed Lot.';
  END IF;

  -- A physically found terminal Lot must remain blocked.
  BEGIN
    PERFORM public.mp_reconcile_lots_location(
      p_location_id => v_target_id,
      p_expected_lot_ids => ARRAY[]::bigint[],
      p_found_lot_ids => ARRAY[v_terminal_found_id],
      p_operator => 'RC78 Lot terminal guard smoke test',
      p_station => 'Inventory Reconcile',
      p_notes => 'Terminal Lot guard'
    );
  EXCEPTION WHEN OTHERS THEN
    v_failed := true;
  END;

  IF NOT v_failed OR NOT EXISTS (
    SELECT 1 FROM public.lots
    WHERE nocopk = v_terminal_found_id
      AND location_id = v_consumed_id
      AND status = 'Consumed'
  ) THEN
    RAISE EXCEPTION 'Terminal lifecycle Lot was incorrectly resurrected by reconciliation.';
  END IF;

  RAISE NOTICE 'Issue #78 Lot inventory reconciliation smoke tests passed.';
END;
$$;

ROLLBACK;
