\set ON_ERROR_STOP on

-- Transactional smoke test for #68 Sterilizer recipe-component behavior.
-- Run after 005_helpers.sql and 007_sterilizer.sql. All test data is rolled back.
BEGIN;

DO $$
DECLARE
  v_grain_item_id bigint;
  v_aio_item_id bigint;
  v_grain_recipe_id bigint;
  v_substrate_recipe_id bigint;
  v_location_id bigint;
  v_run_id bigint;
  v_lot_id bigint;
  v_count integer;
  v_weight numeric;
  v_percent numeric;
  v_component_set text;
  v_plan record;
BEGIN
  SELECT nocopk INTO v_grain_item_id
  FROM public.items
  WHERE item_id = 'GRAIN-BAG';

  SELECT nocopk INTO v_aio_item_id
  FROM public.items
  WHERE item_id = 'AIO-BAG';

  SELECT nocopk INTO v_grain_recipe_id
  FROM public.recipes
  WHERE recipe_id = 'REC-GRAIN-WBS';

  SELECT nocopk INTO v_substrate_recipe_id
  FROM public.recipes
  WHERE recipe_id = 'REC-SUB-CVG-RIZ-V1';

  SELECT nocopk INTO v_location_id
  FROM public.locations
  WHERE lower(btrim(name)) = 'new lots'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  IF v_grain_item_id IS NULL
     OR v_aio_item_id IS NULL
     OR v_grain_recipe_id IS NULL
     OR v_substrate_recipe_id IS NULL
     OR v_location_id IS NULL THEN
    RAISE EXCEPTION 'Smoke-test fixtures are missing from the imported Airtable data.';
  END IF;

  -- single_recipe plan and completion create exactly one component row.
  SELECT * INTO v_plan
  FROM public.mp_sterilizer_validate_component_plan(
    v_grain_item_id,
    v_grain_recipe_id,
    1.5,
    NULL
  );

  IF v_plan.component_mode <> 'single_recipe'
     OR v_plan.component_count <> 1
     OR v_plan.component_weight_sum <> 1.5 THEN
    RAISE EXCEPTION 'Unexpected single_recipe plan: %', row_to_json(v_plan);
  END IF;

  v_run_id := public.mp_sterilizer_start_run(
    p_planned_item_id => v_grain_item_id,
    p_planned_recipe_id => v_grain_recipe_id,
    p_planned_count => 1,
    p_planned_unit_size => 1.5,
    p_process_type => 'Sterilize',
    p_start_time => clock_timestamp() - interval '1 hour',
    p_operator => 'RC5 smoke test',
    p_planned_component_set => NULL
  );

  PERFORM 1
  FROM public.mp_sterilizer_complete_run(
    v_run_id,
    1,
    0,
    'RC5 smoke test',
    clock_timestamp(),
    v_location_id
  );

  SELECT l.nocopk INTO v_lot_id
  FROM public.lots l
  WHERE l.steri_run_id = v_run_id;

  SELECT count(*), sum(component_weight_lb)
  INTO v_count, v_weight
  FROM public.lot_recipe_components
  WHERE lot_id = v_lot_id;

  IF v_count <> 1 OR v_weight <> 1.5 THEN
    RAISE EXCEPTION 'single_recipe lot components were not created correctly: count %, weight %',
      v_count, v_weight;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public._m2m_lots_lot_recipe_components_lot_recipe_components j
    JOIN public.lot_recipe_components lrc
      ON lrc.nocopk = j.lot_recipe_components_id
    WHERE j.lots_id = v_lot_id
      AND lrc.lot_id = v_lot_id
  ) THEN
    RAISE EXCEPTION 'single_recipe inverse lot/component link is missing.';
  END IF;

  -- AIO has one active set for five-pound units, so IN auto-selects it.
  SELECT * INTO v_plan
  FROM public.mp_sterilizer_validate_component_plan(
    v_aio_item_id,
    NULL,
    5,
    NULL
  );

  IF v_plan.component_mode <> 'multi_recipe'
     OR v_plan.resolved_component_set <> 'WBS_CVG_RIZ1'
     OR v_plan.component_count <> 2
     OR v_plan.component_weight_sum <> 5 THEN
    RAISE EXCEPTION 'Unexpected multi_recipe plan: %', row_to_json(v_plan);
  END IF;

  v_run_id := public.mp_sterilizer_start_run(
    p_planned_item_id => v_aio_item_id,
    p_planned_recipe_id => NULL,
    p_planned_count => 1,
    p_planned_unit_size => 5,
    p_process_type => 'Sterilize',
    p_start_time => clock_timestamp() - interval '1 hour',
    p_operator => 'RC5 smoke test',
    p_planned_component_set => NULL
  );

  SELECT planned_component_set INTO v_component_set
  FROM public.sterilization_runs
  WHERE nocopk = v_run_id;

  IF v_component_set <> 'WBS_CVG_RIZ1' THEN
    RAISE EXCEPTION 'Sterilizer IN did not store the auto-selected component set: %', v_component_set;
  END IF;

  PERFORM 1
  FROM public.mp_sterilizer_complete_run(
    v_run_id,
    1,
    0,
    'RC5 smoke test',
    clock_timestamp(),
    v_location_id
  );

  SELECT l.nocopk INTO v_lot_id
  FROM public.lots l
  WHERE l.steri_run_id = v_run_id;

  SELECT count(*), sum(component_weight_lb), sum(component_percent)
  INTO v_count, v_weight, v_percent
  FROM public.lot_recipe_components
  WHERE lot_id = v_lot_id;

  IF v_count <> 2 OR v_weight <> 5 OR abs(v_percent - 100) >= 0.000001 THEN
    RAISE EXCEPTION 'multi_recipe lot components were not created correctly: count %, weight %, percent %',
      v_count, v_weight, v_percent;
  END IF;

  IF (
    SELECT count(*)
    FROM public._m2m_lots_lot_recipe_components_lot_recipe_components j
    WHERE j.lots_id = v_lot_id
  ) <> 2 THEN
    RAISE EXCEPTION 'multi_recipe inverse lot/component links are incomplete.';
  END IF;

  IF (
    SELECT count(*)
    FROM public.lot_recipe_components lrc
    WHERE lrc.lot_id = v_lot_id
      AND lrc.source_item_recipe_component_id IS NOT NULL
  ) <> 2 THEN
    RAISE EXCEPTION 'multi_recipe source component lineage is incomplete.';
  END IF;

  -- Add a second active set inside this rollback-only test and prove that a
  -- blank planned_component_set is rejected before a run is created.
  INSERT INTO public.item_recipe_components
    (component_id, active, item_id, component_set, recipe_id,
     component_role, unit_size_lb, default_weight_lb, sort_order, notes)
  VALUES
    ('IRC-RC5-SMOKE-G', true, v_aio_item_id, 'RC5_ALT', v_grain_recipe_id,
     'grain', 5, 2, 1, 'Rollback-only RC5 smoke fixture'),
    ('IRC-RC5-SMOKE-S', true, v_aio_item_id, 'RC5_ALT', v_substrate_recipe_id,
     'substrate', 5, 3, 2, 'Rollback-only RC5 smoke fixture');

  BEGIN
    PERFORM public.mp_sterilizer_start_run(
      p_planned_item_id => v_aio_item_id,
      p_planned_recipe_id => NULL,
      p_planned_count => 1,
      p_planned_unit_size => 5,
      p_process_type => 'Sterilize',
      p_start_time => clock_timestamp(),
      p_operator => 'RC5 smoke test',
      p_planned_component_set => NULL
    );
    RAISE EXCEPTION 'Expected missing-component-set validation did not occur.';
  EXCEPTION WHEN OTHERS THEN
    IF position('planned_component_set is required' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
  END;

  RAISE NOTICE 'Sterilizer component-mode smoke tests passed.';
END;
$$;

ROLLBACK;
