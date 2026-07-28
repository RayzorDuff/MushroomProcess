\set ON_ERROR_STOP on

-- Transactional component test for issue #16.
-- Exercises the same Sterilizer IN/OUT mutation functions called by Appsmith
-- and verifies that input casing is normalized to Airtable display-case values.
BEGIN;

DO $test$
DECLARE
  v_item_id bigint;
  v_recipe_id bigint;
  v_location_id bigint;
  v_run_id bigint;
  v_lot_id bigint;
  v_start timestamp without time zone;
  v_end timestamp without time zone;
  v_run record;
  v_lot record;
BEGIN
  SELECT nocopk INTO v_item_id
  FROM public.items
  WHERE item_id = 'GRAIN-BAG'
  LIMIT 1;

  SELECT nocopk INTO v_recipe_id
  FROM public.recipes
  WHERE recipe_id = 'REC-GRAIN-WBS'
  LIMIT 1;

  SELECT nocopk INTO v_location_id
  FROM public.locations
  WHERE lower(btrim(name)) = 'new lots'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  IF v_item_id IS NULL OR v_recipe_id IS NULL OR v_location_id IS NULL THEN
    RAISE EXCEPTION 'Sterilizer process-type fixtures are missing from imported data.';
  END IF;

  -- Lowercase Appsmith input must be stored and reported as Sterilize.
  v_start := timestamp '2026-07-15 08:00:00';
  v_end := timestamp '2026-07-15 09:00:00';

  v_run_id := public.mp_sterilizer_start_run(
    p_planned_item_id => v_item_id,
    p_planned_recipe_id => v_recipe_id,
    p_planned_count => 1,
    p_planned_unit_size => 1.5,
    p_process_type => 'sterilize',
    p_start_time => v_start,
    p_operator => 'RC5 #16 smoke test',
    p_notes => 'Rollback-only Sterilize casing test'
  );

  SELECT process_type, target_temp_c, pressure_mode, start_time
  INTO v_run
  FROM public.sterilization_runs
  WHERE nocopk = v_run_id;

  IF v_run.process_type <> 'Sterilize'
     OR v_run.target_temp_c <> 121
     OR v_run.pressure_mode <> 'Closed'
     OR v_run.start_time <> v_start THEN
    RAISE EXCEPTION 'Sterilize normalization/defaults are incorrect: %', row_to_json(v_run);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.events e
    WHERE e.type = 'SterilizerRunCreated'
      AND e.operator = 'RC5 #16 smoke test'
      AND e.timestamp = v_start
      AND e.fields_json::jsonb ->> 'process_type' = 'Sterilize'
      AND (e.fields_json::jsonb ->> 'steri_run_nocopk')::bigint = v_run_id
  ) THEN
    RAISE EXCEPTION 'SterilizerRunCreated did not preserve canonical Sterilize metadata.';
  END IF;

  PERFORM 1
  FROM public.mp_sterilizer_complete_run(
    v_run_id,
    1,
    0,
    'RC5 #16 smoke test',
    v_end,
    v_location_id
  );

  SELECT nocopk, status, process_type_mat, sterilized_at
  INTO v_lot
  FROM public.lots
  WHERE steri_run_id = v_run_id;

  IF v_lot.status <> 'Sterilized'
     OR v_lot.process_type_mat <> 'Sterilize'
     OR v_lot.sterilized_at <> v_end THEN
    RAISE EXCEPTION 'Sterilize completion fields are incorrect: %', row_to_json(v_lot);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.events e
    WHERE e.lot_id = v_lot.nocopk
      AND e.type = 'Sterilized'
      AND e.timestamp = v_end
      AND e.fields_json::jsonb ->> 'process_type' = 'Sterilize'
  ) THEN
    RAISE EXCEPTION 'Sterilize completion event does not use canonical process_type.';
  END IF;

  -- Mixed-case/whitespace input must be stored and reported as Pasteurize.
  v_start := timestamp '2026-07-15 10:00:00';
  v_end := timestamp '2026-07-15 11:00:00';

  v_run_id := public.mp_sterilizer_start_run(
    p_planned_item_id => v_item_id,
    p_planned_recipe_id => v_recipe_id,
    p_planned_count => 1,
    p_planned_unit_size => 1.5,
    p_process_type => '  pAsTeUrIzE  ',
    p_start_time => v_start,
    p_operator => 'RC5 #16 smoke test',
    p_notes => 'Rollback-only Pasteurize casing test'
  );

  SELECT process_type, target_temp_c, pressure_mode, start_time
  INTO v_run
  FROM public.sterilization_runs
  WHERE nocopk = v_run_id;

  IF v_run.process_type <> 'Pasteurize'
     OR v_run.target_temp_c <> 74
     OR v_run.pressure_mode <> 'Open'
     OR v_run.start_time <> v_start THEN
    RAISE EXCEPTION 'Pasteurize normalization/defaults are incorrect: %', row_to_json(v_run);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.events e
    WHERE e.type = 'SterilizerRunCreated'
      AND e.operator = 'RC5 #16 smoke test'
      AND e.timestamp = v_start
      AND e.fields_json::jsonb ->> 'process_type' = 'Pasteurize'
      AND (e.fields_json::jsonb ->> 'steri_run_nocopk')::bigint = v_run_id
  ) THEN
    RAISE EXCEPTION 'SterilizerRunCreated did not preserve canonical Pasteurize metadata.';
  END IF;

  PERFORM 1
  FROM public.mp_sterilizer_complete_run(
    v_run_id,
    1,
    0,
    'RC5 #16 smoke test',
    v_end,
    v_location_id
  );

  SELECT nocopk, status, process_type_mat, sterilized_at
  INTO v_lot
  FROM public.lots
  WHERE steri_run_id = v_run_id;

  IF v_lot.status <> 'Pasteurized'
     OR v_lot.process_type_mat <> 'Pasteurize'
     OR v_lot.sterilized_at <> v_end THEN
    RAISE EXCEPTION 'Pasteurize completion fields are incorrect: %', row_to_json(v_lot);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.events e
    WHERE e.lot_id = v_lot.nocopk
      AND e.type = 'Pasteurized'
      AND e.timestamp = v_end
      AND e.fields_json::jsonb ->> 'process_type' = 'Pasteurize'
  ) THEN
    RAISE EXCEPTION 'Pasteurize completion event does not use canonical process_type.';
  END IF;

  IF (
    SELECT count(*)
    FROM public.print_queue pq
    WHERE pq.run_id IN (
      SELECT sr.nocopk
      FROM public.sterilization_runs sr
      WHERE sr.operator = 'RC5 #16 smoke test'
    )
      AND pq.source_kind = 'steri_sheet'
      AND pq.label_type = 'Sterilizer_Sheet'
      AND pq.print_status = 'Queued'
  ) <> 2 THEN
    RAISE EXCEPTION 'Expected one queued sterilizer sheet for each normalized run.';
  END IF;

  RAISE NOTICE 'Sterilizer process_type normalization and completion smoke tests passed.';
END;
$test$;

ROLLBACK;
