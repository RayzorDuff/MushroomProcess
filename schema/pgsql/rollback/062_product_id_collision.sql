BEGIN;
SELECT pg_advisory_xact_lock(520062);
DO $$ DECLARE b record;
BEGIN
 SELECT * INTO STRICT b FROM public.mp_product_id_062_backup;
 IF pg_get_functiondef(b.name::regprocedure) IS DISTINCT FROM b.applied_definition THEN RAISE EXCEPTION 'Later ID generator change requires review'; END IF;
 EXECUTE b.definition;
END $$;
UPDATE public.mp_product_id_062_backup SET applied_definition=NULL;
COMMIT;
