-- A sellable whole Lot counts as one unit, matching the catalog inventory view.
-- Weight-based portions and manufacturing-source withdrawals remain review work.
BEGIN;
CREATE TABLE public.mp_commerce_lot_picks (
 lot_id bigint PRIMARY KEY REFERENCES public.lots(nocopk),
 provider text NOT NULL,site_key text NOT NULL,reference text NOT NULL,line_id text NOT NULL,
 FOREIGN KEY(provider,site_key,reference) REFERENCES public.mp_commerce_packages
);
CREATE TABLE public.mp_commerce_shipped_lots (
 lot_id bigint PRIMARY KEY REFERENCES public.lots(nocopk),
 provider text NOT NULL,site_key text NOT NULL,external_order_id text NOT NULL,line_id text NOT NULL,
 movement_reference text NOT NULL,
 FOREIGN KEY(provider,site_key,movement_reference) REFERENCES public.mp_commerce_shipments
);
CREATE VIEW public.mp_commerce_shipped_units AS
 SELECT provider,site_key,external_order_id,line_id,movement_reference,product_id AS unit_id,'product'::text AS kind
 FROM public.mp_commerce_shipped_products UNION ALL
 SELECT provider,site_key,external_order_id,line_id,movement_reference,lot_id,'lot' FROM public.mp_commerce_shipped_lots;
CREATE VIEW public.mp_commerce_picked_units AS
 SELECT provider,site_key,reference,line_id,product_id AS unit_id FROM public.mp_commerce_picks UNION ALL
 SELECT provider,site_key,reference,line_id,lot_id FROM public.mp_commerce_lot_picks;

CREATE FUNCTION public.mp_commerce_lot_eligible(p_lot bigint,p_ecommerce bigint) RETURNS boolean
LANGUAGE sql STABLE AS $$
 SELECT EXISTS(SELECT 1 FROM public.lots l JOIN public.ecommerce e
 ON l.item_id=e.item_id AND l.strain_id IS NOT DISTINCT FROM e.strain_id
 JOIN public.locations location ON location.nocopk=l.location_id
 WHERE l.nocopk=p_lot AND e.nocopk=p_ecommerce AND location.active
 AND (l.use_by IS NULL OR l.use_by>=CURRENT_DATE)
 AND regexp_replace(lower(location.name),'[^a-z0-9]','','g') NOT IN
 ('shipped','consumed','expired','compost','composted','retired','missing','missingorlost')
 AND CASE regexp_replace(lower(e.status),'[^a-z0-9]','','g')
 WHEN 'sterilized' THEN regexp_replace(lower(l.status),'[^a-z0-9]','','g') IN ('sterilized','sealed')
 WHEN 'pasteurized' THEN regexp_replace(lower(l.status),'[^a-z0-9]','','g')='pasteurized'
 WHEN 'fullycolonized' THEN regexp_replace(lower(l.status),'[^a-z0-9]','','g') IN ('fullycolonized','fridge','coldshock')
 WHEN 'inoculated' THEN regexp_replace(lower(l.status),'[^a-z0-9]','','g') IN ('inoculated','colonizing')
 ELSE false END);
$$;

CREATE FUNCTION public.mp_commerce_pick_lot(p jsonb) RETURNS text LANGUAGE plpgsql AS $$
DECLARE o public.mp_commerce_orders%ROWTYPE;k public.mp_commerce_packages%ROWTYPE;
 r public.mp_commerce_reservations%ROWTYPE;l public.lots%ROWTYPE;old public.mp_commerce_lot_picks%ROWTYPE;q bigint;
