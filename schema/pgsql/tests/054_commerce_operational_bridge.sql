\set ON_ERROR_STOP on
BEGIN;
DO $$
DECLARE i bigint;loc bigint;shipped bigint;e bigint;product_a bigint;product_b bigint;
 p jsonb;ack jsonb;result text;q bigint;
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
 ack=jsonb_build_array(jsonb_build_object('line_id','1','product_ids',jsonb_build_array(product_a)));
 BEGIN PERFORM mp_commerce_acknowledge_products('woocommerce','bridge-054','54','move-54',ack); RAISE EXCEPTION 'Expected physical movement refusal';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM NOT LIKE 'Product must be physically%' THEN RAISE; END IF; END;
 UPDATE products SET storage_location_id=shipped WHERE nocopk=product_a;
 IF mp_commerce_acknowledge_products('woocommerce','bridge-054','54','move-54',ack)<>'partial' THEN RAISE EXCEPTION 'Expected partial'; END IF;
 IF mp_commerce_acknowledge_products('woocommerce','bridge-054','54','move-54',ack)<>'duplicate' THEN RAISE EXCEPTION 'Expected duplicate'; END IF;
 PERFORM mp_commerce_ingest(p||'{"event_id":"refresh","revision":2}'::jsonb);
 SELECT sum(quantity) INTO q FROM mp_commerce_reservations WHERE site_key='bridge-054';
 IF q<>1 THEN RAISE EXCEPTION 'Refresh reinstated shipped quantity'; END IF;
 PERFORM mp_commerce_ingest(p||'{"event_id":"cancel","revision":3,"status":"cancelled"}'::jsonb);
 IF EXISTS(SELECT 1 FROM mp_commerce_reservations WHERE site_key='bridge-054') THEN RAISE EXCEPTION 'Cancellation retained unshipped hold'; END IF;
 IF (SELECT storage_location_id FROM products WHERE nocopk=product_a)<>shipped OR (SELECT storage_location_id FROM products WHERE nocopk=product_b)<>loc THEN RAISE EXCEPTION 'Cancel altered physical stock'; END IF;
 IF (SELECT count(*) FROM mp_commerce_shipped_products WHERE site_key='bridge-054')<>1 THEN RAISE EXCEPTION 'Shipment history lost'; END IF;
END $$;
ROLLBACK;
