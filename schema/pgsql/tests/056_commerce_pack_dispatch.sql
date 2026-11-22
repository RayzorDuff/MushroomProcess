\set ON_ERROR_STOP on
BEGIN;
DO $$
DECLARE i bigint;loc bigint;shipped bigint;e bigint;product_a bigint;product_b bigint;
 p jsonb;ack jsonb;result text;q bigint;legacy_order bigint;
BEGIN
 INSERT INTO items(item_id,name,category,active) VALUES('BRIDGE-054','Synthetic bridge','grain',true) RETURNING nocopk INTO i;
 INSERT INTO locations(name,active,type) VALUES('Bridge storage',true,'Storage') RETURNING nocopk INTO loc;
 INSERT INTO locations(name,active,type) VALUES('Shipped',true,'Terminal') RETURNING nocopk INTO shipped;
 INSERT INTO products(item_id,storage_location_id,use_by) VALUES(i,loc,CURRENT_DATE+10) RETURNING nocopk INTO product_a;
 INSERT INTO products(item_id,storage_location_id,use_by) VALUES(i,loc,CURRENT_DATE+10) RETURNING nocopk INTO product_b;
 INSERT INTO ecommerce(name,item_id,provider,site_key,external_sku,erp_item_code,sync_enabled,status)
 VALUES('Bridge',i,'woocommerce','bridge-054','SYN-054','ERP-054',true,'Sterilized') RETURNING nocopk INTO e;
 p=jsonb_build_object('schema_version',1,'provider','woocommerce','site_key','bridge-054','external_order_id','54','event_id','new','revision',1,
 'status','processing','currency','USD','total','12','refunds','[]'::jsonb,'payment_processor','clover','processor_payment_id','capture-054',
 'lines',jsonb_build_array(jsonb_build_object('line_id','1','ecommerce_id',e,'erp_item_code','ERP-054','quantity',2)));
 PERFORM mp_commerce_ingest(p);
 BEGIN PERFORM mp_commerce_commit_fulfillment('woocommerce','bridge-054','54','unsafe'); RAISE EXCEPTION 'Expected proof refusal';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM NOT LIKE 'Use mp_commerce_acknowledge%' THEN RAISE; END IF; END;
 PERFORM mp_commerce_match_payment(jsonb_build_object('provider','woocommerce','site_key','bridge-054','external_order_id','54',
 'processor','clover','verification','verified_adapter','state','captured','payment_id','capture-054','currency','USD','captured_amount','12','refunded_amount','0'));
 PERFORM mp_commerce_link_erp('{"provider":"woocommerce","site_key":"bridge-054","external_order_id":"54","erp_site":"synthetic","sales_order":"SO-54","sales_invoice":"SI-54","payment_entry":"PE-54"}');
 PERFORM mp_commerce_confirm_reservation('woocommerce','bridge-054','54');

 UPDATE products SET product_id='PROD-CI-A' WHERE nocopk=product_a;
 UPDATE products SET product_id='PROD-CI-B' WHERE nocopk=product_b;
 ack=jsonb_build_object('provider','woocommerce','site_key','bridge-054','external_order_id','54',
    'reference','package-1','method','shipping','line_id','1','product_code','PROD-CI-A');
 IF mp_commerce_pick(ack)<>'picked' OR mp_commerce_pick(ack)<>'duplicate' THEN RAISE EXCEPTION 'Pick replay failed'; END IF;
 IF (SELECT storage_location_id FROM products WHERE nocopk=product_a)<>loc
    OR (SELECT sum(quantity) FROM mp_commerce_reservations WHERE site_key='bridge-054')<>2 THEN
   RAISE EXCEPTION 'Picking dispatched or released inventory'; END IF;
 BEGIN PERFORM mp_commerce_dispatch('woocommerce','bridge-054','package-1'); RAISE EXCEPTION 'Expected label refusal';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM NOT LIKE 'Shipping label%' THEN RAISE; END IF; END;
 PERFORM mp_commerce_package_tracking(jsonb_build_object('provider','woocommerce','site_key','bridge-054','external_order_id','54','reference','package-1',
   'tracking',jsonb_build_object('carrier','Synthetic','service','Synthetic','tracking_number','CI-1','label_status','purchased','postage','1.00','currency','USD')));
 IF (SELECT storage_location_id FROM products WHERE nocopk=product_a)<>loc THEN RAISE EXCEPTION 'Label purchase dispatched'; END IF;
 IF mp_commerce_dispatch('woocommerce','bridge-054','package-1')<>'partial' THEN RAISE EXCEPTION 'Expected partial'; END IF;
 IF mp_commerce_dispatch('woocommerce','bridge-054','package-1')<>'duplicate' THEN RAISE EXCEPTION 'Dispatch replay failed'; END IF;
 IF (SELECT available_quantity FROM mp_commerce_inventory() WHERE ecommerce_id=e)<>0 THEN RAISE EXCEPTION 'Product shipment reduced availability twice'; END IF;
 IF (SELECT count(*) FROM mp_commerce_shipment_delivery WHERE site_key='bridge-054')<>2 THEN RAISE EXCEPTION 'Independent destination deliveries missing'; END IF;
 UPDATE mp_commerce_shipment_delivery SET delivered_at=now() WHERE site_key='bridge-054';
 PERFORM mp_commerce_package_tracking(jsonb_build_object('provider','woocommerce','site_key','bridge-054','external_order_id','54','reference','package-1',
   'tracking',jsonb_build_object('carrier','Synthetic','service','Synthetic','tracking_number','CI-REPLACEMENT','label_status','replacement','postage','2.00','currency','USD')));
 IF (SELECT count(*) FROM mp_commerce_shipments WHERE site_key='bridge-054')<>1
 OR (SELECT count(*) FROM mp_commerce_shipment_delivery WHERE site_key='bridge-054' AND delivered_at IS NULL AND target='woo')<>1
 OR (SELECT count(*) FROM mp_commerce_shipment_delivery WHERE site_key='bridge-054' AND delivered_at IS NOT NULL AND target='erp')<>1 THEN
 RAISE EXCEPTION 'Tracking replacement replayed a physical movement or ERP delivery'; END IF;
 PERFORM mp_commerce_pick(ack||'{"reference":"package-2","method":"pickup","product_code":"PROD-CI-B"}'::jsonb);
 PERFORM mp_commerce_ingest(p||'{"event_id":"cancel","revision":2,"status":"cancelled"}'::jsonb);
 PERFORM mp_commerce_release_picks();
 IF (SELECT state FROM mp_commerce_packages WHERE reference='package-2')<>'cancelled'
    OR EXISTS(SELECT 1 FROM mp_commerce_picks WHERE reference='package-2') THEN
   RAISE EXCEPTION 'Cancelled packed products remain allocated'; END IF;
 IF (SELECT storage_location_id FROM products WHERE nocopk=product_b)<>loc THEN RAISE EXCEPTION 'Cancellation moved unshipped product'; END IF;
 IF (SELECT storage_location_id FROM products WHERE nocopk=product_a)<>shipped THEN RAISE EXCEPTION 'Cancellation reversed dispatch'; END IF;
 IF (SELECT available_quantity FROM mp_commerce_inventory() WHERE ecommerce_id=e)<>1 THEN RAISE EXCEPTION 'Cancellation did not release only unshipped availability'; END IF;
END $$;
ROLLBACK;
