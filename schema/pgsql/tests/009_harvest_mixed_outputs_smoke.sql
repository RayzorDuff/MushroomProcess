\set ON_ERROR_STOP on

-- Transactional RC5 regression test for mixed fresh/freezer harvest output (#36).
-- Run after 004_computed_views.sql, 005_helpers.sql, and 009_harvest_actions.sql.
-- All fixtures and outputs are rolled back.
BEGIN;

DO $$
DECLARE
  v_block_item_id bigint;
  v_fresh_item_id bigint;
  v_freezer_item_id bigint;
  v_strain_id bigint;
  v_fresh_location_id bigint;
  v_freezer_location_id bigint;
  v_lot_id bigint;
  v_created_count integer;
  v_created_product_ids bigint[];
  v_event_id bigint;
  v_event_fields jsonb;
BEGIN
  SELECT nocopk INTO v_block_item_id
  FROM public.items
  WHERE category = 'fruiting_block'
    AND COALESCE(active, true)
  ORDER BY nocopk
  LIMIT 1;

  SELECT nocopk INTO v_fresh_item_id
  FROM public.items
  WHERE item_id = 'TRAY-FRESH'
    AND COALESCE(active, true)
  ORDER BY nocopk
  LIMIT 1;

  SELECT nocopk INTO v_freezer_item_id
  FROM public.items
  WHERE item_id = 'TRAY-FREEZE'
    AND COALESCE(active, true)
  ORDER BY nocopk
  LIMIT 1;

  SELECT nocopk INTO v_strain_id
  FROM public.strains
  WHERE COALESCE(active, false)
  ORDER BY nocopk
  LIMIT 1;

  SELECT nocopk INTO v_fresh_location_id
  FROM public.locations
  WHERE lower(btrim(name)) = 'products storage'
    AND COALESCE(active, false)
  ORDER BY nocopk
  LIMIT 1;

  SELECT nocopk INTO v_freezer_location_id
  FROM public.locations
  WHERE lower(btrim(name)) = 'freezer'
    AND COALESCE(active, false)
  ORDER BY nocopk
  LIMIT 1;

  IF v_block_item_id IS NULL
     OR v_fresh_item_id IS NULL
     OR v_freezer_item_id IS NULL
     OR v_fresh_location_id IS NULL
     OR v_freezer_location_id IS NULL THEN
    RAISE EXCEPTION 'Mixed-harvest smoke-test fixtures are missing from imported Airtable data.';
  END IF;

  INSERT INTO public.lots (
    lot_id,
    item_id,
    item_name_mat,
    item_category_mat,
    strain_id,
    status,
    unit_size,
    process_type_mat,
    beganfruiting_at,
    created_at,
    notes
  )
  SELECT
    'LOT-RC5-MIXED-HARVEST',
    i.nocopk,
    i.name,
    i.category,
    v_strain_id,
    'Fruiting',
    5,
    'Sterilize',
    clock_timestamp()::timestamp without time zone - interval '10 days',
    clock_timestamp()::timestamp without time zone - interval '30 days',
    'Rollback-only mixed harvest source lot'
  FROM public.items i
  WHERE i.nocopk = v_block_item_id
  RETURNING nocopk INTO v_lot_id;

  v_created_count := public.mp_lots_harvest_create_tray_products(
    p_block_lot_id => v_lot_id,
    p_harvest_weight_g => 300,
    p_flush_no => 1,
    p_fresh_tray_count => 2,
    p_frozen_tray_count => 3,
    p_operator => 'RC5 mixed harvest smoke test',
    p_station => 'Harvest',
    p_timestamp => clock_timestamp()::timestamp without time zone,
    p_notes => 'Rollback-only 2 fresh / 3 freezer harvest',
    p_fresh_harvest_item_id => v_fresh_item_id,
    p_frozen_harvest_item_id => v_freezer_item_id,
    p_fresh_storage_location_id => v_fresh_location_id,
    p_frozen_storage_location_id => v_freezer_location_id
  );

  IF v_created_count <> 5 THEN
    RAISE EXCEPTION 'Expected five tray products, got %.', v_created_count;
  END IF;

  SELECT COALESCE(array_agg(p.nocopk ORDER BY p.nocopk), ARRAY[]::bigint[])
  INTO v_created_product_ids
  FROM public.products p
  JOIN public._m2m_products_lots_origin_lots m
    ON m.products_id = p.nocopk
   AND m.lots_id = v_lot_id
  WHERE p.notes = 'Rollback-only 2 fresh / 3 freezer harvest';

  IF cardinality(v_created_product_ids) <> 5 THEN
    RAISE EXCEPTION 'Expected five linked tray products, got %.', cardinality(v_created_product_ids);
  END IF;

  IF (
    SELECT count(*)
    FROM public.products p
    WHERE p.nocopk = ANY(v_created_product_ids)
      AND p.item_category_mat = 'fresh_tray'
      AND p.storage_location_id = v_fresh_location_id
      AND abs(COALESCE(p.net_weight_g, 0) - 60) <= 0.01
      AND abs(COALESCE(p.harvest_weight_g, 0) - 60) <= 0.01
      AND p.harvest_flush_no = 1
  ) <> 2 THEN
    RAISE EXCEPTION 'Fresh tray count, location, weight, or flush is incorrect.';
  END IF;

  IF (
    SELECT count(*)
    FROM public.products p
    WHERE p.nocopk = ANY(v_created_product_ids)
      AND p.item_category_mat = 'freezer_tray'
      AND p.storage_location_id = v_freezer_location_id
      AND abs(COALESCE(p.net_weight_g, 0) - 60) <= 0.01
      AND abs(COALESCE(p.harvest_weight_g, 0) - 60) <= 0.01
      AND p.harvest_flush_no = 1
  ) <> 3 THEN
    RAISE EXCEPTION 'Freezer tray count, location, weight, or flush is incorrect.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.lots l
    WHERE l.nocopk = v_lot_id
      AND abs(COALESCE(l.harvest_weight_g, 0) - 300) <= 0.01
      AND l.flush_no = 1
      AND l.fresh_tray_count = 2
      AND l.frozen_tray_count = 3
      AND l.firstharvested_at IS NOT NULL
      AND l.lastharvested_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Source lot harvest summary fields were not updated correctly.';
  END IF;

  SELECT e.nocopk, e.fields_json::jsonb
  INTO v_event_id, v_event_fields
  FROM public.events e
  WHERE e.type = 'Harvest'
    AND e.operator = 'RC5 mixed harvest smoke test'
    AND e.fields_json::jsonb ->> 'notes' = 'Rollback-only 2 fresh / 3 freezer harvest'
  ORDER BY e.nocopk DESC
  LIMIT 1;

  IF v_event_id IS NULL THEN
    RAISE EXCEPTION 'Mixed-harvest operation event was not created.';
  END IF;

  IF (
    SELECT count(*)
    FROM public.events e
    WHERE e.type = 'Harvest'
      AND e.operator = 'RC5 mixed harvest smoke test'
      AND e.fields_json::jsonb ->> 'notes' = 'Rollback-only 2 fresh / 3 freezer harvest'
  ) <> 1 THEN
    RAISE EXCEPTION 'Expected exactly one Harvest event for the operation.';
  END IF;

  IF (v_event_fields ->> 'harvest_weight_g')::numeric <> 300
     OR (v_event_fields ->> 'flush_no')::integer <> 1
     OR (v_event_fields ->> 'fresh_tray_count')::integer <> 2
     OR (v_event_fields ->> 'frozen_tray_count')::integer <> 3
     OR (v_event_fields ->> 'total_trays')::integer <> 5
     OR abs((v_event_fields ->> 'per_tray_weight_g')::numeric - 60) > 0.01
     OR jsonb_array_length(v_event_fields -> 'created_product_ids') <> 5
     OR jsonb_array_length(v_event_fields -> 'created_product_nocopks') <> 5 THEN
    RAISE EXCEPTION 'Mixed-harvest event fields_json is incomplete: %', v_event_fields;
  END IF;

  IF (
    SELECT count(*)
    FROM public._m2m_products_events_events m
    WHERE m.events_id = v_event_id
      AND m.products_id = ANY(v_created_product_ids)
  ) <> 5 THEN
    RAISE EXCEPTION 'Harvest event is not linked to every created product.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public._m2m_lots_events_events m
    WHERE m.events_id = v_event_id
      AND m.lots_id = v_lot_id
  ) THEN
    RAISE EXCEPTION 'Harvest event is not linked to the source lot.';
  END IF;

  IF (
    SELECT count(*)
    FROM public.print_queue pq
    WHERE pq.product_id = ANY(v_created_product_ids)
      AND pq.source_kind = 'product'
      AND pq.label_type = 'Product_Package'
      AND pq.print_status = 'Queued'
  ) <> 5 THEN
    RAISE EXCEPTION 'One Product_Package print job was not created per tray product.';
  END IF;

  IF (
    SELECT count(*)
    FROM public.vc_print_queue vpq
    WHERE vpq.product_id = ANY(v_created_product_ids)
      AND vpq.print_target = 'TRAYS'
  ) <> 5 THEN
    RAISE EXCEPTION 'Created tray labels do not resolve to the TRAYS print target.';
  END IF;

  RAISE NOTICE 'Mixed fresh/freezer harvest product, event, lineage, and print smoke tests passed.';
END;
$$;

ROLLBACK;
