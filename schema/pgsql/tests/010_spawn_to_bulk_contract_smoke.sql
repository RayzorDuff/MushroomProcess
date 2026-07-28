\set ON_ERROR_STOP on

-- Transactional component test for issues #1, #52, and the schema portion of #54.
-- Exercises unequal output plans, override/no-override timestamps, controlled
-- fruiting goals, events, computed label fields, print rows, and source use.
BEGIN;

DO $test$
DECLARE
  v_grain_item_id bigint;
  v_substrate_item_id bigint;
  v_bag_output_item_id bigint;
  v_tub_output_item_id bigint;
  v_grain_recipe_id bigint;
  v_substrate_recipe_id bigint;
  v_location_id bigint;
  v_strain_id bigint;

  v_grain_lot_id bigint;
  v_substrate_lot_id bigint;
  v_grain_lot_2_id bigint;
  v_substrate_lot_2_id bigint;
  v_grain_lot_3_id bigint;
  v_substrate_lot_3_id bigint;
  v_created_count integer;
  v_output_ids bigint[];
  v_output record;
  v_override_ts timestamp without time zone := timestamp '2026-05-01 14:30:45';
  v_request_ts timestamp without time zone := timestamp '2026-07-15 15:00:00';
  v_no_override_ts timestamp without time zone := timestamp '2026-06-02 09:10:11';
  v_side_ts timestamp without time zone := timestamp '2026-06-03 10:11:12';
  v_expected_grain numeric;
  v_expected_substrate numeric;
