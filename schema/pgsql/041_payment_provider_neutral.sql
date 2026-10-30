SET search_path = public, pg_catalog;

BEGIN;

/*
 * Issue #85, R1: provider-neutral payment/reconciliation identity.
 *
 * Clover remains the production payment processor during this migration.
 * These aliases are additive and deliberately preserve the existing clover_*
 * columns so current workflows can continue unchanged while later rounds move
 * Fulfillment and n8n reads/writes to the generic contract.
 */
ALTER TABLE public.ecommerce_orders
  ADD COLUMN IF NOT EXISTS payment_processor text,
  ADD COLUMN IF NOT EXISTS processor_payment_id text,
  ADD COLUMN IF NOT EXISTS processor_payment_status text,
  ADD COLUMN IF NOT EXISTS processor_payment_amount numeric,
  ADD COLUMN IF NOT EXISTS processor_payment_time timestamp without time zone,
  ADD COLUMN IF NOT EXISTS processor_match_confidence numeric,
  ADD COLUMN IF NOT EXISTS payment_reconciliation_status text;

CREATE INDEX IF NOT EXISTS ix_ecommerce_orders_processor_payment_id
  ON public.ecommerce_orders(payment_processor, processor_payment_id);

CREATE OR REPLACE FUNCTION public.mp_ecommerce_order_sync_legacy_clover_payment_aliases()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
  v_is_clover boolean;
BEGIN
  /*
   * Existing production rows did not carry an explicit processor. Infer Clover
   * only when Clover reconciliation evidence exists. Website orders that never
   * touched Clover remain processor-neutral until their actual processor is
   * known.
   */
  IF NULLIF(BTRIM(NEW.payment_processor), '') IS NULL AND (
    lower(COALESCE(NEW.payment_method, '')) LIKE 'sell on the go%'
    OR NULLIF(BTRIM(NEW.clover_payment_id), '') IS NOT NULL
    OR NEW.clover_payment_amount IS NOT NULL
    OR NEW.clover_payment_time IS NOT NULL
    OR NEW.clover_match_confidence IS NOT NULL
  ) THEN
    NEW.payment_processor := 'clover';
  END IF;

  v_is_clover := lower(COALESCE(NULLIF(BTRIM(NEW.payment_processor), ''), '')) = 'clover';

  IF NOT v_is_clover THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    NEW.payment_reconciliation_status := COALESCE(
      NEW.payment_reconciliation_status,
      NEW.clover_reconciliation_status
    );
    NEW.processor_payment_id := COALESCE(
      NEW.processor_payment_id,
      NEW.clover_payment_id
    );
    NEW.processor_payment_amount := COALESCE(
      NEW.processor_payment_amount,
      NEW.clover_payment_amount
    );
    NEW.processor_payment_time := COALESCE(
      NEW.processor_payment_time,
      NEW.clover_payment_time
    );
    NEW.processor_match_confidence := COALESCE(
      NEW.processor_match_confidence,
      NEW.clover_match_confidence
    );

    NEW.clover_reconciliation_status := COALESCE(
      NEW.clover_reconciliation_status,
      NEW.payment_reconciliation_status
    );
    NEW.clover_payment_id := COALESCE(
      NEW.clover_payment_id,
      NEW.processor_payment_id
    );
    NEW.clover_payment_amount := COALESCE(
      NEW.clover_payment_amount,
      NEW.processor_payment_amount
    );
    NEW.clover_payment_time := COALESCE(
      NEW.clover_payment_time,
      NEW.processor_payment_time
    );
    NEW.clover_match_confidence := COALESCE(
      NEW.clover_match_confidence,
      NEW.processor_match_confidence
    );
  ELSE
    /* Existing Clover writers update legacy fields; later #85 writers may use
     * the generic aliases. Mirror whichever side changed in this statement.
     */
    IF NEW.clover_reconciliation_status IS DISTINCT FROM OLD.clover_reconciliation_status
       AND NEW.payment_reconciliation_status IS NOT DISTINCT FROM OLD.payment_reconciliation_status THEN
      NEW.payment_reconciliation_status := NEW.clover_reconciliation_status;
    ELSIF NEW.payment_reconciliation_status IS DISTINCT FROM OLD.payment_reconciliation_status
       AND NEW.clover_reconciliation_status IS NOT DISTINCT FROM OLD.clover_reconciliation_status THEN
      NEW.clover_reconciliation_status := NEW.payment_reconciliation_status;
    ELSIF NEW.payment_reconciliation_status IS NULL THEN
      NEW.payment_reconciliation_status := NEW.clover_reconciliation_status;
    ELSIF NEW.clover_reconciliation_status IS NULL THEN
      NEW.clover_reconciliation_status := NEW.payment_reconciliation_status;
    END IF;

    IF NEW.clover_payment_id IS DISTINCT FROM OLD.clover_payment_id
       AND NEW.processor_payment_id IS NOT DISTINCT FROM OLD.processor_payment_id THEN
      NEW.processor_payment_id := NEW.clover_payment_id;
    ELSIF NEW.processor_payment_id IS DISTINCT FROM OLD.processor_payment_id
       AND NEW.clover_payment_id IS NOT DISTINCT FROM OLD.clover_payment_id THEN
      NEW.clover_payment_id := NEW.processor_payment_id;
    ELSIF NEW.processor_payment_id IS NULL THEN
      NEW.processor_payment_id := NEW.clover_payment_id;
    ELSIF NEW.clover_payment_id IS NULL THEN
      NEW.clover_payment_id := NEW.processor_payment_id;
    END IF;

    IF NEW.clover_payment_amount IS DISTINCT FROM OLD.clover_payment_amount
       AND NEW.processor_payment_amount IS NOT DISTINCT FROM OLD.processor_payment_amount THEN
      NEW.processor_payment_amount := NEW.clover_payment_amount;
    ELSIF NEW.processor_payment_amount IS DISTINCT FROM OLD.processor_payment_amount
       AND NEW.clover_payment_amount IS NOT DISTINCT FROM OLD.clover_payment_amount THEN
      NEW.clover_payment_amount := NEW.processor_payment_amount;
    ELSIF NEW.processor_payment_amount IS NULL THEN
      NEW.processor_payment_amount := NEW.clover_payment_amount;
    ELSIF NEW.clover_payment_amount IS NULL THEN
      NEW.clover_payment_amount := NEW.processor_payment_amount;
    END IF;

    IF NEW.clover_payment_time IS DISTINCT FROM OLD.clover_payment_time
       AND NEW.processor_payment_time IS NOT DISTINCT FROM OLD.processor_payment_time THEN
      NEW.processor_payment_time := NEW.clover_payment_time;
    ELSIF NEW.processor_payment_time IS DISTINCT FROM OLD.processor_payment_time
       AND NEW.clover_payment_time IS NOT DISTINCT FROM OLD.clover_payment_time THEN
      NEW.clover_payment_time := NEW.processor_payment_time;
    ELSIF NEW.processor_payment_time IS NULL THEN
      NEW.processor_payment_time := NEW.clover_payment_time;
    ELSIF NEW.clover_payment_time IS NULL THEN
      NEW.clover_payment_time := NEW.processor_payment_time;
    END IF;

    IF NEW.clover_match_confidence IS DISTINCT FROM OLD.clover_match_confidence
       AND NEW.processor_match_confidence IS NOT DISTINCT FROM OLD.processor_match_confidence THEN
      NEW.processor_match_confidence := NEW.clover_match_confidence;
    ELSIF NEW.processor_match_confidence IS DISTINCT FROM OLD.processor_match_confidence
       AND NEW.clover_match_confidence IS NOT DISTINCT FROM OLD.clover_match_confidence THEN
      NEW.clover_match_confidence := NEW.processor_match_confidence;
    ELSIF NEW.processor_match_confidence IS NULL THEN
      NEW.processor_match_confidence := NEW.clover_match_confidence;
    ELSIF NEW.clover_match_confidence IS NULL THEN
      NEW.clover_match_confidence := NEW.processor_match_confidence;
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_ecommerce_orders_sync_legacy_clover_payment_aliases
  ON public.ecommerce_orders;
