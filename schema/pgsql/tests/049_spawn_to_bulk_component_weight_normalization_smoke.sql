\set ON_ERROR_STOP on

-- Regression smoke test for Spawn-to-Bulk source component weight normalization.
-- Covers a source Lot whose measured unit_size is slightly different from
-- its preserved recipe-component total. All fixtures and outputs are rolled back.

BEGIN;

DO $test$
DECLARE
  v_grain_item_id bigint;
  v_substrate_item_id bigint;
  v_output_item_id bigint;
  v_grain_recipe_id bigint;
  v_substrate_recipe_id bigint;
  v_location_id bigint;
  v_strain_id bigint;

  v_grain_lot_id bigint;
  v_substrate_lot_id bigint;
  v_output_lot_id bigint;
  v_component_id bigint;
  v_created_count integer;
  v_output_unit_size numeric;
  v_output_component_sum numeric;
  v_substrate_component_weight numeric;
BEGIN
  SELECT nocopk INTO v_grain_item_id
  FROM public.items
  WHERE item_id = 'GRAIN-BAG'
  LIMIT 1;

  SELECT nocopk INTO v_substrate_item_id
  FROM public.items
  WHERE item_id = 'SUB-CVG-BAG'
  LIMIT 1;

  SELECT nocopk INTO v_output_item_id
  FROM public.items
  WHERE item_id = 'FB-COCO-SM'
  LIMIT 1;

  SELECT nocopk INTO v_grain_recipe_id
  FROM public.recipes
  WHERE recipe_id = 'REC-GRAIN-WBS'
  LIMIT 1;

  SELECT nocopk INTO v_substrate_recipe_id
  FROM public.recipes
  WHERE recipe_id IN ('REC-SUB-CVG-V2', 'REC-SUB-CVG-RIZ-V1')
  ORDER BY CASE recipe_id WHEN 'REC-SUB-CVG-V2' THEN 0 ELSE 1 END
  LIMIT 1;

  SELECT nocopk INTO v_location_id
  FROM public.locations
  WHERE lower(btrim(name)) = 'dark room'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  SELECT nocopk INTO v_strain_id
  FROM public.strains
  WHERE COALESCE(active, false)
    AND NULLIF(btrim(species_strain), '') IS NOT NULL
  ORDER BY nocopk
  LIMIT 1;

  IF v_grain_item_id IS NULL
     OR v_substrate_item_id IS NULL
     OR v_output_item_id IS NULL
     OR v_grain_recipe_id IS NULL
     OR v_substrate_recipe_id IS NULL
     OR v_location_id IS NULL
     OR v_strain_id IS NULL THEN
    RAISE EXCEPTION 'Spawn-to-Bulk weight-normalization fixtures are missing from imported data.';
  END IF;

  INSERT INTO public.lots (
    lot_id,
    item_id,
    item_name_mat,
    item_category_mat,
    recipe_id,
    strain_id,
    strain_species_strain_mat,
    qty,
    unit_size,
    status,
    location_id,
    created_at,
    sterilized_at,
    inoculated_at,
    notes
  )
  SELECT
    'LOT-SPAWN-WEIGHT-GRAIN',
    v_grain_item_id,
    i.name,
    'grain',
    v_grain_recipe_id,
    v_strain_id,
    s.species_strain,
    1,
    1.5,
    'FullyColonized',
    v_location_id,
    clock_timestamp()::timestamp without time zone - interval '10 days',
    clock_timestamp()::timestamp without time zone - interval '10 days',
    clock_timestamp()::timestamp without time zone - interval '8 days',
    'Rollback-only Spawn weight normalization grain source'
  FROM public.items i
  JOIN public.strains s ON s.nocopk = v_strain_id
  WHERE i.nocopk = v_grain_item_id
  RETURNING nocopk INTO v_grain_lot_id;

  INSERT INTO public.lots (
    lot_id,
    item_id,
    item_name_mat,
    item_category_mat,
    recipe_id,
    qty,
    unit_size,
    status,
    location_id,
    created_at,
    sterilized_at,
    notes
  )
  SELECT
    'LOT-SPAWN-WEIGHT-SUB',
    v_substrate_item_id,
    i.name,
    'substrate',
    v_substrate_recipe_id,
    1,
    8.4999938821722244,
    'Sterilized',
    v_location_id,
    clock_timestamp()::timestamp without time zone - interval '5 days',
    clock_timestamp()::timestamp without time zone - interval '5 days',
    'Rollback-only Spawn weight normalization substrate source'
  FROM public.items i
  WHERE i.nocopk = v_substrate_item_id
  RETURNING nocopk INTO v_substrate_lot_id;

  -- Deliberately preserve 8.5 lb of component history on a source Lot whose
  -- measured unit_size is 8.4999938821722244 lb.
  INSERT INTO public.lot_recipe_components (
    lot_id,
    item_id,
    recipe_id,
    component_role,
    component_weight_lb,
    component_percent,
    sort_order,
    notes
  )
  VALUES (
    v_substrate_lot_id,
    v_substrate_item_id,
    v_substrate_recipe_id,
    'substrate',
    8.5,
    100,
    1,
    'Rollback-only preserved component weight'
  )
  RETURNING nocopk INTO v_component_id;

  PERFORM public.mp_link_lot_recipe_component(
    v_component_id,
    v_substrate_lot_id,
    v_substrate_item_id,
    v_substrate_recipe_id,
    NULL
  );

  INSERT INTO public.lot_recipe_components (
    lot_id,
    item_id,
    recipe_id,
    component_role,
    component_weight_lb,
    component_percent,
    sort_order,
    notes
  )
  VALUES (
    v_grain_lot_id,
    v_grain_item_id,
    v_grain_recipe_id,
    'grain',
    1.5,
    100,
    1,
    'Rollback-only grain component'
  )
  RETURNING nocopk INTO v_component_id;

  PERFORM public.mp_link_lot_recipe_component(
    v_component_id,
    v_grain_lot_id,
    v_grain_item_id,
    v_grain_recipe_id,
    NULL
  );

  v_created_count := public.mp_lots_spawn_to_bulk(
    p_grain_lot_ids => ARRAY[v_grain_lot_id],
    p_substrate_lot_ids => ARRAY[v_substrate_lot_id],
    p_output_count => 1,
    p_output_plan_json => '[{"item_code":"FB-COCO-SM","ratio":1}]'::jsonb,
    p_storage_location_id => v_location_id,
    p_operator => 'Spawn weight normalization smoke test',
    p_station => 'Spawn to Bulk',
    p_timestamp => clock_timestamp()::timestamp without time zone,
    p_note => 'Rollback-only Spawn component weight normalization test',
    p_fruiting_goal => 'shoebox'
  );

  IF v_created_count <> 1 THEN
    RAISE EXCEPTION 'Expected one Spawn-to-Bulk output, got %.', v_created_count;
  END IF;

  SELECT l.nocopk, l.unit_size
  INTO v_output_lot_id, v_output_unit_size
  FROM public.lots l
  WHERE l.notes = 'Rollback-only Spawn component weight normalization test'
  ORDER BY l.nocopk DESC
  LIMIT 1;

  IF v_output_lot_id IS NULL THEN
    RAISE EXCEPTION 'Spawn-to-Bulk output Lot was not created.';
  END IF;

  SELECT COALESCE(sum(component_weight_lb), 0)
  INTO v_output_component_sum
  FROM public.lot_recipe_components
  WHERE lot_id = v_output_lot_id;

  SELECT component_weight_lb
  INTO v_substrate_component_weight
  FROM public.lot_recipe_components
  WHERE lot_id = v_output_lot_id
    AND component_role = 'substrate';

  IF abs(v_output_component_sum - v_output_unit_size) >= 0.000001 THEN
    RAISE EXCEPTION
      'Normalization failed: output components total % lb but unit_size is % lb.',
      v_output_component_sum,
      v_output_unit_size;
  END IF;

  IF abs(v_substrate_component_weight - 8.4999938821722244) >= 0.000001 THEN
    RAISE EXCEPTION
      'Normalized substrate component is % lb; expected % lb.',
      v_substrate_component_weight,
      8.4999938821722244;
  END IF;

  IF (
    SELECT count(*)
    FROM public.lot_recipe_components
    WHERE lot_id = v_output_lot_id
      AND component_role = 'grain'
      AND abs(component_weight_lb - 1.5) < 0.000001
  ) <> 1 THEN
    RAISE EXCEPTION 'Grain component changed unexpectedly during normalization.';
  END IF;

  RAISE NOTICE 'Spawn-to-Bulk component weight normalization regression passed.';
END;
$test$;

ROLLBACK;
