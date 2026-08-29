BEGIN;

SET LOCAL statement_timeout = '60s';
SET LOCAL lock_timeout = '5s';
SET LOCAL idle_in_transaction_session_timeout = '60s';

DO $test$
DECLARE
  v_pk bigint;
  v_row public.ecommerce_orders%ROWTYPE;
  v_time timestamp without time zone := timestamp '2026-08-28 18:30:00';
BEGIN
  /* Legacy Clover insert populates the provider-neutral aliases. */
  INSERT INTO public.ecommerce_orders (
    name,
    ecwid_order_id,
    payment_method,
    clover_reconciliation_status,
    clover_payment_id,
    clover_payment_amount,
    clover_payment_time,
    clover_match_confidence
  )
  VALUES (
    '__ISSUE85_R1_LEGACY_CLOVER__',
    'ISSUE85-R1-ORDER-1',
    'Sell on the Go - Credit Card',
    'pending',
    'CLOVER-R1-1',
    42.50,
    v_time,
    95
  )
  RETURNING nocopk INTO v_pk;

  SELECT * INTO STRICT v_row
  FROM public.ecommerce_orders
  WHERE nocopk = v_pk;

  IF v_row.payment_processor <> 'clover'
     OR v_row.payment_reconciliation_status <> 'pending'
     OR v_row.processor_payment_id <> 'CLOVER-R1-1'
     OR v_row.processor_payment_amount <> 42.50
     OR v_row.processor_payment_time <> v_time
     OR v_row.processor_match_confidence <> 95
  THEN
    RAISE EXCEPTION 'Legacy Clover insert did not populate provider-neutral payment aliases.';
  END IF;

  /* Existing Clover workflow updates continue to populate generic fields. */
  UPDATE public.ecommerce_orders
  SET clover_reconciliation_status = 'reconciled',
      clover_payment_id = 'CLOVER-R1-2',
      clover_payment_amount = 43.00,
      clover_match_confidence = 100
  WHERE nocopk = v_pk;

  SELECT * INTO STRICT v_row
  FROM public.ecommerce_orders
  WHERE nocopk = v_pk;

  IF v_row.payment_reconciliation_status <> 'reconciled'
     OR v_row.processor_payment_id <> 'CLOVER-R1-2'
     OR v_row.processor_payment_amount <> 43.00
     OR v_row.processor_match_confidence <> 100
  THEN
    RAISE EXCEPTION 'Legacy Clover update did not propagate to provider-neutral payment aliases.';
  END IF;

  /* Generic Clover writes remain compatible with legacy readers. */
  UPDATE public.ecommerce_orders
  SET payment_reconciliation_status = 'needs_review',
      processor_payment_id = 'CLOVER-R1-GENERIC',
      processor_payment_amount = 44.25,
      processor_match_confidence = 40
  WHERE nocopk = v_pk;

  SELECT * INTO STRICT v_row
  FROM public.ecommerce_orders
  WHERE nocopk = v_pk;

  IF v_row.clover_reconciliation_status <> 'needs_review'
     OR v_row.clover_payment_id <> 'CLOVER-R1-GENERIC'
     OR v_row.clover_payment_amount <> 44.25
     OR v_row.clover_match_confidence <> 40
  THEN
    RAISE EXCEPTION 'Provider-neutral Clover update did not preserve legacy Clover compatibility.';
  END IF;

  /* Ecwid initializes Clover reconciliation to pending even for website sales. */
  INSERT INTO public.ecommerce_orders (
    name,
    ecwid_order_id,
    payment_method,
    clover_reconciliation_status
  )
  VALUES (
    '__ISSUE85_R1_WEBSITE__',
    'ISSUE85-R1-WEB-ORDER',
    'Credit Card',
    'pending'
  )
  RETURNING nocopk INTO v_pk;

  SELECT * INTO STRICT v_row
  FROM public.ecommerce_orders
  WHERE nocopk = v_pk;

  IF v_row.payment_processor IS NOT NULL
     OR v_row.payment_reconciliation_status IS NOT NULL
  THEN
    RAISE EXCEPTION 'Ordinary Ecwid website order was incorrectly classified as Clover.';
  END IF;

  /* Moov is represented directly without populating any Clover aliases. */
  INSERT INTO public.ecommerce_orders (
    name,
    provider,
    site_key,
    external_order_id,
    payment_processor,
    processor_payment_id,
    processor_payment_status,
    processor_payment_amount,
    processor_payment_time,
    payment_reconciliation_status
  )
  VALUES (
    '__ISSUE85_R1_MOOV__',
    'moov_pos',
    'dank_mushrooms',
    'MOOV-SALE-R1',
    'moov',
    'MOOV-PAYMENT-R1',
    'completed',
    18.75,
    v_time,
    'reconciled'
  )
  RETURNING nocopk INTO v_pk;

  SELECT * INTO STRICT v_row
  FROM public.ecommerce_orders
  WHERE nocopk = v_pk;

  IF v_row.payment_processor <> 'moov'
     OR v_row.processor_payment_id <> 'MOOV-PAYMENT-R1'
     OR v_row.processor_payment_status <> 'completed'
     OR v_row.payment_reconciliation_status <> 'reconciled'
     OR v_row.clover_reconciliation_status IS NOT NULL
     OR v_row.clover_payment_id IS NOT NULL
     OR v_row.clover_payment_amount IS NOT NULL
     OR v_row.clover_payment_time IS NOT NULL
     OR v_row.clover_match_confidence IS NOT NULL
  THEN
    RAISE EXCEPTION 'Moov payment identity leaked into legacy Clover aliases.';
  END IF;

  RAISE NOTICE 'Issue #85 R1 provider-neutral payment alias smoke tests passed.';
END;
$test$;

ROLLBACK;