BEGIN
 PERFORM pg_advisory_xact_lock(520052);
 IF p->>'provider' IS DISTINCT FROM 'woocommerce' OR coalesce(p->>'reference','') !~ '^[A-Za-z0-9_.:-]{1,120}$' THEN RAISE EXCEPTION 'Woo package identity required'; END IF;
 SELECT * INTO STRICT o FROM public.mp_commerce_orders WHERE provider=p->>'provider' AND site_key=p->>'site_key'
 AND external_order_id=p->>'external_order_id' FOR UPDATE;
 IF NOT o.reservation_confirmed OR o.status NOT IN ('processing','completed') OR jsonb_array_length(o.snapshot->'refunds')<>0 THEN
   RAISE EXCEPTION 'Confirmed unrefunded active order required'; END IF;
 INSERT INTO public.mp_commerce_packages(provider,site_key,external_order_id,reference,method)
 VALUES(o.provider,o.site_key,o.external_order_id,p->>'reference',p->>'method') ON CONFLICT DO NOTHING;
 SELECT * INTO STRICT k FROM public.mp_commerce_packages WHERE provider=o.provider AND site_key=o.site_key
 AND reference=p->>'reference' FOR UPDATE;
 IF k.external_order_id<>o.external_order_id OR k.method IS DISTINCT FROM p->>'method' OR k.state<>'packing'
 OR EXISTS(SELECT 1 FROM public.mp_commerce_picks WHERE provider=k.provider AND site_key=k.site_key AND reference=k.reference) THEN
 RAISE EXCEPTION 'Package identity differs or contains Product picks; use a separate Lot package'; END IF;
 SELECT * INTO STRICT l FROM public.lots WHERE lot_id=p->>'product_code' FOR UPDATE;
 SELECT * INTO old FROM public.mp_commerce_lot_picks WHERE lot_id=l.nocopk;
 IF FOUND THEN
   IF (old.provider,old.site_key,old.reference,old.line_id)=(k.provider,k.site_key,k.reference,p->>'line_id') THEN RETURN 'duplicate'; END IF;
   RAISE EXCEPTION 'Lot already allocated'; END IF;
 SELECT * INTO STRICT r FROM public.mp_commerce_reservations WHERE provider=o.provider AND site_key=o.site_key
 AND external_order_id=o.external_order_id AND line_id=p->>'line_id';
 SELECT count(*) INTO q FROM public.mp_commerce_picked_units x JOIN public.mp_commerce_packages package USING(provider,site_key,reference)
 WHERE package.provider=o.provider AND package.site_key=o.site_key AND package.external_order_id=o.external_order_id
 AND package.state='packing' AND x.line_id=r.line_id;
 IF q>=r.quantity OR NOT public.mp_commerce_lot_eligible(l.nocopk,r.ecommerce_id)
 OR EXISTS(SELECT 1 FROM public.mp_commerce_shipped_lots WHERE lot_id=l.nocopk) THEN RAISE EXCEPTION 'Lot unavailable or exceeds reserved line'; END IF;
 INSERT INTO public.mp_commerce_lot_picks VALUES(l.nocopk,k.provider,k.site_key,k.reference,r.line_id);
 RETURN 'picked';
END $$;

