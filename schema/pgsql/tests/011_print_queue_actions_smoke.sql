BEGIN;

DO $test$
DECLARE
  v_suffix text := substr(md5(clock_timestamp()::text || random()::text), 1, 10);
  v_queued_id bigint;
  v_printing_id bigint;
  v_printed_id bigint;
  v_error_id bigint;
  v_count integer;
  v_row record;
  v_event_count integer;
BEGIN
  INSERT INTO public.print_queue (
    print_id, source_kind, print_status, label_type, created_at,
    claimed_by, claimed_at, printed_by, printed_at, pdf_path, error_msg
  ) VALUES (
    'PRINT-PQTEST-Q-' || v_suffix,
    'lot', 'Queued', 'RC5_Test', localtimestamp,
    NULL, NULL, NULL, NULL, NULL, NULL
  ) RETURNING nocopk INTO v_queued_id;

  INSERT INTO public.print_queue (
    print_id, source_kind, print_status, label_type, created_at,
    claimed_by, claimed_at, printed_by, printed_at, pdf_path, error_msg
  ) VALUES (
    'PRINT-PQTEST-I-' || v_suffix,
    'product', 'Printing', 'RC5_Test', localtimestamp,
    'daemon-test', localtimestamp, NULL, NULL, NULL, NULL
  ) RETURNING nocopk INTO v_printing_id;

  INSERT INTO public.print_queue (
    print_id, source_kind, print_status, label_type, created_at,
    claimed_by, claimed_at, printed_by, printed_at, pdf_path, error_msg
  ) VALUES (
    'PRINT-PQTEST-P-' || v_suffix,
    'product', 'Printed', 'RC5_Test', localtimestamp,
    'daemon-test', localtimestamp, 'daemon-test', localtimestamp,
    '/tmp/old-printed.pdf', NULL
  ) RETURNING nocopk INTO v_printed_id;

  INSERT INTO public.print_queue (
    print_id, source_kind, print_status, label_type, created_at,
    claimed_by, claimed_at, printed_by, printed_at, pdf_path, error_msg
  ) VALUES (
    'PRINT-PQTEST-E-' || v_suffix,
    'lot', 'Error', 'RC5_Test', localtimestamp,
    'daemon-test', localtimestamp, NULL, NULL,
    '/tmp/old-error.pdf', 'Original test error'
  ) RETURNING nocopk INTO v_error_id;

  v_count := public.mp_print_queue_set_status(
    ARRAY[v_printed_id, v_error_id],
    'Queued',
    'rc5-print-queue-test@example.com',
    true,
    'Reprint requested by smoke test',
    'Print Queue Smoke Test'
  );

  IF v_count <> 2 THEN
    RAISE EXCEPTION 'Expected two requeued jobs, got %.', v_count;
  END IF;

  FOR v_row IN
    SELECT *
    FROM public.print_queue
    WHERE nocopk IN (v_printed_id, v_error_id)
  LOOP
    IF v_row.print_status <> 'Queued' THEN
      RAISE EXCEPTION 'Requeued job % has status %.', v_row.nocopk, v_row.print_status;
    END IF;
    IF v_row.claimed_by IS NOT NULL OR v_row.claimed_at IS NOT NULL THEN
      RAISE EXCEPTION 'Requeued job % retained daemon claim metadata.', v_row.nocopk;
    END IF;
    IF v_row.printed_by IS NOT NULL OR v_row.printed_at IS NOT NULL THEN
      RAISE EXCEPTION 'Requeued job % retained printed metadata.', v_row.nocopk;
    END IF;
    IF v_row.pdf_path IS NOT NULL THEN
      RAISE EXCEPTION 'Requeued job % retained its previous PDF path.', v_row.nocopk;
    END IF;
    IF v_row.error_msg IS NOT NULL THEN
      RAISE EXCEPTION 'Requeued job % retained its previous error.', v_row.nocopk;
    END IF;
  END LOOP;

  SELECT COUNT(*)
  INTO v_event_count
  FROM public.events e
  WHERE e.type = 'PrintQueueStatusChanged'
    AND e.operator = 'rc5-print-queue-test@example.com'
    AND (e.fields_json::jsonb ->> 'print_queue_nocopk')::bigint
        IN (v_printed_id, v_error_id)
    AND e.fields_json::jsonb ->> 'new_status' = 'Queued'
    AND e.fields_json::jsonb ->> 'print_target' = 'ZEBRA'
    AND e.fields_json::jsonb ->> 'reason' = 'Reprint requested by smoke test';

  IF v_event_count <> 2 THEN
    RAISE EXCEPTION 'Expected one requeue audit event per job, got %.', v_event_count;
  END IF;

  BEGIN
    PERFORM public.mp_print_queue_set_status(
      ARRAY[v_error_id, v_printing_id], 'Error', 'rc5-test', false,
      'Should not change an active job', 'Print Queue Smoke Test'
    );
    RAISE EXCEPTION 'Printing job status change unexpectedly succeeded.';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE 'Cannot change jobs currently Printing:%' THEN
        RAISE;
      END IF;
  END;

  SELECT print_status, claimed_by
  INTO v_row
  FROM public.print_queue
  WHERE nocopk = v_printing_id;

  IF v_row.print_status <> 'Printing' OR v_row.claimed_by <> 'daemon-test' THEN
    RAISE EXCEPTION 'Rejected Printing job mutation changed the active row.';
  END IF;

  SELECT print_status, error_msg
  INTO v_row
  FROM public.print_queue
  WHERE nocopk = v_error_id;

  IF v_row.print_status <> 'Queued' OR v_row.error_msg IS NOT NULL THEN
    RAISE EXCEPTION 'Rejected mixed selection partially changed an inactive row.';
  END IF;

  SELECT COUNT(*)
  INTO v_event_count
  FROM public.events e
  WHERE e.type = 'PrintQueueStatusChanged'
    AND e.operator = 'rc5-test'
    AND e.fields_json::jsonb ->> 'reason' = 'Should not change an active job';

  IF v_event_count <> 0 THEN
    RAISE EXCEPTION 'Rejected mixed selection created an audit event.';
  END IF;

  BEGIN
    PERFORM public.mp_print_queue_set_status(
      ARRAY[v_queued_id], 'Queued', 'rc5-test', true,
      'Invalid queued requeue', 'Print Queue Smoke Test'
    );
    RAISE EXCEPTION 'Queued job requeue unexpectedly succeeded.';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM <> 'Only Printed or Error jobs may be requeued.' THEN
        RAISE;
      END IF;
  END;

  BEGIN
    PERFORM public.mp_print_queue_set_status(
      ARRAY[v_queued_id], 'Error', 'rc5-test', false,
      NULL, 'Print Queue Smoke Test'
    );
    RAISE EXCEPTION 'Error status without a reason unexpectedly succeeded.';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM <> 'A reason is required when marking a print job Error.' THEN
        RAISE;
      END IF;
  END;

  v_count := public.mp_print_queue_set_status(
    ARRAY[v_queued_id],
    'Error',
    'rc5-print-queue-test@example.com',
    false,
    'Manual error from smoke test',
    'Print Queue Smoke Test'
  );

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Expected one manually errored job, got %.', v_count;
  END IF;

  SELECT print_status, error_msg, claimed_by, printed_by, pdf_path
  INTO v_row
  FROM public.print_queue
  WHERE nocopk = v_queued_id;

  IF v_row.print_status <> 'Error'
     OR v_row.error_msg <> 'Manual error from smoke test'
     OR v_row.claimed_by IS NOT NULL
     OR v_row.printed_by IS NOT NULL
     OR v_row.pdf_path IS NOT NULL THEN
    RAISE EXCEPTION 'Manual Error update did not reset the expected fields.';
  END IF;

  v_count := public.mp_print_queue_set_status(
    ARRAY[v_queued_id],
    'Printed',
    'rc5-print-queue-test@example.com',
    true,
    'Confirmed manually printed',
    'Print Queue Smoke Test'
  );

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Expected one manually printed job, got %.', v_count;
  END IF;

  SELECT print_status, error_msg, printed_by, printed_at
  INTO v_row
  FROM public.print_queue
  WHERE nocopk = v_queued_id;

  IF v_row.print_status <> 'Printed'
     OR v_row.error_msg IS NOT NULL
     OR v_row.printed_by <> 'rc5-print-queue-test@example.com'
     OR v_row.printed_at IS NULL THEN
    RAISE EXCEPTION 'Manual Printed update did not set the expected fields.';
  END IF;

  SELECT COUNT(*)
  INTO v_event_count
  FROM public.events e
  WHERE e.type = 'PrintQueueStatusChanged'
    AND e.operator = 'rc5-print-queue-test@example.com'
    AND (e.fields_json::jsonb ->> 'print_queue_nocopk')::bigint
        IN (v_queued_id, v_printed_id, v_error_id);

  IF v_event_count <> 4 THEN
    RAISE EXCEPTION 'Expected four successful status-change audit events, got %.', v_event_count;
  END IF;

  BEGIN
    PERFORM public.mp_print_queue_set_status(
      ARRAY[v_queued_id], 'Printing', 'rc5-test', false,
      'Invalid manual claim', 'Print Queue Smoke Test'
    );
    RAISE EXCEPTION 'Manual Printing status unexpectedly succeeded.';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM <> 'Printing is daemon-controlled and cannot be assigned manually.' THEN
        RAISE;
      END IF;
  END;

  BEGIN
    PERFORM public.mp_print_queue_set_status(
      ARRAY[v_queued_id, 9223372036854775807::bigint],
      'Printed', 'rc5-test', false,
      'Missing ID validation', 'Print Queue Smoke Test'
    );
    RAISE EXCEPTION 'Selection containing a missing job unexpectedly succeeded.';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM <> 'One or more selected print queue jobs no longer exist.' THEN
        RAISE;
      END IF;
  END;

  RAISE NOTICE 'Print Queue requeue, manual status, audit, and active-job protection smoke tests passed.';
END;
$test$;

ROLLBACK;
