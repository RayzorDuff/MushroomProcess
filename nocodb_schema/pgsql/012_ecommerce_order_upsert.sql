SET search_path = public, pg_catalog;

BEGIN;

CREATE OR REPLACE FUNCTION public.mp_ecommerce_order_upsert(
  p_order jsonb
)
RETURNS TABLE (
  nocopk bigint,
  id text,
  action text,
  ecwid_order_id text,
  ecwid_event_id text,
  payment_status text,
  clover_reconciliation_status text
)
LANGUAGE plpgsql
AS $function$
DECLARE
  v_ecwid_order_id text;
  v_existing_count integer;
  v_existing_pk bigint;
  v_row public.ecommerce_orders%ROWTYPE;
  v_action text;
BEGIN
  IF p_order IS NULL OR jsonb_typeof(p_order) <> 'object' THEN
    RAISE EXCEPTION 'Ecwid order payload must be a JSON object.';
  END IF;

  v_ecwid_order_id := NULLIF(BTRIM(p_order ->> 'ecwid_order_id'), '');

  IF v_ecwid_order_id IS NULL THEN
    RAISE EXCEPTION 'ecwid_order_id is required.';
  END IF;

  /*
   * Serialize webhook retries for the same Ecwid order without requiring the
   * Airtable-generated base table definition to carry a unique constraint.
   */
  PERFORM pg_advisory_xact_lock(hashtextextended(v_ecwid_order_id, 0));

  SELECT COUNT(*), MIN(o.nocopk)
  INTO v_existing_count, v_existing_pk
  FROM public.ecommerce_orders o
  WHERE o.ecwid_order_id = v_ecwid_order_id;

  IF v_existing_count > 1 THEN
    RAISE EXCEPTION
      'Multiple ecommerce_orders rows already exist for ecwid_order_id %.',
      v_ecwid_order_id;
  END IF;

  IF v_existing_count = 1 THEN
    UPDATE public.ecommerce_orders o
    SET
      name = NULLIF(p_order ->> 'name', ''),
      order_number = NULLIF(p_order ->> 'order_number', '')::numeric,
      order_code = NULLIF(p_order ->> 'order_code', ''),
      status = NULLIF(p_order ->> 'status', ''),
      order_date = CASE
        WHEN NULLIF(p_order ->> 'order_date', '') IS NULL THEN NULL
        ELSE (p_order ->> 'order_date')::timestamptz AT TIME ZONE 'UTC'
      END,
      customer_name = NULLIF(p_order ->> 'customer_name', ''),
      customer_email = NULLIF(p_order ->> 'customer_email', ''),
      items_json = p_order ->> 'items_json',
      ecwid_skus = NULLIF(p_order ->> 'ecwid_skus', ''),
      payment_status = NULLIF(p_order ->> 'payment_status', ''),
      payment_method = NULLIF(p_order ->> 'payment_method', ''),
      subtotal = NULLIF(p_order ->> 'subtotal', '')::numeric,
      tax_total = NULLIF(p_order ->> 'tax_total', '')::numeric,
      order_total = NULLIF(p_order ->> 'order_total', '')::numeric,
      currency = NULLIF(p_order ->> 'currency', ''),
      clover_reconciliation_status = NULLIF(p_order ->> 'clover_reconciliation_status', ''),
      clover_payment_id = NULLIF(p_order ->> 'clover_payment_id', ''),
      clover_payment_amount = NULLIF(p_order ->> 'clover_payment_amount', '')::numeric,
      clover_payment_time = CASE
        WHEN NULLIF(p_order ->> 'clover_payment_time', '') IS NULL THEN NULL
        ELSE (p_order ->> 'clover_payment_time')::timestamptz AT TIME ZONE 'UTC'
      END,
      clover_match_confidence = NULLIF(p_order ->> 'clover_match_confidence', '')::numeric,
      reconciled_at = CASE
        WHEN NULLIF(p_order ->> 'reconciled_at', '') IS NULL THEN NULL
        ELSE (p_order ->> 'reconciled_at')::timestamptz AT TIME ZONE 'UTC'
      END,
      reconciliation_notes = NULLIF(p_order ->> 'reconciliation_notes', ''),
      ecwid_event_type = NULLIF(p_order ->> 'ecwid_event_type', ''),
      ecwid_event_id = NULLIF(p_order ->> 'ecwid_event_id', ''),
      last_webhook_at = CASE
        WHEN NULLIF(p_order ->> 'last_webhook_at', '') IS NULL THEN localtimestamp
        ELSE (p_order ->> 'last_webhook_at')::timestamptz AT TIME ZONE 'UTC'
      END,
      nc_updated_at = localtimestamp
    WHERE o.nocopk = v_existing_pk
    RETURNING o.* INTO v_row;

    v_action := 'updated';
  ELSE
    INSERT INTO public.ecommerce_orders (
      name,
      ecwid_order_id,
      order_number,
      order_code,
      status,
      order_date,
      customer_name,
      customer_email,
      items_json,
      ecwid_skus,
      payment_status,
      payment_method,
      subtotal,
      tax_total,
      order_total,
      currency,
      clover_reconciliation_status,
      clover_payment_id,
      clover_payment_amount,
      clover_payment_time,
      clover_match_confidence,
      reconciled_at,
      reconciliation_notes,
      ecwid_event_type,
      ecwid_event_id,
      last_webhook_at
    )
    VALUES (
      NULLIF(p_order ->> 'name', ''),
      v_ecwid_order_id,
      NULLIF(p_order ->> 'order_number', '')::numeric,
      NULLIF(p_order ->> 'order_code', ''),
      NULLIF(p_order ->> 'status', ''),
      CASE
        WHEN NULLIF(p_order ->> 'order_date', '') IS NULL THEN NULL
        ELSE (p_order ->> 'order_date')::timestamptz AT TIME ZONE 'UTC'
      END,
      NULLIF(p_order ->> 'customer_name', ''),
      NULLIF(p_order ->> 'customer_email', ''),
      p_order ->> 'items_json',
      NULLIF(p_order ->> 'ecwid_skus', ''),
      NULLIF(p_order ->> 'payment_status', ''),
      NULLIF(p_order ->> 'payment_method', ''),
      NULLIF(p_order ->> 'subtotal', '')::numeric,
      NULLIF(p_order ->> 'tax_total', '')::numeric,
      NULLIF(p_order ->> 'order_total', '')::numeric,
      NULLIF(p_order ->> 'currency', ''),
      NULLIF(p_order ->> 'clover_reconciliation_status', ''),
      NULLIF(p_order ->> 'clover_payment_id', ''),
      NULLIF(p_order ->> 'clover_payment_amount', '')::numeric,
      CASE
        WHEN NULLIF(p_order ->> 'clover_payment_time', '') IS NULL THEN NULL
        ELSE (p_order ->> 'clover_payment_time')::timestamptz AT TIME ZONE 'UTC'
      END,
      NULLIF(p_order ->> 'clover_match_confidence', '')::numeric,
      CASE
        WHEN NULLIF(p_order ->> 'reconciled_at', '') IS NULL THEN NULL
        ELSE (p_order ->> 'reconciled_at')::timestamptz AT TIME ZONE 'UTC'
      END,
      NULLIF(p_order ->> 'reconciliation_notes', ''),
      NULLIF(p_order ->> 'ecwid_event_type', ''),
      NULLIF(p_order ->> 'ecwid_event_id', ''),
      CASE
        WHEN NULLIF(p_order ->> 'last_webhook_at', '') IS NULL THEN localtimestamp
        ELSE (p_order ->> 'last_webhook_at')::timestamptz AT TIME ZONE 'UTC'
      END
    )
    RETURNING * INTO v_row;

    v_action := 'created';
  END IF;

  RETURN QUERY
  SELECT
    v_row.nocopk,
    COALESCE(v_row.airtable_id, v_row.nocopk::text),
    v_action,
    v_row.ecwid_order_id,
    v_row.ecwid_event_id,
    v_row.payment_status,
    v_row.clover_reconciliation_status;
END;
$function$;

COMMIT;
