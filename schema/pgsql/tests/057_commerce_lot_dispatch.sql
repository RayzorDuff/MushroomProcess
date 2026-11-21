\set ON_ERROR_STOP on
BEGIN;
DO $$
DECLARE i bigint;loc bigint;shipped bigint;e bigint;product_a bigint;product_b bigint;
 p jsonb;ack jsonb;result text;q bigint;legacy_order bigint; lot bigint;
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

 INSERT INTO lots(lot_id,item_id,location_id,status,use_by) VALUES('LOT-CI-057',i,loc,'Sterilized',CURRENT_DATE+10) RETURNING nocopk INTO lot;
 UPDATE products SET product_id='PROD-CI-057' WHERE nocopk=product_a;
 ack=jsonb_build_object('provider','woocommerce','site_key','bridge-054','external_order_id','54',
 'reference','lot-package','method','pickup','line_id','1','product_code','LOT-CI-057');
 IF mp_commerce_pick_lot(ack)<>'picked' OR mp_commerce_pick_lot(ack)<>'duplicate' THEN RAISE EXCEPTION 'Lot pick replay failed'; END IF;
 IF (SELECT status FROM lots WHERE nocopk=lot)<>'Sterilized' THEN RAISE EXCEPTION 'Picking moved Lot'; END IF;
 BEGIN UPDATE lots SET status='Consumed' WHERE nocopk=lot; RAISE EXCEPTION 'Expected allocation guard';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM NOT LIKE 'Packed Woo lot%' THEN RAISE; END IF; END;
 IF mp_commerce_dispatch('woocommerce','bridge-054','lot-package')<>'partial' THEN RAISE EXCEPTION 'Expected partial Lot shipment'; END IF;
 IF mp_commerce_dispatch('woocommerce','bridge-054','lot-package')<>'duplicate' THEN RAISE EXCEPTION 'Lot dispatch duplicated'; END IF;
 IF (SELECT status FROM lots WHERE nocopk=lot)<>'Shipped' OR (SELECT location_id FROM lots WHERE nocopk=lot)<>shipped THEN RAISE EXCEPTION 'Lot movement missing'; END IF;
 IF (SELECT available_quantity FROM mp_commerce_inventory() WHERE ecommerce_id=e)<>1 THEN RAISE EXCEPTION 'Lot shipment reduced availability twice'; END IF;
 PERFORM mp_commerce_ingest(p||'{"event_id":"after-lot","revision":2}'::jsonb);
 IF (SELECT sum(quantity) FROM mp_commerce_reservations WHERE site_key='bridge-054')<>1 THEN RAISE EXCEPTION 'Refresh reinstated shipped Lot'; END IF;
 PERFORM mp_commerce_pick(ack||'{"reference":"product-package","method":"local_delivery","product_code":"PROD-CI-057"}'::jsonb);
 IF mp_commerce_dispatch('woocommerce','bridge-054','product-package')<>'fulfilled' THEN RAISE EXCEPTION 'Combined Product/Lot order did not complete'; END IF;
 IF (SELECT count(*) FROM mp_commerce_shipped_units WHERE site_key='bridge-054')<>2 THEN RAISE EXCEPTION 'Missing physical unit references'; END IF;
 IF EXISTS(SELECT 1 FROM mp_commerce_reservations WHERE site_key='bridge-054') THEN RAISE EXCEPTION 'Full shipment retained hold'; END IF;
 IF (SELECT count(*) FROM mp_commerce_shipment_delivery WHERE site_key='bridge-054')<>4 THEN RAISE EXCEPTION 'Delivery targets lost'; END IF;
 PERFORM mp_commerce_ingest(p||'{"event_id":"cancel","revision":3,"status":"cancelled"}'::jsonb);
 IF (SELECT count(*) FROM mp_commerce_shipped_units WHERE site_key='bridge-054')<>2 THEN RAISE EXCEPTION 'Cancellation erased physical history'; END IF;
END $$;
ROLLBACK;
