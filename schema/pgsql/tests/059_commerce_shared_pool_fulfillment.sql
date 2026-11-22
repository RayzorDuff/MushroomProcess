\set ON_ERROR_STOP on
BEGIN;
DO $$
DECLARE cvg bigint;legacy bigint;alias_item bigint;hardwood bigint;hard_legacy bigint;
 dried bigint;dried_legacy bigint;chestnut bigint;reishi bigint;loc bigint;badloc bigint;ship bigint;
 recipe bigint;wrong_recipe bigint;ec bigint;alias_ec bigint;handoff uuid;hw_ec bigint;ch_ec bigint;re_ec bigint;
 lot bigint;prod bigint;ord bigint;v bigint;packet jsonb;plan jsonb;token uuid;
BEGIN
 INSERT INTO public.items(item_id,name,category,active) VALUES('T059-CVG','Synthetic CVG','substrate',true) RETURNING nocopk INTO cvg;
 INSERT INTO public.items(item_id,name,category) VALUES('T059-LEGACY','Synthetic legacy 5lb','substrate') RETURNING nocopk INTO legacy;
 INSERT INTO public.items(item_id,name,category) VALUES('T059-ALIAS','Synthetic alias 5lb','substrate') RETURNING nocopk INTO alias_item;
 INSERT INTO public.items(item_id,name,category,active) VALUES('T059-HW','Synthetic HW','substrate',true) RETURNING nocopk INTO hardwood;
 INSERT INTO public.items(item_id,name,category) VALUES('T059-HW-OLD','Synthetic HW 7.5lb','substrate') RETURNING nocopk INTO hard_legacy;
 INSERT INTO public.items(item_id,name,category,active) VALUES('T059-DRIED','Synthetic dried','freezedriedmushrooms',true) RETURNING nocopk INTO dried;
 INSERT INTO public.items(item_id,name,category) VALUES('T059-DRIED-OLD','Synthetic 1oz','freezedriedmushrooms') RETURNING nocopk INTO dried_legacy;
 INSERT INTO public.strains(strain_id,species_strain) VALUES('T059-CH','Synthetic Chestnut') RETURNING nocopk INTO chestnut;
 INSERT INTO public.strains(strain_id,species_strain) VALUES('T059-RE','Synthetic Reishi') RETURNING nocopk INTO reishi;
 INSERT INTO public.recipes(recipe_id,name) VALUES('T059-CVG-R','Synthetic CVG recipe') RETURNING nocopk INTO recipe;
 INSERT INTO public.recipes(recipe_id,name) VALUES('T059-HW-R','Synthetic 75/25') RETURNING nocopk INTO wrong_recipe;
 INSERT INTO public.mp_inventory_item_rules VALUES
 ('T059-LEGACY','T059-CVG','lb',5,ARRAY['T059-CVG-R']),
 ('T059-ALIAS','T059-CVG','lb',5,ARRAY['T059-CVG-R']),
 ('T059-HW-OLD','T059-HW','lb',7.5,ARRAY['T059-HW-R']),
 ('T059-DRIED-OLD','T059-DRIED','oz',1,ARRAY[]::text[]);
 INSERT INTO public.locations(name,active,type) VALUES('T058 New Lots',true,'Storage') RETURNING nocopk INTO loc;
 INSERT INTO public.locations(name,active,type) VALUES('Missing or Lost',true,'Exception') RETURNING nocopk INTO badloc;
 INSERT INTO public.locations(name,active,type) VALUES('Shipped',true,'Terminal') RETURNING nocopk INTO ship;
 INSERT INTO public.ecommerce(name,item_id,status,provider,site_key,external_sku,external_product_id,sync_enabled,erp_item_code)
 VALUES('Synthetic CVG',legacy,'Pasteurized','ecwid','t058','T059-CVG','900581',true,'T059-CVG') RETURNING nocopk INTO ec;
 INSERT INTO public.ecommerce(name,item_id,status,provider,site_key,external_sku,external_product_id,sync_enabled,erp_item_code)
 VALUES('Synthetic alias',alias_item,'Pasteurized','woocommerce','t058','T059-ALIAS','900582',true,'T059-CVG') RETURNING nocopk INTO alias_ec;
 INSERT INTO public.ecommerce(name,item_id,status,provider,site_key,external_sku,external_product_id,sync_enabled)
 VALUES('Synthetic hardwood',hard_legacy,'Sterilized','ecwid','t058','T059-HW','900583',true) RETURNING nocopk INTO hw_ec;
 INSERT INTO public.ecommerce(name,item_id,strain_id,provider,site_key,external_sku,external_product_id,sync_enabled)
 VALUES('Synthetic Chestnut',dried_legacy,chestnut,'ecwid','t058','T059-CH','900584',true) RETURNING nocopk INTO ch_ec;
 INSERT INTO public.ecommerce(name,item_id,strain_id,provider,site_key,external_sku,external_product_id,sync_enabled)
 VALUES('Synthetic Reishi',dried_legacy,reishi,'ecwid','t058','T059-RE','900585',true) RETURNING nocopk INTO re_ec;
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

 packet:=jsonb_build_object('schema_version',1,'provider','woocommerce','site_key','danks.store','external_order_id','pool-059','event_id','new',
 'revision',1,'status','processing','currency','USD','total','10','refunds','[]'::jsonb,'payment_processor','clover','processor_payment_id','cap-059',
 'lines',jsonb_build_array(jsonb_build_object('line_id','1','ecommerce_id',alias_ec,'erp_item_code','T059-CVG','quantity',2)));
 UPDATE public.ecommerce SET site_key='danks.store' WHERE nocopk=alias_ec;
 PERFORM public.mp_commerce_ingest(packet);
 PERFORM public.mp_commerce_match_payment(jsonb_build_object('provider','woocommerce','site_key','danks.store','external_order_id','pool-059',
 'processor','clover','verification','verified_adapter','state','captured','payment_id','cap-059','currency','USD','captured_amount','10','refunded_amount','0'));
 PERFORM public.mp_commerce_link_erp('{"provider":"woocommerce","site_key":"danks.store","external_order_id":"pool-059","erp_site":"synthetic","sales_order":"SO-059","sales_invoice":"SI-059","payment_entry":"PE-059"}');
 PERFORM public.mp_commerce_confirm_reservation('woocommerce','danks.store','pool-059');
 SELECT nocopk INTO lot FROM public.lots WHERE item_id=cvg AND unit_size=2.5 LIMIT 1;
 UPDATE public.lots SET lot_id='LOT-T059-WRONG' WHERE nocopk=lot;
 BEGIN
  PERFORM public.mp_commerce_pick_lot(jsonb_build_object('provider','woocommerce','site_key','danks.store','external_order_id','pool-059','reference','wrong-size','method','pickup','line_id','1','product_code','LOT-T059-WRONG'));
  RAISE EXCEPTION 'Expected wrong-size refusal';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM NOT LIKE 'Lot unavailable%' THEN RAISE; END IF; END;
 IF (SELECT location_id FROM public.lots WHERE nocopk=lot)<>loc THEN RAISE EXCEPTION 'Rejected lot moved'; END IF;
 SELECT unit_id INTO lot FROM public.mp_inventory_units() WHERE pool_key=(SELECT pool_key FROM public.mp_inventory_specs() WHERE ecommerce_id=alias_ec) AND kind='lot' AND eligible LIMIT 1;
 IF NOT public.mp_commerce_lot_eligible(lot,alias_ec) THEN RAISE EXCEPTION 'Canonical 5lb Lot rejected for legacy listing'; END IF;
 UPDATE public.lots SET lot_id='LOT-T059-GENERIC' WHERE nocopk=lot;
 plan:=jsonb_build_object('provider','woocommerce','site_key','danks.store','external_order_id','pool-059','reference','059-lot','method','pickup','line_id','1','product_code','LOT-T059-GENERIC');
 PERFORM public.mp_commerce_pick_lot(plan);
 IF public.mp_commerce_dispatch_request(plan)<>'partial' OR public.mp_commerce_dispatch_request(plan)<>'duplicate' THEN RAISE EXCEPTION 'Canonical partial Lot dispatch/replay'; END IF;
 SELECT unit_id INTO lot FROM public.mp_inventory_units() WHERE pool_key=(SELECT pool_key FROM public.mp_inventory_specs() WHERE ecommerce_id=alias_ec) AND kind='lot' AND eligible LIMIT 1;
 -- Package the next canonical whole Lot, preserving its recipe/size lineage.
 UPDATE public.lots SET status='Consumed' WHERE nocopk=lot;
 INSERT INTO public.products(product_id,item_id,net_weight_oz,net_weight_g,process_type_mat,storage_location_id,use_by)
 VALUES('PROD-T059-GENERIC',cvg,80,2267.96,'Pasteurized',loc,CURRENT_DATE+90) RETURNING nocopk INTO prod;
 INSERT INTO public._m2m_products_lots_origin_lots(products_id,lots_id) VALUES(prod,lot);
 IF NOT public.mp_commerce_product_eligible(prod,alias_ec) THEN RAISE EXCEPTION 'Canonical packaged Product rejected'; END IF;
 plan:=plan||'{"reference":"059-product","product_code":"PROD-T059-GENERIC"}'::jsonb;
 PERFORM public.mp_commerce_pick(plan);
 IF (SELECT storage_location_id FROM public.products WHERE nocopk=prod)<>loc THEN RAISE EXCEPTION 'Packing moved physical stock'; END IF;
 IF public.mp_commerce_dispatch_request(plan)<>'fulfilled' OR public.mp_commerce_dispatch_request(plan)<>'duplicate' THEN RAISE EXCEPTION 'Canonical final Product dispatch/replay'; END IF;
 IF (SELECT count(*) FROM public.mp_commerce_shipped_units WHERE external_order_id='pool-059')<>2 THEN RAISE EXCEPTION 'Duplicate physical movements'; END IF;
 -- An in-flight Ecwid write must block the ownership change.
 PERFORM public.mp_ecwid_inventory_initialize(ec,3);
 UPDATE public.mp_ecwid_inventory_publications SET pending_token=gen_random_uuid() WHERE ecommerce_id=ec;
 BEGIN
  PERFORM public.mp_commerce_select_woo_inventory_owner(alias_ec,ec);
  RAISE EXCEPTION 'Expected pending write refusal';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM NOT LIKE 'Resolve pending Ecwid%' THEN RAISE; END IF; END;
 UPDATE public.mp_ecwid_inventory_publications SET pending_token=NULL WHERE ecommerce_id=ec;
 -- Explicit owner handoff changes publication, preserving identities/holds.
 handoff:=public.mp_commerce_select_woo_inventory_owner(alias_ec,ec);
 SELECT available_quantity INTO v FROM public.mp_commerce_inventory() WHERE ecommerce_id=alias_ec;
 IF v<>3 OR (SELECT available_quantity FROM public.mp_commerce_inventory() WHERE ecommerce_id=ec)<>0 THEN RAISE EXCEPTION 'Owner handoff lost or duplicated stock'; END IF;
 IF (SELECT external_product_id FROM public.ecommerce WHERE nocopk=ec)<>'900581' THEN RAISE EXCEPTION 'Owner handoff rewrote Ecwid identity'; END IF;
 IF public.mp_commerce_restore_inventory_owner(handoff)<>'restored' OR public.mp_commerce_restore_inventory_owner(handoff)<>'duplicate' THEN RAISE EXCEPTION 'Owner rollback/retry'; END IF;
 IF (SELECT available_quantity FROM public.mp_commerce_inventory() WHERE ecommerce_id=ec)<>3 THEN RAISE EXCEPTION 'Owner rollback lost remaining stock'; END IF;
 RAISE NOTICE '059 canonical Product/Lot partial dispatch, replay, owner handoff and rollback passed';
END $$;
ROLLBACK;
