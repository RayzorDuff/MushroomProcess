\set ON_ERROR_STOP on

-- Transactional database-view contract coverage for the filterable fields in #66.
-- This does not replace Appsmith UI testing; it proves vc_print_queue exposes the
-- persisted audit/filter fields and routes jobs to the expected print target.
BEGIN;

DO $$
DECLARE
  v_grain_item_id bigint;
  v_tray_item_id bigint;
  v_lot_id bigint;
  v_product_id bigint;
  v_run_id bigint;
  v_lot_job_id bigint;
  v_product_job_id bigint;
  v_run_job_id bigint;
  v_created timestamp without time zone := timestamp '2026-07-15 19:00:00';
BEGIN
  SELECT nocopk INTO v_grain_item_id
  FROM public.items
  WHERE item_id = 'GRAIN-BAG'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  SELECT nocopk INTO v_tray_item_id
  FROM public.items
  WHERE item_id = 'TRAY-FREEZE'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  IF v_grain_item_id IS NULL OR v_tray_item_id IS NULL THEN
    RAISE EXCEPTION 'Print Queue view smoke-test item fixtures are missing.';
  END IF;

  INSERT INTO public.lots (
    lot_id, item_id, item_name_mat, item_category_mat, status, unit_size, created_at
  )
  SELECT
    'LOT-RC5-PQ-VIEW', v_grain_item_id, i.name, i.category,
    'Colonizing', 5, v_created - interval '1 day'
  FROM public.items i
  WHERE i.nocopk = v_grain_item_id
  RETURNING nocopk INTO v_lot_id;

  INSERT INTO public.products (
    product_id, item_id, name_mat, item_category_mat,
    net_weight_g, tray_state, pack_date
  )
  SELECT
    'PROD-RC5-PQ-VIEW', v_tray_item_id, i.name, i.category,
    100, 'freezer_tray', v_created::date
  FROM public.items i
  WHERE i.nocopk = v_tray_item_id
  RETURNING nocopk INTO v_product_id;

  INSERT INTO public.sterilization_runs (
    steri_run_id, process_type, start_time, end_time, planned_count, good_count
  ) VALUES (
    'RUN-RC5-PQ-VIEW', 'Sterilize', v_created - interval '2 hours',
    v_created - interval '1 hour', 1, 1
  )
  RETURNING nocopk INTO v_run_id;

  INSERT INTO public.print_queue (
    print_id, source_kind, lot_id, product_id, print_status, label_type,
    error_msg, created_at, run_id, claimed_by, claimed_at,
    printed_by, printed_at, pdf_path
  ) VALUES (
    'PRINT-RC5-PQ-VIEW-LOT', 'lot', v_lot_id, NULL, 'Queued',
    'Grain_Inoculated', NULL, v_created, NULL, NULL, NULL, NULL, NULL, NULL
  ) RETURNING nocopk INTO v_lot_job_id;

  INSERT INTO public.print_queue (
    print_id, source_kind, lot_id, product_id, print_status, label_type,
    error_msg, created_at, run_id, claimed_by, claimed_at,
    printed_by, printed_at, pdf_path
  ) VALUES (
    'PRINT-RC5-PQ-VIEW-PRODUCT', 'product', NULL, v_product_id, 'Printed',
    'Harvest_Freezer', NULL, v_created + interval '1 minute', NULL,
    'trays-daemon', v_created + interval '2 minutes',
    'trays-daemon', v_created + interval '3 minutes', '/tmp/rc5-tray.pdf'
  ) RETURNING nocopk INTO v_product_job_id;

  INSERT INTO public.print_queue (
    print_id, source_kind, lot_id, product_id, print_status, label_type,
    error_msg, created_at, run_id, claimed_by, claimed_at,
    printed_by, printed_at, pdf_path
  ) VALUES (
    'PRINT-RC5-PQ-VIEW-RUN', 'steri_sheet', NULL, NULL, 'Error',
    'Sterilizer_Sheet', 'rollback-only error', v_created + interval '4 minutes',
    v_run_id, 'zebra-daemon', v_created + interval '5 minutes',
    NULL, NULL, NULL
  ) RETURNING nocopk INTO v_run_job_id;

  IF (
    SELECT count(*)
    FROM public.vc_print_queue
    WHERE nocopk IN (v_lot_job_id, v_product_job_id, v_run_job_id)
  ) <> 3 THEN
    RAISE EXCEPTION 'vc_print_queue did not expose all inserted jobs.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.vc_print_queue v
    WHERE v.nocopk = v_lot_job_id
      AND v.print_id = 'PRINT-RC5-PQ-VIEW-LOT'
      AND v.print_target = 'ZEBRA'
      AND v.source_kind = 'lot'
      AND v.print_status = 'Queued'
      AND v.label_type = 'Grain_Inoculated'
      AND v.lot_id = v_lot_id
      AND v.product_id IS NULL
      AND v.run_id IS NULL
      AND v.created_at = v_created
      AND 'grain' = ANY(v.item_category_mat_from_lot_id)
  ) THEN
    RAISE EXCEPTION 'Lot queue view/filter contract is incomplete.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.vc_print_queue v
    WHERE v.nocopk = v_product_job_id
      AND v.print_id = 'PRINT-RC5-PQ-VIEW-PRODUCT'
      AND v.print_target = 'TRAYS'
      AND v.source_kind = 'product'
      AND v.print_status = 'Printed'
      AND v.label_type = 'Harvest_Freezer'
      AND v.product_id = v_product_id
      AND v.claimed_by = 'trays-daemon'
      AND v.claimed_at = v_created + interval '2 minutes'
      AND v.printed_by = 'trays-daemon'
      AND v.printed_at = v_created + interval '3 minutes'
      AND v.pdf_path = '/tmp/rc5-tray.pdf'
      AND 'freezer_tray' = ANY(v.item_category_mat_from_product_id)
  ) THEN
    RAISE EXCEPTION 'Product queue view/filter or TRAYS routing contract is incomplete.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.vc_print_queue v
    WHERE v.nocopk = v_run_job_id
      AND v.print_id = 'PRINT-RC5-PQ-VIEW-RUN'
      AND v.print_target = 'ZEBRA'
      AND v.source_kind = 'steri_sheet'
      AND v.print_status = 'Error'
      AND v.label_type = 'Sterilizer_Sheet'
      AND v.run_id = v_run_id
      AND v.claimed_by = 'zebra-daemon'
      AND v.claimed_at = v_created + interval '5 minutes'
      AND v.error_msg = 'rollback-only error'
  ) THEN
    RAISE EXCEPTION 'Sterilizer-sheet queue view/filter contract is incomplete.';
  END IF;

  -- Exercise the exact field predicates needed by the Appsmith filter surface.
  IF (SELECT count(*) FROM public.vc_print_queue WHERE nocopk IN (v_lot_job_id, v_product_job_id, v_run_job_id) AND print_target = 'ZEBRA') <> 2
     OR (SELECT count(*) FROM public.vc_print_queue WHERE nocopk IN (v_lot_job_id, v_product_job_id, v_run_job_id) AND print_status = 'Printed') <> 1
     OR (SELECT count(*) FROM public.vc_print_queue WHERE nocopk IN (v_lot_job_id, v_product_job_id, v_run_job_id) AND claimed_by = 'trays-daemon') <> 1
     OR (SELECT count(*) FROM public.vc_print_queue WHERE nocopk IN (v_lot_job_id, v_product_job_id, v_run_job_id) AND printed_by = 'trays-daemon') <> 1
     OR (SELECT count(*) FROM public.vc_print_queue WHERE nocopk IN (v_lot_job_id, v_product_job_id, v_run_job_id) AND source_kind = 'steri_sheet') <> 1
     OR (SELECT count(*) FROM public.vc_print_queue WHERE nocopk IN (v_lot_job_id, v_product_job_id, v_run_job_id) AND label_type = 'Grain_Inoculated') <> 1
     OR (SELECT count(*) FROM public.vc_print_queue WHERE nocopk IN (v_lot_job_id, v_product_job_id, v_run_job_id) AND run_id = v_run_id) <> 1
     OR (SELECT count(*) FROM public.vc_print_queue WHERE nocopk IN (v_lot_job_id, v_product_job_id, v_run_job_id) AND lot_id = v_lot_id) <> 1
     OR (SELECT count(*) FROM public.vc_print_queue WHERE nocopk IN (v_lot_job_id, v_product_job_id, v_run_job_id) AND product_id = v_product_id) <> 1
     OR (SELECT count(*) FROM public.vc_print_queue WHERE nocopk IN (v_lot_job_id, v_product_job_id, v_run_job_id) AND created_at >= v_created AND created_at < v_created + interval '5 minutes') <> 3
     OR (SELECT count(*) FROM public.vc_print_queue WHERE nocopk IN (v_lot_job_id, v_product_job_id, v_run_job_id) AND claimed_at >= v_created + interval '2 minutes' AND claimed_at <= v_created + interval '5 minutes') <> 2
     OR (SELECT count(*) FROM public.vc_print_queue WHERE nocopk IN (v_lot_job_id, v_product_job_id, v_run_job_id) AND printed_at >= v_created + interval '3 minutes' AND printed_at <= v_created + interval '3 minutes') <> 1 THEN
    RAISE EXCEPTION 'One or more Print Queue filter predicates returned an unexpected count.';
  END IF;

  RAISE NOTICE 'Print Queue view fields, filter predicates, audit timestamps, and target-routing smoke tests passed.';
END;
$$;

ROLLBACK;
