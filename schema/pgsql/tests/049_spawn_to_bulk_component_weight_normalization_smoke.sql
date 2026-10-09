\set ON_ERROR_STOP on

-- Regression smoke test for Spawn-to-Bulk source component weight normalization.
-- Covers the Product-return case where the packaged substrate weight is
-- 8.499993882... lb while its preserved origin component history totals 8.5 lb.
-- All fixtures and outputs are rolled back.

BEGIN;

DO $test$
DECLARE
  v_dark_loc bigint;
  v_consumed_loc bigint;
  v_grain_item bigint;
  v_sub_item bigint;
  v_output_item bigint;
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
  v_now timestamp without time zone := clock_timestamp()::timestamp without time zone;
  v_returned_unit_size numeric;
  v_returned_component_sum numeric;
  v_output_unit_size numeric;
  v_output_component_sum numeric;
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

  SELECT nocopk INTO v_grain_item
  FROM public.items
  WHERE item_id = 'GRAIN-BAG'
  LIMIT 1;

  SELECT nocopk INTO v_sub_item
  FROM public.items
  WHERE item_id = 'SUB-CVG-BAG'
  LIMIT 1;

  SELECT nocopk INTO v_output_item
  FROM public.items
  WHERE item_id = 'FB-GENERIC'
  LIMIT 1;

  SELECT nocopk INTO v_grain_recipe
  FROM public.recipes
  WHERE recipe_id = 'REC-GRAIN-WBS'
  LIMIT 1;

  SELECT nocopk INTO v_sub_recipe
  FROM public.recipes
  WHERE recipe_id = 'REC-SUB-CVG-V2'
  LIMIT 1;

  SELECT nocopk INTO v_strain
  FROM public.strains
  WHERE COALESCE(active, false)
    AND NULLIF(btrim(species_strain), '') IS NOT NULL
  ORDER BY nocopk
  LIMIT 1;

  IF v_dark_loc IS NULL OR v_consumed_loc IS NULL
     OR v_grain_item IS NULL OR v_sub_item IS NULL OR v_output_item IS NULL
     OR v_grain_recipe IS NULL OR v_sub_recipe IS NULL OR v_strain IS NULL THEN
    RAISE EXCEPTION 'Spawn-to-Bulk component normalization smoke fixtures are missing required imported data.';
  END IF;

  INSERT INTO public.lots(
    lot_id, item_id, item_name_mat, item_category_mat, recipe_id, strain_id,
    strain_species_strain_mat, qty, unit_size, status, location_id,
    created_at, inoculated_at, use_by
  )
  SELECT
    'LOT-049-GRAIN', v_grain_item, i.name, 'grain', v_grain_recipe, v_strain,
    s.species_strain, 1, 1.5, 'Colonizing', v_dark_loc,
    v_now - interval '10 days', v_now - interval '10 days', v_now::date + 60
  FROM public.items i
  CROSS JOIN public.strains s
  WHERE i.nocopk = v_grain_item
    AND s.nocopk = v_strain
  RETURNING nocopk INTO v_grain;

  INSERT INTO public.lot_recipe_components(
    lot_id, item_id, recipe_id, component_role, component_weight_lb,
    component_percent, sort_order, notes
  )
  VALUES (
    v_grain, v_grain_item, v_grain_recipe, 'grain', 1.5, 100, 1,
    'Rollback-only 049 grain component'
  )
  RETURNING nocopk INTO v_component;

  PERFORM public.mp_link_lot_recipe_component(
    v_component, v_grain, v_grain_item, v_grain_recipe, NULL
  );

  INSERT INTO public.lots(
    lot_id, item_id, item_name_mat, item_category_mat, recipe_id,
    qty, unit_size, status, location_id, created_at, sterilized_at,
    use_by, process_type_mat
  )
  SELECT
    'LOT-049-SUB-ORIGIN', v_sub_item, i.name, 'substrate', v_sub_recipe,
    1, 8.5, 'Consumed', v_consumed_loc, v_now - interval '20 days',
    v_now - interval '20 days', v_now::date + 30, 'Sterilize'
  FROM public.items i
  WHERE i.nocopk = v_sub_item
  RETURNING nocopk INTO v_sub_origin;

  INSERT INTO public.lot_recipe_components(
    lot_id, item_id, recipe_id, component_role, component_weight_lb,
    component_percent, sort_order, notes
  )
  VALUES (
    v_sub_origin, v_sub_item, v_sub_recipe, 'substrate', 8.5, 100, 1,
    'Rollback-only 049 substrate component'
  )
  RETURNING nocopk INTO v_component;

  PERFORM public.mp_link_lot_recipe_component(
    v_component, v_sub_origin, v_sub_item, v_sub_recipe, NULL
  );

  -- 3855.53237 g converts to approximately 8.4999938821722244 lb, matching
  -- the measured value in the reported production failure.
  INSERT INTO public.products(
    product_id, item_id, name_mat, item_category_mat, net_weight_g,
    pack_date, use_by, storage_location_id, origin_lot_ids_json, process_type_mat
  )
  SELECT
    'PROD-049-SUB', v_sub_item, i.name, 'substrate', 3855.53237,
    v_now::date - 5, v_now::date + 25, NULL,
    to_jsonb(ARRAY['LOT-049-SUB-ORIGIN'])::text, 'Sterilize'
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
    p_operator => '049 regression',
    p_station => 'Spawn to Bulk',
    p_timestamp => v_now,
    p_note => 'Rollback-only source component normalization regression'
  );

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Expected one Spawn-to-Bulk output, got %.', v_count;
  END IF;

  SELECT l.nocopk, l.unit_size
  INTO v_returned_sub, v_returned_unit_size
  FROM public.lots l
  WHERE l.source_product_id = v_product;

  IF v_returned_sub IS NULL THEN
    RAISE EXCEPTION 'Product-backed Spawn-to-Bulk did not create the returned substrate Lot.';
  END IF;

  SELECT COALESCE(sum(component_weight_lb), 0)
  INTO v_returned_component_sum
  FROM public.lot_recipe_components
  WHERE lot_id = v_returned_sub;

  -- The returned Lot retains the historical 8.5 lb component total; the
  -- Spawn-to-Bulk operation must normalize that contribution to the Lot's
  -- actual measured 8.499993882... lb unit_size.
  IF abs(v_returned_unit_size - 8.4999938821722244) >= 0.000001 THEN
    RAISE EXCEPTION 'Unexpected returned substrate unit_size: %.', v_returned_unit_size;
  END IF;

  IF abs(v_returned_component_sum - 8.5) >= 0.000001 THEN
    RAISE EXCEPTION 'Regression fixture did not preserve the 8.5 lb source component total: %.', v_returned_component_sum;
  END IF;

  SELECT l.nocopk, l.unit_size
  INTO v_output, v_output_unit_size
  FROM public.lots l
  JOIN public._m2m_lots_lots_substrate_inputs x
    ON x.lots_id = l.nocopk
  WHERE x.lots1_id = v_returned_sub
    AND l.spawned_at = v_now
  LIMIT 1;

  IF v_output IS NULL THEN
    RAISE EXCEPTION 'Product-backed Spawn-to-Bulk did not create an output Lot.';
  END IF;

  SELECT COALESCE(sum(component_weight_lb), 0)
  INTO v_output_component_sum
  FROM public.lot_recipe_components
  WHERE lot_id = v_output;

  IF abs(v_output_component_sum - v_output_unit_size) >= 0.000001 THEN
    RAISE EXCEPTION
      'Spawn-to-Bulk component normalization failed: output components total % lb but unit_size is % lb.',
      v_output_component_sum,
      v_output_unit_size;
  END IF;

  IF (
    SELECT count(*)
    FROM public.lot_recipe_components lrc
    WHERE lrc.lot_id = v_output
      AND lrc.component_role = 'substrate'
      AND abs(lrc.component_weight_lb - 8.4999938821722244) < 0.000001
  ) <> 1 THEN
    RAISE EXCEPTION 'Normalized substrate contribution was not preserved on the output Lot.';
  END IF;

  IF (
    SELECT count(*)
    FROM public.lot_recipe_components lrc
    WHERE lrc.lot_id = v_output
      AND lrc.component_role = 'grain'
      AND abs(lrc.component_weight_lb - 1.5) < 0.000001
  ) <> 1 THEN
    RAISE EXCEPTION 'Grain contribution changed unexpectedly during normalization.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.print_queue q
    WHERE q.lot_id = v_returned_sub
  ) THEN
    RAISE EXCEPTION 'Returned substrate Lot incorrectly received an intermediate label.';
  END IF;

  RAISE NOTICE 'Spawn-to-Bulk component weight normalization regression passed.';
END;
$test$;

ROLLBACK;
