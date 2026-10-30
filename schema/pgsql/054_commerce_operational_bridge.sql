-- Explicit operational acknowledgment and ERP identity mapping; no storefront stock writes.
BEGIN;
ALTER TABLE public.mp_commerce_orders ADD COLUMN IF NOT EXISTS reservation_confirmed boolean NOT NULL DEFAULT false;
CREATE TABLE IF NOT EXISTS public.mp_commerce_erp_links (
 provider text NOT NULL,site_key text NOT NULL,external_order_id text NOT NULL,
 erp_site text NOT NULL,sales_order text NOT NULL,sales_invoice text,payment_entry text,
 PRIMARY KEY(provider,site_key,external_order_id),UNIQUE(erp_site,sales_order),
 UNIQUE(erp_site,sales_invoice),UNIQUE(erp_site,payment_entry),
 FOREIGN KEY(provider,site_key,external_order_id) REFERENCES public.mp_commerce_orders(provider,site_key,external_order_id)
);
CREATE TABLE IF NOT EXISTS public.mp_commerce_shipments (
 provider text NOT NULL,site_key text NOT NULL,external_order_id text NOT NULL,
 movement_reference text NOT NULL,payload jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(provider,site_key,movement_reference),
 FOREIGN KEY(provider,site_key,external_order_id) REFERENCES public.mp_commerce_orders(provider,site_key,external_order_id)
);
CREATE TABLE IF NOT EXISTS public.mp_commerce_shipped_products (
 product_id bigint PRIMARY KEY REFERENCES public.products(nocopk),
 provider text NOT NULL,site_key text NOT NULL,external_order_id text NOT NULL,line_id text NOT NULL,
 movement_reference text NOT NULL,
 FOREIGN KEY(provider,site_key,movement_reference) REFERENCES public.mp_commerce_shipments(provider,site_key,movement_reference)
);
CREATE OR REPLACE FUNCTION public.mp_commerce_link_erp(p jsonb) RETURNS text LANGUAGE plpgsql AS $$
DECLARE old public.mp_commerce_erp_links%ROWTYPE;
BEGIN
 PERFORM pg_advisory_xact_lock(520052);
 IF coalesce(btrim(p->>'erp_site'),'')='' OR coalesce(btrim(p->>'sales_order'),'')='' THEN RAISE EXCEPTION 'ERP site/order required'; END IF;
 SELECT * INTO old FROM public.mp_commerce_erp_links WHERE provider=p->>'provider' AND site_key=p->>'site_key' AND external_order_id=p->>'external_order_id';
 IF FOUND AND (old.erp_site IS DISTINCT FROM p->>'erp_site' OR old.sales_order IS DISTINCT FROM p->>'sales_order'
   OR old.sales_invoice IS NOT NULL AND old.sales_invoice IS DISTINCT FROM nullif(p->>'sales_invoice','')
   OR old.payment_entry IS NOT NULL AND old.payment_entry IS DISTINCT FROM nullif(p->>'payment_entry','')) THEN
   RAISE EXCEPTION 'ERP identity drift';
 END IF;
 INSERT INTO public.mp_commerce_erp_links VALUES(p->>'provider',p->>'site_key',p->>'external_order_id',p->>'erp_site',p->>'sales_order',nullif(p->>'sales_invoice',''),nullif(p->>'payment_entry',''))
 ON CONFLICT(provider,site_key,external_order_id) DO UPDATE SET sales_invoice=excluded.sales_invoice,payment_entry=excluded.payment_entry;
 RETURN 'linked';
END $$;
CREATE OR REPLACE FUNCTION public.mp_commerce_confirm_reservation(p_provider text,p_site text,p_order text)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE o public.mp_commerce_orders%ROWTYPE;m public.mp_commerce_payment_matches%ROWTYPE;
BEGIN
 PERFORM pg_advisory_xact_lock(520052);
 SELECT * INTO STRICT o FROM public.mp_commerce_orders WHERE provider=p_provider AND site_key=p_site AND external_order_id=p_order FOR UPDATE;
 SELECT * INTO STRICT m FROM public.mp_commerce_payment_matches WHERE provider=p_provider AND site_key=p_site AND external_order_id=p_order;
 IF o.status NOT IN ('processing','completed') OR m.evidence->>'state'<>'captured'
    OR (m.evidence->>'refunded_amount')::numeric<>0 THEN RAISE EXCEPTION 'Unrefunded verified capture and active order required'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.mp_commerce_erp_links WHERE provider=p_provider AND site_key=p_site AND external_order_id=p_order AND sales_invoice IS NOT NULL AND payment_entry IS NOT NULL) THEN RAISE EXCEPTION 'Reviewed ERP financial references required'; END IF;
 UPDATE public.mp_commerce_orders SET reservation_confirmed=true WHERE provider=p_provider AND site_key=p_site AND external_order_id=p_order;
 RETURN 'confirmed';
