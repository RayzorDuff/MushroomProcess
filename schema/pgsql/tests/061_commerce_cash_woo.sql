\set ON_ERROR_STOP on
BEGIN;
SELECT public.mp_commerce_prepare_cash_packing();
DO $$
DECLARE item bigint;loc bigint;ship bigint;ec bigint;pid bigint;p jsonb;cash uuid;r jsonb;ref jsonb;
BEGIN
 INSERT INTO items(item_id,name,category,active) VALUES('T061-WOO','Synthetic cash Woo','grain',true) RETURNING nocopk INTO item;
 INSERT INTO locations(name,active,type) VALUES('T061 Woo Products',true,'Storage') RETURNING nocopk INTO loc;
 SELECT nocopk INTO ship FROM locations WHERE active AND lower(name)='shipped' LIMIT 1;
 IF ship IS NULL THEN INSERT INTO locations(name,active,type) VALUES('Shipped',true,'Terminal') RETURNING nocopk INTO ship; END IF;
 INSERT INTO ecommerce(name,item_id,status,provider,site_key,external_sku,external_product_id,sync_enabled,erp_item_code)
 VALUES('T061 Woo',item,'Sterilized','woocommerce','danks.store','T061-WOO','900611',true,'ERP-T061') RETURNING nocopk INTO ec;
 INSERT INTO products(product_id,item_id,storage_location_id,use_by) VALUES('T061-WOO-P',item,loc,CURRENT_DATE+5) RETURNING nocopk INTO pid;
 INSERT INTO products(product_id,item_id,storage_location_id,use_by) VALUES('T061-WOO-P2',item,loc,CURRENT_DATE+5);
 p:=jsonb_build_object('schema_version',1,'provider','woocommerce','site_key','danks.store','external_order_id','611','event_id','t061-new','revision',1,'status','on-hold',
 'currency','USD','total','20.00','refunds','[]'::jsonb,'payment_processor','cash','processor_payment_id',null,
 'lines',jsonb_build_array(jsonb_build_object('line_id','1','ecommerce_id',ec,'erp_item_code','ERP-T061','quantity',2)));
 PERFORM mp_commerce_ingest(p);
 IF mp_commerce_pick('{"provider":"woocommerce","site_key":"danks.store","external_order_id":"611","reference":"t061-pkg","method":"pickup","line_id":"1","product_code":"T061-WOO-P"}')<>'picked' THEN RAISE EXCEPTION 'Cash order could not pack before payment'; END IF;
 IF (SELECT storage_location_id FROM products WHERE nocopk=pid)<>loc THEN RAISE EXCEPTION 'Cash packing moved physical stock'; END IF;
 BEGIN
  PERFORM mp_commerce_dispatch('woocommerce','danks.store','t061-pkg');RAISE EXCEPTION 'BAD cash dispatched without receipt/accounting';
 EXCEPTION WHEN others THEN IF SQLERRM LIKE 'BAD %' THEN RAISE; END IF; END;
 r:=mp_commerce_record_cash('{"provider":"woocommerce","site_key":"danks.store","external_order_id":"611","operator":"synthetic@example.invalid","amount":"20.00","currency":"USD","cash_received":true}');
 cash:=(r->>'receipt_id')::uuid;
 ref:='{"erp_site":"erp-test.danks.store","sales_order":"SO-T061W","sales_invoice":"SI-T061W","payment_entry":"PE-T061W"}';
 PERFORM mp_commerce_ack_cash(cash,ref);
 BEGIN
  PERFORM mp_commerce_confirm_cash(cash);RAISE EXCEPTION 'BAD cash confirmed before native paid Woo snapshot';
 EXCEPTION WHEN others THEN IF SQLERRM LIKE 'BAD %' THEN RAISE; END IF; END;
 PERFORM mp_commerce_ingest(p||'{"event_id":"t061-paid","revision":2,"status":"processing"}');
 IF mp_commerce_confirm_cash(cash)<>'confirmed' THEN RAISE EXCEPTION 'Cash order confirmation'; END IF;
 PERFORM mp_commerce_dispatch('woocommerce','danks.store','t061-pkg');
 IF (SELECT storage_location_id FROM products WHERE nocopk=pid)<>ship THEN RAISE EXCEPTION 'Cash dispatch did not move product'; END IF;
 IF (SELECT count(*) FROM mp_commerce_shipped_products WHERE product_id=pid)<>1 THEN RAISE EXCEPTION 'Cash duplicate shipment'; END IF;
 PERFORM mp_commerce_dispatch('woocommerce','danks.store','t061-pkg');
 PERFORM mp_commerce_ingest(p||'{"event_id":"t061-cancel","revision":3,"status":"cancelled"}');
 IF EXISTS(SELECT 1 FROM mp_commerce_reservations WHERE external_order_id='611') THEN RAISE EXCEPTION 'Cash cancellation left unshipped holds'; END IF;
 RAISE NOTICE 'Cash Woo: unpaid packing, separate receipt/accounting, paid snapshot, partial dispatch, retry and cancellation passed';
END $$;
ROLLBACK;
