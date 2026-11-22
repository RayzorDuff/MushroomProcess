-- Preserve all existing IDs/UUIDs/QR labels. Only allocate a missing new ID.
BEGIN;
SET LOCAL lock_timeout='10s';
CREATE TABLE IF NOT EXISTS public.mp_product_id_062_backup (
 name text PRIMARY KEY,definition text NOT NULL,applied_definition text);
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM public.mp_product_id_062_backup WHERE pg_get_functiondef(name::regprocedure)
 IS DISTINCT FROM coalesce(applied_definition,definition)) THEN RAISE EXCEPTION 'Later Product ID generator change requires review'; END IF;
END $$;
INSERT INTO public.mp_product_id_062_backup(name,definition)
 VALUES('public.set_autogen_ids_products()',pg_get_functiondef('public.set_autogen_ids_products()'::regprocedure)) ON CONFLICT DO NOTHING;
CREATE OR REPLACE FUNCTION public.set_autogen_ids_products() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE base text;candidate text;attempt integer:=0;
BEGIN
 IF NEW.nocouuid IS NULL THEN NEW.nocouuid:=gen_random_uuid(); END IF;
 IF NEW.nc_created_at IS NULL THEN NEW.nc_created_at:=now(); END IF;
 IF TG_OP='UPDATE' THEN NEW.nc_updated_at:=now(); END IF;
 IF NEW.product_id IS NULL OR NEW.product_id='' THEN
  -- One namespace lock avoids deadlocks from acquiring several random-prefix
  -- locks in different batch orders. It does not take the commerce stock lock.
  PERFORM pg_advisory_xact_lock(520062);
  base:='PROD-'||to_char(NEW.nc_created_at::timestamp,'YYMMDD')||'-'||right(coalesce(nullif(NEW.airtable_id::text,''),replace(NEW.nocouuid::text,'-',''),NEW.nocopk::text),4);
  candidate:=base;
  WHILE EXISTS(SELECT 1 FROM public.products WHERE product_id=candidate AND nocopk IS DISTINCT FROM NEW.nocopk) LOOP
   IF NEW.nocopk IS NULL THEN RAISE EXCEPTION 'Product primary identity required for collision recovery'; END IF;
   attempt:=attempt+1;
   IF attempt>32 THEN RAISE EXCEPTION 'Product ID collision requires explicit review'; END IF;
   candidate:=base||'-'||NEW.nocopk::text||CASE WHEN attempt=1 THEN '' ELSE '-'||attempt::text END;
  END LOOP;
  NEW.product_id:=candidate;
 END IF;
 RETURN NEW;
END $$;
UPDATE public.mp_product_id_062_backup SET applied_definition=pg_get_functiondef(name::regprocedure);
COMMIT;
