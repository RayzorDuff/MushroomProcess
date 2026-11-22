-- Pause Woo intake/dispatch workers first; keep existing receipts and stock.
BEGIN;
SELECT pg_advisory_xact_lock(520052);
DO $$ DECLARE entry record;
BEGIN
 IF EXISTS(SELECT 1 FROM public.mp_commerce_pool_owner_changes WHERE restored_at IS NULL) THEN RAISE EXCEPTION 'Restore active owner handoffs before 059 rollback'; END IF;
 FOR entry IN SELECT * FROM public.mp_commerce_059_backup LOOP
  IF pg_get_functiondef(entry.name::regprocedure) IS DISTINCT FROM entry.applied_definition THEN
   RAISE EXCEPTION 'Later function change requires review before rollback'; END IF;
 END LOOP;
 FOR entry IN SELECT * FROM public.mp_commerce_059_backup LOOP EXECUTE entry.definition; END LOOP;
END $$;
UPDATE public.mp_commerce_059_backup SET applied_definition=NULL;
COMMIT;
