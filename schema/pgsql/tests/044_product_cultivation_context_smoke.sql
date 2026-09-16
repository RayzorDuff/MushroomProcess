\set ON_ERROR_STOP on

-- Issue #57 Phase 2 smoke test.
-- Exercises UI candidate shaping plus atomic Product-backed inoculation and
-- Spawn-to-Bulk behavior. All fixtures and outputs are rolled back.
BEGIN;

DO $test$
DECLARE
  v_products_loc bigint;
  v_consumed_loc bigint;
  v_fridge_loc bigint;
  v_dark_loc bigint;
  v_grain_item bigint;
  v_sub_item bigint;
  v_lc_item bigint;
  v_grain_recipe bigint;
  v_sub_recipe bigint;
  v_strain bigint;

  v_lc_origin bigint;
  v_lc_product bigint;
  v_grain_origin bigint;
  v_grain_product bigint;
  v_returned_source bigint;
  v_returned_target bigint;
  v_inoc_count integer;

  v_full_lc_origin bigint;
  v_full_lc_product bigint;
  v_full_target bigint;
  v_full_returned_source bigint;

  v_spawn_grain bigint;
  v_sub_origin bigint;
  v_sub_product bigint;
  v_spawn_count integer;
  v_returned_sub bigint;
  v_output bigint;
  v_component bigint;

  v_atomic_source_origin bigint;
  v_atomic_source_product bigint;
  v_atomic_error text;
  v_now timestamp without time zone := now();
