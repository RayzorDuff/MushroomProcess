-- 007_sterilizer.sql

ALTER TABLE public.sterilization_runs
  ADD COLUMN IF NOT EXISTS notes text;

-- Resolve and validate the recipe-component plan used by Sterilizer IN/OUT.
-- single_recipe items require one planned recipe. multi_recipe items derive
-- their components from active item_recipe_components for the selected size
-- and component set.
CREATE OR REPLACE FUNCTION public.mp_sterilizer_validate_component_plan(
  p_planned_item_id bigint,
  p_planned_recipe_id bigint,
  p_planned_unit_size numeric,
  p_planned_component_set text DEFAULT NULL
)
RETURNS TABLE(
  component_mode text,
  size_source text,
  resolved_component_set text,
  component_count integer,
  component_weight_sum numeric
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_item record;
  v_requested_set text := NULLIF(btrim(COALESCE(p_planned_component_set, '')), '');
  v_component_sets text[] := ARRAY[]::text[];
  v_candidate_count integer := 0;
  v_invalid_count integer := 0;
BEGIN
  IF p_planned_item_id IS NULL THEN
    RAISE EXCEPTION 'Planned Item is required.';
  END IF;

  IF p_planned_unit_size IS NULL OR p_planned_unit_size <= 0 THEN
    RAISE EXCEPTION 'Planned Unit Size must be > 0.';
  END IF;

  SELECT
    i.nocopk,
    i.item_id,
    i.name,
    lower(btrim(COALESCE(NULLIF(i.component_mode, ''), 'single_recipe'))) AS component_mode,
    lower(btrim(COALESCE(NULLIF(i.size_source, ''), 'lot_unit_size'))) AS size_source
  INTO v_item
  FROM public.items i
  WHERE i.nocopk = p_planned_item_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Planned Item not found for nocopk: %', p_planned_item_id;
  END IF;

  IF v_item.component_mode NOT IN ('single_recipe', 'multi_recipe') THEN
    RAISE EXCEPTION 'Item % has unsupported component_mode: %',
      COALESCE(v_item.item_id, p_planned_item_id::text), v_item.component_mode;
  END IF;

  component_mode := v_item.component_mode;
  size_source := v_item.size_source;

  IF p_planned_recipe_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.recipes r
    WHERE r.nocopk = p_planned_recipe_id
  ) THEN
    RAISE EXCEPTION 'Planned Recipe not found for nocopk: %', p_planned_recipe_id;
  END IF;

  IF component_mode = 'single_recipe' THEN
    IF p_planned_recipe_id IS NULL THEN
      RAISE EXCEPTION 'Planned Recipe is required for single_recipe item %.',
        COALESCE(v_item.item_id, p_planned_item_id::text);
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM public.item_recipe_components irc
      WHERE COALESCE(irc.active, false)
        AND irc.item_id = p_planned_item_id
        AND irc.recipe_id = p_planned_recipe_id
        AND (
          irc.unit_size_lb IS NULL
          OR abs(irc.unit_size_lb - p_planned_unit_size) < 0.000001
        )
    ) THEN
      RAISE EXCEPTION
        'Planned Recipe is not an active item_recipe_component for single_recipe item % at % lb.',
        COALESCE(v_item.item_id, p_planned_item_id::text), p_planned_unit_size;
    END IF;

    resolved_component_set := NULL;
    component_count := 1;
    component_weight_sum := p_planned_unit_size;
    RETURN NEXT;
    RETURN;
  END IF;

  SELECT
    count(*)::integer,
    COALESCE(
      array_agg(DISTINCT NULLIF(btrim(irc.component_set), ''))
        FILTER (WHERE NULLIF(btrim(irc.component_set), '') IS NOT NULL),
      ARRAY[]::text[]
    )
  INTO v_candidate_count, v_component_sets
  FROM public.item_recipe_components irc
  WHERE COALESCE(irc.active, false)
    AND irc.item_id = p_planned_item_id
    AND (
      irc.unit_size_lb IS NULL
      OR abs(irc.unit_size_lb - p_planned_unit_size) < 0.000001
    );

  IF v_candidate_count = 0 THEN
    RAISE EXCEPTION
      'No active item_recipe_components found for multi_recipe item % at % lb.',
      COALESCE(v_item.item_id, p_planned_item_id::text), p_planned_unit_size;
  END IF;

  IF v_requested_set IS NULL THEN
    IF cardinality(v_component_sets) > 1 THEN
      RAISE EXCEPTION
        'planned_component_set is required for multi_recipe item % at % lb. Available component sets: %',
        COALESCE(v_item.item_id, p_planned_item_id::text),
        p_planned_unit_size,
        array_to_string(v_component_sets, ', ');
    ELSIF cardinality(v_component_sets) = 1 THEN
      v_requested_set := v_component_sets[1];
    END IF;
  ELSIF NOT (v_requested_set = ANY(v_component_sets)) THEN
    RAISE EXCEPTION
      'planned_component_set % does not match active components for item % at % lb. Available component sets: %',
      v_requested_set,
      COALESCE(v_item.item_id, p_planned_item_id::text),
      p_planned_unit_size,
      COALESCE(NULLIF(array_to_string(v_component_sets, ', '), ''), '(none)');
  END IF;

  SELECT
    count(*)::integer,
    count(*) FILTER (
      WHERE irc.recipe_id IS NULL
         OR NULLIF(btrim(irc.component_role), '') IS NULL
         OR (
           COALESCE(irc.default_weight_lb, 0) <= 0
           AND COALESCE(irc.default_percent, 0) <= 0
         )
    )::integer,
    COALESCE(
      sum(
        COALESCE(
          NULLIF(irc.default_weight_lb, 0),
          p_planned_unit_size * NULLIF(irc.default_percent, 0) / 100.0
        )
      ),
      0
    )
  INTO component_count, v_invalid_count, component_weight_sum
  FROM public.item_recipe_components irc
  WHERE COALESCE(irc.active, false)
    AND irc.item_id = p_planned_item_id
    AND (
      irc.unit_size_lb IS NULL
      OR abs(irc.unit_size_lb - p_planned_unit_size) < 0.000001
    )
    AND (
      (v_requested_set IS NULL AND NULLIF(btrim(irc.component_set), '') IS NULL)
      OR
      (v_requested_set IS NOT NULL AND (
        NULLIF(btrim(irc.component_set), '') IS NULL
        OR btrim(irc.component_set) = v_requested_set
      ))
    );

  IF component_count = 0 THEN
    RAISE EXCEPTION
      'Selected component plan has no active rows for item % at % lb and component set %.',
      COALESCE(v_item.item_id, p_planned_item_id::text),
      p_planned_unit_size,
      COALESCE(v_requested_set, '(blank)');
  END IF;

  IF v_invalid_count > 0 THEN
    RAISE EXCEPTION
      'Selected component plan for item % contains % invalid row(s); recipe, role, and weight or percent are required.',
      COALESCE(v_item.item_id, p_planned_item_id::text), v_invalid_count;
  END IF;

  IF size_source = 'component_sum'
     AND abs(component_weight_sum - p_planned_unit_size) >= 0.000001 THEN
    RAISE EXCEPTION
      'Component weights for item % total % lb but planned_unit_size is % lb.',
      COALESCE(v_item.item_id, p_planned_item_id::text),
      component_weight_sum,
      p_planned_unit_size;
  END IF;

  resolved_component_set := v_requested_set;
  RETURN NEXT;
