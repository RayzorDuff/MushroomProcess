\set ON_ERROR_STOP on
BEGIN;
DO $$
DECLARE item_pk bigint; location_pk bigint; ecommerce_pk bigint; second_pk bigint;
 p jsonb; changed jsonb; evidence jsonb; outcome text; q bigint; count_before bigint;
BEGIN
 INSERT INTO public.items(item_id,name,category,active) VALUES('ITEM-COMMERCE-052','Ledger synthetic','fruiting_block',true) RETURNING nocopk INTO item_pk;
 INSERT INTO public.locations(name,active,type) VALUES('Ledger synthetic storage',true,'Storage') RETURNING nocopk INTO location_pk;
 INSERT INTO public.products(item_id,storage_location_id,use_by) VALUES(item_pk,location_pk,CURRENT_DATE+10),(item_pk,location_pk,CURRENT_DATE+10);
 INSERT INTO public.ecommerce(name,item_id,provider,site_key,external_sku,sync_enabled,erp_item_code,status)
 VALUES('Ledger mapping',item_pk,'woocommerce','synthetic','052',true,'ERP-052','Sterilized') RETURNING nocopk INTO ecommerce_pk;
 INSERT INTO public.ecommerce(name,item_id,provider,site_key,external_sku,sync_enabled,erp_item_code,status)
 VALUES('Parallel mapping',item_pk,'ecwid','synthetic','052-old',true,'ERP-052','Sterilized') RETURNING nocopk INTO second_pk;
 p=jsonb_build_object('schema_version',1,'provider','woocommerce','site_key','synthetic','external_order_id','100',
 'event_id','first','revision',1,'status','processing','currency','USD','total','10.00','refunds','[]'::jsonb,
 'payment_processor','clover','processor_payment_id','capture-052',
 'lines',jsonb_build_array(jsonb_build_object('line_id','1','ecommerce_id',ecommerce_pk,'erp_item_code','ERP-052','quantity',2)));
 changed=p||jsonb_build_object('status','cancelled','lines',jsonb_build_array(jsonb_build_object('line_id','1','ecommerce_id',ecommerce_pk,'erp_item_code','ERP-052','quantity',-1)));
 BEGIN PERFORM public.mp_commerce_ingest(changed); RAISE EXCEPTION 'Expected malformed terminal refusal';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM NOT LIKE 'Invalid operational line%' THEN RAISE; END IF; END;
 outcome=public.mp_commerce_ingest(p);
 IF outcome<>'applied' OR public.mp_commerce_ingest(p)<>'duplicate' THEN RAISE EXCEPTION 'Idempotency failure'; END IF;
 SELECT available_quantity INTO q FROM public.mp_commerce_inventory() WHERE ecommerce_id=second_pk;
 IF q<>0 THEN RAISE EXCEPTION 'Parallel-channel reservation leak'; END IF;
 changed=p||jsonb_build_object('external_order_id','101','event_id','oversell');
 BEGIN PERFORM public.mp_commerce_ingest(changed); RAISE EXCEPTION 'Expected insufficient inventory';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM NOT LIKE 'Insufficient sellable%' THEN RAISE; END IF; END;
 IF EXISTS(SELECT 1 FROM public.mp_commerce_orders WHERE external_order_id='101') THEN RAISE EXCEPTION 'Partial order persisted'; END IF;
 changed=p||jsonb_build_object('event_id','first','status','cancelled');
 BEGIN PERFORM public.mp_commerce_ingest(changed); RAISE EXCEPTION 'Expected identity rejection';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM NOT LIKE 'Event identity reused%' THEN RAISE; END IF; END;
 changed=p||jsonb_build_object('event_id','conflict','status','cancelled');
 BEGIN PERFORM public.mp_commerce_ingest(changed); RAISE EXCEPTION 'Expected revision rejection';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM NOT LIKE 'Same-revision conflict%' THEN RAISE; END IF; END;
 evidence=jsonb_build_object('provider','woocommerce','site_key','synthetic','external_order_id','100','processor','clover',
 'verification','verified_adapter','state','authorized','payment_id','capture-052','currency','USD','captured_amount','10.00','refunded_amount','0');
 BEGIN PERFORM public.mp_commerce_match_payment(evidence); RAISE EXCEPTION 'Expected authorization refusal';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM NOT LIKE 'Invalid verified%' THEN RAISE; END IF; END;
 evidence=evidence||'{"state":"captured"}'::jsonb;
 IF public.mp_commerce_match_payment(evidence)<>'matched' OR public.mp_commerce_match_payment(evidence)<>'matched' THEN RAISE EXCEPTION 'Payment retry failure'; END IF;
 changed=p||jsonb_build_object('event_id','cancel','revision',2,'status','cancelled');
 PERFORM public.mp_commerce_ingest(changed);
 IF public.mp_commerce_ingest(p||'{"event_id":"old"}'::jsonb)<>'stale' THEN RAISE EXCEPTION 'Stale event applied'; END IF;
 SELECT available_quantity INTO q FROM public.mp_commerce_inventory() WHERE ecommerce_id=ecommerce_pk;
 IF q<>2 THEN RAISE EXCEPTION 'Cancellation did not release'; END IF;
 changed=p||jsonb_build_object('external_order_id','101','event_id','payment-collision');
 PERFORM public.mp_commerce_ingest(changed);
 BEGIN PERFORM public.mp_commerce_match_payment(evidence||'{"external_order_id":"101"}'::jsonb); RAISE EXCEPTION 'Expected payment reuse refusal';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM NOT LIKE 'Payment already belongs%' THEN RAISE; END IF; END;
 PERFORM public.mp_commerce_ingest(changed||jsonb_build_object('status','cancelled','revision',2,'event_id','cancel-101'));
 -- A new order may reserve, but a Woo completed event must not move physical stock.
 p=p||jsonb_build_object('external_order_id','102','event_id','second','processor_payment_id','capture-102');
 PERFORM public.mp_commerce_ingest(p);
 PERFORM public.mp_commerce_ingest(p||jsonb_build_object('event_id','complete','revision',2,'status','completed'));
 IF (SELECT count(*) FROM public.products WHERE item_id=item_pk AND storage_location_id=location_pk)<>2 THEN RAISE EXCEPTION 'Lineage changed'; END IF;
 -- Operational fulfillment moves inventory first, then acknowledges its reference.
 UPDATE public.products SET use_by=CURRENT_DATE-1 WHERE item_id=item_pk;
 PERFORM public.mp_commerce_commit_fulfillment('woocommerce','synthetic','102','synthetic-movement-102');
 IF public.mp_commerce_commit_fulfillment('woocommerce','synthetic','102','synthetic-movement-102')<>'duplicate' THEN RAISE EXCEPTION 'Duplicate fulfillment'; END IF;
 PERFORM public.mp_commerce_ingest(p||jsonb_build_object('event_id','refund','revision',3,'status','refunded','refunds',
 jsonb_build_array(jsonb_build_object('external_refund_id','R1','amount','10.00'))));
 SELECT available_quantity INTO q FROM public.mp_commerce_inventory() WHERE ecommerce_id=ecommerce_pk;
 IF q<>0 THEN RAISE EXCEPTION 'Refund restocked shipped inventory'; END IF;
 IF (SELECT count(*) FROM public.mp_commerce_payment_matches WHERE external_order_id='100')<>1 THEN RAISE EXCEPTION 'Duplicate payment'; END IF;
END $$;
ROLLBACK;
