\set ON_ERROR_STOP on

-- Transactional smoke test for canonical freeze-dried packaging, #61, #63, and #68.
-- Run after 004_computed_views.sql, 005_helpers.sql, and 008_lot_actions.sql.
-- All fixtures and outputs are rolled back.
BEGIN;

DO $$
DECLARE
  v_package_item_id bigint;
  v_tray_item_id bigint;
  v_origin_item_id bigint;
  v_storage_id bigint;
  v_consumed_location_id bigint;
  v_strain_id bigint;
  v_origin_lot_id bigint;
  v_source_product_ids bigint[];
  v_created_product_ids bigint[];
  v_event_id bigint;
  v_count integer;
  v_bad_size_rejected boolean := false;
  v_default_source_product_id bigint;
  v_default_created_product_id bigint;
  v_default_count integer;
  v_default_use_by date := (current_date + interval '2 years')::date;
  v_default_label_useby text;
  v_event_fields jsonb;
  v_product record;
BEGIN
  SELECT nocopk INTO v_package_item_id
  FROM public.items
  WHERE item_id = 'MUSH-DRIED'
    AND COALESCE(active, true)
  LIMIT 1;

  SELECT nocopk INTO v_tray_item_id
  FROM public.items
  WHERE item_id = 'TRAY-FREEZE'
    AND COALESCE(active, true)
  LIMIT 1;

  SELECT nocopk INTO v_origin_item_id
  FROM public.items
  WHERE COALESCE(active, true)
    AND item_id IN ('AIO-BAG', 'BLOCK-HW', 'GRAIN-BAG')
  ORDER BY CASE item_id WHEN 'AIO-BAG' THEN 0 WHEN 'BLOCK-HW' THEN 1 ELSE 2 END
  LIMIT 1;

  SELECT nocopk INTO v_storage_id
  FROM public.locations
  WHERE lower(btrim(name)) = 'products storage'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  SELECT nocopk INTO v_consumed_location_id
  FROM public.locations
  WHERE lower(btrim(name)) = 'consumed'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  SELECT nocopk INTO v_strain_id
  FROM public.strains
  WHERE COALESCE(active, false)
  ORDER BY nocopk
  LIMIT 1;

  IF v_package_item_id IS NULL
     OR v_tray_item_id IS NULL
     OR v_origin_item_id IS NULL
     OR v_storage_id IS NULL
     OR v_consumed_location_id IS NULL THEN
    RAISE EXCEPTION 'Freeze-dried packaging smoke-test fixtures are missing from imported Airtable data.';
  END IF;

  INSERT INTO public.lots (
    lot_id,
    item_id,
    item_name_mat,
    item_category_mat,
    strain_id,
    strain_species_strain_mat,
    status,
    unit_size,
    process_type_mat,
    created_at
  )
  SELECT
    'LOT-RC5-FD-PACKAGE',
    v_origin_item_id,
    i.name,
    i.category,
    v_strain_id,
    s.species_strain,
    'Fruiting',
    5,
    'Sterilize',
    clock_timestamp()::timestamp without time zone - interval '30 days'
  FROM public.items i
  LEFT JOIN public.strains s ON s.nocopk = v_strain_id
  WHERE i.nocopk = v_origin_item_id
  RETURNING nocopk INTO v_origin_lot_id;

  WITH inserted AS (
    INSERT INTO public.products (
      product_id,
      item_id,
      name_mat,
      item_category_mat,
      net_weight_g,
      net_weight_oz,
      pack_date,
      storage_location_id,
      origin_lot_ids_json,
      process_type_mat,
      strain_id,
      tray_state,
      notes
    )
    VALUES
      (
        'PROD-RC5-FD-SRC1',
        v_tray_item_id,
        'Freezer Tray',
        'freezer_tray',
        8,
        8 / 28.349523125,
        current_date - 1,
        v_storage_id,
        '["LOT-RC5-FD-PACKAGE"]',
        'Sterilize',
        v_strain_id,
        'Frozen',
        'Rollback-only freeze-dried source tray 1'
      ),
      (
        'PROD-RC5-FD-SRC2',
        v_tray_item_id,
        'Freezer Tray',
        'freezer_tray',
        8,
        8 / 28.349523125,
        current_date - 1,
        v_storage_id,
        '["LOT-RC5-FD-PACKAGE"]',
        'Sterilize',
        v_strain_id,
        'Frozen',
        'Rollback-only freeze-dried source tray 2'
      )
    RETURNING nocopk
  )
  SELECT array_agg(nocopk ORDER BY nocopk)
  INTO v_source_product_ids
  FROM inserted;

  INSERT INTO public._m2m_products_lots_origin_lots(products_id, lots_id)
  SELECT source_id, v_origin_lot_id
  FROM unnest(v_source_product_ids) AS source_id
  ON CONFLICT DO NOTHING;

  PERFORM public.mp_product_set_storage_location(source_id, v_storage_id)
  FROM unnest(v_source_product_ids) AS source_id;

  v_count := public.mp_products_package_freeze_dried_basic(
    p_source_product_ids => v_source_product_ids,
    p_package_item_id => v_package_item_id,
    p_package_size_g => 5,
    p_package_count => 2,
    p_storage_location_id => v_storage_id,
    p_use_by => current_date + 365,
    p_operator => 'RC5 smoke test',
    p_station => 'Products',
    p_pack_date => current_date,
    p_notes => 'Rollback-only freeze-dried package smoke test',
    p_package_class => 'Sample'
  );

  IF v_count <> 2 THEN
    RAISE EXCEPTION 'Expected two packaged products, got %.', v_count;
  END IF;

  SELECT COALESCE(array_agg(p.nocopk ORDER BY p.nocopk), ARRAY[]::bigint[])
  INTO v_created_product_ids
  FROM public.products p
  WHERE p.notes = 'Rollback-only freeze-dried package smoke test';

  IF cardinality(v_created_product_ids) <> 2 THEN
    RAISE EXCEPTION 'Expected two created freeze-dried products, got %.', cardinality(v_created_product_ids);
  END IF;

  FOR v_product IN
    SELECT
      p.nocopk,
      p.item_id,
      p.package_item_id,
      p.item_category_mat,
      p.net_weight_g,
      p.package_class,
      p.package_size,
      p.package_count,
      p.storage_location_id,
      p.use_by,
      vp.package_size_g,
      vp.label_title_prod,
      vp.label_subtitle_prod
    FROM public.products p
    JOIN public.vc_products vp ON vp.nocopk = p.nocopk
    WHERE p.nocopk = ANY(v_created_product_ids)
  LOOP
    IF v_product.item_id <> v_package_item_id
       OR v_product.package_item_id <> v_package_item_id
       OR v_product.item_category_mat <> 'freezedriedmushrooms'
       OR abs(v_product.net_weight_g - 5) > 0.01
       OR v_product.package_class <> 'Sample'
       OR v_product.package_size <> '5 g'
       OR v_product.package_count <> 1
       OR v_product.storage_location_id <> v_storage_id
       OR v_product.use_by <> current_date + 365
       OR abs(v_product.package_size_g - 5) > 0.01
       OR NULLIF(btrim(v_product.label_title_prod), '') IS NULL
       OR NULLIF(btrim(v_product.label_subtitle_prod), '') IS NULL THEN
      RAISE EXCEPTION 'Created freeze-dried product fields are incorrect: %', row_to_json(v_product);
    END IF;
  END LOOP;

  IF (
    SELECT count(*)
    FROM public.products p
    WHERE p.nocopk = ANY(v_source_product_ids)
      AND p.tray_state = 'empty_tray'
      AND p.storage_location_id = v_consumed_location_id
      AND abs(COALESCE(p.net_weight_g, 0)) <= 0.01
      AND abs(COALESCE(p.net_weight_oz, 0)) <= 0.01
  ) <> 2 THEN
    RAISE EXCEPTION 'Source freezer trays were not emptied and moved to Consumed.';
  END IF;

  IF (
    SELECT count(*)
    FROM public._m2m_products_locations_storage_location m
    WHERE m.products_id = ANY(v_source_product_ids)
      AND m.locations_id = v_consumed_location_id
  ) <> 2 THEN
    RAISE EXCEPTION 'Source freezer tray Consumed-location relationships were not updated.';
  END IF;

  IF (
    SELECT count(*)
    FROM public._m2m_products_products_merge_tray_products m
    WHERE m.products_id = ANY(v_created_product_ids)
      AND m.products1_id = ANY(v_source_product_ids)
  ) <> 4 THEN
    RAISE EXCEPTION 'Created products do not retain all source tray links.';
  END IF;

  IF (
    SELECT count(*)
    FROM public._m2m_products_lots_origin_lots m
    WHERE m.products_id = ANY(v_created_product_ids)
      AND m.lots_id = v_origin_lot_id
  ) <> 2 THEN
    RAISE EXCEPTION 'Created products do not retain inherited origin-lot links.';
  END IF;

  SELECT e.nocopk, e.fields_json::jsonb
  INTO v_event_id, v_event_fields
  FROM public.events e
  WHERE e.type = 'Package Freeze Dried'
    AND e.operator = 'RC5 smoke test'
    AND e.fields_json::jsonb ->> 'notes' = 'Rollback-only freeze-dried package smoke test'
  ORDER BY e.nocopk DESC
  LIMIT 1;

  IF v_event_id IS NULL THEN
    RAISE EXCEPTION 'Package Freeze Dried operation event was not created.';
  END IF;

  IF (
    SELECT count(*)
    FROM public.events e
    WHERE e.type = 'Package Freeze Dried'
      AND e.operator = 'RC5 smoke test'
      AND e.fields_json::jsonb ->> 'notes' = 'Rollback-only freeze-dried package smoke test'
  ) <> 1 THEN
    RAISE EXCEPTION 'Expected one event for the package operation.';
  END IF;

  IF jsonb_array_length(v_event_fields -> 'source_product_ids') <> 2
     OR jsonb_array_length(v_event_fields -> 'created_product_ids') <> 2
     OR jsonb_array_length(v_event_fields -> 'origin_lot_ids') <> 1
     OR v_event_fields ->> 'package_item_business_id' <> 'MUSH-DRIED'
     OR v_event_fields ->> 'package_class' <> 'Sample'
     OR v_event_fields ->> 'package_size' <> '5 g'
     OR (v_event_fields ->> 'package_count')::integer <> 2
     OR abs((v_event_fields ->> 'package_size_g')::numeric - 5) > 0.01
     OR abs((v_event_fields ->> 'total_packaged_weight_g')::numeric - 10) > 0.01
     OR abs((v_event_fields ->> 'unpackaged_source_weight_g')::numeric - 6) > 0.01
     OR v_event_fields ->> 'source_tray_state_after' <> 'empty_tray'
     OR v_event_fields ->> 'source_storage_location_after' <> 'Consumed'
     OR (v_event_fields ->> 'source_storage_location_id_after')::bigint <> v_consumed_location_id
     OR abs((v_event_fields ->> 'source_net_weight_g_after')::numeric) > 0.01 THEN
    RAISE EXCEPTION 'Package event fields_json is incomplete: %', v_event_fields;
  END IF;

  IF (
    SELECT count(*)
    FROM public._m2m_products_events_events m
    WHERE m.events_id = v_event_id
      AND m.products_id = ANY(v_source_product_ids || v_created_product_ids)
  ) <> 4 THEN
    RAISE EXCEPTION 'Package event is not linked to all source and created products.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public._m2m_lots_events_events m
    WHERE m.events_id = v_event_id
      AND m.lots_id = v_origin_lot_id
  ) THEN
    RAISE EXCEPTION 'Package event is not linked to the inherited origin lot.';
  END IF;

  IF (
    SELECT count(*)
    FROM public.print_queue pq
    WHERE pq.product_id = ANY(v_created_product_ids)
      AND pq.source_kind = 'product'
      AND pq.label_type = 'Product_Package'
      AND pq.print_status = 'Queued'
  ) <> 2 THEN
    RAISE EXCEPTION 'Product_Package print jobs were not created for every package.';
  END IF;

  INSERT INTO public.products (
    product_id,
    item_id,
    name_mat,
    item_category_mat,
    net_weight_g,
    net_weight_oz,
    pack_date,
    storage_location_id,
    origin_lot_ids_json,
    process_type_mat,
    strain_id,
    tray_state,
    notes
  )
  VALUES (
    'PROD-RC5-FD-DEFAULT-USEBY-SRC',
    v_tray_item_id,
    'Freezer Tray',
    'freezer_tray',
    5,
    5 / 28.349523125,
    current_date,
    v_storage_id,
    '["LOT-RC5-FD-PACKAGE"]',
    'Sterilize',
    v_strain_id,
    'Frozen',
    'Rollback-only default use-by source tray'
  )
  RETURNING nocopk INTO v_default_source_product_id;

  INSERT INTO public._m2m_products_lots_origin_lots(products_id, lots_id)
  VALUES (v_default_source_product_id, v_origin_lot_id)
  ON CONFLICT DO NOTHING;

  PERFORM public.mp_product_set_storage_location(
    v_default_source_product_id,
    v_storage_id
  );

  v_default_count := public.mp_products_package_freeze_dried_basic(
    p_source_product_ids => ARRAY[v_default_source_product_id]::bigint[],
    p_package_item_id => v_package_item_id,
    p_package_size_g => 5,
    p_package_count => 1,
    p_storage_location_id => v_storage_id,
    p_use_by => NULL,
    p_operator => 'RC5 default use-by smoke test',
    p_station => 'Products',
    p_pack_date => current_date,
    p_notes => 'Rollback-only default use-by smoke test',
    p_package_class => 'Retail'
  );

  IF v_default_count <> 1 THEN
    RAISE EXCEPTION 'Expected one default-use-by package, got %.', v_default_count;
  END IF;

  SELECT p.nocopk, vp.label_useby_prod
  INTO v_default_created_product_id, v_default_label_useby
  FROM public.products p
  JOIN public.vc_products vp ON vp.nocopk = p.nocopk
  WHERE p.notes = 'Rollback-only default use-by smoke test'
  ORDER BY p.nocopk DESC
  LIMIT 1;

  IF v_default_created_product_id IS NULL THEN
    RAISE EXCEPTION 'Default-use-by freeze-dried product was not created.';
  END IF;

  IF (
    SELECT p.use_by
    FROM public.products p
    WHERE p.nocopk = v_default_created_product_id
  ) <> v_default_use_by THEN
    RAISE EXCEPTION 'Blank use-by did not default to two years after pack date.';
  END IF;

  IF v_default_label_useby <> 'Use by: ' || to_char(v_default_use_by, 'YYYY-MM-DD') THEN
    RAISE EXCEPTION 'Default use-by label text is incorrect: %', v_default_label_useby;
  END IF;

  BEGIN
    PERFORM public.mp_products_package_freeze_dried_basic(
      p_source_product_ids => v_source_product_ids,
      p_package_item_id => v_package_item_id,
      p_package_size_g => 3,
      p_package_count => 1,
      p_storage_location_id => v_storage_id,
      p_use_by => NULL,
      p_operator => 'RC5 smoke test',
      p_station => 'Products',
      p_pack_date => current_date,
      p_notes => 'Unsupported-size check',
      p_package_class => 'Retail'
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'Unsupported package size:%' THEN
      v_bad_size_rejected := true;
    ELSE
      RAISE;
    END IF;
  END;

  IF NOT v_bad_size_rejected THEN
    RAISE EXCEPTION 'Unsupported freeze-dried package size was not rejected.';
  END IF;

  RAISE NOTICE 'Freeze-dried package, source consumption, use-by default/override, lineage, event, and print smoke tests passed.';
END;
$$;

ROLLBACK;
