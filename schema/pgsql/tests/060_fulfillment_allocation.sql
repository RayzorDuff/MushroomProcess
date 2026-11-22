\set ON_ERROR_STOP on
BEGIN;
DO $$
DECLARE item bigint;loc bigint;ship bigint;ec bigint;ord bigint;other bigint;pid bigint;stale bigint;wrong bigint;packet jsonb;before_stock bigint;actual bigint;
BEGIN
 INSERT INTO items(item_id,name,category,active) VALUES('T060-ITEM','Synthetic fulfill','grain',true) RETURNING nocopk INTO item;
 INSERT INTO locations(name,active,type) VALUES('T060 Products',true,'Storage') RETURNING nocopk INTO loc;
 -- A clean CI database may already have the one Shipped location from lookup seeds.
 SELECT nocopk INTO ship FROM locations WHERE active AND lower(name)='shipped' LIMIT 1;
 IF ship IS NULL THEN INSERT INTO locations(name,active,type) VALUES('Shipped',true,'Terminal') RETURNING nocopk INTO ship; END IF;
 INSERT INTO ecommerce(name,item_id,status,provider,site_key,external_sku,external_product_id,sync_enabled)
 VALUES('T060 listing',item,'Sterilized','ecwid','t060','T060-SKU','900600',true) RETURNING nocopk INTO ec;
 INSERT INTO products(product_id,item_id,storage_location_id,use_by)
 SELECT 'T060-'||i,item,loc,CURRENT_DATE+5 FROM generate_series(1,53) i;
 INSERT INTO products(product_id,item_id,storage_location_id,use_by) VALUES('T060-SHIPPED',item,ship,CURRENT_DATE+5);
 INSERT INTO products(product_id,item_id,storage_location_id,use_by) VALUES('T060-EXPIRED',item,loc,CURRENT_DATE-1);
 INSERT INTO ecommerce_orders(ecwid_order_id,provider,site_key,status,payment_method,payment_status,items_json)
 VALUES('T060-ORDER','ecwid','t060','AWAITING_PROCESSING','Cash','AWAITING_PAYMENT','[{"id":1,"sku":"T060-SKU","quantity":2}]') RETURNING nocopk INTO ord;
 INSERT INTO ecommerce_orders(ecwid_order_id,provider,site_key,status,payment_method,payment_status,items_json)
 VALUES('T060-OTHER','ecwid','t060','AWAITING_PROCESSING','Cash','AWAITING_PAYMENT','[{"id":1,"sku":"T060-SKU","quantity":2}]') RETURNING nocopk INTO other;
 packet:=mp_fulfillment_search(ord::text,'',1,10);
 IF (packet->>'count')::bigint<>53 OR jsonb_array_length(packet->'products')<>10 OR NOT (packet->>'has_next')::boolean THEN RAISE EXCEPTION 'Empty search pagination failed: %',packet; END IF;
 packet:=mp_fulfillment_search(ord::text,'',6,10);
 IF jsonb_array_length(packet->'products')<>3 OR (packet->>'has_next')::boolean THEN RAISE EXCEPTION 'Last page incorrect'; END IF;
 SELECT nocopk INTO pid FROM products WHERE product_id='T060-1';
 SELECT nocopk INTO stale FROM products WHERE product_id='T060-2';
 SELECT desired_quantity INTO before_stock FROM mp_ecommerce_catalog_inventory() WHERE ecommerce_id=ec;
 packet:=mp_fulfillment_assign(ord::text,pid::text,'synthetic@example.invalid','1');
 IF packet->>'status'<>'assigned' OR (SELECT storage_location_id FROM products WHERE nocopk=pid)<>loc THEN RAISE EXCEPTION 'Assign moved stock'; END IF;
 IF mp_fulfillment_assign(ord::text,pid::text,'synthetic@example.invalid','1')->>'status'<>'duplicate' THEN RAISE EXCEPTION 'Assignment replay'; END IF;
 IF mp_fulfillment_search(other::text,'T060-1')->>'count'<>'10' THEN -- remaining matching T060-10..19 only
  RAISE EXCEPTION 'Assigned product leaked or substring search broken'; END IF;
 BEGIN
  PERFORM mp_fulfillment_assign(other::text,pid::text,'synthetic@example.invalid','1');RAISE EXCEPTION 'BAD accepted assigned product';
 EXCEPTION WHEN others THEN IF SQLERRM LIKE 'BAD %' THEN RAISE; END IF; END;
 SELECT nocopk INTO wrong FROM products WHERE product_id='T060-SHIPPED';
 BEGIN
  PERFORM mp_fulfillment_assign(ord::text,wrong::text,'synthetic@example.invalid','1');RAISE EXCEPTION 'BAD accepted shipped product';
 EXCEPTION WHEN others THEN IF SQLERRM LIKE 'BAD %' THEN RAISE; END IF; END;
 UPDATE products SET storage_location_id=ship WHERE nocopk=stale;
 BEGIN
  PERFORM mp_fulfillment_assign(ord::text,stale::text,'synthetic@example.invalid','1');RAISE EXCEPTION 'BAD stale search allowed assignment';
 EXCEPTION WHEN others THEN IF SQLERRM LIKE 'BAD %' THEN RAISE; END IF; END;
 IF (mp_fulfillment_progress(ord)->>'product_assignment_complete')::boolean THEN RAISE EXCEPTION 'Partial assignment reported complete'; END IF;
 packet:=mp_fulfillment_dispatch(ord::text,'T060-dispatch-one','synthetic@example.invalid');
 IF packet->>'status'<>'dispatched' OR (packet->'progress'->>'dispatch_complete')::boolean THEN RAISE EXCEPTION 'Partial dispatch reported complete'; END IF;
 IF mp_fulfillment_dispatch(ord::text,'T060-dispatch-one','synthetic@example.invalid')->>'status'<>'duplicate' THEN RAISE EXCEPTION 'Dispatch replay'; END IF;
 SELECT count(*) INTO actual FROM events WHERE product_id=pid AND type='fulfillment_dispatch';
 IF actual<>1 THEN RAISE EXCEPTION 'Duplicate physical event'; END IF;
 SELECT nocopk INTO pid FROM products WHERE product_id='T060-3';
 PERFORM mp_fulfillment_assign(ord::text,pid::text,'synthetic@example.invalid','1');
 IF NOT (mp_fulfillment_progress(ord)->>'product_assignment_complete')::boolean THEN RAISE EXCEPTION 'Full assignment not recognized'; END IF;
 UPDATE ecommerce_orders SET status='WILL_NOT_DELIVER' WHERE nocopk=ord;
 IF NOT mp_fulfillment_product_eligible(pid) THEN RAISE EXCEPTION 'Cancellation did not release unshipped unit'; END IF;
 IF (SELECT count(*) FROM mp_fulfillment_allocations WHERE order_id=ord AND dispatched_at IS NOT NULL)<>1 THEN RAISE EXCEPTION 'Cancellation erased shipment'; END IF;
 PERFORM mp_fulfillment_assign(other::text,pid::text,'synthetic@example.invalid','1');
 SELECT nocopk INTO pid FROM products WHERE product_id='T060-4';
 PERFORM mp_fulfillment_assign(other::text,pid::text,'synthetic@example.invalid','1');
 packet:=mp_fulfillment_dispatch(other::text,'T060-dispatch-two','synthetic@example.invalid');
 IF NOT (packet->'progress'->>'dispatch_complete')::boolean THEN RAISE EXCEPTION 'Complete dispatch not recognized'; END IF;
 RAISE NOTICE '060: paginated eligible search, stale/bypass refusal, preserved allocation, partial/replayed dispatch and cancellation passed';
END $$;
ROLLBACK;
