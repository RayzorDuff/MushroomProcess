-- Woo packing is distinct from dispatch. Keep the legacy Ecwid path intact.
BEGIN;
CREATE TABLE public.mp_commerce_packages (
 provider text NOT NULL, site_key text NOT NULL, external_order_id text NOT NULL,
 reference text NOT NULL, method text NOT NULL CHECK(method IN ('shipping','pickup','local_delivery')),
 state text NOT NULL DEFAULT 'packing' CHECK(state IN ('packing','dispatched','cancelled')),
 tracking jsonb NOT NULL DEFAULT '{}', created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(provider,site_key,reference),
 FOREIGN KEY(provider,site_key,external_order_id) REFERENCES public.mp_commerce_orders
);
CREATE TABLE public.mp_commerce_picks (
 product_id bigint PRIMARY KEY REFERENCES public.products(nocopk),
 provider text NOT NULL, site_key text NOT NULL, reference text NOT NULL, line_id text NOT NULL,
 FOREIGN KEY(provider,site_key,reference) REFERENCES public.mp_commerce_packages
);
CREATE TABLE public.mp_commerce_shipment_delivery (
 provider text NOT NULL,site_key text NOT NULL,movement_reference text NOT NULL,
 target text NOT NULL CHECK(target IN ('erp','woo')),
 delivered_at timestamptz, attempts integer NOT NULL DEFAULT 0, last_error text,
 PRIMARY KEY(provider,site_key,movement_reference,target),
 FOREIGN KEY(provider,site_key,movement_reference) REFERENCES public.mp_commerce_shipments
);
CREATE SEQUENCE public.mp_commerce_inventory_revision;

CREATE FUNCTION public.mp_commerce_pick(p jsonb) RETURNS text LANGUAGE plpgsql AS $$
DECLARE o public.mp_commerce_orders%ROWTYPE; r public.mp_commerce_reservations%ROWTYPE;
 package public.mp_commerce_packages%ROWTYPE; product public.products%ROWTYPE;
 old public.mp_commerce_picks%ROWTYPE; q bigint; loc text;
BEGIN
 PERFORM pg_advisory_xact_lock(520052);
 IF p->>'provider' IS DISTINCT FROM 'woocommerce' OR coalesce(btrim(p->>'reference'),'')=''
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
 SELECT count(*) INTO q FROM public.mp_commerce_picks x JOIN public.mp_commerce_packages k
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

CREATE FUNCTION public.mp_commerce_package_tracking(p jsonb) RETURNS text LANGUAGE plpgsql AS $$
DECLARE k public.mp_commerce_packages%ROWTYPE; t jsonb:=p->'tracking';
BEGIN
 PERFORM pg_advisory_xact_lock(520052);
 SELECT * INTO STRICT k FROM public.mp_commerce_packages WHERE provider=p->>'provider'
 AND site_key=p->>'site_key' AND reference=p->>'reference' FOR UPDATE;
 IF k.state<>'packing' THEN RAISE EXCEPTION 'Tracking changes require packing package'; END IF;
 IF jsonb_typeof(t) IS DISTINCT FROM 'object' OR coalesce(t->>'label_status','') NOT IN ('purchased','manual','voided','replacement','none')
 OR (t ? 'postage' AND ((t->>'postage')::numeric<0 OR t->>'currency' IS DISTINCT FROM 'USD')) THEN
 RAISE EXCEPTION 'Reviewed label status and nonnegative USD postage required'; END IF;
 UPDATE public.mp_commerce_packages SET tracking=t WHERE provider=k.provider AND site_key=k.site_key AND reference=k.reference;
 RETURN 'recorded';
END $$;

