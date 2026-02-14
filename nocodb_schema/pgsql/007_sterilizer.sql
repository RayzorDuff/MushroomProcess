-- 007_sterilizer.sql

-- Start a sterilization run (Sterilizer IN) with Airtable-parity validation.
CREATE OR REPLACE FUNCTION public.mp_sterilizer_start_run(
  p_planned_item_id bigint,
  p_planned_recipe_id bigint,
  p_planned_count numeric,
  p_planned_unit_size numeric,
  p_process_type text,
  p_start_time timestamp without time zone,
  p_operator text,
  p_target_temp_c numeric DEFAULT NULL,
  p_pressure_mode text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  v_run_id bigint;
  v_err text := '';
BEGIN
  IF p_planned_item_id IS NULL THEN v_err := v_err || 'Planned Item is required. '; END IF;
  IF p_planned_recipe_id IS NULL THEN v_err := v_err || 'Planned Recipe is required. '; END IF;
  IF p_planned_count IS NULL OR p_planned_count <= 0 THEN v_err := v_err || 'Planned Count must be > 0. '; END IF;
  IF p_planned_unit_size IS NULL OR p_planned_unit_size <= 0 THEN v_err := v_err || 'Planned Unit Size must be > 0. '; END IF;

  IF p_process_type NOT IN ('sterilize','pasteurize') THEN
    v_err := v_err || 'Process Type must be sterilize or pasteurize. ';
  END IF;

  IF p_start_time IS NULL THEN
    v_err := v_err || 'Start Time is required. ';
  END IF;

  IF length(trim(v_err)) > 0 THEN
    RAISE EXCEPTION '%', trim(v_err);
  END IF;

  INSERT INTO "public"."sterilization_runs"
    ("planned_item_id","planned_recipe_id","planned_count","planned_unit_size",
     "process_type","start_time","operator","target_temp_c","pressure_mode",
     "ui_error","ui_error_at")
  VALUES
    (p_planned_item_id, p_planned_recipe_id, p_planned_count, p_planned_unit_size,
     p_process_type, p_start_time, p_operator, p_target_temp_c, p_pressure_mode,
     NULL, NULL)
  RETURNING "nocopk" INTO v_run_id;

  RETURN v_run_id;
END;
$$;

-- Complete a run (Sterilizer OUT): update run, validate counts, create lots,
--    write events for each created lot, write destroyed events, and enqueue steri_sheet print job.
CREATE OR REPLACE FUNCTION public.mp_sterilizer_complete_run(
  p_run_id bigint,
  p_good_count numeric,
  p_destroyed_count numeric,
  p_operator text,
  p_end_time timestamp without time zone DEFAULT NULL
)
RETURNS TABLE(end_time timestamp without time zone, lots_created integer, print_queue_id bigint)
LANGUAGE plpgsql
AS $$
DECLARE
  v_run record;
  v_end timestamp without time zone;
  v_total numeric;
  v_item_name text;
  v_item_category text;
  v_status text;
  v_evt_id bigint;
  v_pq_id bigint;
  v_n integer;
  v_lot_id bigint;
BEGIN
  SELECT sr.*, i."name" AS item_name, i."category" AS item_category
    INTO v_run
  FROM "public"."sterilization_runs" sr
  LEFT JOIN "public"."items" i ON i."nocopk" = sr."planned_item_id"
  WHERE sr."nocopk" = p_run_id
  FOR UPDATE OF sr;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Run not found: %', p_run_id;
  END IF;

  v_end := COALESCE(p_end_time, now());
  v_total := COALESCE(p_good_count,0) + COALESCE(p_destroyed_count,0);

  IF v_run."planned_count" IS NULL OR v_run."planned_count" <= 0 THEN
    RAISE EXCEPTION 'Run planned_count is missing/invalid.';
  END IF;

  IF v_total <> v_run."planned_count" THEN
    RAISE EXCEPTION 'Good (% ) + Destroyed (%) must equal Planned (%).',
      COALESCE(p_good_count,0), COALESCE(p_destroyed_count,0), v_run."planned_count";
  END IF;

  IF COALESCE(p_good_count,0) < 0 OR COALESCE(p_destroyed_count,0) < 0 THEN
    RAISE EXCEPTION 'Counts cannot be negative.';
  END IF;

  IF v_run."start_time" IS NULL THEN
    RAISE EXCEPTION 'Run has no start_time; cannot complete.';
  END IF;

  IF v_end < v_run."start_time" THEN
    RAISE EXCEPTION 'End time cannot be before start time.';
  END IF;

  UPDATE "public"."sterilization_runs" sr
  SET
    "end_time" = v_end,
    "good_count" = p_good_count,
    "destroyed_count" = p_destroyed_count,
    "operator" = COALESCE(p_operator, sr."operator"),
    "ui_error" = NULL,
    "ui_error_at" = NULL
  WHERE sr."nocopk" = p_run_id;

  v_item_name := v_run.item_name;
  v_item_category := v_run.item_category;

  v_status := CASE
    WHEN v_run."process_type" = 'pasteurize' THEN 'Pasteurized'
    ELSE 'Sterilized'
  END;

  lots_created := 0;

  -- Idempotency guard: prevent double-creating lots for the same run.
  IF EXISTS (SELECT 1 FROM "public"."lots" l WHERE l."steri_run_id" = p_run_id) THEN
    RAISE EXCEPTION 'Lots already exist for run % (refusing to create duplicates).', p_run_id;
  END IF;


  -- Create lots (1 per planned unit).
  FOR v_n IN 1..COALESCE(p_good_count,0)::int LOOP
    INSERT INTO "public"."lots"
      ("item_name_mat","item_category_mat","process_type_mat",
       "qty","unit_size","status",
       "steri_run_id","operator","created_at","sterilized_at","use_by")
    VALUES
      (v_item_name, v_item_category, v_run."process_type",
       1, v_run."planned_unit_size", v_status,
       v_run."nocopk", p_operator, now(), v_end,
       CASE
         WHEN v_item_category IN ('grain','substrate','casing')
         THEN (v_end::date + 90)
         ELSE NULL
       END)
    RETURNING "nocopk" INTO v_lot_id;

    -- Maintain explicit run↔lot link tables (Airtable/NocoDB parity)
    PERFORM public.mp_link_sterilization_run_lot(p_run_id, v_lot_id);
    -- Propagate planned item/recipe links from the run to the created lot (Airtable/NocoDB parity)
    PERFORM public.mp_link_lot_item(v_lot_id, v_run."planned_item_id");
    PERFORM public.mp_link_lot_recipe(v_lot_id, v_run."planned_recipe_id");

    lots_created := lots_created + 1;

    -- Event: Sterilized/Pasteurized linked to each created lot (Airtable parity)
    v_evt_id := public.mp_events_insert_and_link_lot(
      v_lot_id::bigint,	
      CASE WHEN v_run."process_type" = 'pasteurize' THEN 'Pasteurized' ELSE 'Sterilized' END,
      v_end::timestamp,
      p_operator::text,
      'Sterilizer OUT'::text,
      json_build_object('run_id', v_run."nocopk")::jsonb
    );
  END LOOP;

  -- Destroyed events (not linked to any lot or product)
  FOR v_n IN 1..COALESCE(p_destroyed_count,0)::int LOOP
    PERFORM public.mp_events_insert(
      NULL,
      NULL,
      'Destroyed',
      v_end,
      p_operator,
      'Sterilizer OUT',
      json_build_object('run_id', v_run."nocopk")::text
    );
  END LOOP;

  -- Print queue: enqueue steri_sheet for this run (idempotent: do not create duplicates)
  SELECT pq."nocopk" INTO v_pq_id
  FROM "public"."print_queue" pq
  JOIN "public"."_m2m_print_queue_sterilization_runs_run_id" j
    ON j."print_queue_id" = pq."nocopk" AND j."sterilization_runs_id" = v_run."nocopk"
  WHERE pq."source_kind" = 'steri_sheet'
  ORDER BY pq."nocopk" DESC
  LIMIT 1;

  IF v_pq_id IS NULL THEN
    v_pq_id := public.mp_print_queue_enqueue(
      'steri_sheet',
      'Sterilizer_Sheet',
      NULL,
      NULL,
      v_run."nocopk",
      'Queued'

    );
  END IF;

  end_time := v_end;
  print_queue_id := v_pq_id;
  RETURN NEXT;
END;
$$;