END;
$$;

DROP FUNCTION IF EXISTS public.mp_sterilizer_start_run(
  bigint,
  bigint,
  numeric,
  numeric,
  text,
  timestamp without time zone,
  text,
  numeric,
  text,
  text
);

DROP FUNCTION IF EXISTS public.mp_sterilizer_start_run(
  bigint,
  bigint,
  numeric,
  numeric,
  text,
  timestamp without time zone,
  text,
  numeric,
  text,
  text,
  text
);

-- Start a sterilization run (Sterilizer IN) with component-mode validation.
CREATE FUNCTION public.mp_sterilizer_start_run(
  p_planned_item_id bigint,
  p_planned_recipe_id bigint,
  p_planned_count numeric,
  p_planned_unit_size numeric,
  p_process_type text,
  p_start_time timestamp without time zone,
  p_operator text,
  p_target_temp_c numeric DEFAULT NULL,
  p_pressure_mode text DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_planned_component_set text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  v_run_id bigint;
  v_steri_run_id text;
  v_event_id bigint;
  v_err text := '';
  v_process_type text;
  v_target_temp_c numeric;
  v_pressure_mode text;
  v_planned_item_id text;
  v_planned_item_name text;
  v_planned_recipe_id text;
  v_planned_recipe_name text;
  v_plan record;
BEGIN
  v_process_type := CASE lower(btrim(COALESCE(p_process_type, '')))
    WHEN 'sterilize' THEN 'Sterilize'
    WHEN 'pasteurize' THEN 'Pasteurize'
    ELSE NULL
  END;

  IF p_planned_item_id IS NULL THEN v_err := v_err || 'Planned Item is required. '; END IF;
  IF p_planned_count IS NULL OR p_planned_count <= 0 THEN v_err := v_err || 'Planned Count must be > 0. '; END IF;
  IF p_planned_count IS NOT NULL AND p_planned_count <> trunc(p_planned_count) THEN
    v_err := v_err || 'Planned Count must be a whole number. ';
  END IF;
  IF p_planned_unit_size IS NULL OR p_planned_unit_size <= 0 THEN v_err := v_err || 'Planned Unit Size must be > 0. '; END IF;

  IF v_process_type IS NULL THEN
    v_err := v_err || 'Process Type must be Sterilize or Pasteurize. ';
  END IF;

  IF p_start_time IS NULL THEN
    v_err := v_err || 'Start Time is required. ';
  END IF;

  IF length(trim(v_err)) > 0 THEN
    RAISE EXCEPTION '%', trim(v_err);
  END IF;

  SELECT *
  INTO v_plan
  FROM public.mp_sterilizer_validate_component_plan(
    p_planned_item_id,
    p_planned_recipe_id,
    p_planned_unit_size,
    p_planned_component_set
  );

  v_target_temp_c := COALESCE(
    p_target_temp_c,
    CASE WHEN lower(v_process_type) = 'sterilize' THEN 121 ELSE 74 END
  );

  v_pressure_mode := COALESCE(
    NULLIF(btrim(p_pressure_mode), ''),
    CASE WHEN lower(v_process_type) = 'sterilize' THEN 'Closed' ELSE 'Open' END
  );

  SELECT i.item_id, i.name
  INTO v_planned_item_id, v_planned_item_name
  FROM public.items i
  WHERE i.nocopk = p_planned_item_id;

  IF p_planned_recipe_id IS NOT NULL THEN
    SELECT r.recipe_id, r.name
    INTO v_planned_recipe_id, v_planned_recipe_name
    FROM public.recipes r
    WHERE r.nocopk = p_planned_recipe_id;
  END IF;

  INSERT INTO public.sterilization_runs
    (planned_item_id, planned_recipe_id, planned_count, planned_unit_size,
     process_type, start_time, operator, target_temp_c, pressure_mode,
     notes, planned_component_set, ui_error, ui_error_at)
  VALUES
    (p_planned_item_id, p_planned_recipe_id, p_planned_count, p_planned_unit_size,
     v_process_type, p_start_time, p_operator, v_target_temp_c, v_pressure_mode,
     NULLIF(btrim(p_notes), ''), v_plan.resolved_component_set, NULL, NULL)
  RETURNING nocopk, steri_run_id INTO v_run_id, v_steri_run_id;

  v_event_id := public.mp_events_insert(
    NULL::bigint,
    NULL::bigint,
    'SterilizerRunCreated'::text,
    p_start_time::timestamp without time zone,
    p_operator::text,
    'Sterilizer IN'::text,
    jsonb_strip_nulls(jsonb_build_object(
      'steri_run_id', v_steri_run_id,
      'steri_run_nocopk', v_run_id,
      'planned_item_nocopk', p_planned_item_id,
      'planned_item_id', v_planned_item_id,
      'planned_item_name', v_planned_item_name,
      'planned_recipe_nocopk', p_planned_recipe_id,
      'planned_recipe_id', v_planned_recipe_id,
      'planned_recipe_name', v_planned_recipe_name,
      'planned_count', p_planned_count,
      'planned_unit_size', p_planned_unit_size,
      'component_mode', v_plan.component_mode,
      'planned_component_set', v_plan.resolved_component_set,
      'component_count', v_plan.component_count,
      'component_weight_sum', v_plan.component_weight_sum,
      'process_type', v_process_type,
      'target_temp_c', v_target_temp_c,
      'pressure_mode', v_pressure_mode,
      'notes', NULLIF(btrim(p_notes), ''),
      'operator', p_operator,
      'start_time', p_start_time
    ))
  );

  RETURN v_run_id;
END;
$$;

-- Complete a run (Sterilizer OUT): update run, validate counts, create lots,
-- create one or more lot_recipe_components per lot, write events, and enqueue
-- the consolidated sterilizer sheet print job.
CREATE OR REPLACE FUNCTION public.mp_sterilizer_complete_run(
  p_run_id bigint,
  p_good_count numeric,
  p_destroyed_count numeric,
  p_operator text,
  p_end_time timestamp without time zone DEFAULT NULL,
  p_sterilized_location_id bigint DEFAULT NULL
)
RETURNS TABLE(end_time timestamp without time zone, lots_created integer, print_queue_id bigint)
LANGUAGE plpgsql
AS $$
DECLARE
  v_run record;
  v_plan record;
  v_component record;
  v_end timestamp without time zone;
  v_total numeric;
  v_item_name text;
  v_item_category text;
  v_status text;
  v_evt_id bigint;
  v_pq_id bigint;
  v_n integer;
  v_lot_id bigint;
  v_lot_recipe_component_id bigint;
  v_source_component_id bigint;
  v_source_component_role text;
  v_source_sort_order numeric;
  v_component_weight numeric;
  v_component_percent numeric;
  v_sterilized_location_id bigint;
BEGIN
  SELECT
    sr.*,
    i.name AS item_name,
    i.category AS item_category
  INTO v_run
  FROM public.sterilization_runs sr
  LEFT JOIN public.items i ON i.nocopk = sr.planned_item_id
  WHERE sr.nocopk = p_run_id
  FOR UPDATE OF sr;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Run not found: %', p_run_id;
  END IF;

  v_end := COALESCE(p_end_time, now());
  v_total := COALESCE(p_good_count, 0) + COALESCE(p_destroyed_count, 0);

  IF v_run.planned_count IS NULL OR v_run.planned_count <= 0 THEN
    RAISE EXCEPTION 'Run planned_count is missing/invalid.';
  END IF;

  IF v_run.planned_count <> trunc(v_run.planned_count)
     OR COALESCE(p_good_count, 0) <> trunc(COALESCE(p_good_count, 0))
     OR COALESCE(p_destroyed_count, 0) <> trunc(COALESCE(p_destroyed_count, 0)) THEN
    RAISE EXCEPTION 'Planned, Good, and Destroyed counts must be whole numbers.';
  END IF;

  IF v_total <> v_run.planned_count THEN
    RAISE EXCEPTION 'Good (%) + Destroyed (%) must equal Planned (%).',
      COALESCE(p_good_count, 0), COALESCE(p_destroyed_count, 0), v_run.planned_count;
  END IF;

  IF COALESCE(p_good_count, 0) < 0 OR COALESCE(p_destroyed_count, 0) < 0 THEN
    RAISE EXCEPTION 'Counts cannot be negative.';
  END IF;

  IF v_run.start_time IS NULL THEN
    RAISE EXCEPTION 'Run has no start_time; cannot complete.';
  END IF;

  IF v_end < v_run.start_time THEN
    RAISE EXCEPTION 'End time cannot be before start time.';
  END IF;

  IF p_sterilized_location_id IS NOT NULL AND p_sterilized_location_id <= 0 THEN
    RAISE EXCEPTION 'Sterilized storage location must be a valid location nocopk.';
  END IF;

  -- Revalidate at OUT so changed or deactivated component definitions cannot
  -- silently create lots with an incomplete recipe lineage.
  SELECT *
  INTO v_plan
  FROM public.mp_sterilizer_validate_component_plan(
    v_run.planned_item_id,
    v_run.planned_recipe_id,
    v_run.planned_unit_size,
    v_run.planned_component_set
  );

  v_item_name := v_run.item_name;
  v_item_category := v_run.item_category;

  v_status := CASE
    WHEN lower(btrim(v_run.process_type)) = 'pasteurize' THEN 'Pasteurized'
    ELSE 'Sterilized'
  END;

  v_sterilized_location_id := COALESCE(
    p_sterilized_location_id,
    (
      SELECT l.nocopk
      FROM public.locations l
      WHERE lower(btrim(l.name)) = lower(btrim('New Lots'))
      ORDER BY CASE WHEN COALESCE(l.active, false) THEN 0 ELSE 1 END, l.nocopk
      LIMIT 1
    )
  );

  IF v_sterilized_location_id IS NULL THEN
    RAISE EXCEPTION 'Sterilized storage location is required and no default New Lots location was found.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.locations l
    WHERE l.nocopk = v_sterilized_location_id
  ) THEN
    RAISE EXCEPTION 'Sterilized storage location not found for nocopk: %', v_sterilized_location_id;
  END IF;

  -- Idempotency guard: prevent double-creating lots for the same run.
  IF EXISTS (SELECT 1 FROM public.lots l WHERE l.steri_run_id = p_run_id) THEN
    RAISE EXCEPTION 'Lots already exist for run % (refusing to create duplicates).', p_run_id;
  END IF;

  UPDATE public.sterilization_runs sr
  SET
    end_time = v_end,
    good_count = p_good_count,
    destroyed_count = p_destroyed_count,
    operator = COALESCE(p_operator, sr.operator),
    planned_component_set = v_plan.resolved_component_set,
    ui_error = NULL,
    ui_error_at = NULL
  WHERE sr.nocopk = p_run_id;

  lots_created := 0;

  -- Create lots (1 per planned unit).
  FOR v_n IN 1..COALESCE(p_good_count, 0)::int LOOP
    INSERT INTO public.lots
      (item_name_mat, item_category_mat, process_type_mat,
       qty, unit_size, status,
       steri_run_id, operator, created_at, sterilized_at, use_by,
       item_id, recipe_id)
    VALUES
      (v_item_name, v_item_category, v_run.process_type,
       1, v_run.planned_unit_size, v_status,
       v_run.nocopk, p_operator, now(), v_end,
       CASE
         WHEN v_item_category IN ('grain', 'substrate', 'casing', 'cordyceps_substrate')
         THEN (v_end + interval '3 months')::date
         ELSE NULL
       END,
       v_run.planned_item_id,
       v_run.planned_recipe_id)
    RETURNING nocopk INTO v_lot_id;

    -- Maintain explicit run/item/recipe link tables for Airtable/NocoDB parity.
    PERFORM public.mp_link_sterilization_run_lot(p_run_id, v_lot_id);
    PERFORM public.mp_link_lot_item(v_lot_id, v_run.planned_item_id);
    PERFORM public.mp_link_lot_recipe(v_lot_id, v_run.planned_recipe_id);
    PERFORM public.mp_lot_set_location(v_lot_id, v_sterilized_location_id);

    IF v_plan.component_mode = 'multi_recipe' THEN
      FOR v_component IN
        SELECT
          irc.nocopk,
          irc.recipe_id,
          btrim(irc.component_role) AS component_role,
          COALESCE(
            NULLIF(irc.default_weight_lb, 0),
            v_run.planned_unit_size * NULLIF(irc.default_percent, 0) / 100.0
          ) AS component_weight,
          COALESCE(
            NULLIF(irc.default_percent, 0),
            COALESCE(
              NULLIF(irc.default_weight_lb, 0),
              v_run.planned_unit_size * NULLIF(irc.default_percent, 0) / 100.0
            ) / v_run.planned_unit_size * 100.0
          ) AS component_percent,
          irc.sort_order
        FROM public.item_recipe_components irc
        WHERE COALESCE(irc.active, false)
          AND irc.item_id = v_run.planned_item_id
          AND (
            irc.unit_size_lb IS NULL
            OR abs(irc.unit_size_lb - v_run.planned_unit_size) < 0.000001
          )
          AND (
            (v_plan.resolved_component_set IS NULL AND NULLIF(btrim(irc.component_set), '') IS NULL)
            OR
            (v_plan.resolved_component_set IS NOT NULL AND (
              NULLIF(btrim(irc.component_set), '') IS NULL
              OR btrim(irc.component_set) = v_plan.resolved_component_set
            ))
          )
        ORDER BY COALESCE(irc.sort_order, 0), irc.nocopk
      LOOP
        INSERT INTO public.lot_recipe_components
          (lot_id, item_id, recipe_id, source_item_recipe_component_id,
           component_role, component_weight_lb, component_percent,
           sort_order, notes)
        VALUES
          (v_lot_id, v_run.planned_item_id, v_component.recipe_id, v_component.nocopk,
           v_component.component_role, v_component.component_weight,
           v_component.component_percent, v_component.sort_order,
           'Created from multi_recipe item component plan on sterilization run ' ||
             COALESCE(v_run.steri_run_id, v_run.nocopk::text))
        RETURNING nocopk INTO v_lot_recipe_component_id;

        PERFORM public.mp_link_lot_recipe_component(
          v_lot_recipe_component_id,
          v_lot_id,
          v_run.planned_item_id,
          v_component.recipe_id,
          v_component.nocopk
        );
      END LOOP;
    ELSE
      SELECT
        irc.nocopk,
        NULLIF(btrim(irc.component_role), ''),
        irc.sort_order
      INTO v_source_component_id, v_source_component_role, v_source_sort_order
      FROM public.item_recipe_components irc
      WHERE COALESCE(irc.active, false)
        AND irc.item_id = v_run.planned_item_id
        AND irc.recipe_id = v_run.planned_recipe_id
        AND (
          irc.unit_size_lb IS NULL
          OR abs(irc.unit_size_lb - v_run.planned_unit_size) < 0.000001
        )
      ORDER BY
        CASE WHEN irc.unit_size_lb IS NOT NULL THEN 0 ELSE 1 END,
        COALESCE(irc.sort_order, 0),
        irc.nocopk
      LIMIT 1;

      INSERT INTO public.lot_recipe_components
        (lot_id, item_id, recipe_id, source_item_recipe_component_id,
         component_role, component_weight_lb, sort_order, notes)
      VALUES
        (v_lot_id, v_run.planned_item_id, v_run.planned_recipe_id, v_source_component_id,
         COALESCE(
           v_source_component_role,
           CASE lower(COALESCE(v_item_category, ''))
             WHEN 'grain' THEN 'grain'
             WHEN 'substrate' THEN 'substrate'
             WHEN 'cordyceps_substrate' THEN 'substrate'
             WHEN 'all_in_one_bag' THEN 'substrate'
             WHEN 'agar_flask' THEN 'agar'
             WHEN 'plate' THEN 'agar'
             WHEN 'lc_flask' THEN 'lc'
             WHEN 'lc_syringe' THEN 'lc'
             WHEN 'casing' THEN 'casing'
             ELSE 'primary'
           END
         ),
         v_run.planned_unit_size,
         COALESCE(v_source_sort_order, 1),
         'Created from sterilization run planned_recipe')
      RETURNING nocopk INTO v_lot_recipe_component_id;

      PERFORM public.mp_link_lot_recipe_component(
        v_lot_recipe_component_id,
        v_lot_id,
        v_run.planned_item_id,
        v_run.planned_recipe_id,
        v_source_component_id
      );
    END IF;

    lots_created := lots_created + 1;

    v_evt_id := public.mp_events_insert_and_link_lot(
      v_lot_id::bigint,
      CASE WHEN lower(btrim(v_run.process_type)) = 'pasteurize' THEN 'Pasteurized' ELSE 'Sterilized' END,
      v_end::timestamp,
      p_operator::text,
      'Sterilizer OUT'::text,
      jsonb_strip_nulls(jsonb_build_object(
        'run_id', v_run.nocopk,
        'run_no', v_run.steri_run_id,
        'process_type', v_run.process_type,
        'unit_size', v_run.planned_unit_size,
        'component_mode', v_plan.component_mode,
        'component_set', v_plan.resolved_component_set,
        'component_count', v_plan.component_count
      ))
    );
  END LOOP;

  -- Destroyed events are not linked to a lot or product.
  FOR v_n IN 1..COALESCE(p_destroyed_count, 0)::int LOOP
    PERFORM public.mp_events_insert(
      NULL::bigint,
      NULL::bigint,
      'Destroyed'::text,
      v_end::timestamp,
      p_operator::text,
      'Sterilizer OUT'::text,
      jsonb_strip_nulls(jsonb_build_object(
        'run_id', v_run.nocopk,
        'run_no', v_run.steri_run_id,
        'process_type', v_run.process_type,
        'planned_item_id', v_run.planned_item_id,
        'planned_item_name', v_item_name,
        'planned_recipe_id', v_run.planned_recipe_id,
        'planned_unit_size', v_run.planned_unit_size,
        'component_mode', v_plan.component_mode,
        'component_set', v_plan.resolved_component_set,
        'destroyed_count', p_destroyed_count,
        'destroyed_sequence', v_n
      ))
    );
  END LOOP;

  -- Enqueue one consolidated sterilizer sheet for this run.
  SELECT pq.nocopk INTO v_pq_id
  FROM public.print_queue pq
  JOIN public._m2m_print_queue_sterilization_runs_run_id j
    ON j.print_queue_id = pq.nocopk
   AND j.sterilization_runs_id = v_run.nocopk
  WHERE pq.source_kind = 'steri_sheet'
  ORDER BY pq.nocopk DESC
  LIMIT 1;

  IF v_pq_id IS NULL THEN
    v_pq_id := public.mp_print_queue_enqueue(
      'steri_sheet',
      'Sterilizer_Sheet',
      NULL,
      NULL,
      v_run.nocopk,
      'Queued'
    );
  END IF;

  end_time := v_end;
  print_queue_id := v_pq_id;
  RETURN NEXT;
END;
$$;
