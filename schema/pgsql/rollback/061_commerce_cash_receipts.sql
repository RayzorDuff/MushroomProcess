-- Disable new cash recording and its posting cycle before applying. Keep history.
BEGIN;
SELECT pg_advisory_xact_lock(520052);
DO $$ DECLARE entry record;
BEGIN
 IF EXISTS(SELECT 1 FROM public.mp_commerce_cash_receipts WHERE erp_references IS NULL) THEN RAISE EXCEPTION 'Reconcile pending real cash receipts before rollback'; END IF;
 FOR entry IN SELECT * FROM public.mp_commerce_cash_woo_backup WHERE applied_definition IS NOT NULL LOOP
  IF pg_get_functiondef(entry.name::regprocedure)<>entry.applied_definition THEN RAISE EXCEPTION 'Later Woo packing change requires review'; END IF;
  EXECUTE entry.definition;
 END LOOP;
END $$;
UPDATE public.mp_commerce_cash_woo_backup SET applied_definition=NULL;
DROP FUNCTION IF EXISTS public.mp_commerce_prepare_cash_packing();
DROP FUNCTION IF EXISTS public.mp_commerce_record_cash(jsonb);
DROP FUNCTION IF EXISTS public.mp_commerce_ack_cash(uuid,jsonb);
DROP FUNCTION IF EXISTS public.mp_commerce_confirm_cash(uuid);
COMMIT;
