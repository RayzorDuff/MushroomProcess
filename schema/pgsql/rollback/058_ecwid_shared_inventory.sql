-- Pause Commercial Inventory Sync and legacy publishers FIRST. Keep receipts/data.
BEGIN;
SELECT pg_advisory_xact_lock(520052);
DO $$ DECLARE entry record;
BEGIN
 IF EXISTS(SELECT 1 FROM public.mp_ecwid_inventory_publications WHERE pending_token IS NOT NULL) THEN
  RAISE EXCEPTION 'Resolve pending Ecwid API outcomes before rollback'; END IF;
 FOR entry IN SELECT * FROM public.mp_inventory_058_backup LOOP
  IF pg_get_functiondef(entry.name::regprocedure) IS DISTINCT FROM entry.applied_definition THEN
   RAISE EXCEPTION 'Installed function changed since 058: review before rollback'; END IF;
 END LOOP;
 FOR entry IN SELECT * FROM public.mp_inventory_058_backup LOOP EXECUTE entry.definition; END LOOP;
END $$;
UPDATE public.mp_inventory_058_backup SET applied_definition=NULL;
-- Keep additive rules/baselines/backups for audit. They have no active scheduler.
-- Do not reset stock, restore a whole database, or replay a stock delta.
COMMIT;