BEGIN
  SELECT nocopk INTO v_grain_item_id
  FROM public.items
  WHERE item_id = 'GRAIN-BAG'
  LIMIT 1;

  SELECT nocopk INTO v_substrate_item_id
  FROM public.items
  WHERE item_id = 'SUB-CVG-BAG'
  LIMIT 1;

  SELECT nocopk INTO v_bag_output_item_id
  FROM public.items
  WHERE item_id = 'FB-CVG-BAG'
  LIMIT 1;

  SELECT nocopk INTO v_tub_output_item_id
  FROM public.items
  WHERE item_id = 'FB-CVG-TUB'
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
     OR v_bag_output_item_id IS NULL
     OR v_tub_output_item_id IS NULL
     OR v_grain_recipe_id IS NULL
     OR v_substrate_recipe_id IS NULL
     OR v_location_id IS NULL
     OR v_strain_id IS NULL THEN
    RAISE EXCEPTION 'Spawn contract fixtures are missing from imported data.';
  END IF;

  -- Pair 1: 2 lb grain + 8 lb substrate, allocated 3:7 to two different
  -- output types. This covers issue #1 and uses an override date for #52.
  INSERT INTO public.lots (
    lot_id, item_id, item_name_mat, item_category_mat, recipe_id,
    strain_id, strain_species_strain_mat, qty, unit_size, status,
    location_id, created_at, sterilized_at, inoculated_at, notes
  )
  SELECT
    'LOT-RC5-SPAWN-CONTRACT-G1', v_grain_item_id, i.name, 'grain',
    v_grain_recipe_id, v_strain_id, s.species_strain, 1, 2,
    'FullyColonized', v_location_id, v_override_ts - interval '10 days',
    v_override_ts - interval '10 days', v_override_ts - interval '8 days',
    'Rollback-only #1/#52/#54 grain source'
  FROM public.items i
  JOIN public.strains s ON s.nocopk = v_strain_id
  WHERE i.nocopk = v_grain_item_id
  RETURNING nocopk INTO v_grain_lot_id;

  INSERT INTO public.lots (
    lot_id, item_id, item_name_mat, item_category_mat, recipe_id,
    qty, unit_size, status, location_id, created_at, sterilized_at, notes
  )
  SELECT
    'LOT-RC5-SPAWN-CONTRACT-S1', v_substrate_item_id, i.name,
    'substrate', v_substrate_recipe_id, 1, 8, 'Sterilized',
    v_location_id, v_override_ts - interval '5 days',
    v_override_ts - interval '5 days',
    'Rollback-only #1/#52/#54 substrate source'
  FROM public.items i
  WHERE i.nocopk = v_substrate_item_id
  RETURNING nocopk INTO v_substrate_lot_id;

  -- Controlled vocabulary must reject unsupported values before mutation.
  BEGIN
    PERFORM public.mp_lots_spawn_to_bulk(
      p_grain_lot_ids => ARRAY[v_grain_lot_id],
      p_substrate_lot_ids => ARRAY[v_substrate_lot_id],
      p_output_count => 1,
      p_output_plan_json => '[]'::jsonb,
      p_storage_location_id => v_location_id,
      p_override_spawn_time => v_override_ts,
      p_operator => 'RC5 spawn contract smoke test',
      p_station => 'Spawn to Bulk',
      p_timestamp => v_request_ts,
      p_note => 'Rollback-only invalid goal attempt',
      p_fruiting_goal => 'invalid-goal'
    );
    RAISE EXCEPTION 'Expected invalid fruiting-goal validation did not occur.';
  EXCEPTION WHEN OTHERS THEN
    IF position('Fruiting goal must be top, side, shoebox, or monotub' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
  END;

  IF EXISTS (
    SELECT 1 FROM public.lots
    WHERE notes = 'Rollback-only invalid goal attempt'
  ) THEN
    RAISE EXCEPTION 'Invalid fruiting goal created an output lot.';
  END IF;

  v_created_count := public.mp_lots_spawn_to_bulk(
    p_grain_lot_ids => ARRAY[v_grain_lot_id],
    p_substrate_lot_ids => ARRAY[v_substrate_lot_id],
    p_output_count => 2,
    p_output_plan_json => '[
      {"item_code":"FB-CVG-BAG","ratio":3},
      {"item_code":"FB-CVG-TUB","ratio":7}
    ]'::jsonb,
    p_storage_location_id => v_location_id,
    p_override_spawn_time => v_override_ts,
    p_operator => 'RC5 spawn contract smoke test',
    p_station => 'Spawn to Bulk',
    p_timestamp => v_request_ts,
    p_note => 'Rollback-only unequal override spawn test',
    p_fruiting_goal => 'MONOTUB'
  );

  IF v_created_count <> 2 THEN
    RAISE EXCEPTION 'Expected two unequal Spawn to Bulk outputs, got %.', v_created_count;
  END IF;

  SELECT COALESCE(array_agg(nocopk ORDER BY nocopk), ARRAY[]::bigint[])
  INTO v_output_ids
  FROM public.lots
  WHERE notes = 'Rollback-only unequal override spawn test';

  IF cardinality(v_output_ids) <> 2 THEN
    RAISE EXCEPTION 'Could not resolve the two unequal Spawn to Bulk outputs.';
  END IF;

  FOR v_output IN
    SELECT l.nocopk, l.item_id, l.unit_size, l.created_at, l.spawned_at,
           l.use_by, l.fruiting_goal, l.label_template
    FROM public.lots l
    WHERE l.nocopk = ANY(v_output_ids)
    ORDER BY l.unit_size
  LOOP
    IF v_output.unit_size = 3 THEN
      IF v_output.item_id <> v_bag_output_item_id THEN
        RAISE EXCEPTION '3 lb ratio output did not retain FB-CVG-BAG.';
      END IF;
      v_expected_grain := 0.6;
      v_expected_substrate := 2.4;
    ELSIF v_output.unit_size = 7 THEN
      IF v_output.item_id <> v_tub_output_item_id THEN
        RAISE EXCEPTION '7 lb ratio output did not retain FB-CVG-TUB.';
      END IF;
      v_expected_grain := 1.4;
      v_expected_substrate := 5.6;
    ELSE
      RAISE EXCEPTION 'Unexpected ratio output size: %', v_output.unit_size;
    END IF;

    IF v_output.created_at <> v_override_ts
       OR v_output.spawned_at <> v_override_ts
       OR v_output.use_by <> (v_override_ts::date + interval '3 months')::date
       OR v_output.fruiting_goal <> 'monotub'
       OR v_output.label_template <> 'Bulk_Created' THEN
      RAISE EXCEPTION 'Override/goal output fields are incorrect: %', row_to_json(v_output);
    END IF;

    IF (
      SELECT count(*)
      FROM public.lot_recipe_components c
      WHERE c.lot_id = v_output.nocopk
        AND c.component_role = 'grain'
        AND abs(c.component_weight_lb - v_expected_grain) < 0.000001
    ) <> 1 OR (
      SELECT count(*)
      FROM public.lot_recipe_components c
      WHERE c.lot_id = v_output.nocopk
        AND c.component_role = 'substrate'
        AND abs(c.component_weight_lb - v_expected_substrate) < 0.000001
    ) <> 1 OR abs((
      SELECT COALESCE(sum(c.component_weight_lb), 0)
      FROM public.lot_recipe_components c
      WHERE c.lot_id = v_output.nocopk
    ) - v_output.unit_size) >= 0.000001 THEN
      RAISE EXCEPTION 'Ratio output % component allocation is incorrect.', v_output.nocopk;
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM public.events e
      WHERE e.lot_id = v_output.nocopk
        AND e.type = 'SpawnedToBulk'
        AND e.timestamp = v_override_ts
        AND e.fields_json::jsonb ->> 'fruiting_goal' = 'monotub'
        AND e.fields_json::jsonb ->> 'output_item_code' IN ('FB-CVG-BAG', 'FB-CVG-TUB')
        AND jsonb_array_length(e.fields_json::jsonb -> 'output_plan_json') = 2
    ) THEN
      RAISE EXCEPTION 'Ratio output % event metadata/timestamp is incomplete.', v_output.nocopk;
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM public.vc_print_queue q
      WHERE q.lot_id = v_output.nocopk
        AND q.source_kind = 'lot'
        AND q.label_type = 'Bulk_Created'
        AND q.print_status = 'Queued'
        AND q.label_spawned_line_from_lot_id = ARRAY['Spawned: 2026-05-01']::text[]
        AND q.label_useby_line_from_lot_id = ARRAY['Use by: 2026-08-01']::text[]
    ) THEN
      RAISE EXCEPTION 'Ratio output % print queue label data did not use the override date.', v_output.nocopk;
    END IF;
  END LOOP;

  IF (
    SELECT count(*) FROM public.lots
    WHERE nocopk IN (v_grain_lot_id, v_substrate_lot_id)
      AND status = 'Consumed'
  ) <> 2 THEN
    RAISE EXCEPTION 'Ratio/override test did not consume both source lots.';
  END IF;

  -- Pair 2: no override; p_timestamp must remain the effective timestamp and
  -- the supported top goal must persist to lot and event metadata.
  INSERT INTO public.lots (
    lot_id, item_id, item_name_mat, item_category_mat, recipe_id,
    strain_id, strain_species_strain_mat, qty, unit_size, status,
    location_id, created_at, inoculated_at, notes
  )
  SELECT
    'LOT-RC5-SPAWN-CONTRACT-G2', v_grain_item_id, i.name, 'grain',
    v_grain_recipe_id, v_strain_id, s.species_strain, 1, 1,
    'FullyColonized', v_location_id, v_no_override_ts - interval '8 days',
    v_no_override_ts - interval '6 days', 'Rollback-only no-override grain source'
  FROM public.items i
  JOIN public.strains s ON s.nocopk = v_strain_id
  WHERE i.nocopk = v_grain_item_id
  RETURNING nocopk INTO v_grain_lot_2_id;

  INSERT INTO public.lots (
    lot_id, item_id, item_name_mat, item_category_mat, recipe_id,
    qty, unit_size, status, location_id, created_at, sterilized_at, notes
  )
  SELECT
    'LOT-RC5-SPAWN-CONTRACT-S2', v_substrate_item_id, i.name,
    'substrate', v_substrate_recipe_id, 1, 2, 'Sterilized',
    v_location_id, v_no_override_ts - interval '4 days',
    v_no_override_ts - interval '4 days', 'Rollback-only no-override substrate source'
  FROM public.items i
  WHERE i.nocopk = v_substrate_item_id
  RETURNING nocopk INTO v_substrate_lot_2_id;

  v_created_count := public.mp_lots_spawn_to_bulk(
    p_grain_lot_ids => ARRAY[v_grain_lot_2_id],
    p_substrate_lot_ids => ARRAY[v_substrate_lot_2_id],
    p_output_count => 1,
    p_output_plan_json => '[]'::jsonb,
    p_storage_location_id => v_location_id,
    p_override_spawn_time => NULL,
    p_operator => 'RC5 spawn contract smoke test',
    p_station => 'Spawn to Bulk',
    p_timestamp => v_no_override_ts,
    p_note => 'Rollback-only no-override top-goal test',
    p_fruiting_goal => 'top'
  );

  IF v_created_count <> 1 OR NOT EXISTS (
    SELECT 1
    FROM public.lots l
    WHERE l.notes = 'Rollback-only no-override top-goal test'
      AND l.created_at = v_no_override_ts
      AND l.spawned_at = v_no_override_ts
      AND l.fruiting_goal = 'top'
      AND l.use_by = (v_no_override_ts::date + interval '3 months')::date
  ) OR NOT EXISTS (
    SELECT 1
    FROM public.events e
    JOIN public.lots l ON l.nocopk = e.lot_id
    WHERE l.notes = 'Rollback-only no-override top-goal test'
      AND e.type = 'SpawnedToBulk'
      AND e.timestamp = v_no_override_ts
      AND e.fields_json::jsonb ->> 'fruiting_goal' = 'top'
  ) THEN
    RAISE EXCEPTION 'No-override/top-goal Spawn to Bulk behavior regressed.';
  END IF;

  -- Pair 3 supplies the remaining supported side value. Shoebox is exercised
  -- by 010_spawn_to_bulk_components_smoke.sql.
  INSERT INTO public.lots (
    lot_id, item_id, item_name_mat, item_category_mat, recipe_id,
    strain_id, strain_species_strain_mat, qty, unit_size, status,
    location_id, created_at, inoculated_at, notes
  )
  SELECT
    'LOT-RC5-SPAWN-CONTRACT-G3', v_grain_item_id, i.name, 'grain',
    v_grain_recipe_id, v_strain_id, s.species_strain, 1, 1,
    'FullyColonized', v_location_id, v_side_ts - interval '8 days',
    v_side_ts - interval '6 days', 'Rollback-only side-goal grain source'
  FROM public.items i
  JOIN public.strains s ON s.nocopk = v_strain_id
  WHERE i.nocopk = v_grain_item_id
  RETURNING nocopk INTO v_grain_lot_3_id;

  INSERT INTO public.lots (
    lot_id, item_id, item_name_mat, item_category_mat, recipe_id,
    qty, unit_size, status, location_id, created_at, sterilized_at, notes
  )
  SELECT
    'LOT-RC5-SPAWN-CONTRACT-S3', v_substrate_item_id, i.name,
    'substrate', v_substrate_recipe_id, 1, 2, 'Sterilized',
    v_location_id, v_side_ts - interval '4 days',
    v_side_ts - interval '4 days', 'Rollback-only side-goal substrate source'
  FROM public.items i
  WHERE i.nocopk = v_substrate_item_id
  RETURNING nocopk INTO v_substrate_lot_3_id;

  v_created_count := public.mp_lots_spawn_to_bulk(
    p_grain_lot_ids => ARRAY[v_grain_lot_3_id],
    p_substrate_lot_ids => ARRAY[v_substrate_lot_3_id],
    p_output_count => 1,
    p_output_plan_json => '[]'::jsonb,
    p_storage_location_id => v_location_id,
    p_override_spawn_time => NULL,
    p_operator => 'RC5 spawn contract smoke test',
    p_station => 'Spawn to Bulk',
    p_timestamp => v_side_ts,
    p_note => 'Rollback-only side-goal test',
    p_fruiting_goal => 'side'
  );

  IF v_created_count <> 1 OR NOT EXISTS (
    SELECT 1
    FROM public.lots l
    WHERE l.notes = 'Rollback-only side-goal test'
      AND l.fruiting_goal = 'side'
  ) OR NOT EXISTS (
    SELECT 1
    FROM public.events e
    JOIN public.lots l ON l.nocopk = e.lot_id
    WHERE l.notes = 'Rollback-only side-goal test'
      AND e.fields_json::jsonb ->> 'fruiting_goal' = 'side'
  ) THEN
    RAISE EXCEPTION 'Supported side fruiting goal was not persisted.';
  END IF;

  RAISE NOTICE 'Spawn unequal-ratio, override/no-override timestamp, fruiting-goal, event, label, print, and source-consumption smoke tests passed.';
END;
$test$;

ROLLBACK;