ALTER FUNCTION public.mp_commerce_dispatch(text,text,text) RENAME TO mp_commerce_dispatch_products;
CREATE FUNCTION public.mp_commerce_dispatch(p_provider text,p_site text,p_reference text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE k public.mp_commerce_packages%ROWTYPE;o public.mp_commerce_orders%ROWTYPE;
 line record;lot record;remaining bigint;held bigint;shipped_location bigint;n bigint;payload jsonb;
BEGIN
 PERFORM pg_advisory_xact_lock(520052);
 IF NOT EXISTS(SELECT 1 FROM public.mp_commerce_lot_picks WHERE provider=p_provider AND site_key=p_site AND reference=p_reference) THEN
   RETURN public.mp_commerce_dispatch_products(p_provider,p_site,p_reference); END IF;
 SELECT * INTO STRICT k FROM public.mp_commerce_packages WHERE provider=p_provider AND site_key=p_site AND reference=p_reference FOR UPDATE;
 IF k.state='dispatched' THEN RETURN 'duplicate'; END IF;
 IF k.state<>'packing' THEN RAISE EXCEPTION 'Packing package required'; END IF;
 SELECT * INTO STRICT o FROM public.mp_commerce_orders WHERE provider=k.provider AND site_key=k.site_key AND external_order_id=k.external_order_id FOR UPDATE;
 IF NOT o.reservation_confirmed OR o.status NOT IN ('processing','completed') OR jsonb_array_length(o.snapshot->'refunds')<>0 THEN
   RAISE EXCEPTION 'Confirmed unrefunded active order required'; END IF;
 IF k.method='shipping' AND (coalesce(k.tracking->>'tracking_number','')='' OR coalesce(k.tracking->>'carrier','')=''
 OR coalesce(k.tracking->>'service','')='' OR coalesce(k.tracking->>'label_status','') NOT IN ('purchased','manual','replacement')) THEN
 RAISE EXCEPTION 'Shipping label or manual tracking required'; END IF;
 SELECT min(nocopk),count(*) INTO shipped_location,n FROM public.locations
 WHERE active AND regexp_replace(lower(name),'[^a-z0-9]','','g')='shipped';
 IF n<>1 THEN RAISE EXCEPTION 'One Shipped location required'; END IF;
 SELECT jsonb_agg(jsonb_build_object('line_id',line_id,'lot_ids',ids) ORDER BY line_id) INTO payload
 FROM (SELECT line_id,jsonb_agg(lot_id ORDER BY lot_id) ids FROM public.mp_commerce_lot_picks
 WHERE provider=k.provider AND site_key=k.site_key AND reference=k.reference GROUP BY line_id) x;
 INSERT INTO public.mp_commerce_shipments VALUES(k.provider,k.site_key,k.external_order_id,k.reference,payload,now());
 PERFORM set_config('rootedops.dispatch_reference', k.reference, true);
 FOR line IN SELECT x.line_id,count(*) quantity FROM public.mp_commerce_lot_picks x
 WHERE x.provider=k.provider AND x.site_key=k.site_key AND x.reference=k.reference GROUP BY x.line_id LOOP
   SELECT quantity INTO STRICT held FROM public.mp_commerce_reservations WHERE provider=k.provider AND site_key=k.site_key
   AND external_order_id=k.external_order_id AND line_id=line.line_id FOR UPDATE;
   IF line.quantity>held THEN RAISE EXCEPTION 'Shipment exceeds reserved line'; END IF;
   FOR lot IN SELECT x.lot_id,r.ecommerce_id FROM public.mp_commerce_lot_picks x JOIN public.mp_commerce_reservations r
    ON (x.provider,x.site_key,x.line_id)=(r.provider,r.site_key,r.line_id) AND r.external_order_id=k.external_order_id
    WHERE x.provider=k.provider AND x.site_key=k.site_key AND x.reference=k.reference AND x.line_id=line.line_id ORDER BY x.lot_id LOOP
     PERFORM 1 FROM public.lots WHERE nocopk=lot.lot_id FOR UPDATE;
     IF NOT public.mp_commerce_lot_eligible(lot.lot_id,lot.ecommerce_id) THEN RAISE EXCEPTION 'Lot no longer eligible'; END IF;
     PERFORM public.mp_lot_set_location(lot.lot_id,shipped_location);
     UPDATE public.lots SET status='Shipped' WHERE nocopk=lot.lot_id;
     INSERT INTO public.mp_commerce_shipped_lots VALUES(lot.lot_id,k.provider,k.site_key,k.external_order_id,line.line_id,k.reference);
   END LOOP;
   UPDATE public.mp_commerce_reservations SET quantity=quantity-line.quantity WHERE provider=k.provider AND site_key=k.site_key
   AND external_order_id=k.external_order_id AND line_id=line.line_id AND quantity>line.quantity;
   IF NOT FOUND THEN DELETE FROM public.mp_commerce_reservations WHERE provider=k.provider AND site_key=k.site_key
   AND external_order_id=k.external_order_id AND line_id=line.line_id; END IF;
 END LOOP;
 SELECT coalesce(sum((x->>'quantity')::bigint),0)-(SELECT count(*) FROM public.mp_commerce_shipped_units
 WHERE provider=k.provider AND site_key=k.site_key AND external_order_id=k.external_order_id) INTO remaining FROM jsonb_array_elements(o.snapshot->'lines') x;
 UPDATE public.mp_commerce_orders SET fulfilled=(remaining=0),inventory_committed=(remaining=0),fulfillment_reference=CASE WHEN remaining=0 THEN k.reference ELSE fulfillment_reference END
 WHERE provider=k.provider AND site_key=k.site_key AND external_order_id=k.external_order_id;
 UPDATE public.mp_commerce_packages SET state='dispatched' WHERE provider=k.provider AND site_key=k.site_key AND reference=k.reference;
 INSERT INTO public.mp_commerce_shipment_delivery(provider,site_key,movement_reference,target)
 VALUES(k.provider,k.site_key,k.reference,'erp'),(k.provider,k.site_key,k.reference,'woo');
 PERFORM set_config('rootedops.dispatch_reference','',true);
 RETURN CASE WHEN remaining=0 THEN 'fulfilled' ELSE 'partial' END;
END $$;
REVOKE ALL ON FUNCTION public.mp_commerce_dispatch(text,text,text),public.mp_commerce_pick_lot(jsonb) FROM PUBLIC;

CREATE FUNCTION public.mp_commerce_guard_picked_lot() RETURNS trigger LANGUAGE plpgsql
SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN
 IF (NEW.location_id,NEW.status,NEW.qty) IS DISTINCT FROM (OLD.location_id,OLD.status,OLD.qty)
 AND EXISTS(SELECT 1 FROM public.mp_commerce_lot_picks x JOIN public.mp_commerce_packages k USING(provider,site_key,reference)
 WHERE x.lot_id=OLD.nocopk AND k.state='packing' AND k.reference IS DISTINCT FROM current_setting('rootedops.dispatch_reference',true)) THEN
 RAISE EXCEPTION 'Packed Woo lot requires dispatch or cancellation before change'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER mp_commerce_guard_picked_lot BEFORE UPDATE OF location_id,status,qty ON public.lots
FOR EACH ROW EXECUTE FUNCTION public.mp_commerce_guard_picked_lot();

CREATE FUNCTION public.mp_commerce_guard_mixed_package() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM public.mp_commerce_lot_picks WHERE provider=NEW.provider AND site_key=NEW.site_key AND reference=NEW.reference) THEN
 RAISE EXCEPTION 'Use separate packages for whole Lots and Products'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER mp_commerce_guard_mixed_package BEFORE INSERT ON public.mp_commerce_picks
