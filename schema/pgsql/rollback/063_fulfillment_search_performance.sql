BEGIN;
SET LOCAL lock_timeout='10s';
SELECT pg_advisory_xact_lock(520052);
DO $$
DECLARE row record;
BEGIN
 FOR row IN SELECT * FROM public.mp_fulfillment_063_backup LOOP
  IF pg_get_functiondef(row.name::regprocedure) IS DISTINCT FROM row.applied_definition THEN
   RAISE EXCEPTION 'Later fulfillment function change requires review: %',row.name;
  END IF;
 END LOOP;
 FOR row IN SELECT * FROM public.mp_fulfillment_063_backup LOOP EXECUTE row.definition; END LOOP;
END $$;
UPDATE public.mp_fulfillment_063_backup SET applied_definition=NULL;
-- Retain the harmless supporting index and all allocation/dispatch data.
COMMIT;