CREATE TRIGGER trg_ecommerce_orders_sync_legacy_clover_payment_aliases
BEFORE INSERT OR UPDATE ON public.ecommerce_orders
FOR EACH ROW
EXECUTE FUNCTION public.mp_ecommerce_order_sync_legacy_clover_payment_aliases();

/*
 * Backfill only market-sale rows or rows with actual Clover payment evidence.
 * Ecwid currently initializes clover_reconciliation_status='pending' on every
 * order, including ordinary website orders, so that field alone is not proof
 * that Clover participated in the payment.
 */
UPDATE public.ecommerce_orders
SET
  payment_processor = COALESCE(NULLIF(BTRIM(payment_processor), ''), 'clover'),
  payment_reconciliation_status = COALESCE(payment_reconciliation_status, clover_reconciliation_status),
  processor_payment_id = COALESCE(processor_payment_id, clover_payment_id),
  processor_payment_amount = COALESCE(processor_payment_amount, clover_payment_amount),
  processor_payment_time = COALESCE(processor_payment_time, clover_payment_time),
  processor_match_confidence = COALESCE(processor_match_confidence, clover_match_confidence)
WHERE
  lower(COALESCE(NULLIF(BTRIM(payment_processor), ''), 'clover')) = 'clover'
  AND (
    lower(COALESCE(payment_method, '')) LIKE 'sell on the go%'
    OR NULLIF(BTRIM(clover_payment_id), '') IS NOT NULL
    OR clover_payment_amount IS NOT NULL
    OR clover_payment_time IS NOT NULL
    OR clover_match_confidence IS NOT NULL
  );

COMMIT;
