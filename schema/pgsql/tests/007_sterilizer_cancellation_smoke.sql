\set ON_ERROR_STOP on

-- Transactional smoke test for Sterilizer OUT cancellation/archival.
-- Verifies that cancelled runs remain auditable, create no lots, are idempotent,
-- and cannot later be completed.
BEGIN;

DO $test$
DECLARE
  v_item_id bigint;
  v_recipe_id bigint;
  v_run_id bigint;
  v_start timestamp without time zone := timestamp '2026-09-06 12:00:00';
  v_cancel timestamp without time zone := timestamp '2026-09-06 12:05:00';
  v_run record;
  v_result record;
  v_failed boolean := false;
BEGIN
  SELECT nocopk INTO v_item_id
  FROM public.items
  WHERE item_id = 'GRAIN-BAG'
  LIMIT 1;

  SELECT nocopk INTO v_recipe_id
  FROM public.recipes
  WHERE recipe_id = 'REC-GRAIN-WBS'
  LIMIT 1;

  IF v_item_id IS NULL OR v_recipe_id IS NULL THEN
    RAISE EXCEPTION 'Sterilizer cancellation fixtures are missing from imported data.';
  END IF;

  v_run_id := public.mp_sterilizer_start_run(
    p_planned_item_id => v_item_id,
    p_planned_recipe_id => v_recipe_id,
    p_planned_count => 2,
    p_planned_unit_size => 2,
    p_process_type => 'Sterilize',
    p_start_time => v_start,
    p_operator => 'Sterilizer cancellation smoke test',
    p_notes => 'Rollback-only cancellation test'
  );

  SELECT * INTO v_result
  FROM public.mp_sterilizer_cancel_run(
    v_run_id,
    'Sterilizer cancellation smoke test',
    'Created in error',
    v_cancel
  );

  IF v_result.run_id <> v_run_id OR v_result.cancelled_at <> v_cancel THEN
    RAISE EXCEPTION 'Cancellation return values are incorrect: %', row_to_json(v_result);
  END IF;

  SELECT cancelled_at, cancelled_by, cancellation_reason, end_time
  INTO v_run
  FROM public.sterilization_runs
  WHERE nocopk = v_run_id;

  IF v_run.cancelled_at <> v_cancel
     OR v_run.cancelled_by <> 'Sterilizer cancellation smoke test'
     OR v_run.cancellation_reason <> 'Created in error'
     OR v_run.end_time IS NOT NULL THEN
    RAISE EXCEPTION 'Cancelled run fields are incorrect: %', row_to_json(v_run);
  END IF;

  IF EXISTS (SELECT 1 FROM public.lots WHERE steri_run_id = v_run_id) THEN
    RAISE EXCEPTION 'Cancelled run unexpectedly created lots.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.print_queue pq
    WHERE pq.run_id = v_run_id
      AND pq.source_kind = 'steri_sheet'
  ) THEN
    RAISE EXCEPTION 'Cancelled run unexpectedly created a sterilizer print job.';
  END IF;

  IF (
    SELECT count(*)
    FROM public.events e
    WHERE e.type = 'SterilizerRunCancelled'
      AND e.operator = 'Sterilizer cancellation smoke test'
      AND e.timestamp = v_cancel
      AND (e.fields_json::jsonb ->> 'steri_run_nocopk')::bigint = v_run_id
      AND e.fields_json::jsonb ->> 'reason' = 'Created in error'
  ) <> 1 THEN
    RAISE EXCEPTION 'Expected exactly one SterilizerRunCancelled audit event.';
  END IF;

  -- Cancellation is idempotent: a repeated request returns the existing state
  -- and does not create a duplicate audit event.
  PERFORM 1
  FROM public.mp_sterilizer_cancel_run(
    v_run_id,
    'Sterilizer cancellation smoke test',
    'Duplicate click should be harmless',
    timestamp '2026-09-06 12:06:00'
  );

  IF (
    SELECT count(*)
    FROM public.events e
    WHERE e.type = 'SterilizerRunCancelled'
      AND (e.fields_json::jsonb ->> 'steri_run_nocopk')::bigint = v_run_id
  ) <> 1 THEN
    RAISE EXCEPTION 'Repeated cancellation created a duplicate audit event.';
  END IF;

  BEGIN
    PERFORM 1
    FROM public.mp_sterilizer_complete_run(
      v_run_id,
      2,
      0,
      'Sterilizer cancellation smoke test',
      timestamp '2026-09-06 13:00:00',
      NULL
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF position('was cancelled' in SQLERRM) > 0 THEN
        v_failed := true;
      ELSE
        RAISE;
      END IF;
  END;

  IF NOT v_failed THEN
    RAISE EXCEPTION 'Cancelled run was incorrectly allowed to complete.';
  END IF;

  RAISE NOTICE 'Sterilizer cancellation/archival smoke test passed.';
END;
$test$;

ROLLBACK;
