-- 011_print_queue_actions.sql
-- Controlled, audited status changes for the Appsmith Print Queue page.

CREATE OR REPLACE FUNCTION public.mp_print_queue_set_status(
  p_print_queue_ids bigint[],
  p_new_status text,
  p_operator text DEFAULT NULL,
  p_clear_error boolean DEFAULT false,
  p_reason text DEFAULT NULL,
  p_station text DEFAULT 'Print Queue'
)
RETURNS integer
LANGUAGE plpgsql
AS $function$
DECLARE
  v_ids bigint[];
  v_status text;
  v_operator text;
  v_station text;
  v_found_count integer;
  v_updated_count integer := 0;
  v_printing_ids text;
  v_event_id bigint;
  r record;
BEGIN
  v_ids := ARRAY(
    SELECT DISTINCT u.id
    FROM unnest(COALESCE(p_print_queue_ids, ARRAY[]::bigint[])) AS u(id)
    WHERE u.id IS NOT NULL
    ORDER BY u.id
  );

  IF COALESCE(cardinality(v_ids), 0) = 0 THEN
    RAISE EXCEPTION 'Select at least one print queue job.';
  END IF;

  CASE lower(BTRIM(COALESCE(p_new_status, '')))
    WHEN 'queued' THEN v_status := 'Queued';
    WHEN 'printed' THEN v_status := 'Printed';
    WHEN 'error' THEN v_status := 'Error';
    WHEN 'printing' THEN
      RAISE EXCEPTION 'Printing is daemon-controlled and cannot be assigned manually.';
    ELSE
      RAISE EXCEPTION 'Unsupported print status: %', COALESCE(p_new_status, '<blank>');
  END CASE;

  IF v_status = 'Error'
     AND NULLIF(BTRIM(COALESCE(p_reason, '')), '') IS NULL THEN
    RAISE EXCEPTION 'A reason is required when marking a print job Error.';
  END IF;

  v_operator := COALESCE(NULLIF(BTRIM(COALESCE(p_operator, '')), ''), 'system');
  v_station := COALESCE(NULLIF(BTRIM(COALESCE(p_station, '')), ''), 'Print Queue');

  /*
   * Lock the complete selection before validating or mutating any row.
   * Ordering the locks prevents avoidable deadlocks during multi-job actions.
   */
  FOR r IN
    SELECT pq.nocopk
    FROM public.print_queue pq
    WHERE pq.nocopk = ANY(v_ids)
    ORDER BY pq.nocopk
    FOR UPDATE
  LOOP
    NULL;
  END LOOP;

  SELECT COUNT(*)
  INTO v_found_count
  FROM public.print_queue pq
  WHERE pq.nocopk = ANY(v_ids);

  IF v_found_count <> cardinality(v_ids) THEN
    RAISE EXCEPTION 'One or more selected print queue jobs no longer exist.';
  END IF;

  SELECT STRING_AGG(
    COALESCE(NULLIF(pq.print_id, ''), pq.nocopk::text),
    ', ' ORDER BY pq.nocopk
  )
  INTO v_printing_ids
  FROM public.print_queue pq
  WHERE pq.nocopk = ANY(v_ids)
    AND lower(BTRIM(COALESCE(pq.print_status, ''))) = 'printing';

  IF v_printing_ids IS NOT NULL THEN
    RAISE EXCEPTION 'Cannot change jobs currently Printing: %', v_printing_ids;
  END IF;

  IF v_status = 'Queued'
     AND EXISTS (
       SELECT 1
       FROM public.print_queue pq
       WHERE pq.nocopk = ANY(v_ids)
         AND lower(BTRIM(COALESCE(pq.print_status, ''))) NOT IN ('printed', 'error')
     ) THEN
    RAISE EXCEPTION 'Only Printed or Error jobs may be requeued.';
  END IF;

  FOR r IN
    SELECT
      pq.nocopk,
      pq.print_id,
      pq.print_status,
      v.print_target,
      pq.source_kind,
      pq.label_type,
      pq.lot_id,
      pq.product_id,
      pq.run_id,
      pq.error_msg,
      pq.claimed_by,
      pq.claimed_at,
      pq.printed_by,
      pq.printed_at,
      pq.pdf_path
    FROM public.print_queue pq
    LEFT JOIN public.vc_print_queue v
      ON v.nocopk = pq.nocopk
    WHERE pq.nocopk = ANY(v_ids)
    ORDER BY pq.nocopk
  LOOP
    v_event_id := public.mp_events_insert(
      p_lot_id => r.lot_id,
      p_product_id => r.product_id,
      p_type => 'PrintQueueStatusChanged'::text,
      p_timestamp => localtimestamp,
      p_operator => v_operator,
      p_station => v_station,
      p_fields_json => jsonb_build_object(
        'print_queue_nocopk', r.nocopk,
        'print_id', r.print_id,
        'previous_status', r.print_status,
        'new_status', v_status,
        'print_target', r.print_target,
        'source_kind', r.source_kind,
        'label_type', r.label_type,
        'lot_id', r.lot_id,
        'product_id', r.product_id,
        'run_id', r.run_id,
        'previous_error_msg', r.error_msg,
        'previous_claimed_by', r.claimed_by,
        'previous_claimed_at', r.claimed_at,
        'previous_printed_by', r.printed_by,
        'previous_printed_at', r.printed_at,
        'previous_pdf_path', r.pdf_path,
        'clear_error', COALESCE(p_clear_error, false),
        'reason', NULLIF(BTRIM(COALESCE(p_reason, '')), '')
      )
    );

    IF v_event_id IS NULL THEN
      RAISE EXCEPTION 'Print queue audit event was not created for job %.', r.nocopk;
    END IF;

    IF r.lot_id IS NOT NULL THEN
      PERFORM public.mp_events_link_lot(v_event_id, r.lot_id);
    END IF;

    IF r.product_id IS NOT NULL THEN
      PERFORM public.mp_events_link_product(v_event_id, r.product_id);
    END IF;

    UPDATE public.print_queue
    SET
      print_status = v_status,
      claimed_by = NULL,
      claimed_at = NULL,
      printed_by = CASE
        WHEN v_status = 'Printed' THEN v_operator
        ELSE NULL
      END,
      printed_at = CASE
        WHEN v_status = 'Printed' THEN localtimestamp
        ELSE NULL
      END,
      pdf_path = CASE
        WHEN v_status = 'Printed' THEN pdf_path
        ELSE NULL
      END,
      error_msg = CASE
        WHEN v_status = 'Error' THEN BTRIM(p_reason)
        WHEN v_status = 'Printed' THEN NULL
        WHEN v_status = 'Queued' AND COALESCE(p_clear_error, false) THEN NULL
        ELSE error_msg
      END,
      nc_updated_at = localtimestamp
    WHERE nocopk = r.nocopk;

    v_updated_count := v_updated_count + 1;
  END LOOP;

  RETURN v_updated_count;
END;
$function$;