FOR EACH ROW EXECUTE FUNCTION public.mp_commerce_guard_mixed_package();

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
        SELECT (line->>'quantity')::bigint-count(*) INTO v_remaining FROM public.mp_commerce_shipped_units
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
     IF EXISTS(SELECT 1 FROM public._m2m_products_ecommerce_orders_ecommerce_orders WHERE products_id=(pid#>>'{}')::bigint)
        OR EXISTS(SELECT 1 FROM public._m2m_ecommerce_orders_products_products WHERE products_id=(pid#>>'{}')::bigint) THEN
       RAISE EXCEPTION 'Legacy allocation requires explicit reconciliation';
     END IF;
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
 SELECT coalesce(sum((l->>'quantity')::bigint),0)-(SELECT count(*) FROM public.mp_commerce_shipped_units WHERE provider=p_provider AND site_key=p_site AND external_order_id=p_order)
   INTO remaining FROM jsonb_array_elements(o.snapshot->'lines') l;
 UPDATE public.mp_commerce_orders SET fulfilled=(remaining=0),inventory_committed=(remaining=0),fulfillment_reference=CASE WHEN remaining=0 THEN p_reference ELSE fulfillment_reference END
 WHERE provider=p_provider AND site_key=p_site AND external_order_id=p_order;
 RETURN CASE WHEN remaining=0 THEN 'fulfilled' ELSE 'partial' END;
END $$;
CREATE OR REPLACE FUNCTION public.mp_commerce_pick(p jsonb) RETURNS text LANGUAGE plpgsql AS $$
DECLARE o public.mp_commerce_orders%ROWTYPE; r public.mp_commerce_reservations%ROWTYPE;
 package public.mp_commerce_packages%ROWTYPE; product public.products%ROWTYPE;
 old public.mp_commerce_picks%ROWTYPE; q bigint; loc text;
BEGIN
 PERFORM pg_advisory_xact_lock(520052);
 IF p->>'provider' IS DISTINCT FROM 'woocommerce' OR coalesce(p->>'reference','') !~ '^[A-Za-z0-9_.:-]{1,120}$'
    OR p->>'method' IS NULL THEN
   RAISE EXCEPTION 'Woo identity and stable package reference required'; END IF;
 SELECT * INTO STRICT o FROM public.mp_commerce_orders WHERE provider=p->>'provider'
   AND site_key=p->>'site_key' AND external_order_id=p->>'external_order_id' FOR UPDATE;
 IF NOT o.reservation_confirmed OR o.status NOT IN ('processing','completed')
    OR jsonb_array_length(o.snapshot->'refunds')<>0 THEN RAISE EXCEPTION 'Confirmed unrefunded active order required'; END IF;
 INSERT INTO public.mp_commerce_packages(provider,site_key,external_order_id,reference,method)
 VALUES(o.provider,o.site_key,o.external_order_id,p->>'reference',p->>'method') ON CONFLICT DO NOTHING;
 SELECT * INTO STRICT package FROM public.mp_commerce_packages WHERE provider=o.provider
   AND site_key=o.site_key AND reference=p->>'reference' FOR UPDATE;
 IF package.external_order_id<>o.external_order_id OR package.method<>p->>'method' OR package.state<>'packing' THEN
   RAISE EXCEPTION 'Package identity or state differs'; END IF;
 SELECT * INTO STRICT product FROM public.products WHERE product_id=p->>'product_code' FOR UPDATE;
 SELECT * INTO old FROM public.mp_commerce_picks WHERE product_id=product.nocopk;
 IF FOUND THEN
   IF (old.provider,old.site_key,old.reference,old.line_id)=(o.provider,o.site_key,package.reference,p->>'line_id') THEN RETURN 'duplicate'; END IF;
   RAISE EXCEPTION 'Product already picked for another line or package';
 END IF;
 SELECT * INTO STRICT r FROM public.mp_commerce_reservations WHERE provider=o.provider
   AND site_key=o.site_key AND external_order_id=o.external_order_id AND line_id=p->>'line_id';
 SELECT count(*) INTO q FROM public.mp_commerce_picked_units x JOIN public.mp_commerce_packages k
   USING(provider,site_key,reference) WHERE k.provider=o.provider AND k.site_key=o.site_key
   AND k.external_order_id=o.external_order_id AND k.state='packing' AND x.line_id=r.line_id;
 SELECT regexp_replace(lower(name),'[^a-z0-9]','','g') INTO loc FROM public.locations
   WHERE nocopk=product.storage_location_id AND active;
 IF q>=r.quantity OR product.item_id<>r.item_id OR product.strain_id IS DISTINCT FROM r.strain_id
   OR product.use_by<CURRENT_DATE OR loc IS NULL OR loc IN
   ('shipped','consumed','expired','compost','composted','retired','missing','missingorlost')
   OR EXISTS(SELECT 1 FROM public.mp_commerce_shipped_products WHERE product_id=product.nocopk)
   OR EXISTS(SELECT 1 FROM public._m2m_products_ecommerce_orders_ecommerce_orders WHERE products_id=product.nocopk)
   OR EXISTS(SELECT 1 FROM public._m2m_ecommerce_orders_products_products WHERE products_id=product.nocopk) THEN
   RAISE EXCEPTION 'Product is unavailable or exceeds the reserved line'; END IF;
 INSERT INTO public.mp_commerce_picks VALUES(product.nocopk,o.provider,o.site_key,package.reference,r.line_id);
 RETURN 'picked';
END $$;

CREATE OR REPLACE FUNCTION public.mp_commerce_release_picks() RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE n bigint;m bigint;
BEGIN
 PERFORM pg_advisory_xact_lock(520052);
 UPDATE public.mp_commerce_packages k SET state='cancelled' FROM public.mp_commerce_orders o
 WHERE (k.provider,k.site_key,k.external_order_id)=(o.provider,o.site_key,o.external_order_id)
 AND k.state='packing' AND o.status IN ('cancelled','failed');
 DELETE FROM public.mp_commerce_picks x USING public.mp_commerce_packages k
 WHERE (x.provider,x.site_key,x.reference)=(k.provider,k.site_key,k.reference) AND k.state='cancelled';
 GET DIAGNOSTICS n=ROW_COUNT;
 DELETE FROM public.mp_commerce_lot_picks x USING public.mp_commerce_packages k
 WHERE (x.provider,x.site_key,x.reference)=(k.provider,k.site_key,k.reference) AND k.state='cancelled';
 GET DIAGNOSTICS m=ROW_COUNT;
 RETURN n+m;
END $$;

CREATE FUNCTION public.mp_commerce_dispatch_request(p jsonb) RETURNS text LANGUAGE plpgsql AS $$
DECLARE k public.mp_commerce_packages%ROWTYPE;
BEGIN
 PERFORM pg_advisory_xact_lock(520052);
 SELECT * INTO STRICT k FROM public.mp_commerce_packages WHERE provider=p->>'provider'
 AND site_key=p->>'site_key' AND reference=p->>'reference' FOR UPDATE;
 IF k.external_order_id IS DISTINCT FROM p->>'external_order_id' THEN RAISE EXCEPTION 'Dispatch order identity differs'; END IF;
 RETURN public.mp_commerce_dispatch(k.provider,k.site_key,k.reference);
END $$;
CREATE FUNCTION public.mp_commerce_unpick(p jsonb) RETURNS text LANGUAGE plpgsql AS $$
DECLARE k public.mp_commerce_packages%ROWTYPE;n bigint;m bigint;
BEGIN
 PERFORM pg_advisory_xact_lock(520052);
 SELECT * INTO STRICT k FROM public.mp_commerce_packages WHERE provider=p->>'provider'
 AND site_key=p->>'site_key' AND reference=p->>'reference' FOR UPDATE;
 IF k.state<>'packing' OR k.external_order_id IS DISTINCT FROM p->>'external_order_id' THEN RAISE EXCEPTION 'Matching packing package required'; END IF;
 DELETE FROM public.mp_commerce_picks x USING public.products product
 WHERE x.product_id=product.nocopk AND product.product_id=p->>'product_code'
 AND (x.provider,x.site_key,x.reference)=(k.provider,k.site_key,k.reference);
 GET DIAGNOSTICS n=ROW_COUNT;
 DELETE FROM public.mp_commerce_lot_picks x USING public.lots lot
 WHERE x.lot_id=lot.nocopk AND lot.lot_id=p->>'product_code'
 AND (x.provider,x.site_key,x.reference)=(k.provider,k.site_key,k.reference);
 GET DIAGNOSTICS m=ROW_COUNT;
 RETURN CASE WHEN n+m=0 THEN 'missing' ELSE 'unpicked' END;
END $$;
REVOKE ALL ON FUNCTION public.mp_commerce_dispatch_request(jsonb),public.mp_commerce_unpick(jsonb) FROM PUBLIC;
COMMIT;