END $$;
CREATE OR REPLACE FUNCTION public.mp_commerce_acknowledge_products(p_provider text,p_site text,p_order text,p_reference text,p_lines jsonb)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE o public.mp_commerce_orders%ROWTYPE;old public.mp_commerce_shipments%ROWTYPE;
 line jsonb;pid jsonb;inventory record;held bigint;line_count bigint;remaining bigint;
BEGIN
 PERFORM pg_advisory_xact_lock(520052);
 SELECT * INTO STRICT o FROM public.mp_commerce_orders WHERE provider=p_provider AND site_key=p_site AND external_order_id=p_order FOR UPDATE;
 IF coalesce(btrim(p_reference),'')='' OR jsonb_typeof(p_lines) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lines)=0 THEN RAISE EXCEPTION 'Movement reference and nonempty lines required'; END IF;
 SELECT * INTO old FROM public.mp_commerce_shipments WHERE provider=p_provider AND site_key=p_site AND movement_reference=p_reference;
 IF FOUND THEN
   IF old.external_order_id<>p_order OR old.payload IS DISTINCT FROM p_lines THEN RAISE EXCEPTION 'Movement identity reused'; END IF;
   RETURN 'duplicate';
 END IF;
 IF NOT o.reservation_confirmed OR o.status NOT IN ('processing','completed') THEN RAISE EXCEPTION 'Confirmed active reservation required'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(o.snapshot->'refunds')) THEN RAISE EXCEPTION 'Refunded order needs manual shipment review'; END IF;
 INSERT INTO public.mp_commerce_shipments VALUES(p_provider,p_site,p_order,p_reference,p_lines,now());
 FOR line IN SELECT value FROM jsonb_array_elements(p_lines) LOOP
   IF jsonb_typeof(line->'product_ids') IS DISTINCT FROM 'array' OR jsonb_array_length(line->'product_ids')=0 THEN RAISE EXCEPTION 'Product acknowledgments required'; END IF;
   SELECT r.quantity INTO STRICT held FROM public.mp_commerce_reservations r WHERE provider=p_provider AND site_key=p_site AND external_order_id=p_order AND line_id=line->>'line_id' FOR UPDATE;
   line_count=jsonb_array_length(line->'product_ids');
   IF line_count>held THEN RAISE EXCEPTION 'Shipment exceeds reserved line'; END IF;
   FOR pid IN SELECT value FROM jsonb_array_elements(line->'product_ids') LOOP
     SELECT p.item_id,p.strain_id,l.name AS location,e.item_id AS expected_item,e.strain_id AS expected_strain INTO STRICT inventory
       FROM public.products p JOIN public.locations l ON l.nocopk=p.storage_location_id
       JOIN public.mp_commerce_reservations r ON r.provider=p_provider AND r.site_key=p_site AND r.external_order_id=p_order AND r.line_id=line->>'line_id'
       JOIN public.ecommerce e ON e.nocopk=r.ecommerce_id WHERE p.nocopk=(pid#>>'{}')::bigint FOR UPDATE OF p;
     IF regexp_replace(lower(inventory.location),'[^a-z0-9]','','g')<>'shipped'
       OR inventory.item_id<>inventory.expected_item OR inventory.strain_id IS DISTINCT FROM inventory.expected_strain THEN
       RAISE EXCEPTION 'Product must be physically shipped and match operational definition';
     END IF;
     INSERT INTO public.mp_commerce_shipped_products VALUES((pid#>>'{}')::bigint,p_provider,p_site,p_order,line->>'line_id',p_reference);
   END LOOP;
   IF line_count=held THEN DELETE FROM public.mp_commerce_reservations WHERE provider=p_provider AND site_key=p_site AND external_order_id=p_order AND line_id=line->>'line_id';
   ELSE UPDATE public.mp_commerce_reservations SET quantity=quantity-line_count WHERE provider=p_provider AND site_key=p_site AND external_order_id=p_order AND line_id=line->>'line_id'; END IF;
 END LOOP;
 SELECT coalesce(sum((l->>'quantity')::bigint),0)-(SELECT count(*) FROM public.mp_commerce_shipped_products WHERE provider=p_provider AND site_key=p_site AND external_order_id=p_order)
   INTO remaining FROM jsonb_array_elements(o.snapshot->'lines') l;
 UPDATE public.mp_commerce_orders SET fulfilled=(remaining=0),inventory_committed=(remaining=0),fulfillment_reference=CASE WHEN remaining=0 THEN p_reference ELSE fulfillment_reference END
 WHERE provider=p_provider AND site_key=p_site AND external_order_id=p_order;
 RETURN CASE WHEN remaining=0 THEN 'fulfilled' ELSE 'partial' END;
END $$;
-- Retire string-only release: an operational Product acknowledgment is now required.
CREATE OR REPLACE FUNCTION public.mp_commerce_commit_fulfillment(p_provider text,p_site text,p_order text,p_reference text)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM public.mp_commerce_orders WHERE provider=p_provider AND site_key=p_site AND external_order_id=p_order AND inventory_committed AND fulfillment_reference=p_reference) THEN RETURN 'duplicate'; END IF;
 RAISE EXCEPTION 'Use mp_commerce_acknowledge_products after explicit physical movement';
END $$;
REVOKE ALL ON FUNCTION public.mp_commerce_link_erp(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mp_commerce_confirm_reservation(text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mp_commerce_acknowledge_products(text,text,text,text,jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION public.mp_commerce_ingest(p jsonb) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  provider_key text := p->>'provider'; site text := p->>'site_key';
  order_id text := p->>'external_order_id'; event_key text := p->>'event_id';
  previous public.mp_commerce_orders%ROWTYPE; old_event jsonb;
  line jsonb; candidate record; reserved bigint; duplicate_lines bigint;
  refund_total numeric; previous_refund jsonb;v_remaining bigint;
BEGIN
  -- Serialize admissions across provider aliases that share physical inventory.
  -- This deliberately conservative global lock trades throughput for safety.
  PERFORM pg_advisory_xact_lock(520052);
  IF jsonb_typeof(p)<>'object' OR p->>'schema_version' IS DISTINCT FROM '1'
     OR COALESCE(btrim(provider_key),'')='' OR COALESCE(btrim(site),'')=''
     OR COALESCE(btrim(order_id),'')='' OR COALESCE(btrim(event_key),'')=''
     OR COALESCE(p->>'revision','') !~ '^[0-9]+$'
     OR COALESCE(p->>'currency','') !~ '^[A-Z]{3}$'
     OR COALESCE(p->>'total','') !~ '^[0-9]+(\.[0-9]+)?$'
     OR COALESCE(p->>'status','') NOT IN ('pending','on-hold','processing','completed','cancelled','failed','refunded')
     OR jsonb_typeof(p->'lines') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'lines')=0
     OR jsonb_typeof(p->'refunds') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Invalid normalized commerce event';
  END IF;
  FOR line IN SELECT value FROM jsonb_array_elements(p->'lines') LOOP
    IF jsonb_typeof(line) IS DISTINCT FROM 'object'
       OR coalesce(btrim(line->>'line_id'),'')=''
       OR coalesce(line->>'quantity','') !~ '^[1-9][0-9]*$'
       OR coalesce(line->>'ecommerce_id','') !~ '^[1-9][0-9]*$'
       OR coalesce(btrim(line->>'erp_item_code'),'')='' THEN
      RAISE EXCEPTION 'Invalid operational line';
    END IF;
  END LOOP;
  SELECT payload INTO old_event FROM public.mp_commerce_events
    WHERE provider=provider_key AND site_key=site AND event_id=event_key;
  IF FOUND THEN
    IF old_event IS DISTINCT FROM p THEN RAISE EXCEPTION 'Event identity reused with different payload'; END IF;
    RETURN 'duplicate';
  END IF;
  SELECT * INTO previous FROM public.mp_commerce_orders
    WHERE provider=provider_key AND site_key=site AND external_order_id=order_id FOR UPDATE;
  IF FOUND THEN
    IF (p->>'revision')::bigint < previous.revision THEN RETURN 'stale'; END IF;
    IF (p->>'revision')::bigint = previous.revision THEN
      IF (p-'event_id') IS DISTINCT FROM (previous.snapshot-'event_id') THEN
        RAISE EXCEPTION 'Same-revision conflict; fetch current authoritative order';
      END IF;
      INSERT INTO public.mp_commerce_events VALUES(provider_key,site,event_key,order_id,p,now());
      RETURN 'duplicate';
    END IF;
    IF p->'lines' IS DISTINCT FROM previous.snapshot->'lines'
       OR p->>'currency' IS DISTINCT FROM previous.snapshot->>'currency'
       OR (p->>'total')::numeric IS DISTINCT FROM (previous.snapshot->>'total')::numeric THEN
      RAISE EXCEPTION 'Order line/currency/total edit requires manual reconciliation';
    END IF;
    IF previous.status IN ('cancelled','failed','refunded') AND p->>'status' NOT IN ('cancelled','failed','refunded') THEN
      RAISE EXCEPTION 'Terminal order cannot be reopened automatically';
    END IF;
    IF NULLIF(previous.snapshot->>'processor_payment_id','') IS NOT NULL
       AND p->>'processor_payment_id' IS DISTINCT FROM previous.snapshot->>'processor_payment_id' THEN
      RAISE EXCEPTION 'Payment identity drift';
    END IF;
    FOR previous_refund IN SELECT value FROM jsonb_array_elements(previous.snapshot->'refunds') LOOP
      IF NOT (p->'refunds' @> jsonb_build_array(previous_refund)) THEN
        RAISE EXCEPTION 'Refund history cannot disappear or change';
      END IF;
    END LOOP;
  END IF;
  SELECT count(*)-count(DISTINCT value->>'line_id') INTO duplicate_lines FROM jsonb_array_elements(p->'lines');
  IF duplicate_lines<>0 THEN RAISE EXCEPTION 'Duplicate line identities'; END IF;
  SELECT count(*)-count(DISTINCT value->>'external_refund_id') INTO duplicate_lines FROM jsonb_array_elements(p->'refunds');
  IF duplicate_lines<>0 THEN RAISE EXCEPTION 'Duplicate refund identities'; END IF;
  FOR line IN SELECT value FROM jsonb_array_elements(p->'refunds') LOOP
    IF COALESCE(btrim(line->>'external_refund_id'),'')='' OR COALESCE(line->>'amount','') !~ '^[0-9]+(\.[0-9]+)?$' THEN
      RAISE EXCEPTION 'Invalid refund snapshot';
    END IF;
  END LOOP;
  SELECT coalesce(sum((value->>'amount')::numeric),0) INTO refund_total FROM jsonb_array_elements(p->'refunds');
  IF refund_total>(p->>'total')::numeric OR (p->>'status'='refunded' AND refund_total<>(p->>'total')::numeric) THEN
    RAISE EXCEPTION 'Refund total mismatch';
  END IF;
  INSERT INTO public.mp_commerce_orders(provider,site_key,external_order_id,revision,status,snapshot)
    VALUES(provider_key,site,order_id,(p->>'revision')::bigint,p->>'status',p)
    ON CONFLICT(provider,site_key,external_order_id) DO UPDATE
      SET revision=excluded.revision,status=excluded.status,snapshot=excluded.snapshot;
  -- Fulfilled orders retain their hold until the operator commits physical stock
  -- movement. Refunds never restock shipped products or create return lineage.
  IF NOT coalesce(previous.fulfilled,false) THEN
    DELETE FROM public.mp_commerce_reservations
      WHERE provider=provider_key AND site_key=site AND external_order_id=order_id;
    IF p->>'status' NOT IN ('cancelled','failed','refunded') THEN
      FOR line IN SELECT value FROM jsonb_array_elements(p->'lines') LOOP
        IF COALESCE(line->>'line_id','')='' OR COALESCE(line->>'quantity','') !~ '^[1-9][0-9]*$' THEN
          RAISE EXCEPTION 'Invalid operational line';
        END IF;
        SELECT * INTO candidate FROM public.mp_ecommerce_catalog_inventory()
          WHERE ecommerce_id=(line->>'ecommerce_id')::bigint;
        IF NOT FOUND OR candidate.provider<>provider_key OR candidate.site_key<>site
           OR candidate.erp_item_code IS DISTINCT FROM line->>'erp_item_code'
           OR candidate.erp_item_code IS NULL THEN RAISE EXCEPTION 'Unapproved operational mapping'; END IF;
        SELECT (line->>'quantity')::bigint-count(*) INTO v_remaining FROM public.mp_commerce_shipped_products
          WHERE provider=provider_key AND site_key=site AND external_order_id=order_id AND line_id=line->>'line_id';
        IF v_remaining<0 THEN RAISE EXCEPTION 'Shipment history exceeds ordered quantity'; END IF;
        IF v_remaining=0 THEN CONTINUE; END IF;
        SELECT coalesce(sum(quantity),0) INTO reserved FROM public.mp_commerce_reservations
          WHERE item_id=candidate.item_id AND strain_id IS NOT DISTINCT FROM candidate.strain_id;
        IF candidate.desired_quantity-reserved < v_remaining THEN
          RAISE EXCEPTION 'Insufficient sellable operational quantity';
        END IF;
        INSERT INTO public.mp_commerce_reservations VALUES(provider_key,site,order_id,line->>'line_id',
          candidate.ecommerce_id,candidate.item_id,candidate.strain_id,v_remaining);
      END LOOP;
    END IF;
  END IF;
  INSERT INTO public.mp_commerce_events VALUES(provider_key,site,event_key,order_id,p,now());
  RETURN 'applied';
END $$;
COMMIT;