CREATE FUNCTION public.mp_commerce_dispatch(p_provider text,p_site text,p_reference text)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE k public.mp_commerce_packages%ROWTYPE; lines jsonb; result text;
BEGIN
 PERFORM pg_advisory_xact_lock(520052);
 SELECT * INTO STRICT k FROM public.mp_commerce_packages WHERE provider=p_provider AND site_key=p_site
 AND reference=p_reference FOR UPDATE;
 IF k.state='dispatched' THEN RETURN 'duplicate'; END IF;
 IF k.state<>'packing' THEN RAISE EXCEPTION 'Packing package required'; END IF;
 IF k.method='shipping' AND (coalesce(k.tracking->>'tracking_number','')=''
   OR coalesce(k.tracking->>'carrier','')='' OR coalesce(k.tracking->>'service','')=''
   OR coalesce(k.tracking->>'label_status','') NOT IN ('purchased','manual','replacement')) THEN
   RAISE EXCEPTION 'Shipping label or manual tracking review required before dispatch'; END IF;
 SELECT jsonb_agg(jsonb_build_object('line_id',line_id,'product_ids',ids) ORDER BY line_id)
 INTO lines FROM (SELECT line_id,jsonb_agg(product_id ORDER BY product_id) ids FROM public.mp_commerce_picks
 WHERE provider=p_provider AND site_key=p_site AND reference=p_reference GROUP BY line_id) x;
 PERFORM set_config('rootedops.dispatch_reference', k.reference, true);
 result=public.mp_commerce_ship_products(k.provider,k.site_key,k.external_order_id,k.reference,lines);
 PERFORM set_config('rootedops.dispatch_reference', '', true);
 UPDATE public.mp_commerce_packages SET state='dispatched' WHERE provider=k.provider AND site_key=k.site_key AND reference=k.reference;
 INSERT INTO public.mp_commerce_shipment_delivery(provider,site_key,movement_reference,target)
 VALUES(k.provider,k.site_key,k.reference,'erp'),(k.provider,k.site_key,k.reference,'woo');
 RETURN result;
END $$;

-- Call for cancelled orders after intake. Never release dispatched physical history.
CREATE FUNCTION public.mp_commerce_release_picks() RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
 PERFORM pg_advisory_xact_lock(520052);
 WITH cancelled AS (UPDATE public.mp_commerce_packages k SET state='cancelled'
 FROM public.mp_commerce_orders o WHERE (k.provider,k.site_key,k.external_order_id)=(o.provider,o.site_key,o.external_order_id)
 AND k.state='packing' AND o.status IN ('cancelled','failed') RETURNING k.provider,k.site_key,k.reference)
 DELETE FROM public.mp_commerce_picks x USING cancelled c
 WHERE (x.provider,x.site_key,x.reference)=(c.provider,c.site_key,c.reference);
 GET DIAGNOSTICS n=ROW_COUNT;
 RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.mp_commerce_pick(jsonb),public.mp_commerce_package_tracking(jsonb),
 public.mp_commerce_dispatch(text,text,text),public.mp_commerce_release_picks() FROM PUBLIC;

CREATE FUNCTION public.mp_commerce_guard_picked_product() RETURNS trigger LANGUAGE plpgsql
SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN
 IF NEW.storage_location_id IS DISTINCT FROM OLD.storage_location_id AND EXISTS(
   SELECT 1 FROM public.mp_commerce_picks x JOIN public.mp_commerce_packages k USING(provider,site_key,reference)
   WHERE x.product_id=OLD.nocopk AND k.state='packing'
   AND k.reference IS DISTINCT FROM current_setting('rootedops.dispatch_reference',true)) THEN
   RAISE EXCEPTION 'Packed Woo product requires dispatch or cancellation before movement';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER mp_commerce_guard_picked_product BEFORE UPDATE OF storage_location_id ON public.products
FOR EACH ROW EXECUTE FUNCTION public.mp_commerce_guard_picked_product();
CREATE FUNCTION public.mp_commerce_guard_legacy_pick() RETURNS trigger LANGUAGE plpgsql
SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN
 PERFORM pg_advisory_xact_lock(520052);
 IF EXISTS(SELECT 1 FROM public.mp_commerce_picks WHERE product_id=NEW.products_id) THEN
   RAISE EXCEPTION 'Product belongs to a Woo package';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER mp_commerce_guard_legacy_pick BEFORE INSERT ON public._m2m_products_ecommerce_orders_ecommerce_orders
FOR EACH ROW EXECUTE FUNCTION public.mp_commerce_guard_legacy_pick();
CREATE TRIGGER mp_commerce_guard_legacy_pick BEFORE INSERT ON public._m2m_ecommerce_orders_products_products
FOR EACH ROW EXECUTE FUNCTION public.mp_commerce_guard_legacy_pick();
COMMIT;
