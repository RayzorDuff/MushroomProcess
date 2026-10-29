\set ON_ERROR_STOP on
BEGIN;
DO $$
DECLARE difference_count bigint;
BEGIN
  -- Existing Ecwid candidates must keep exactly the same availability.
  SELECT count(*) INTO difference_count
  FROM public.mp_ecommerce_ecwid_catalog_sync_candidates() old
  FULL JOIN (SELECT * FROM public.mp_ecommerce_catalog_inventory() WHERE provider = 'ecwid') new
    USING (ecommerce_id)
  WHERE old.desired_quantity IS DISTINCT FROM new.desired_quantity;
  IF difference_count <> 0 THEN RAISE EXCEPTION 'Catalog quantity regression'; END IF;
END $$;
ROLLBACK;
