\set ON_ERROR_STOP on
BEGIN;
DO $$
DECLARE oid bigint;packet jsonb;result jsonb;receipt uuid;refs jsonb;
BEGIN
 INSERT INTO ecommerce_orders(provider,site_key,external_order_id,status,payment_method,payment_status,order_total,subtotal,tax_total,currency,items_json)
 VALUES('ecwid','t061','1','DELIVERED','Cash','AWAITING_PAYMENT',12,12,0,'USD','[{"id":1,"sku":"T061","quantity":1}]') RETURNING nocopk INTO oid;
 packet:=jsonb_build_object('order_record_id',oid::text,'cash_received',true,'operator','synthetic@example.invalid','amount','12.00','currency','USD');
 BEGIN
  PERFORM mp_commerce_record_cash(packet||'{"cash_received":false}'::jsonb);RAISE EXCEPTION 'BAD implicit payment accepted';
 EXCEPTION WHEN others THEN IF SQLERRM LIKE 'BAD %' THEN RAISE; END IF; END;
 BEGIN
  PERFORM mp_commerce_record_cash(packet||'{"amount":"11.00"}'::jsonb);RAISE EXCEPTION 'BAD amount mismatch accepted';
 EXCEPTION WHEN others THEN IF SQLERRM LIKE 'BAD %' THEN RAISE; END IF; END;
 result:=mp_commerce_record_cash(packet);receipt:=(result->>'receipt_id')::uuid;
 IF result->>'status'<>'cash_received' OR NOT (result->>'erp_pending')::boolean THEN RAISE EXCEPTION 'Cash receipt state'; END IF;
 IF mp_commerce_record_cash(packet)->>'status'<>'duplicate' THEN RAISE EXCEPTION 'Cash receipt replay'; END IF;
 IF (SELECT status FROM ecommerce_orders WHERE nocopk=oid)<>'DELIVERED' OR (SELECT payment_status FROM ecommerce_orders WHERE nocopk=oid)<>'PAID' THEN RAISE EXCEPTION 'Cash changed fulfillment or failed payment status'; END IF;
 refs:='{"erp_site":"erp-test.danks.store","sales_order":"SO-T061","sales_invoice":"SI-T061","payment_entry":"PE-T061"}';
 IF mp_commerce_ack_cash(receipt,refs)<>'acknowledged' OR mp_commerce_ack_cash(receipt,refs)<>'duplicate' THEN RAISE EXCEPTION 'ERP cash ack replay'; END IF;
 BEGIN
  PERFORM mp_commerce_ack_cash(receipt,refs||'{"payment_entry":"OTHER"}');RAISE EXCEPTION 'BAD ERP identity drift accepted';
 EXCEPTION WHEN others THEN IF SQLERRM LIKE 'BAD %' THEN RAISE; END IF; END;
 UPDATE ecommerce_orders SET order_total=13 WHERE nocopk=oid;
 BEGIN
  PERFORM mp_commerce_record_cash(packet||'{"amount":"13.00"}');RAISE EXCEPTION 'BAD altered sale accepted';
 EXCEPTION WHEN others THEN IF SQLERRM LIKE 'BAD %' THEN RAISE; END IF; END;
 UPDATE ecommerce_orders SET order_total=12,payment_status='REFUNDED' WHERE nocopk=oid;
 BEGIN
  PERFORM mp_commerce_record_cash(packet);RAISE EXCEPTION 'BAD refunded sale accepted';
 EXCEPTION WHEN others THEN IF SQLERRM LIKE 'BAD %' THEN RAISE; END IF; END;
 RAISE NOTICE '061 cash: explicit receipt after delivered sale, exact money, replay, ERP ack and drift refusal passed';
END $$;
ROLLBACK;