BEGIN
  SELECT nocopk INTO v_products_loc
  FROM public.locations
  WHERE regexp_replace(lower(btrim(name)), '[^a-z0-9]', '', 'g') IN ('productsstorage','productstorage')
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;
  IF v_products_loc IS NULL THEN
    INSERT INTO public.locations(name, active, type)
    VALUES ('Products Storage', true, 'Storage')
    RETURNING nocopk INTO v_products_loc;
  END IF;

  SELECT nocopk INTO v_consumed_loc
  FROM public.locations
  WHERE regexp_replace(lower(btrim(name)), '[^a-z0-9]', '', 'g') = 'consumed'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;
  IF v_consumed_loc IS NULL THEN
    INSERT INTO public.locations(name, active, type)
    VALUES ('Consumed', true, 'Terminal')
    RETURNING nocopk INTO v_consumed_loc;
  END IF;

  SELECT nocopk INTO v_fridge_loc
  FROM public.locations
  WHERE regexp_replace(lower(btrim(name)), '[^a-z0-9]', '', 'g') = 'fridge'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;
  IF v_fridge_loc IS NULL THEN
    INSERT INTO public.locations(name, active, type)
    VALUES ('Fridge', true, 'Storage')
    RETURNING nocopk INTO v_fridge_loc;
  END IF;

  SELECT nocopk INTO v_dark_loc
  FROM public.locations
  WHERE regexp_replace(lower(btrim(name)), '[^a-z0-9]', '', 'g') = 'darkroom'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;
  IF v_dark_loc IS NULL THEN
    INSERT INTO public.locations(name, active, type)
    VALUES ('Dark Room', true, 'Production')
    RETURNING nocopk INTO v_dark_loc;
  END IF;

  SELECT nocopk INTO v_grain_item FROM public.items WHERE item_id = 'GRAIN-BAG' LIMIT 1;
  SELECT nocopk INTO v_sub_item FROM public.items WHERE item_id = 'SUB-CVG-BAG' LIMIT 1;
  SELECT nocopk INTO v_lc_item FROM public.items WHERE item_id = 'LC-SYRINGE' LIMIT 1;
  SELECT nocopk INTO v_grain_recipe FROM public.recipes WHERE recipe_id = 'REC-GRAIN-WBS' LIMIT 1;
  SELECT nocopk INTO v_sub_recipe FROM public.recipes WHERE recipe_id = 'REC-SUB-CVG-V2' LIMIT 1;
  SELECT nocopk INTO v_strain
  FROM public.strains
  WHERE COALESCE(active, false) AND NULLIF(btrim(species_strain), '') IS NOT NULL
  ORDER BY nocopk
  LIMIT 1;

  IF v_grain_item IS NULL OR v_sub_item IS NULL OR v_lc_item IS NULL
     OR v_grain_recipe IS NULL OR v_sub_recipe IS NULL OR v_strain IS NULL THEN
    RAISE EXCEPTION 'Issue #57 Phase 2 smoke fixtures are missing imported item/recipe/strain data.';
  END IF;

  ---------------------------------------------------------------------------
  -- Mixed Product source + Product target inoculation, with partial LC left.
  ---------------------------------------------------------------------------
  INSERT INTO public.lots(
    lot_id, item_id, item_name_mat, item_category_mat, strain_id,
    strain_species_strain_mat, qty, unit_size, status, location_id,
    created_at, inoculated_at, use_by, label_template, source_type
  )
  SELECT
    'LOT-ISS57-P2-LC-ORIGIN', v_lc_item, i.name, 'lc_syringe', v_strain,
    s.species_strain, 1, 10, 'Consumed', v_consumed_loc,
    v_now - interval '30 days', v_now - interval '30 days',
    CURRENT_DATE + 45, 'LC_Syringe_Drawn', 'Drawn'
  FROM public.items i
  JOIN public.strains s ON s.nocopk = v_strain
  WHERE i.nocopk = v_lc_item
  RETURNING nocopk INTO v_lc_origin;

  INSERT INTO public.products(
    product_id, item_id, name_mat, item_category_mat, strain_id,
    net_volume_ml, pack_date, use_by, storage_location_id, origin_lot_ids_json
  )
  SELECT
    'PROD-ISS57-P2-LC-PARTIAL', v_lc_item, i.name, 'lc_syringe', v_strain,
    10, CURRENT_DATE - 10, CURRENT_DATE + 60, v_products_loc,
    to_jsonb(ARRAY['LOT-ISS57-P2-LC-ORIGIN'])::text
  FROM public.items i WHERE i.nocopk = v_lc_item
  RETURNING nocopk INTO v_lc_product;
  INSERT INTO public._m2m_products_lots_origin_lots(products_id, lots_id)
  VALUES (v_lc_product, v_lc_origin);

  INSERT INTO public.lots(
    lot_id, item_id, item_name_mat, item_category_mat, recipe_id,
    qty, unit_size, status, location_id, created_at, sterilized_at,
    use_by, process_type_mat
  )
  SELECT
    'LOT-ISS57-P2-GRAIN-ORIGIN', v_grain_item, i.name, 'grain', v_grain_recipe,
    1, 2, 'Consumed', v_consumed_loc, v_now - interval '20 days',
    v_now - interval '20 days', CURRENT_DATE + 30, 'Sterilize'
  FROM public.items i WHERE i.nocopk = v_grain_item
  RETURNING nocopk INTO v_grain_origin;

  INSERT INTO public.products(
    product_id, item_id, name_mat, item_category_mat, net_weight_g,
    pack_date, use_by, storage_location_id, origin_lot_ids_json, process_type_mat
  )
  SELECT
    'PROD-ISS57-P2-GRAIN', v_grain_item, i.name, 'grain', 907.18474,
    CURRENT_DATE - 10, CURRENT_DATE + 50, v_products_loc,
    to_jsonb(ARRAY['LOT-ISS57-P2-GRAIN-ORIGIN'])::text, 'Sterilize'
  FROM public.items i WHERE i.nocopk = v_grain_item
  RETURNING nocopk INTO v_grain_product;
  INSERT INTO public._m2m_products_lots_origin_lots(products_id, lots_id)
  VALUES (v_grain_product, v_grain_origin);

  IF NOT EXISTS (
    SELECT 1 FROM public.v_product_cultivation_candidates c
    WHERE c.product_nocopk = v_lc_product
      AND c.inventory_kind = 'product'
      AND c.can_inoculate_source
      AND c.lot_id LIKE 'PRODUCT · %'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.v_product_cultivation_candidates c
    WHERE c.product_nocopk = v_grain_product
      AND c.can_inoculate_target
  ) THEN
    RAISE EXCEPTION 'Show Eligible Products candidate view did not expose inoculation Product roles.';
  END IF;

  SELECT r.inoculated_count, r.returned_source_lot_id, r.returned_target_lot_ids[1]
  INTO v_inoc_count, v_returned_source, v_returned_target
  FROM public.mp_inoculate_with_products_result(
    p_source_product_id => v_lc_product,
    p_target_product_ids => ARRAY[v_grain_product],
    p_storage_location_id => v_dark_loc,
    p_lc_volume_ml => 2,
    p_operator => 'Issue 57 Phase 2 smoke',
    p_station => 'Inoculation',
    p_timestamp => v_now,
    p_note => 'Product-backed partial LC inoculation'
  ) r;

  IF v_inoc_count <> 1 OR v_returned_source IS NULL OR v_returned_target IS NULL THEN
    RAISE EXCEPTION 'Product-backed inoculation did not return expected source/target Lot IDs.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.lots l
    WHERE l.nocopk = v_returned_target
      AND l.source_product_id = v_grain_product
      AND l.status = 'Colonizing'
      AND l.strain_id = v_strain
      AND l.use_by = CURRENT_DATE + 30
      AND l.label_template = 'Grain_Inoculated'
  ) THEN
    RAISE EXCEPTION 'Returned grain Product was not inoculated with preserved expiration/lineage/label.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.lots l
    WHERE l.nocopk = v_returned_source
      AND l.source_product_id = v_lc_product
      AND l.remaining_volume_ml = 8
      AND l.status = 'Fridge'
      AND l.location_id = v_fridge_loc
      AND l.label_template = 'LC_Syringe_Drawn'
  ) THEN
    RAISE EXCEPTION 'Partially used LC Product did not become a labeled remaining LC Lot in Fridge.';
  END IF;

  IF (SELECT count(*) FROM public.print_queue q
      WHERE q.lot_id = v_returned_source AND q.label_type = 'LC_Syringe_Drawn') <> 1 THEN
    RAISE EXCEPTION 'Partially used LC Product did not queue exactly one replacement syringe label.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.print_queue q
    WHERE q.lot_id = v_returned_target AND q.label_type = 'Grain_Inoculated'
  ) THEN
    RAISE EXCEPTION 'Product-backed grain target did not retain the normal inoculated-grain label.';
  END IF;

  IF (
    SELECT count(*) FROM public.products p
    WHERE p.nocopk IN (v_lc_product, v_grain_product)
      AND p.storage_location_id = v_consumed_loc
  ) <> 2 THEN
    RAISE EXCEPTION 'Used Products were not removed from sellable inventory.';
  END IF;

  ---------------------------------------------------------------------------
  -- Fully depleted Product LC source: no replacement source label.
  ---------------------------------------------------------------------------
  INSERT INTO public.lots(
    lot_id, item_id, item_name_mat, item_category_mat, strain_id,
    strain_species_strain_mat, qty, unit_size, status, location_id,
    created_at, inoculated_at, use_by, label_template, source_type
  )
  SELECT
    'LOT-ISS57-P2-LC-FULL-ORIGIN', v_lc_item, i.name, 'lc_syringe', v_strain,
    s.species_strain, 1, 5, 'Consumed', v_consumed_loc,
    v_now - interval '25 days', v_now - interval '25 days',
    CURRENT_DATE + 40, 'LC_Syringe_Received', 'Purchased'
  FROM public.items i
  JOIN public.strains s ON s.nocopk = v_strain
  WHERE i.nocopk = v_lc_item
  RETURNING nocopk INTO v_full_lc_origin;

  INSERT INTO public.products(
    product_id, item_id, name_mat, item_category_mat, strain_id,
    net_volume_ml, pack_date, use_by, storage_location_id, origin_lot_ids_json
  )
  SELECT
    'PROD-ISS57-P2-LC-FULL', v_lc_item, i.name, 'lc_syringe', v_strain,
    5, CURRENT_DATE - 8, CURRENT_DATE + 40, v_products_loc,
    to_jsonb(ARRAY['LOT-ISS57-P2-LC-FULL-ORIGIN'])::text
  FROM public.items i WHERE i.nocopk = v_lc_item
  RETURNING nocopk INTO v_full_lc_product;
  INSERT INTO public._m2m_products_lots_origin_lots(products_id, lots_id)
  VALUES (v_full_lc_product, v_full_lc_origin);

  INSERT INTO public.lots(
    lot_id, item_id, item_name_mat, item_category_mat, recipe_id,
    qty, unit_size, status, location_id, created_at, sterilized_at, use_by
  )
  SELECT
    'LOT-ISS57-P2-GRAIN-TARGET', v_grain_item, i.name, 'grain', v_grain_recipe,
    1, 2, 'Sterilized', v_dark_loc, v_now - interval '3 days',
    v_now - interval '3 days', CURRENT_DATE + 80
  FROM public.items i WHERE i.nocopk = v_grain_item
  RETURNING nocopk INTO v_full_target;

  SELECT r.inoculated_count, r.returned_source_lot_id
  INTO v_inoc_count, v_full_returned_source
  FROM public.mp_inoculate_with_products_result(
    p_source_product_id => v_full_lc_product,
    p_target_lot_ids => ARRAY[v_full_target],
    p_storage_location_id => v_dark_loc,
    p_lc_volume_ml => 5,
    p_operator => 'Issue 57 Phase 2 smoke',
    p_timestamp => v_now
  ) r;

  IF v_inoc_count <> 1 THEN
    RAISE EXCEPTION 'Fully depleted Product LC inoculation failed.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.lots l
    WHERE l.nocopk = v_full_returned_source
      AND l.remaining_volume_ml = 0
      AND l.status = 'Consumed'
  ) THEN
    RAISE EXCEPTION 'Fully used LC Product source was not consumed.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.print_queue q
    WHERE q.lot_id = v_full_returned_source
      AND q.label_type IN ('LC_Syringe_Drawn', 'LC_Syringe_Received')
  ) THEN
    RAISE EXCEPTION 'Fully depleted LC Product incorrectly queued a replacement syringe label.';
  END IF;

  ---------------------------------------------------------------------------
  -- Product substrate target in Spawn-to-Bulk: no intermediate label and
  -- output expiration capped by the packaged substrate.
  ---------------------------------------------------------------------------
  INSERT INTO public.lots(
    lot_id, item_id, item_name_mat, item_category_mat, recipe_id,
    strain_id, strain_species_strain_mat, qty, unit_size, status,
    location_id, created_at, sterilized_at, inoculated_at, use_by
  )
  SELECT
    'LOT-ISS57-P2-SPAWN-GRAIN', v_grain_item, i.name, 'grain', v_grain_recipe,
    v_strain, s.species_strain, 1, 2, 'FullyColonized', v_dark_loc,
    v_now - interval '15 days', v_now - interval '15 days',
    v_now - interval '12 days', CURRENT_DATE + 60
  FROM public.items i
  JOIN public.strains s ON s.nocopk = v_strain
  WHERE i.nocopk = v_grain_item
  RETURNING nocopk INTO v_spawn_grain;

  INSERT INTO public.lots(
    lot_id, item_id, item_name_mat, item_category_mat, recipe_id,
    qty, unit_size, status, location_id, created_at, sterilized_at,
    use_by, process_type_mat
  )
  SELECT
    'LOT-ISS57-P2-SUB-ORIGIN', v_sub_item, i.name, 'substrate', v_sub_recipe,
    1, 6, 'Consumed', v_consumed_loc, v_now - interval '12 days',
    v_now - interval '12 days', CURRENT_DATE + 20, 'Pasteurize'
  FROM public.items i WHERE i.nocopk = v_sub_item
  RETURNING nocopk INTO v_sub_origin;

  INSERT INTO public.lot_recipe_components(
    lot_id, item_id, recipe_id, component_role, component_weight_lb,
    component_percent, sort_order, notes
  ) VALUES (
    v_sub_origin, v_sub_item, v_sub_recipe, 'substrate', 6, 100, 1,
    'Issue 57 Phase 2 preserved substrate component'
  ) RETURNING nocopk INTO v_component;
  PERFORM public.mp_link_lot_recipe_component(v_component, v_sub_origin, v_sub_item, v_sub_recipe, NULL);

  INSERT INTO public.products(
    product_id, item_id, name_mat, item_category_mat, net_weight_g,
    pack_date, use_by, storage_location_id, origin_lot_ids_json, process_type_mat
  )
  SELECT
    'PROD-ISS57-P2-SUB', v_sub_item, i.name, 'substrate', 2721.55422,
    CURRENT_DATE - 7, CURRENT_DATE + 35, v_products_loc,
    to_jsonb(ARRAY['LOT-ISS57-P2-SUB-ORIGIN'])::text, 'Pasteurize'
  FROM public.items i WHERE i.nocopk = v_sub_item
  RETURNING nocopk INTO v_sub_product;
  INSERT INTO public._m2m_products_lots_origin_lots(products_id, lots_id)
  VALUES (v_sub_product, v_sub_origin);

  IF NOT EXISTS (
    SELECT 1 FROM public.v_product_cultivation_candidates c
    WHERE c.product_nocopk = v_sub_product AND c.can_spawn_substrate
  ) THEN
    RAISE EXCEPTION 'Show Eligible Products candidate view did not expose substrate Product role.';
  END IF;

  v_spawn_count := public.mp_spawn_to_bulk_with_products(
    p_grain_lot_ids => ARRAY[v_spawn_grain],
    p_substrate_product_ids => ARRAY[v_sub_product],
    p_output_count => 1,
    p_output_plan_json => '[{"item_code":"FB-CVG-BAG","ratio":1}]'::jsonb,
    p_storage_location_id => v_dark_loc,
    p_operator => 'Issue 57 Phase 2 smoke',
    p_station => 'Spawn to Bulk',
    p_timestamp => v_now,
    p_note => 'Product-backed Spawn to Bulk'
  );

  IF v_spawn_count <> 1 THEN
    RAISE EXCEPTION 'Product-backed Spawn-to-Bulk expected one output, got %.', v_spawn_count;
  END IF;

  SELECT l.nocopk INTO v_returned_sub
  FROM public.lots l WHERE l.source_product_id = v_sub_product;

  SELECT DISTINCT output.nocopk INTO v_output
  FROM public.lots output
  JOIN public._m2m_lots_lots_substrate_inputs x ON x.lots_id = output.nocopk
  WHERE x.lots1_id = v_returned_sub
    AND output.spawned_at = v_now;

  IF v_returned_sub IS NULL OR v_output IS NULL THEN
    RAISE EXCEPTION 'Spawn-to-Bulk genealogy did not retain Product -> returned substrate -> output links.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.print_queue q WHERE q.lot_id = v_returned_sub
  ) THEN
    RAISE EXCEPTION 'Returned substrate Product incorrectly queued an intermediate substrate label.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.lots l
    WHERE l.nocopk = v_output
      AND l.label_template = 'Bulk_Created'
      AND l.use_by = CURRENT_DATE + 20
  ) THEN
    RAISE EXCEPTION 'Spawn-to-Bulk output did not preserve normal label while capping expiration.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.print_queue q
    WHERE q.lot_id = v_output AND q.label_type = 'Bulk_Created'
  ) THEN
    RAISE EXCEPTION 'Product-backed Spawn-to-Bulk output label was not queued.';
  END IF;

  ---------------------------------------------------------------------------
  -- Atomicity: if a later Product target is invalid, an already-returned
  -- Product source must roll back and remain sellable.
  ---------------------------------------------------------------------------
  INSERT INTO public.lots(
    lot_id, item_id, item_name_mat, item_category_mat, strain_id,
    strain_species_strain_mat, qty, unit_size, status, location_id,
    created_at, inoculated_at, use_by, label_template
  )
  SELECT
    'LOT-ISS57-P2-ATOMIC-LC-ORIGIN', v_lc_item, i.name, 'lc_syringe', v_strain,
    s.species_strain, 1, 4, 'Consumed', v_consumed_loc,
    v_now - interval '10 days', v_now - interval '10 days',
    CURRENT_DATE + 30, 'LC_Syringe_Drawn'
  FROM public.items i
  JOIN public.strains s ON s.nocopk = v_strain
  WHERE i.nocopk = v_lc_item
  RETURNING nocopk INTO v_atomic_source_origin;

  INSERT INTO public.products(
    product_id, item_id, name_mat, item_category_mat, strain_id,
    net_volume_ml, pack_date, use_by, storage_location_id, origin_lot_ids_json
  )
  SELECT
    'PROD-ISS57-P2-ATOMIC-LC', v_lc_item, i.name, 'lc_syringe', v_strain,
    4, CURRENT_DATE - 3, CURRENT_DATE + 30, v_products_loc,
    to_jsonb(ARRAY['LOT-ISS57-P2-ATOMIC-LC-ORIGIN'])::text
  FROM public.items i WHERE i.nocopk = v_lc_item
  RETURNING nocopk INTO v_atomic_source_product;
  INSERT INTO public._m2m_products_lots_origin_lots(products_id, lots_id)
  VALUES (v_atomic_source_product, v_atomic_source_origin);

  BEGIN
    PERFORM * FROM public.mp_inoculate_with_products_result(
      p_source_product_id => v_atomic_source_product,
      p_target_product_ids => ARRAY[9223372036854770000::bigint],
      p_storage_location_id => v_dark_loc,
      p_lc_volume_ml => 1,
      p_operator => 'Issue 57 Phase 2 smoke',
      p_timestamp => v_now
    );
    RAISE EXCEPTION 'Expected invalid later Product target to abort atomic inoculation.';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_atomic_error = MESSAGE_TEXT;
    IF v_atomic_error NOT ILIKE '%not eligible as an inoculation target%' THEN
      RAISE;
    END IF;
  END;

  IF EXISTS (
    SELECT 1 FROM public.lots l WHERE l.source_product_id = v_atomic_source_product
  ) OR EXISTS (
    SELECT 1 FROM public.products p
    WHERE p.nocopk = v_atomic_source_product AND p.storage_location_id = v_consumed_loc
  ) THEN
    RAISE EXCEPTION 'Atomic Product-backed inoculation left a partial Product -> Lot transition after failure.';
  END IF;
END;
$test$;

ROLLBACK;
