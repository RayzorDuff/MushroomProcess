\set ON_ERROR_STOP on
BEGIN;
-- This inventory regression does not test short random Lot ID allocation.
-- Keep fixtures deterministic; the trigger/function disappear on ROLLBACK.
CREATE FUNCTION pg_temp.t058_lot_fixture_id() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.lot_id IS NULL OR NEW.lot_id='' THEN NEW.lot_id:='LOT-T058-'||NEW.nocopk::text; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER a_t058_lot_fixture_id BEFORE INSERT ON public.lots
 FOR EACH ROW EXECUTE FUNCTION pg_temp.t058_lot_fixture_id();
DO $$
DECLARE cvg bigint;legacy bigint;alias_item bigint;hardwood bigint;hard_legacy bigint;
 dried bigint;dried_legacy bigint;chestnut bigint;reishi bigint;loc bigint;badloc bigint;ship bigint;
 recipe bigint;wrong_recipe bigint;ec bigint;alias_ec bigint;hw_ec bigint;ch_ec bigint;re_ec bigint;
 lot bigint;prod bigint;ord bigint;v bigint;packet jsonb;plan jsonb;token uuid;
BEGIN
 INSERT INTO public.items(item_id,name,category,active) VALUES('T058-CVG','Synthetic CVG','substrate',true) RETURNING nocopk INTO cvg;
 INSERT INTO public.items(item_id,name,category) VALUES('T058-LEGACY','Synthetic legacy 5lb','substrate') RETURNING nocopk INTO legacy;
 INSERT INTO public.items(item_id,name,category) VALUES('T058-ALIAS','Synthetic alias 5lb','substrate') RETURNING nocopk INTO alias_item;
 INSERT INTO public.items(item_id,name,category,active) VALUES('T058-HW','Synthetic HW','substrate',true) RETURNING nocopk INTO hardwood;
 INSERT INTO public.items(item_id,name,category) VALUES('T058-HW-OLD','Synthetic HW 7.5lb','substrate') RETURNING nocopk INTO hard_legacy;
 INSERT INTO public.items(item_id,name,category,active) VALUES('T058-DRIED','Synthetic dried','freezedriedmushrooms',true) RETURNING nocopk INTO dried;
 INSERT INTO public.items(item_id,name,category) VALUES('T058-DRIED-OLD','Synthetic 1oz','freezedriedmushrooms') RETURNING nocopk INTO dried_legacy;
 INSERT INTO public.strains(strain_id,species_strain) VALUES('T058-CH','Synthetic Chestnut') RETURNING nocopk INTO chestnut;
 INSERT INTO public.strains(strain_id,species_strain) VALUES('T058-RE','Synthetic Reishi') RETURNING nocopk INTO reishi;
 INSERT INTO public.recipes(recipe_id,name) VALUES('T058-CVG-R','Synthetic CVG recipe') RETURNING nocopk INTO recipe;
 INSERT INTO public.recipes(recipe_id,name) VALUES('T058-HW-R','Synthetic 75/25') RETURNING nocopk INTO wrong_recipe;
 INSERT INTO public.mp_inventory_item_rules VALUES
 ('T058-LEGACY','T058-CVG','lb',5,ARRAY['T058-CVG-R']),
 ('T058-ALIAS','T058-CVG','lb',5,ARRAY['T058-CVG-R']),
 ('T058-HW-OLD','T058-HW','lb',7.5,ARRAY['T058-HW-R']),
 ('T058-DRIED-OLD','T058-DRIED','oz',1,ARRAY[]::text[]);
 INSERT INTO public.locations(name,active,type) VALUES('T058 New Lots',true,'Storage') RETURNING nocopk INTO loc;
 INSERT INTO public.locations(name,active,type) VALUES('Missing or Lost',true,'Exception') RETURNING nocopk INTO badloc;
 INSERT INTO public.locations(name,active,type) VALUES('Shipped',true,'Terminal') RETURNING nocopk INTO ship;
 INSERT INTO public.ecommerce(name,item_id,status,provider,site_key,external_sku,external_product_id,sync_enabled,erp_item_code)
 VALUES('Synthetic CVG',legacy,'Pasteurized','ecwid','t058','T058-CVG','900581',true,'T058-CVG') RETURNING nocopk INTO ec;
 INSERT INTO public.ecommerce(name,item_id,status,provider,site_key,external_sku,external_product_id,sync_enabled,erp_item_code)
 VALUES('Synthetic alias',alias_item,'Pasteurized','woocommerce','t058','T058-ALIAS','900582',true,'T058-CVG') RETURNING nocopk INTO alias_ec;
 INSERT INTO public.ecommerce(name,item_id,status,provider,site_key,external_sku,external_product_id,sync_enabled)
 VALUES('Synthetic hardwood',hard_legacy,'Sterilized','ecwid','t058','T058-HW','900583',true) RETURNING nocopk INTO hw_ec;
 INSERT INTO public.ecommerce(name,item_id,strain_id,provider,site_key,external_sku,external_product_id,sync_enabled)
 VALUES('Synthetic Chestnut',dried_legacy,chestnut,'ecwid','t058','T058-CH','900584',true) RETURNING nocopk INTO ch_ec;
 INSERT INTO public.ecommerce(name,item_id,strain_id,provider,site_key,external_sku,external_product_id,sync_enabled)
 VALUES('Synthetic Reishi',dried_legacy,reishi,'ecwid','t058','T058-RE','900585',true) RETURNING nocopk INTO re_ec;
 INSERT INTO public.lots(item_id,unit_size,recipe_id,status,qty,location_id,use_by)
 SELECT cvg,5,recipe,'Pasteurized',1,loc,CURRENT_DATE+90 FROM generate_series(1,5);
 INSERT INTO public.lots(item_id,unit_size,recipe_id,status,qty,location_id,use_by)
 SELECT hardwood,7.5,wrong_recipe,'Sterilized',1,loc,CURRENT_DATE+90 FROM generate_series(1,3);
 INSERT INTO public.products(item_id,strain_id,net_weight_oz,net_weight_g,package_size,storage_location_id,use_by)
 SELECT dried,chestnut,1,28.3,'1 oz',loc,CURRENT_DATE+90 FROM generate_series(1,3);
 INSERT INTO public.products(item_id,strain_id,net_weight_oz,net_weight_g,package_size,storage_location_id,use_by)
 SELECT dried,reishi,1,28.3,'1 oz',loc,CURRENT_DATE+90 FROM generate_series(1,13);
 INSERT INTO public.products(item_id,strain_id,net_weight_g,storage_location_id,use_by)
 SELECT dried_legacy,chestnut,28,loc,CURRENT_DATE+90 FROM generate_series(1,9);
 -- Negative specifications: other size/recipe/strain/stage/date/location/retirement.
 INSERT INTO public.lots(item_id,unit_size,recipe_id,status,qty,location_id,use_by) VALUES
 (cvg,2.5,recipe,'Pasteurized',1,loc,CURRENT_DATE+90),
 (cvg,5,wrong_recipe,'Pasteurized',1,loc,CURRENT_DATE+90),
 (cvg,5,recipe,'Sterilized',1,loc,CURRENT_DATE+90),
 (cvg,5,recipe,'Pasteurized',1,loc,CURRENT_DATE-1),
 (cvg,5,recipe,'Pasteurized',1,badloc,CURRENT_DATE+90),
 (cvg,5,recipe,'Pasteurized',1,NULL,CURRENT_DATE+90),
 (cvg,5,recipe,'Pasteurized',4,loc,CURRENT_DATE+90);
 INSERT INTO public.lots(item_id,unit_size,recipe_id,status,qty,location_id,use_by,retired_at)
 VALUES(cvg,5,recipe,'Pasteurized',1,loc,CURRENT_DATE+90,now());
 INSERT INTO public.products(item_id,strain_id,net_weight_g,package_size,storage_location_id,use_by)
 SELECT dried,reishi,5,'5 g',loc,CURRENT_DATE+90 FROM generate_series(1,11);
 SELECT available_quantity INTO v FROM public.mp_commerce_inventory() WHERE ecommerce_id=ec;
 IF v<>5 THEN RAISE EXCEPTION '5lb CVG candidates: %',v; END IF;
 SELECT available_quantity INTO v FROM public.mp_commerce_inventory() WHERE ecommerce_id=hw_ec;
 IF v<>3 THEN RAISE EXCEPTION '7.5lb hardwood candidates: %',v; END IF;
 SELECT available_quantity INTO v FROM public.mp_commerce_inventory() WHERE ecommerce_id=ch_ec;
 IF v<>12 THEN RAISE EXCEPTION 'Chestnut 1oz candidates: %',v; END IF;
 SELECT available_quantity INTO v FROM public.mp_commerce_inventory() WHERE ecommerce_id=re_ec;
 IF v<>13 THEN RAISE EXCEPTION 'Reishi 1oz candidates: %',v; END IF;
 SELECT available_quantity INTO v FROM public.mp_commerce_inventory() WHERE ecommerce_id=alias_ec;
 IF v<>0 THEN RAISE EXCEPTION 'Overlapping listing republished stock'; END IF;
 packet:=jsonb_build_object('schema_version',1,'provider','woocommerce','site_key','t058','external_order_id','1','event_id','first',
 'revision',1,'status','pending','currency','USD','total','10.00','refunds','[]'::jsonb,
 'lines',jsonb_build_array(jsonb_build_object('line_id','1','ecommerce_id',alias_ec,'erp_item_code','T058-CVG','quantity',2)));
 PERFORM public.mp_commerce_ingest(packet);
 IF public.mp_commerce_ingest(packet)<>'duplicate' THEN RAISE EXCEPTION 'Reservation retry'; END IF;
 SELECT available_quantity INTO v FROM public.mp_commerce_inventory() WHERE ecommerce_id=ec;
 IF v<>3 THEN RAISE EXCEPTION 'Alias reservation missed physical pool'; END IF;
 UPDATE public.ecommerce SET sync_enabled=false WHERE nocopk=alias_ec;
 SELECT available_quantity INTO v FROM public.mp_commerce_inventory() WHERE ecommerce_id=ec;
 IF v<>3 THEN RAISE EXCEPTION 'Disabled alias lost outstanding reservations'; END IF;
 UPDATE public.ecommerce SET sync_enabled=true WHERE nocopk=alias_ec;
 PERFORM public.mp_commerce_ingest(packet||'{"revision":2,"event_id":"cancel","status":"cancelled"}'::jsonb);
 SELECT available_quantity INTO v FROM public.mp_commerce_inventory() WHERE ecommerce_id=ec;
 IF v<>5 THEN RAISE EXCEPTION 'Cancellation did not release holds'; END IF;
 PERFORM public.mp_ecwid_inventory_initialize(ec,5);
 -- Native Ecwid checkout has already taken one from external quantity.
 INSERT INTO public.ecommerce_orders(ecwid_order_id,provider,site_key,status,payment_status,items_json)
 VALUES('T058-SALE','ecwid','t058','AWAITING_PROCESSING','AWAITING_PAYMENT',jsonb_build_array(jsonb_build_object('sku','T058-CVG','productId',900581,'quantity',1))::text) RETURNING nocopk INTO ord;
 SELECT available_quantity INTO v FROM public.mp_commerce_inventory() WHERE ecommerce_id=ec;
 IF v<>4 OR public.mp_ecwid_inventory_plan(ec)->>'status'<>'unchanged' THEN RAISE EXCEPTION 'Native checkout double-deducted or restored'; END IF;
 SELECT unit_id INTO lot FROM public.mp_inventory_units() WHERE pool_key=(SELECT pool_key FROM public.mp_inventory_specs() WHERE ecommerce_id=ec) AND eligible AND kind='lot' LIMIT 1;
 -- Existing MP package/assign/ship flow: one Product replaces one whole Lot.
 UPDATE public.lots SET status='Consumed' WHERE nocopk=lot;
 INSERT INTO public.products(item_id,net_weight_oz,net_weight_g,process_type_mat,storage_location_id,use_by)
 VALUES(cvg,80,2267.96,'Pasteurized',loc,CURRENT_DATE+90) RETURNING nocopk INTO prod;
 INSERT INTO public._m2m_products_lots_origin_lots(products_id,lots_id) VALUES(prod,lot);
 INSERT INTO public._m2m_products_ecommerce_orders_ecommerce_orders(products_id,ecommerce_orders_id) VALUES(prod,ord);
 SELECT available_quantity INTO v FROM public.mp_commerce_inventory() WHERE ecommerce_id=ec;
 IF v<>4 OR public.mp_inventory_legacy_hold(ec)<>1
 OR public.mp_ecwid_inventory_plan(ec)->>'status'<>'unchanged' THEN
  RAISE EXCEPTION 'Packing while awaiting cash changed availability or released the hold'; END IF;
 IF (SELECT desired_quantity FROM public.mp_ecommerce_catalog_inventory() WHERE ecommerce_id=ec)<>5 THEN
  RAISE EXCEPTION 'Packaging counted the origin Lot and Product twice'; END IF;
 UPDATE public.products SET storage_location_id=ship WHERE nocopk=prod;
 IF public.mp_ecwid_inventory_plan(ec)->>'status'<>'unchanged' THEN RAISE EXCEPTION 'MP dispatch deducted a native sale twice'; END IF;
 UPDATE public.ecommerce_orders SET status='SHIPPED' WHERE nocopk=ord;
 IF public.mp_ecwid_inventory_plan(ec)->>'status'<>'unchanged' THEN RAISE EXCEPTION 'Ecwid fulfillment status changed basis'; END IF;
 INSERT INTO public.lots(item_id,unit_size,recipe_id,status,qty,location_id,use_by) VALUES(cvg,5,recipe,'Pasteurized',1,loc,CURRENT_DATE+90);
 plan:=public.mp_ecwid_inventory_plan(ec);
 IF plan->>'status'<>'ready' OR (plan->>'quantityDelta')::bigint<>1 THEN RAISE EXCEPTION 'Replenishment delta: %',plan; END IF;
 IF public.mp_ecwid_inventory_plan(ec)->>'status'<>'review_unknown_outcome' THEN RAISE EXCEPTION 'Uncertain delta was replayed'; END IF;
 PERFORM public.mp_ecwid_inventory_resolve((plan->>'token')::uuid,'applied');
 IF public.mp_ecwid_inventory_plan(ec)->>'status'<>'unchanged' THEN RAISE EXCEPTION 'Acknowledged delta replayed'; END IF;
 UPDATE public.ecommerce_orders SET payment_status='REFUNDED' WHERE nocopk=ord;
 plan:=public.mp_ecwid_inventory_plan(ec);
 IF (plan->>'quantityDelta')::bigint<>-1 THEN RAISE EXCEPTION 'Refund restored physically shipped stock'; END IF;
 PERFORM public.mp_ecwid_inventory_resolve((plan->>'token')::uuid,'not_applied');
 plan:=public.mp_ecwid_inventory_plan(ec);
 IF (plan->>'quantityDelta')::bigint<>-1 THEN RAISE EXCEPTION 'Verified no-write recovery lost delta'; END IF;
 PERFORM public.mp_ecwid_inventory_resolve((plan->>'token')::uuid,'applied');
 -- A two-unit Ecwid order, one physical shipment, then cancel unshipped units.
 INSERT INTO public.ecommerce_orders(ecwid_order_id,provider,site_key,status,payment_status,items_json)
 VALUES('T058-PARTIAL','ecwid','t058','AWAITING_PROCESSING','PAID',jsonb_build_array(jsonb_build_object('sku','T058-CVG','quantity',2))::text) RETURNING nocopk INTO ord;
 SELECT available_quantity INTO v FROM public.mp_commerce_inventory() WHERE ecommerce_id=ec;
 IF v<>3 THEN RAISE EXCEPTION 'Two-unit native sale hold'; END IF;
 SELECT unit_id INTO lot FROM public.mp_inventory_units() WHERE pool_key=(SELECT pool_key FROM public.mp_inventory_specs() WHERE ecommerce_id=ec) AND eligible AND kind='lot' LIMIT 1;
 UPDATE public.lots SET status='Consumed' WHERE nocopk=lot;
 INSERT INTO public.products(item_id,net_weight_oz,net_weight_g,process_type_mat,storage_location_id,use_by)
 VALUES(cvg,80,2267.96,'Pasteurized',ship,CURRENT_DATE+90) RETURNING nocopk INTO prod;
 INSERT INTO public._m2m_products_lots_origin_lots(products_id,lots_id) VALUES(prod,lot);
 INSERT INTO public._m2m_products_ecommerce_orders_ecommerce_orders(products_id,ecommerce_orders_id) VALUES(prod,ord);
 SELECT available_quantity INTO v FROM public.mp_commerce_inventory() WHERE ecommerce_id=ec;
 IF v<>3 OR public.mp_ecwid_inventory_plan(ec)->>'status'<>'unchanged' THEN RAISE EXCEPTION 'Partial shipment deducted twice'; END IF;
 UPDATE public.ecommerce_orders SET payment_status='CANCELLED' WHERE nocopk=ord;
 SELECT available_quantity INTO v FROM public.mp_commerce_inventory() WHERE ecommerce_id=ec;
 plan:=public.mp_ecwid_inventory_plan(ec);
 IF v<>4 OR (plan->>'quantityDelta')::bigint<>-1 THEN RAISE EXCEPTION 'Partial cancellation restored shipped units'; END IF;
 token:=(plan->>'token')::uuid;
 PERFORM public.mp_ecwid_inventory_resolve(token,'applied');
 IF public.mp_ecwid_inventory_resolve(token,'applied')<>'duplicate' THEN RAISE EXCEPTION 'Receipt ack not idempotent'; END IF;
 -- A cash/direct MP sale has no Ecwid order and no native checkout deduction.
 SELECT unit_id INTO lot FROM public.mp_inventory_units() WHERE pool_key=(SELECT pool_key FROM public.mp_inventory_specs() WHERE ecommerce_id=ec) AND eligible AND kind='lot' LIMIT 1;
 UPDATE public.lots SET status='Consumed' WHERE nocopk=lot;
 INSERT INTO public.products(item_id,net_weight_oz,net_weight_g,process_type_mat,storage_location_id,use_by)
 VALUES(cvg,80,2267.96,'Pasteurized',loc,CURRENT_DATE+90) RETURNING nocopk INTO prod;
 INSERT INTO public._m2m_products_lots_origin_lots(products_id,lots_id) VALUES(prod,lot);
 IF public.mp_ecwid_inventory_plan(ec)->>'status'<>'unchanged' THEN
  RAISE EXCEPTION 'Cash-sale packing changed stock before dispatch'; END IF;
 UPDATE public.products SET storage_location_id=ship WHERE nocopk=prod;
 plan:=public.mp_ecwid_inventory_plan(ec);
 SELECT available_quantity INTO v FROM public.mp_commerce_inventory() WHERE ecommerce_id=ec;
 IF v<>3 OR (plan->>'quantityDelta')::bigint<>-1 THEN
  RAISE EXCEPTION 'Cash MP dispatch without Ecwid order failed to deduct once'; END IF;
 PERFORM public.mp_ecwid_inventory_resolve((plan->>'token')::uuid,'applied');
 IF public.mp_ecwid_inventory_plan(ec)->>'status'<>'unchanged' THEN
  RAISE EXCEPTION 'Cash-sale stock publication replayed'; END IF;
 RAISE NOTICE '058 synthetic review candidates 5/3/3/13; shared reservations, native sale, MP shipment, replenish, refund and unknown-outcome checks passed';
END $$;
ROLLBACK;
