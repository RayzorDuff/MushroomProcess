\set ON_ERROR_STOP on
BEGIN;
DO $$
DECLARE difference_count bigint;
BEGIN
  DECLARE
    item_pk bigint;
    ecommerce_pk bigint;
    location_pk bigint;
    got record;
  BEGIN
    INSERT INTO public.items(item_id, name, category, active)
      VALUES ('ITEM-COMMERCE-051', 'Synthetic commerce item', 'fruiting_block', true)
      RETURNING nocopk INTO item_pk;
    INSERT INTO public.locations(name,active,type) VALUES ('Commerce Test Storage',true,'Storage')
      RETURNING nocopk INTO location_pk;
    INSERT INTO public.ecommerce(name,item_id,provider,site_key,external_sku,sync_enabled,erp_item_code,status)
      VALUES ('Synthetic WooCommerce',item_pk,'woocommerce','test','COMMERCE-051',true,'COMMERCE-051','Sterilized')
      RETURNING nocopk INTO ecommerce_pk;
    INSERT INTO public.products(item_id,storage_location_id,use_by) VALUES
      (item_pk,location_pk,CURRENT_DATE+10),(item_pk,location_pk,CURRENT_DATE-1);
    INSERT INTO public.lots(item_id,status,use_by) VALUES (item_pk,'Sterilized',CURRENT_DATE+10);
    SELECT * INTO got FROM public.mp_ecommerce_catalog_inventory() WHERE ecommerce_id=ecommerce_pk;
    IF got.erp_item_code IS DISTINCT FROM 'COMMERCE-051' OR got.desired_quantity IS DISTINCT FROM 2::bigint THEN
      RAISE EXCEPTION 'Provider-neutral synthetic inventory incorrect: %', row_to_json(got);
    END IF;
    UPDATE public.ecommerce SET sync_enabled=false WHERE nocopk=ecommerce_pk;
    IF EXISTS (SELECT 1 FROM public.mp_ecommerce_catalog_inventory() WHERE ecommerce_id=ecommerce_pk) THEN
      RAISE EXCEPTION 'Disabled mapping must not be a sync candidate';
    END IF;
  END;
  -- Existing Ecwid candidates must keep exactly the same availability.
  SELECT count(*) INTO difference_count
  FROM public.mp_ecommerce_ecwid_catalog_sync_candidates() old
  FULL JOIN (SELECT * FROM public.mp_ecommerce_catalog_inventory() WHERE provider = 'ecwid') new
    USING (ecommerce_id)
  WHERE old.desired_quantity IS DISTINCT FROM new.desired_quantity;
  IF difference_count <> 0 THEN RAISE EXCEPTION 'Catalog quantity regression'; END IF;
END $$;
ROLLBACK;
