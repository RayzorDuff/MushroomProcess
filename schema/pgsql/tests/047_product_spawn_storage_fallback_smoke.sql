\set ON_ERROR_STOP on

-- Issue #57 regression: a packaged substrate Product may have no
-- storage_location_id. Spawn-to-Bulk must still be able to return it to a
-- temporary Lot by using the selected Spawn-to-Bulk location.
BEGIN;

DO $test$
DECLARE
  v_dark_loc bigint;
  v_consumed_loc bigint;
  v_grain_item bigint;
  v_sub_item bigint;
  v_grain_recipe bigint;
  v_sub_recipe bigint;
  v_strain bigint;
  v_grain bigint;
  v_sub_origin bigint;
  v_component bigint;
  v_product bigint;
  v_returned_sub bigint;
  v_output bigint;
  v_count integer;
  v_now timestamp without time zone := now();
BEGIN
  SELECT nocopk INTO v_dark_loc
  FROM public.locations
  WHERE regexp_replace(lower(btrim(name)), '[^a-z0-9]', '', 'g') = 'darkroom'
    AND COALESCE(active, false)
  ORDER BY nocopk
  LIMIT 1;

  SELECT nocopk INTO v_consumed_loc
  FROM public.locations
  WHERE regexp_replace(lower(btrim(name)), '[^a-z0-9]', '', 'g') = 'consumed'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  SELECT nocopk INTO v_grain_item FROM public.items WHERE item_id = 'GRAIN-BAG' LIMIT 1;
  SELECT nocopk INTO v_sub_item FROM public.items WHERE item_id = 'SUB-CVG-BAG' LIMIT 1;
  SELECT nocopk INTO v_grain_recipe FROM public.recipes WHERE recipe_id = 'REC-GRAIN-WBS' LIMIT 1;
  SELECT nocopk INTO v_sub_recipe FROM public.recipes WHERE recipe_id = 'REC-SUB-CVG-V2' LIMIT 1;
  SELECT nocopk INTO v_strain
  FROM public.strains
  WHERE COALESCE(active, false)
    AND NULLIF(btrim(species_strain), '') IS NOT NULL
  ORDER BY nocopk
  LIMIT 1;

  IF v_dark_loc IS NULL OR v_consumed_loc IS NULL
     OR v_grain_item IS NULL OR v_sub_item IS NULL
     OR v_grain_recipe IS NULL OR v_sub_recipe IS NULL OR v_strain IS NULL THEN
    RAISE EXCEPTION 'Issue #57 storage fallback smoke fixtures are missing required imported data.';
  END IF;

  INSERT INTO public.lots(
    lot_id, item_id, item_name_mat, item_category_mat, recipe_id, strain_id,
    strain_species_strain_mat, qty, unit_size, status, location_id,
    created_at, inoculated_at, use_by
  )
  SELECT
    'LOT-ISS57-047-GRAIN', v_grain_item, i.name, 'grain', v_grain_recipe, v_strain,
    s.species_strain, 1, 2, 'Colonizing', v_dark_loc,
    v_now - interval '10 days', v_now - interval '10 days', v_now::date + 60
  FROM public.items i
  CROSS JOIN public.strains s
  WHERE i.nocopk = v_grain_item AND s.nocopk = v_strain
  RETURNING nocopk INTO v_grain;

  INSERT INTO public.lot_recipe_components(
    lot_id, item_id, recipe_id, component_role, component_weight_lb,
    component_percent, sort_order, notes
  ) VALUES (
    v_grain, v_grain_item, v_grain_recipe, 'grain', 2, 100, 1,
    'Issue 57 047 grain component'
  ) RETURNING nocopk INTO v_component;
  PERFORM public.mp_link_lot_recipe_component(v_component, v_grain, v_grain_item, v_grain_recipe, NULL);

  INSERT INTO public.lots(
    lot_id, item_id, item_name_mat, item_category_mat, recipe_id,
    qty, unit_size, status, location_id, created_at, sterilized_at,
    use_by, process_type_mat
  )
  SELECT
    'LOT-ISS57-047-SUB-ORIGIN', v_sub_item, i.name, 'substrate', v_sub_recipe,
    1, 2, 'Consumed', v_consumed_loc, v_now - interval '20 days',
    v_now - interval '20 days', v_now + 30, 'Sterilize'
  FROM public.items i
  WHERE i.nocopk = v_sub_item
  RETURNING nocopk INTO v_sub_origin;

  INSERT INTO public.lot_recipe_components(
    lot_id, item_id, recipe_id, component_role, component_weight_lb,
    component_percent, sort_order, notes
  ) VALUES (
    v_sub_origin, v_sub_item, v_sub_recipe, 'substrate', 2, 100, 1,
    'Issue 57 047 substrate component'
  ) RETURNING nocopk INTO v_component;
  PERFORM public.mp_link_lot_recipe_component(v_component, v_sub_origin, v_sub_item, v_sub_recipe, NULL);

  -- Deliberately omit storage_location_id: this is the legacy/market-product
  -- case that previously failed inside mp_product_return_to_lot.
  INSERT INTO public.products(
    product_id, item_id, name_mat, item_category_mat, net_weight_g,
    pack_date, use_by, storage_location_id, origin_lot_ids_json, process_type_mat
  )
  SELECT
    'PROD-ISS57-047-SUB', v_sub_item, i.name, 'substrate', 907.18474,
    v_now::date - 5, v_now::date + 25, NULL,
    to_jsonb(ARRAY['LOT-ISS57-047-SUB-ORIGIN'])::text, 'Sterilize'
  FROM public.items i
  WHERE i.nocopk = v_sub_item
  RETURNING nocopk INTO v_product;

  INSERT INTO public._m2m_products_lots_origin_lots(products_id, lots_id)
  VALUES (v_product, v_sub_origin);

  v_count := public.mp_spawn_to_bulk_with_products(
    p_grain_lot_ids => ARRAY[v_grain],
    p_substrate_product_ids => ARRAY[v_product],
    p_output_count => 1,
    p_output_plan_json => '[{"item_code":"FB-GENERIC","ratio":1}]'::jsonb,
    p_storage_location_id => v_dark_loc,
    p_operator => 'Issue 57 047 smoke',
    p_station => 'Spawn to Bulk',
    p_timestamp => v_now,
    p_note => 'Product without storage location'
  );

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Expected one Spawn-to-Bulk output, got %.', v_count;
  END IF;

  SELECT l.nocopk INTO v_returned_sub
  FROM public.lots l
  WHERE l.source_product_id = v_product;

  IF v_returned_sub IS NULL THEN
    RAISE EXCEPTION 'Product without storage location did not create a returned substrate Lot.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.lots l
    WHERE l.nocopk = v_returned_sub
      AND l.location_id = v_dark_loc
  ) THEN
    RAISE EXCEPTION 'Returned substrate Lot did not receive the selected Spawn-to-Bulk storage location.';
  END IF;

  SELECT DISTINCT output.nocopk INTO v_output
  FROM public.lots output
  JOIN public._m2m_lots_lots_substrate_inputs x ON x.lots_id = output.nocopk
  WHERE x.lots1_id = v_returned_sub
    AND output.spawned_at = v_now;

  IF v_output IS NULL THEN
    RAISE EXCEPTION 'Product-backed Spawn-to-Bulk did not create an output lot.';
  END IF;

  IF EXISTS (SELECT 1 FROM public.print_queue q WHERE q.lot_id = v_returned_sub) THEN
    RAISE EXCEPTION 'Returned substrate Lot incorrectly received an intermediate label.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.lots l
    WHERE l.nocopk = v_output AND l.label_template = 'Bulk_Created'
  ) THEN
    RAISE EXCEPTION 'Product-backed Spawn-to-Bulk output did not retain Bulk_Created label policy.';
  END IF;
END;
$test$;

ROLLBACK;
