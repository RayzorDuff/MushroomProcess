BEGIN;

SET LOCAL statement_timeout = '60s';
SET LOCAL lock_timeout = '5s';
SET LOCAL idle_in_transaction_session_timeout = '60s';

DO $test$
DECLARE
  v_test_id text := '__RC5_ECWID_UPSERT__';
  v_duplicate_id text := '__RC5_ECWID_DUPLICATE__';
  v_result record;
  v_row public.ecommerce_orders%ROWTYPE;
  v_failed boolean;
BEGIN
  DELETE FROM public.ecommerce_orders
  WHERE ecwid_order_id IN (v_test_id, v_duplicate_id);

  SELECT *
  INTO v_result
  FROM public.mp_ecommerce_order_upsert(
    jsonb_build_object(
      'ecwid_order_id', v_test_id,
      'order_number', 900001,
      'order_code', 'RC5-ECWID-1',
      'name', '#RC5-ECWID-1 – Test Customer',
      'status', 'AWAITING_PROCESSING',
      'payment_status', 'AWAITING_PAYMENT',
      'payment_method', 'Online Card',
      'order_date', '2026-07-27T18:30:00.000Z',
      'customer_name', 'Test Customer',
      'customer_email', 'ecwid-test@example.invalid',
      'items_json', '[{"sku":"TEST-SKU","quantity":1}]',
      'ecwid_skus', 'TEST-SKU',
      'subtotal', 10.00,
      'tax_total', 0.80,
      'order_total', 10.80,
      'currency', 'USD',
      'ecwid_event_type', 'order.created',
      'ecwid_event_id', 'evt-rc5-create',
      'last_webhook_at', '2026-07-27T18:31:00.000Z',
      'clover_reconciliation_status', 'pending'
    )
  );

  IF v_result.action <> 'created' THEN
    RAISE EXCEPTION 'Expected created action, got %.', v_result.action;
  END IF;

  SELECT * INTO STRICT v_row
  FROM public.ecommerce_orders
  WHERE ecwid_order_id = v_test_id;

  IF v_row.order_code <> 'RC5-ECWID-1'
     OR v_row.payment_status <> 'AWAITING_PAYMENT'
     OR v_row.order_total <> 10.80
     OR v_row.ecwid_event_id <> 'evt-rc5-create'
     OR v_row.clover_reconciliation_status <> 'pending'
  THEN
    RAISE EXCEPTION 'Created Ecwid order fields were not persisted correctly.';
  END IF;

  UPDATE public.ecommerce_orders
  SET
    clover_reconciliation_status = 'reconciled',
    clover_payment_id = 'clover-before-update',
    clover_payment_amount = 10.80,
    reconciled_at = localtimestamp,
    reconciliation_notes = 'must be reset by awaiting-payment webhook'
  WHERE nocopk = v_row.nocopk;

  SELECT *
  INTO v_result
  FROM public.mp_ecommerce_order_upsert(
    jsonb_build_object(
      'ecwid_order_id', v_test_id,
      'order_number', 900001,
      'order_code', 'RC5-ECWID-1',
      'name', '#RC5-ECWID-1 – Updated Customer',
      'status', 'AWAITING_PROCESSING',
      'payment_status', 'AWAITING_PAYMENT',
      'payment_method', 'Online Card',
      'order_date', '2026-07-27T18:30:00.000Z',
      'customer_name', 'Updated Customer',
      'customer_email', 'updated@example.invalid',
      'items_json', '[{"sku":"TEST-SKU","quantity":2}]',
      'ecwid_skus', 'TEST-SKU',
      'subtotal', 20.00,
      'tax_total', 1.60,
      'order_total', 21.60,
      'currency', 'USD',
      'ecwid_event_type', 'order.updated',
      'ecwid_event_id', 'evt-rc5-update',
      'last_webhook_at', '2026-07-27T18:35:00.000Z',
      'clover_reconciliation_status', 'pending',
      'clover_payment_id', NULL,
      'clover_payment_amount', NULL,
      'clover_payment_time', NULL,
      'clover_match_confidence', NULL,
      'reconciled_at', NULL,
      'reconciliation_notes', NULL
    )
  );

  IF v_result.action <> 'updated' THEN
    RAISE EXCEPTION 'Expected updated action, got %.', v_result.action;
  END IF;

  IF (SELECT COUNT(*) FROM public.ecommerce_orders WHERE ecwid_order_id = v_test_id) <> 1 THEN
    RAISE EXCEPTION 'Ecwid retry created a duplicate ecommerce_orders row.';
  END IF;

  SELECT * INTO STRICT v_row
  FROM public.ecommerce_orders
  WHERE ecwid_order_id = v_test_id;

  IF v_row.customer_name <> 'Updated Customer'
     OR v_row.order_total <> 21.60
     OR v_row.ecwid_event_id <> 'evt-rc5-update'
     OR v_row.clover_reconciliation_status <> 'pending'
     OR v_row.clover_payment_id IS NOT NULL
     OR v_row.clover_payment_amount IS NOT NULL
     OR v_row.reconciled_at IS NOT NULL
     OR v_row.reconciliation_notes IS NOT NULL
  THEN
    RAISE EXCEPTION 'Updated Ecwid order or reconciliation reset is incorrect.';
  END IF;

  INSERT INTO public.ecommerce_orders(ecwid_order_id, order_code)
  VALUES
    (v_duplicate_id, 'DUP-A'),
    (v_duplicate_id, 'DUP-B');

  v_failed := false;
  BEGIN
    PERFORM *
    FROM public.mp_ecommerce_order_upsert(
      jsonb_build_object(
        'ecwid_order_id', v_duplicate_id,
        'order_number', 900002,
        'payment_status', 'AWAITING_PAYMENT'
      )
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE 'Multiple ecommerce_orders rows already exist%' THEN
        RAISE;
      END IF;
      v_failed := true;
  END;

  IF NOT v_failed THEN
    RAISE EXCEPTION 'Duplicate existing Ecwid orders were not rejected.';
  END IF;

  v_failed := false;
  BEGIN
    PERFORM *
    FROM public.mp_ecommerce_order_upsert('{}'::jsonb);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM <> 'ecwid_order_id is required.' THEN
        RAISE;
      END IF;
      v_failed := true;
  END;

  IF NOT v_failed THEN
    RAISE EXCEPTION 'Blank ecwid_order_id was not rejected.';
  END IF;

  RAISE NOTICE 'Ecwid PostgreSQL create/update, retry idempotency, reconciliation reset, and duplicate-data guard smoke tests passed.';
END;
$test$;

ROLLBACK;
