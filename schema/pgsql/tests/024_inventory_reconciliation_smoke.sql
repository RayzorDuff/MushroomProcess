\set ON_ERROR_STOP on

-- Transactional smoke test for product inventory reconciliation, GitHub #78.
-- Run after 005_helpers.sql, 008_lot_actions.sql, and
-- 024_inventory_reconciliation.sql. All fixtures and outputs are rolled back.
BEGIN;

DO $$
DECLARE
  v_target_id bigint;
  v_other_id bigint;
  v_missing_id bigint;
  v_shipped_id bigint;
  v_consumed_id bigint;

  v_correct_id bigint;
  v_missing_expected_id bigint;
  v_elsewhere_id bigint;
  v_restore_missing_id bigint;
  v_concurrent_id bigint;
  v_shipped_product_id bigint;
  v_terminal_product_id bigint;

  v_result record;
  v_failed boolean;
  v_summary_fields jsonb;
BEGIN
  INSERT INTO public.locations(name, active, type, notes)
  VALUES ('RC78 Reconcile Target', true, 'test', 'Rollback-only inventory reconciliation fixture')
  RETURNING nocopk INTO v_target_id;

  INSERT INTO public.locations(name, active, type, notes)
  VALUES ('RC78 Other Location', true, 'test', 'Rollback-only inventory reconciliation fixture')
  RETURNING nocopk INTO v_other_id;

  SELECT nocopk INTO v_missing_id
  FROM public.locations
  WHERE regexp_replace(lower(btrim(COALESCE(name, ''))), '[^a-z0-9]', '', 'g') = 'missingorlost'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  SELECT nocopk INTO v_shipped_id
  FROM public.locations
  WHERE regexp_replace(lower(btrim(COALESCE(name, ''))), '[^a-z0-9]', '', 'g') = 'shipped'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  SELECT nocopk INTO v_consumed_id
  FROM public.locations
  WHERE regexp_replace(lower(btrim(COALESCE(name, ''))), '[^a-z0-9]', '', 'g') = 'consumed'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  IF v_missing_id IS NULL OR v_shipped_id IS NULL OR v_consumed_id IS NULL THEN
    RAISE EXCEPTION 'Inventory reconciliation smoke test requires Missing or Lost, Shipped, and Consumed locations.';
  END IF;

  INSERT INTO public.products(product_id, name_mat, item_category_mat, storage_location_id, notes)
  VALUES ('PROD-RC78-CORRECT', 'RC78 Correct', 'test_product', v_target_id, 'RC78 fixture')
  RETURNING nocopk INTO v_correct_id;

  INSERT INTO public.products(product_id, name_mat, item_category_mat, storage_location_id, notes)
  VALUES ('PROD-RC78-MISSING', 'RC78 Missing', 'test_product', v_target_id, 'RC78 fixture')
  RETURNING nocopk INTO v_missing_expected_id;

  INSERT INTO public.products(product_id, name_mat, item_category_mat, storage_location_id, notes)
  VALUES ('PROD-RC78-ELSEWHERE', 'RC78 Elsewhere', 'test_product', v_other_id, 'RC78 fixture')
  RETURNING nocopk INTO v_elsewhere_id;

  INSERT INTO public.products(product_id, name_mat, item_category_mat, storage_location_id, notes)
  VALUES ('PROD-RC78-RESTORE', 'RC78 Restore', 'test_product', v_missing_id, 'RC78 fixture')
  RETURNING nocopk INTO v_restore_missing_id;

  INSERT INTO public.products(product_id, name_mat, item_category_mat, storage_location_id, notes)
  VALUES ('PROD-RC78-CONCURRENT', 'RC78 Concurrent', 'test_product', v_target_id, 'RC78 fixture')
  RETURNING nocopk INTO v_concurrent_id;

  INSERT INTO public.products(product_id, name_mat, item_category_mat, storage_location_id, notes)
  VALUES ('PROD-RC78-SHIPPED', 'RC78 Shipped', 'test_product', v_shipped_id, 'RC78 fixture')
  RETURNING nocopk INTO v_shipped_product_id;

  INSERT INTO public.products(product_id, name_mat, item_category_mat, storage_location_id, notes)
  VALUES ('PROD-RC78-TERMINAL', 'RC78 Terminal', 'test_product', v_consumed_id, 'RC78 fixture')
  RETURNING nocopk INTO v_terminal_product_id;

  -- Ensure the Airtable/NocoDB-compatible location link tables are synchronized
  -- before exercising the reconciliation helper.
  PERFORM public.mp_product_set_storage_location(v_correct_id, v_target_id);
  PERFORM public.mp_product_set_storage_location(v_missing_expected_id, v_target_id);
  PERFORM public.mp_product_set_storage_location(v_elsewhere_id, v_other_id);
  PERFORM public.mp_product_set_storage_location(v_restore_missing_id, v_missing_id);
  PERFORM public.mp_product_set_storage_location(v_concurrent_id, v_target_id);
  PERFORM public.mp_product_set_storage_location(v_shipped_product_id, v_shipped_id);
  PERFORM public.mp_product_set_storage_location(v_terminal_product_id, v_consumed_id);

  -- Simulate a legitimate newer workflow after Appsmith captured the snapshot.
  PERFORM public.mp_product_set_storage_location(v_concurrent_id, v_other_id);

  SELECT * INTO v_result
  FROM public.mp_reconcile_products_location(
    p_location_id => v_target_id,
    p_expected_product_ids => ARRAY[v_correct_id, v_missing_expected_id, v_concurrent_id],
    p_found_product_ids => ARRAY[v_correct_id, v_elsewhere_id, v_restore_missing_id, v_elsewhere_id],
    p_allow_shipped_correction => false,
    p_operator => 'RC78 inventory reconciliation smoke test',
    p_station => 'Inventory Reconcile',
    p_notes => 'Main reconciliation smoke path'
  );

  IF v_result.expected_count <> 3
     OR v_result.found_count <> 3
     OR v_result.already_correct_count <> 1
     OR v_result.moved_in_count <> 2
     OR v_result.shipped_corrected_count <> 0
     OR v_result.marked_missing_count <> 1
     OR v_result.skipped_expected_count <> 1 THEN
    RAISE EXCEPTION 'Unexpected reconciliation counts: %', row_to_json(v_result);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.products
    WHERE nocopk = v_correct_id AND storage_location_id = v_target_id
  ) THEN
    RAISE EXCEPTION 'Expected-and-found product moved unexpectedly.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.products
    WHERE nocopk = v_missing_expected_id AND storage_location_id = v_missing_id
  ) THEN
    RAISE EXCEPTION 'Expected-but-not-found product did not move to Missing or Lost.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.products
    WHERE nocopk IN (v_elsewhere_id, v_restore_missing_id)
      AND storage_location_id = v_target_id
    GROUP BY storage_location_id
    HAVING count(*) = 2
  ) THEN
    RAISE EXCEPTION 'Found products from another/Missing location did not move to the target.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.products
    WHERE nocopk = v_concurrent_id AND storage_location_id = v_other_id
  ) THEN
    RAISE EXCEPTION 'A newer post-snapshot product move was overwritten.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public._m2m_products_locations_storage_location m
    WHERE m.products_id = v_missing_expected_id
      AND m.locations_id = v_missing_id
  ) OR NOT EXISTS (
    SELECT 1
    FROM public._m2m_products_locations_storage_location m
    WHERE m.products_id = v_elsewhere_id
      AND m.locations_id = v_target_id
  ) THEN
    RAISE EXCEPTION 'Reconciliation did not synchronize product-location relationship rows.';
  END IF;

  IF jsonb_array_length(v_result.changes_json) <> 3
     OR jsonb_array_length(v_result.skipped_json) <> 1 THEN
    RAISE EXCEPTION 'Unexpected changes/skipped JSON payload: changes %, skipped %', v_result.changes_json, v_result.skipped_json;
  END IF;

  SELECT e.fields_json::jsonb
  INTO v_summary_fields
  FROM public.events e
  WHERE e.nocopk = v_result.summary_event_id;

  IF v_summary_fields ->> 'workflow' <> 'mp_reconcile_products_location'
     OR v_summary_fields ->> 'reconciliation_id' <> v_result.reconciliation_id
     OR (v_summary_fields ->> 'marked_missing_count')::integer <> 1
     OR (v_summary_fields ->> 'skipped_expected_count')::integer <> 1 THEN
    RAISE EXCEPTION 'InventoryReconciliation summary event is incomplete: %', v_summary_fields;
  END IF;

  IF (
    SELECT count(*)
    FROM public.events e
    WHERE e.operator = 'RC78 inventory reconciliation smoke test'
      AND e.type = 'ProductInventoryReconciled'
      AND e.fields_json::jsonb ->> 'reconciliation_id' = v_result.reconciliation_id
  ) <> 3 THEN
    RAISE EXCEPTION 'Expected one ProductInventoryReconciled event for each changed product.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.events e
    WHERE e.type = 'ProductInventoryReconciled'
      AND e.fields_json::jsonb ->> 'product_nocopk' = v_concurrent_id::text
      AND e.fields_json::jsonb ->> 'reconciliation_id' = v_result.reconciliation_id
  ) THEN
    RAISE EXCEPTION 'Skipped concurrent product should not have a mutation event.';
  END IF;

  -- A Shipped correction must be explicitly enabled.
  v_failed := false;
  BEGIN
    PERFORM public.mp_reconcile_products_location(
      p_location_id => v_target_id,
      p_expected_product_ids => ARRAY[]::bigint[],
      p_found_product_ids => ARRAY[v_shipped_product_id],
      p_allow_shipped_correction => false,
      p_operator => 'RC78 shipped guard smoke test',
      p_station => 'Inventory Reconcile',
      p_notes => 'Should not run'
    );
  EXCEPTION WHEN OTHERS THEN
    v_failed := true;
  END;

  IF NOT v_failed OR NOT EXISTS (
    SELECT 1 FROM public.products
    WHERE nocopk = v_shipped_product_id AND storage_location_id = v_shipped_id
  ) THEN
    RAISE EXCEPTION 'Shipped product was not protected when override was disabled.';
  END IF;

  -- Shipped correction also requires explanatory notes.
  v_failed := false;
  BEGIN
    PERFORM public.mp_reconcile_products_location(
      p_location_id => v_target_id,
      p_expected_product_ids => ARRAY[]::bigint[],
      p_found_product_ids => ARRAY[v_shipped_product_id],
      p_allow_shipped_correction => true,
      p_operator => 'RC78 shipped notes guard smoke test',
      p_station => 'Inventory Reconcile',
      p_notes => NULL
    );
  EXCEPTION WHEN OTHERS THEN
    v_failed := true;
  END;

  IF NOT v_failed OR NOT EXISTS (
    SELECT 1 FROM public.products
    WHERE nocopk = v_shipped_product_id AND storage_location_id = v_shipped_id
  ) THEN
    RAISE EXCEPTION 'Shipped correction did not require notes.';
  END IF;

  SELECT * INTO v_result
  FROM public.mp_reconcile_products_location(
    p_location_id => v_target_id,
    p_expected_product_ids => ARRAY[]::bigint[],
    p_found_product_ids => ARRAY[v_shipped_product_id],
    p_allow_shipped_correction => true,
    p_operator => 'RC78 shipped correction smoke test',
    p_station => 'Inventory Reconcile',
    p_notes => 'Wrong product number was recorded as sold; physically found during reconciliation.'
  );

  IF v_result.moved_in_count <> 1
     OR v_result.shipped_corrected_count <> 1
     OR NOT EXISTS (
       SELECT 1 FROM public.products
       WHERE nocopk = v_shipped_product_id AND storage_location_id = v_target_id
     ) THEN
    RAISE EXCEPTION 'Approved Shipped correction did not move the product to the physical location.';
  END IF;

  -- Consumed/Expired/Retired/etc. are lifecycle corrections, not location
  -- reconciliation, and must remain blocked.
  v_failed := false;
  BEGIN
    PERFORM public.mp_reconcile_products_location(
      p_location_id => v_target_id,
      p_expected_product_ids => ARRAY[]::bigint[],
      p_found_product_ids => ARRAY[v_terminal_product_id],
      p_allow_shipped_correction => true,
      p_operator => 'RC78 terminal guard smoke test',
      p_station => 'Inventory Reconcile',
      p_notes => 'Terminal product guard'
    );
  EXCEPTION WHEN OTHERS THEN
    v_failed := true;
  END;

  IF NOT v_failed OR NOT EXISTS (
    SELECT 1 FROM public.products
    WHERE nocopk = v_terminal_product_id AND storage_location_id = v_consumed_id
  ) THEN
    RAISE EXCEPTION 'Terminal lifecycle product was incorrectly resurrected by reconciliation.';
  END IF;

  RAISE NOTICE 'Issue #78 product inventory reconciliation smoke tests passed.';
END;
$$;

ROLLBACK;
