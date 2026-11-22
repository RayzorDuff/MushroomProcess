-- Cash is operator-confirmed tender, never a Clover capture or dispatch signal.
BEGIN;
SELECT pg_advisory_xact_lock(520052);
CREATE TABLE IF NOT EXISTS public.mp_commerce_cash_receipts (
 receipt_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 provider text NOT NULL,site_key text NOT NULL,external_order_id text NOT NULL,
 amount numeric(18,2) NOT NULL CHECK(amount>0),currency text NOT NULL CHECK(currency ~ '^[A-Z]{3}$'),
 received_at timestamptz NOT NULL,operator text NOT NULL,snapshot jsonb NOT NULL,
 erp_references jsonb,erp_acknowledged_at timestamptz,
 UNIQUE(provider,site_key,external_order_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS mp_cash_erp_payment_identity ON public.mp_commerce_cash_receipts ((erp_references->>'erp_site'),(erp_references->>'payment_entry')) WHERE erp_references IS NOT NULL;
CREATE OR REPLACE FUNCTION public.mp_commerce_record_cash(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE o public.ecommerce_orders%ROWTYPE;commerce record;prior public.mp_commerce_cash_receipts%ROWTYPE;
 provider_key text;site text;order_key text;method text;total numeric;currency_code text;details jsonb;at_time timestamptz;actor text;
BEGIN
 PERFORM pg_advisory_xact_lock(520052);
 actor:=nullif(trim(p->>'operator'),'');
 IF p->'cash_received' IS DISTINCT FROM 'true'::jsonb OR actor IS NULL OR actor='system'
 OR coalesce(p->>'amount','') !~ '^[0-9]+(\.[0-9]{1,2})?$' THEN RAISE EXCEPTION 'Confirm actual cash receipt, exact amount and named operator'; END IF;
 IF nullif(p->>'order_record_id','') IS NOT NULL THEN
  SELECT * INTO STRICT o FROM public.ecommerce_orders WHERE coalesce(airtable_id,nocopk::text)=p->>'order_record_id' OR nocopk::text=p->>'order_record_id' FOR UPDATE;
  provider_key:=coalesce(nullif(o.provider,''),'ecwid');site:=coalesce(nullif(o.site_key,''),'dank_mushrooms');order_key:=coalesce(nullif(o.external_order_id,''),o.ecwid_order_id);
  IF provider_key='woocommerce' THEN RAISE EXCEPTION 'Use Woo ledger identity for cash receipt'; END IF;
  method:=lower(trim(o.payment_method));total:=o.order_total;currency_code:=o.currency;
  IF nullif(o.processor_payment_id,'') IS NOT NULL OR nullif(o.clover_payment_id,'') IS NOT NULL OR coalesce(o.clover_payment_amount,0)>0 OR o.clover_payment_time IS NOT NULL THEN RAISE EXCEPTION 'Existing processor evidence requires review before recording cash'; END IF;
  IF upper(coalesce(o.status,'')) IN('WILL_NOT_DELIVER','RETURNED','CANCELLED') OR upper(coalesce(o.payment_status,'')) IN('REFUNDED','CANCELLED','CANCELED','FAILED') THEN RAISE EXCEPTION 'Cancelled/refunded cash sale requires review'; END IF;
  details:=jsonb_build_object('items',coalesce(nullif(o.items_json,''),'[]')::jsonb,'subtotal',o.subtotal,'tax',o.tax_total,'total',o.order_total,'currency',o.currency);
 ELSE
  provider_key:=p->>'provider';site:=p->>'site_key';order_key:=p->>'external_order_id';
  IF provider_key IS DISTINCT FROM 'woocommerce' THEN RAISE EXCEPTION 'Exact Woo source identity required'; END IF;
  SELECT * INTO STRICT commerce FROM public.mp_commerce_orders WHERE provider=provider_key AND site_key=site AND external_order_id=order_key FOR UPDATE;
  IF commerce.snapshot->>'payment_processor' IS DISTINCT FROM 'cash' OR commerce.status NOT IN('pending','on-hold','processing','completed') OR jsonb_array_length(commerce.snapshot->'refunds')<>0 THEN RAISE EXCEPTION 'Active unrefunded cash order required'; END IF;
  method:='cash';total:=(commerce.snapshot->>'total')::numeric;currency_code:=commerce.snapshot->>'currency';
  details:=jsonb_build_object('lines',commerce.snapshot->'lines','commercial',commerce.snapshot->'commercial',
   'external_customer_id',commerce.snapshot->'external_customer_id','total',total,'currency',currency_code);
 END IF;
 IF method IS NULL OR method NOT IN('cash','pay by cash','pay with cash','cash on delivery','cod','sell on the go - cash') THEN RAISE EXCEPTION 'Payment method is not a reviewed cash tender'; END IF;
 IF total IS NULL OR total<=0 OR total<>(p->>'amount')::numeric OR currency_code IS DISTINCT FROM p->>'currency'
 OR nullif(order_key,'') IS NULL THEN RAISE EXCEPTION 'Exact positive order amount, currency and stable source ID required'; END IF;
 SELECT * INTO prior FROM public.mp_commerce_cash_receipts WHERE provider=provider_key AND site_key=site AND external_order_id=order_key;
 IF FOUND THEN
  IF prior.amount<>total OR prior.currency<>currency_code OR prior.snapshot IS DISTINCT FROM details THEN RAISE EXCEPTION 'Cash sale changed after receipt: accounting review required'; END IF;
  RETURN jsonb_build_object('ok',true,'status','duplicate','receipt_id',prior.receipt_id,'erp_pending',prior.erp_references IS NULL);
 END IF;
 at_time:=coalesce(nullif(p->>'received_at','')::timestamptz,now());
 IF at_time>now()+interval '5 minutes' THEN RAISE EXCEPTION 'Cash receipt time is in the future'; END IF;
 INSERT INTO public.mp_commerce_cash_receipts(provider,site_key,external_order_id,amount,currency,received_at,operator,snapshot)
 VALUES(provider_key,site,order_key,total,currency_code,at_time,actor,details) RETURNING * INTO prior;
 -- Legacy status aliases are not processor proof or ERP completion.
 IF o.nocopk IS NOT NULL THEN
  UPDATE public.ecommerce_orders SET payment_status='PAID',payment_processor='cash',processor_payment_id=NULL,
   clover_reconciliation_status=NULL,clover_payment_id=NULL,clover_payment_amount=NULL,clover_payment_time=NULL,clover_match_confidence=NULL,processor_match_confidence=NULL,
   processor_payment_status='received',processor_payment_amount=total,processor_payment_time=at_time,
   payment_reconciliation_status='cash_received_erp_pending',nc_updated_at=now() WHERE nocopk=o.nocopk;
 END IF;
 RETURN jsonb_build_object('ok',true,'status','cash_received','receipt_id',prior.receipt_id,'erp_pending',true);
END $$;
CREATE OR REPLACE FUNCTION public.mp_commerce_ack_cash(p_receipt uuid,p_references jsonb) RETURNS text LANGUAGE plpgsql AS $$
DECLARE r public.mp_commerce_cash_receipts%ROWTYPE;
BEGIN
 PERFORM pg_advisory_xact_lock(520052);
 SELECT * INTO STRICT r FROM public.mp_commerce_cash_receipts WHERE receipt_id=p_receipt FOR UPDATE;
 IF coalesce(p_references->>'sales_order','')='' OR coalesce(p_references->>'sales_invoice','')='' OR coalesce(p_references->>'payment_entry','')='' THEN RAISE EXCEPTION 'ERP sale, invoice and cash receipt references required'; END IF;
 IF r.erp_references IS NOT NULL THEN
  IF r.erp_references IS DISTINCT FROM p_references THEN RAISE EXCEPTION 'ERP cash reference drift'; END IF;
  RETURN 'duplicate';
 END IF;
 UPDATE public.mp_commerce_cash_receipts SET erp_references=p_references,erp_acknowledged_at=now() WHERE receipt_id=p_receipt;
 UPDATE public.ecommerce_orders SET payment_reconciliation_status='accounted',nc_updated_at=now()
 WHERE coalesce(nullif(provider,''),'ecwid')=r.provider AND coalesce(nullif(site_key,''),'dank_mushrooms')=r.site_key
 AND coalesce(nullif(external_order_id,''),ecwid_order_id)=r.external_order_id;
 RETURN 'acknowledged';
END $$;
-- Invoked only after 054-059 are actually installed. Installing 061 alone does
-- not replace a Woo function or activate any worker.
CREATE TABLE IF NOT EXISTS public.mp_commerce_cash_woo_backup(name text PRIMARY KEY,definition text NOT NULL,applied_definition text);
ALTER TABLE public.mp_commerce_cash_woo_backup ALTER COLUMN applied_definition DROP NOT NULL;
CREATE OR REPLACE FUNCTION public.mp_commerce_prepare_cash_packing() RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_name text;original text;changed text;prior record;
BEGIN
 PERFORM pg_advisory_xact_lock(520052);
 IF to_regprocedure('public.mp_commerce_product_eligible(bigint,bigint)') IS NULL THEN RAISE EXCEPTION 'Apply reviewed Woo shared-pool 059 first'; END IF;
 FOREACH v_name IN ARRAY ARRAY['public.mp_commerce_pick(jsonb)','public.mp_commerce_pick_lot(jsonb)'] LOOP
  SELECT pg_get_functiondef(v_name::regprocedure) INTO original;
  SELECT * INTO prior FROM public.mp_commerce_cash_woo_backup b WHERE b.name=v_name;
  IF FOUND AND prior.applied_definition IS NOT NULL THEN
   IF original<>prior.applied_definition THEN RAISE EXCEPTION 'Later Woo packing change requires review'; END IF;
   CONTINUE;
  END IF;
  IF FOUND AND prior.applied_definition IS NULL AND original<>prior.definition THEN RAISE EXCEPTION 'Later Woo packing change requires review'; END IF;
  changed:=replace(original, 'IF NOT o.reservation_confirmed OR o.status NOT IN (''processing'',''completed'')',
   'IF NOT ((o.reservation_confirmed AND o.status IN (''processing'',''completed'')) OR (o.snapshot->>''payment_processor''=''cash'' AND o.status IN (''pending'',''on-hold'',''processing'',''completed'')))');
  IF changed=original THEN RAISE EXCEPTION 'Unrecognized Woo packing gate'; END IF;
  EXECUTE changed;
  INSERT INTO public.mp_commerce_cash_woo_backup VALUES(v_name,original,pg_get_functiondef(v_name::regprocedure)) ON CONFLICT(name) DO UPDATE SET applied_definition=excluded.applied_definition;
 END LOOP;
END $$;
CREATE OR REPLACE FUNCTION public.mp_commerce_confirm_cash(p_receipt uuid) RETURNS text LANGUAGE plpgsql AS $$
DECLARE r public.mp_commerce_cash_receipts%ROWTYPE;o record;packet jsonb;
BEGIN
 PERFORM pg_advisory_xact_lock(520052);
 SELECT * INTO STRICT r FROM public.mp_commerce_cash_receipts WHERE receipt_id=p_receipt;
 IF r.provider<>'woocommerce' OR r.erp_references IS NULL OR to_regclass('public.mp_commerce_erp_links') IS NULL THEN RAISE EXCEPTION 'Posted Woo cash receipt and installed ERP bridge required'; END IF;
 SELECT * INTO STRICT o FROM public.mp_commerce_orders WHERE provider=r.provider AND site_key=r.site_key AND external_order_id=r.external_order_id FOR UPDATE;
 IF o.snapshot->>'payment_processor' IS DISTINCT FROM 'cash' OR o.status NOT IN('processing','completed')
 OR jsonb_array_length(o.snapshot->'refunds')<>0 OR (o.snapshot->>'total')::numeric<>r.amount OR o.snapshot->>'currency'<>r.currency THEN RAISE EXCEPTION 'Wait for active paid Woo snapshot or review financial drift'; END IF;
 packet:=jsonb_build_object('processor','cash','payment_id',r.receipt_id::text,'provider',r.provider,'site_key',r.site_key,'external_order_id',r.external_order_id,'state','received','amount',r.amount,'currency',r.currency,'refunded_amount',0);
 INSERT INTO public.mp_commerce_payment_matches VALUES('cash',r.site_key,r.receipt_id::text,r.provider,r.external_order_id,packet)
 ON CONFLICT(processor,site_key,payment_id) DO NOTHING;
 EXECUTE 'SELECT public.mp_commerce_link_erp($1)' USING (r.erp_references||jsonb_build_object('provider',r.provider,'site_key',r.site_key,'external_order_id',r.external_order_id));
 EXECUTE 'UPDATE public.mp_commerce_orders SET reservation_confirmed=true WHERE provider=$1 AND site_key=$2 AND external_order_id=$3' USING r.provider,r.site_key,r.external_order_id;
 RETURN 'confirmed';
END $$;
REVOKE ALL ON TABLE public.mp_commerce_cash_receipts,public.mp_commerce_cash_woo_backup FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mp_commerce_record_cash(jsonb),public.mp_commerce_ack_cash(uuid,jsonb),public.mp_commerce_prepare_cash_packing(),public.mp_commerce_confirm_cash(uuid) FROM PUBLIC;
COMMIT;
