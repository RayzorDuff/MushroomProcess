-- Standalone Ecwid correction. Requires 026/027/051/052, NOT 054-057.
BEGIN;
SET LOCAL lock_timeout='10s';
SELECT pg_advisory_xact_lock(520052);
DO $$ BEGIN
 IF to_regprocedure('public.mp_ecommerce_ecwid_catalog_sync_candidates()') IS NULL
 OR to_regprocedure('public.mp_ecommerce_catalog_inventory()') IS NULL
 OR to_regprocedure('public.mp_commerce_inventory()') IS NULL
 OR to_regclass('public.mp_commerce_reservations') IS NULL THEN
  RAISE EXCEPTION '058 requires installed catalog and reservation functions; do not deploy the Woo stack to satisfy this check';
 END IF;
END $$;
CREATE TEMP TABLE mp_inventory_before_058 AS
 SELECT c.ecommerce_id,c.external_product_id,c.external_sku,c.desired_quantity gross,n.available_quantity net
 FROM public.mp_ecommerce_catalog_inventory() c JOIN public.mp_commerce_inventory() n USING(ecommerce_id);
CREATE TABLE IF NOT EXISTS public.mp_inventory_058_backup(name text PRIMARY KEY, definition text NOT NULL,applied_definition text);
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM public.mp_inventory_058_backup b
 WHERE pg_get_functiondef(b.name::regprocedure) IS DISTINCT FROM coalesce(b.applied_definition,b.definition)) THEN
  RAISE EXCEPTION 'A tracked function changed after 058: review the later migration before reapplying'; END IF;
END $$;
INSERT INTO public.mp_inventory_058_backup(name,definition)
 SELECT p.oid::regprocedure::text,pg_get_functiondef(p.oid) FROM pg_proc p
 WHERE p.oid IN ('public.mp_ecommerce_ecwid_catalog_sync_candidates()'::regprocedure,
 'public.mp_ecommerce_catalog_inventory()'::regprocedure,'public.mp_commerce_inventory()'::regprocedure,
 'public.mp_commerce_ingest(jsonb)'::regprocedure)
 ON CONFLICT DO NOTHING;

-- Business identifiers, never numeric production IDs. These are specifications,
-- not stock overrides. Unlisted legacy items retain exact-item matching.
CREATE TABLE IF NOT EXISTS public.mp_inventory_item_rules (
 legacy_code text PRIMARY KEY, source_code text NOT NULL, size_kind text NOT NULL,
 size_value numeric NOT NULL CHECK(size_value>0), recipe_codes text[] NOT NULL);
INSERT INTO public.mp_inventory_item_rules VALUES
 ('SUB-CVG-5','SUB-CVG-BAG','lb',5,ARRAY['REC-SUB-CVG-V3']),
 ('SUB-MM75-7_5','SUB-HW-BAG','lb',7.5,ARRAY['REC-SUB-MM75']),
 ('MUSH-DRIED-1OZ','MUSH-DRIED','oz',1,ARRAY[]::text[])
 ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION public.mp_inventory_specs()
RETURNS TABLE(ecommerce_id bigint,pool_key text,source_item_id bigint,size_kind text,
 size_value numeric,recipe_codes text[],is_owner boolean)
LANGUAGE sql STABLE AS $$
 WITH specs AS (
 SELECT e.nocopk ecommerce_id,coalesce(src.nocopk,e.item_id) source_item_id,
 CASE WHEN r.legacy_code IS NULL AND EXISTS(SELECT 1 FROM public.mp_inventory_item_rules z WHERE z.source_code=i.item_id) THEN 'review' ELSE r.size_kind END size_kind,r.size_value,r.recipe_codes,
 jsonb_build_array(coalesce(r.source_code,i.item_id),CASE WHEN r.legacy_code IS NULL AND EXISTS(SELECT 1 FROM public.mp_inventory_item_rules z WHERE z.source_code=i.item_id) THEN 'review' ELSE r.size_kind END,r.size_value,r.recipe_codes,
 regexp_replace(lower(coalesce(e.status,'')),'[^a-z0-9]','','g'),e.strain_id)::text pool_key,
 lower(coalesce(nullif(trim(e.provider),''),'ecwid')) provider,e.is_primary_public_listing,
 coalesce(e.sync_enabled,e.sync_to_ecwid,false) AND coalesce(nullif(trim(e.external_sku),''),nullif(trim(e.ecwid_sku),'')) IS NOT NULL enabled
 FROM public.ecommerce e JOIN public.items i ON i.nocopk=e.item_id
 LEFT JOIN public.mp_inventory_item_rules r ON r.legacy_code=i.item_id
 LEFT JOIN public.items src ON src.item_id=r.source_code
 ), ranked AS (
 SELECT *,row_number() OVER(PARTITION BY pool_key ORDER BY
 CASE WHEN enabled THEN 0 ELSE 1 END,CASE WHEN is_primary_public_listing IS FALSE THEN 1 ELSE 0 END,ecommerce_id) rank
 FROM specs)
 SELECT ecommerce_id,pool_key,source_item_id,size_kind,size_value,recipe_codes,enabled AND rank=1 FROM ranked;
$$;
CREATE OR REPLACE FUNCTION public.mp_inventory_location_eligible(p_id bigint)
RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT coalesce((SELECT active IS DISTINCT FROM false
 AND coalesce(name,'')<>'' AND lower(coalesce(type,'')) NOT IN ('terminal','exception')
 AND regexp_replace(lower(name),'[^a-z0-9]','','g') !~
 '(shipped|expired|consumed|compost|retired|missing|contaminated|inviable|invalid|quarantine)'
 FROM public.locations WHERE nocopk=p_id),false);
$$;
CREATE OR REPLACE FUNCTION public.mp_inventory_product_size(p public.products,k text,n numeric)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
 SELECT CASE k
 WHEN 'oz' THEN p.net_weight_oz=n
   AND (p.net_weight_g IS NULL OR abs(p.net_weight_g-n*28.349523125)<=0.11)
   AND (nullif(trim(p.package_size),'') IS NULL OR
        regexp_replace(lower(p.package_size),'[[:space:]]','','g') IN (n::text||'oz',trim(trailing '.' FROM trim(trailing '0' FROM n::text))||'oz'))
 WHEN 'lb' THEN abs(coalesce(p.net_weight_oz*28.349523125,p.net_weight_g)-n*453.59237)<=0.11
 ELSE false END;
$$;
CREATE OR REPLACE FUNCTION public.mp_inventory_units()
RETURNS TABLE(pool_key text,kind text,unit_id bigint,eligible boolean,shipped boolean)
LANGUAGE sql STABLE AS $$
 WITH specs AS (SELECT DISTINCT s.pool_key,s.source_item_id,s.size_kind,s.size_value,s.recipe_codes,
 e.item_id,e.strain_id,regexp_replace(lower(coalesce(e.status,'')),'[^a-z0-9]','','g') stage
 FROM public.mp_inventory_specs() s JOIN public.ecommerce e ON e.nocopk=s.ecommerce_id
 WHERE EXISTS(SELECT 1 FROM public.mp_inventory_specs() owner WHERE owner.pool_key=s.pool_key AND owner.is_owner)),
 units AS (
 SELECT s.pool_key,'product'::text kind,p.nocopk unit_id,
 (p.use_by IS NULL OR p.use_by>=CURRENT_DATE) AND public.mp_inventory_location_eligible(p.storage_location_id) eligible,
 regexp_replace(lower(coalesce(loc.name,'')),'[^a-z0-9]','','g')='shipped' shipped
 FROM specs s JOIN public.products p ON p.item_id IN(s.item_id,s.source_item_id)
 AND p.strain_id IS NOT DISTINCT FROM s.strain_id
 LEFT JOIN public.locations loc ON loc.nocopk=p.storage_location_id
 WHERE s.size_kind IS NULL OR ((public.mp_inventory_product_size(p,s.size_kind,s.size_value)
 OR (p.item_id=s.item_id AND s.size_kind='oz' AND p.net_weight_oz IS NULL
 AND nullif(trim(p.package_size),'') IS NULL AND (p.net_weight_g IS NULL OR abs(p.net_weight_g-s.size_value*28.349523125)<=0.5)))
 AND (cardinality(s.recipe_codes)=0 OR EXISTS (
 SELECT 1 FROM public._m2m_products_lots_origin_lots m JOIN public.lots l ON l.nocopk=m.lots_id
 JOIN public.recipes r ON r.nocopk=l.recipe_id
 WHERE m.products_id=p.nocopk AND r.recipe_id=ANY(s.recipe_codes)
 AND l.unit_size=s.size_value
 AND ((s.stage='pasteurized' AND lower(coalesce(p.process_type_mat,'')) LIKE '%pasteur%')
 OR (s.stage='sterilized' AND lower(coalesce(p.process_type_mat,'')) LIKE '%steril%')))))
 UNION ALL
 SELECT s.pool_key,'lot',l.nocopk,
 (l.use_by IS NULL OR l.use_by>=CURRENT_DATE) AND l.retired_at IS NULL
 AND coalesce(l.qty,1)=1 AND public.mp_inventory_location_eligible(l.location_id)
 AND NOT EXISTS(SELECT 1 FROM public._m2m_products_lots_origin_lots m WHERE m.lots_id=l.nocopk),
 regexp_replace(lower(coalesce(loc.name,'')),'[^a-z0-9]','','g')='shipped'
 FROM specs s JOIN public.lots l ON l.item_id IN(s.item_id,s.source_item_id)
 AND l.strain_id IS NOT DISTINCT FROM s.strain_id
 LEFT JOIN public.locations loc ON loc.nocopk=l.location_id
 LEFT JOIN public.recipes r ON r.nocopk=l.recipe_id
 WHERE (s.size_kind IS NULL OR (s.size_kind='lb' AND l.unit_size=s.size_value
 AND ((l.item_id=s.item_id AND l.recipe_id IS NULL) OR r.recipe_id=ANY(s.recipe_codes))))
 AND CASE s.stage
 WHEN 'sterilized' THEN regexp_replace(lower(coalesce(l.status,'')),'[^a-z0-9]','','g') IN('sterilized','sealed')
 WHEN 'pasteurized' THEN regexp_replace(lower(coalesce(l.status,'')),'[^a-z0-9]','','g')='pasteurized'
 WHEN 'fullycolonized' THEN regexp_replace(lower(coalesce(l.status,'')),'[^a-z0-9]','','g') IN('fullycolonized','fridge','coldshock')
 WHEN 'inoculated' THEN regexp_replace(lower(coalesce(l.status,'')),'[^a-z0-9]','','g') IN('inoculated','colonizing') ELSE false END)
 SELECT DISTINCT u.pool_key,u.kind,u.unit_id,
 u.eligible AND NOT EXISTS(SELECT 1 FROM units other WHERE other.kind=u.kind
 AND other.unit_id=u.unit_id AND other.pool_key<>u.pool_key AND other.eligible),u.shipped FROM units u;
$$;

CREATE OR REPLACE FUNCTION public.mp_ecommerce_catalog_inventory()
RETURNS TABLE(ecommerce_id bigint,erp_item_code text,ecommerce_name text,ecommerce_status text,
 item_id bigint,strain_id bigint,provider text,site_key text,external_sku text,upc text,
 external_product_id text,external_variation_id text,available_from_products bigint,
 available_from_lots bigint,desired_quantity bigint)
LANGUAGE sql STABLE AS $$
 SELECT e.nocopk,e.erp_item_code,e.name,e.status,e.item_id,e.strain_id,
 coalesce(nullif(trim(e.provider),''),'ecwid'),coalesce(nullif(trim(e.site_key),''),'dank_mushrooms'),
 coalesce(nullif(trim(e.external_sku),''),nullif(trim(e.ecwid_sku),'')),
 public.mp_normalize_gtin_text(coalesce(nullif(e.upc,''),nullif(e.ecwid_upc,''))),e.external_product_id,e.external_variation_id,
 count(u.unit_id) FILTER(WHERE u.kind='product'),count(u.unit_id) FILTER(WHERE u.kind='lot'),count(u.unit_id)
 FROM public.mp_inventory_specs() s JOIN public.ecommerce e ON e.nocopk=s.ecommerce_id
 LEFT JOIN public.mp_inventory_units() u ON u.pool_key=s.pool_key AND u.eligible
 WHERE coalesce(e.sync_enabled,e.sync_to_ecwid,false)
 AND coalesce(nullif(trim(e.external_sku),''),nullif(trim(e.ecwid_sku),'')) IS NOT NULL
 GROUP BY e.nocopk ORDER BY e.nocopk;
$$;

-- Raw reservation item_id is retained for history; accounting joins the same
-- listing specification as the physical-unit query, including aliased listings.
CREATE OR REPLACE FUNCTION public.mp_inventory_reserved(p_ecommerce bigint)
RETURNS bigint LANGUAGE sql STABLE AS $$
 SELECT coalesce(sum(r.quantity),0)::bigint FROM public.mp_commerce_reservations r
 JOIN public.mp_inventory_specs() held ON held.ecommerce_id=r.ecommerce_id
 JOIN public.mp_inventory_specs() target ON target.ecommerce_id=p_ecommerce AND target.pool_key=held.pool_key;
$$;
CREATE OR REPLACE FUNCTION public.mp_inventory_ecwid_order_units()
RETURNS TABLE(order_id text,site_key text,pool_key text,ordered bigint,dispatched bigint,open_order boolean)
LANGUAGE plpgsql STABLE AS $$
DECLARE o record;line jsonb;body jsonb;qty bigint;key text;keys text[];ids bigint[]; shipped_count bigint;
BEGIN
 FOR o IN SELECT * FROM public.ecommerce_orders
 WHERE lower(coalesce(nullif(trim(provider),''),'ecwid'))='ecwid'
 AND coalesce(nullif(ecwid_order_id,''),nullif(external_order_id,'')) IS NOT NULL
 AND upper(coalesce(payment_status,'')) NOT IN ('CANCELLED','CANCELED','REFUNDED','INCOMPLETE','FAILED') LOOP
  IF nullif(trim(o.items_json),'') IS NULL THEN
   IF upper(coalesce(o.status,'')) NOT IN ('SHIPPED','DELIVERED','WILL_NOT_DELIVER','RETURNED') THEN
    RAISE EXCEPTION 'Open Ecwid order without items: inventory review required';
   END IF;
   CONTINUE;
  END IF;
  BEGIN body:=o.items_json::jsonb;
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'Invalid Ecwid order items: inventory review required'; END;
  IF jsonb_typeof(body)<>'array' THEN RAISE EXCEPTION 'Ecwid item array required'; END IF;
  keys:=ARRAY[]::text[];
  -- Match every line once, even when historical/overlapping listings share it.
  DECLARE totals jsonb := '{}'::jsonb; matched text[]; item_key text;
  BEGIN
   FOR line IN SELECT value FROM jsonb_array_elements(body) LOOP
    SELECT array_agg(DISTINCT s.pool_key) INTO matched
    FROM public.ecommerce e JOIN public.mp_inventory_specs() s ON s.ecommerce_id=e.nocopk
    WHERE coalesce(nullif(line->>'sku',''),'#')=coalesce(nullif(e.external_sku,''),nullif(e.ecwid_sku,''))
    AND lower(coalesce(nullif(e.provider,''),'ecwid'))='ecwid'
    AND coalesce(nullif(e.site_key,''),'dank_mushrooms')=coalesce(nullif(o.site_key,''),'dank_mushrooms');
    IF matched IS NULL THEN CONTINUE; END IF;
    IF cardinality(matched)<>1 OR coalesce(line->>'quantity','') !~ '^[0-9]+$' THEN
     RAISE EXCEPTION 'Ambiguous Ecwid line or quantity requires inventory review'; END IF;
    key:=matched[1];
    totals:=totals||jsonb_build_object(key,coalesce((totals->>key)::bigint,0)+(line->>'quantity')::bigint);
   END LOOP;
   FOR key,item_key IN SELECT * FROM jsonb_each_text(totals) LOOP
    qty:=item_key::bigint;
   SELECT count(DISTINCT u.unit_id) INTO shipped_count
    FROM public._m2m_products_ecommerce_orders_ecommerce_orders m
    JOIN public.mp_inventory_units() u ON u.kind='product' AND u.unit_id=m.products_id
    WHERE m.ecommerce_orders_id=o.nocopk AND u.pool_key=key AND u.shipped;
   order_id:=coalesce(nullif(o.external_order_id,''),o.ecwid_order_id,o.nocopk::text);
   site_key:=coalesce(nullif(o.site_key,''),'dank_mushrooms');pool_key:=key;ordered:=qty;
   dispatched:=least(qty,shipped_count);
   open_order:=upper(coalesce(o.status,'')) NOT IN ('SHIPPED','DELIVERED','WILL_NOT_DELIVER','RETURNED');
   RETURN NEXT;
   END LOOP;
  END;
 END LOOP;
END $$;
CREATE OR REPLACE FUNCTION public.mp_inventory_legacy_hold(p_ecommerce bigint)
RETURNS bigint LANGUAGE sql STABLE AS $$
 SELECT coalesce(sum(greatest(0,o.ordered-o.dispatched)),0)::bigint
 FROM public.mp_inventory_ecwid_order_units() o JOIN public.mp_inventory_specs() s
 ON s.ecommerce_id=p_ecommerce AND s.pool_key=o.pool_key
 WHERE o.open_order AND NOT EXISTS(SELECT 1 FROM public.mp_commerce_orders m
 WHERE m.provider='ecwid' AND m.site_key=o.site_key AND m.external_order_id=o.order_id);
$$;
CREATE OR REPLACE FUNCTION public.mp_commerce_inventory()
RETURNS TABLE(ecommerce_id bigint,available_quantity bigint) LANGUAGE sql STABLE AS $$
 SELECT c.ecommerce_id,CASE WHEN s.is_owner THEN greatest(0,c.desired_quantity
 -public.mp_inventory_reserved(c.ecommerce_id)-public.mp_inventory_legacy_hold(c.ecommerce_id)) ELSE 0 END::bigint
 FROM public.mp_ecommerce_catalog_inventory() c JOIN public.mp_inventory_specs() s USING(ecommerce_id);
$$;
CREATE OR REPLACE FUNCTION public.mp_ecommerce_ecwid_catalog_sync_candidates()
RETURNS TABLE(ecommerce_id bigint,ecommerce_name text,ecommerce_status text,item_id bigint,strain_id bigint,
 provider text,site_key text,external_sku text,upc text,external_product_id text,external_variation_id text,
 available_from_products bigint,available_from_lots bigint,desired_quantity bigint)
LANGUAGE sql STABLE AS $$
 SELECT c.ecommerce_id,c.ecommerce_name,c.ecommerce_status,c.item_id,c.strain_id,c.provider,c.site_key,
 c.external_sku,c.upc,c.external_product_id,c.external_variation_id,c.available_from_products,
 c.available_from_lots,n.available_quantity
 FROM public.mp_ecommerce_catalog_inventory() c JOIN public.mp_commerce_inventory() n USING(ecommerce_id)
 WHERE lower(c.provider)='ecwid';
$$;

-- Preserve the installed 052 OR 054 intake implementation and its permissions.
-- Only replace its known reservation predicate. Unknown installed code stops.
DO $$ DECLARE definition text; updated text;
BEGIN
 SELECT pg_get_functiondef('public.mp_commerce_ingest(jsonb)'::regprocedure) INTO definition;
 IF position('mp_inventory_reserved(candidate.ecommerce_id)' IN definition)>0 THEN RETURN; END IF;
 updated:=regexp_replace(definition,
 'SELECT coalesce\(sum\(quantity\),0\) INTO reserved FROM public.mp_commerce_reservations[[:space:]]+WHERE item_id=candidate.item_id AND strain_id IS NOT DISTINCT FROM candidate.strain_id;',
 'SELECT public.mp_inventory_reserved(candidate.ecommerce_id)+public.mp_inventory_legacy_hold(candidate.ecommerce_id) INTO reserved;','g');
 IF updated=definition THEN RAISE EXCEPTION 'Unrecognized installed intake reservation predicate; retain paused publication and review its definition'; END IF;
 EXECUTE updated;
END $$;

-- A delta basis excludes Ecwid's own pending holds: Ecwid already decrements at
-- checkout. Crediting a linked shipped unit offsets its later MP physical move.
CREATE OR REPLACE FUNCTION public.mp_ecwid_inventory_basis(p_id bigint)
RETURNS bigint LANGUAGE sql STABLE AS $$
 SELECT c.desired_quantity
 -(SELECT coalesce(sum(r.quantity),0) FROM public.mp_commerce_reservations r
 JOIN public.mp_inventory_specs() a ON a.ecommerce_id=r.ecommerce_id
 WHERE a.pool_key=s.pool_key AND r.provider<>'ecwid')
 +(SELECT coalesce(sum(o.dispatched),0) FROM public.mp_inventory_ecwid_order_units() o WHERE o.pool_key=s.pool_key)
 FROM public.mp_ecommerce_catalog_inventory() c JOIN public.mp_inventory_specs() s USING(ecommerce_id)
 WHERE c.ecommerce_id=p_id AND s.is_owner;
$$;
CREATE TABLE IF NOT EXISTS public.mp_ecwid_inventory_publications (
 ecommerce_id bigint PRIMARY KEY REFERENCES public.ecommerce(nocopk),
 external_product_id text NOT NULL,external_variation_id text,basis bigint NOT NULL,
 pending_token uuid,pending_basis bigint,pending_delta bigint,updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS public.mp_ecwid_inventory_receipts (
 token uuid PRIMARY KEY,ecommerce_id bigint NOT NULL REFERENCES public.ecommerce(nocopk),
 old_basis bigint NOT NULL,new_basis bigint NOT NULL,delta bigint NOT NULL,
 outcome text NOT NULL CHECK(outcome IN ('pending','applied','not_applied')),
 created_at timestamptz NOT NULL DEFAULT now(),resolved_at timestamptz);
CREATE OR REPLACE FUNCTION public.mp_ecwid_inventory_initialize(p_id bigint,p_confirmed_quantity bigint)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c record;n bigint;b bigint;
BEGIN
 PERFORM pg_advisory_xact_lock(520052);
 SELECT * INTO STRICT c FROM public.mp_ecommerce_ecwid_catalog_sync_candidates() WHERE ecommerce_id=p_id;
 SELECT available_quantity INTO STRICT n FROM public.mp_commerce_inventory() WHERE ecommerce_id=p_id;
 b:=public.mp_ecwid_inventory_basis(p_id);
 IF b IS NULL OR c.external_product_id IS NULL OR c.external_product_id !~ '^[0-9]+$'
 OR n IS DISTINCT FROM p_confirmed_quantity THEN RAISE EXCEPTION 'Fresh Ecwid readback must equal current reviewed net MP availability'; END IF;
 IF EXISTS(SELECT 1 FROM public.mp_ecwid_inventory_publications WHERE ecommerce_id=p_id) THEN
  RAISE EXCEPTION 'Publication baseline already exists: do not reset it after a sale'; END IF;
 INSERT INTO public.mp_ecwid_inventory_publications VALUES(p_id,c.external_product_id,c.external_variation_id,b,NULL,NULL,NULL,now());
 RETURN 'initialized';
END $$;
CREATE OR REPLACE FUNCTION public.mp_ecwid_inventory_plan(p_id bigint)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c record;old public.mp_ecwid_inventory_publications%ROWTYPE;b bigint;t uuid;
BEGIN
 PERFORM pg_advisory_xact_lock(520052);
 SELECT * INTO c FROM public.mp_ecommerce_ecwid_catalog_sync_candidates() WHERE ecommerce_id=p_id;
 IF NOT FOUND THEN RETURN jsonb_build_object('status','review_disabled','ecommerce_id',p_id); END IF;
 SELECT * INTO old FROM public.mp_ecwid_inventory_publications WHERE ecommerce_id=p_id FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('status','review_baseline_required','ecommerce_id',p_id); END IF;
 IF old.pending_token IS NOT NULL THEN RETURN jsonb_build_object('status','review_unknown_outcome','ecommerce_id',p_id); END IF;
 IF old.external_product_id IS DISTINCT FROM c.external_product_id
 OR old.external_variation_id IS DISTINCT FROM c.external_variation_id THEN RAISE EXCEPTION 'Ecwid target identity drift'; END IF;
 IF EXISTS(SELECT 1 FROM public.ecommerce_orders WHERE upper(payment_status)='PARTIALLY_REFUNDED') THEN
  RAISE EXCEPTION 'Partial Ecwid refund requires inventory review'; END IF;
 IF EXISTS(SELECT 1 FROM public.mp_commerce_orders WHERE provider='ecwid') THEN
  RAISE EXCEPTION 'Ecwid ledger coexistence requires explicit reconciliation; do not double-count legacy shipments'; END IF;
 b:=public.mp_ecwid_inventory_basis(p_id);
 IF b IS NULL THEN RETURN jsonb_build_object('status','review_pool_owner','ecommerce_id',p_id); END IF;
 IF b=old.basis THEN RETURN jsonb_build_object('status','unchanged','ecommerce_id',p_id); END IF;
 t:=gen_random_uuid();
 INSERT INTO public.mp_ecwid_inventory_receipts(token,ecommerce_id,old_basis,new_basis,delta,outcome) VALUES(t,p_id,old.basis,b,b-old.basis,'pending');
 UPDATE public.mp_ecwid_inventory_publications SET pending_token=t,pending_basis=b,pending_delta=b-old.basis WHERE ecommerce_id=p_id;
 RETURN jsonb_build_object('status','ready','ecommerce_id',p_id,'token',t,'quantityDelta',b-old.basis,
 'external_product_id',c.external_product_id,'external_variation_id',c.external_variation_id);
END $$;
CREATE OR REPLACE FUNCTION public.mp_ecwid_inventory_initial_plan(p_id bigint,p_external_quantity bigint)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c record;n bigint;b bigint;
BEGIN
 PERFORM pg_advisory_xact_lock(520052);
 IF p_external_quantity<0 THEN RAISE EXCEPTION 'Nonnegative Ecwid readback required'; END IF;
 SELECT * INTO STRICT c FROM public.mp_ecommerce_ecwid_catalog_sync_candidates() WHERE ecommerce_id=p_id;
 SELECT available_quantity INTO STRICT n FROM public.mp_commerce_inventory() WHERE ecommerce_id=p_id;
 b:=public.mp_ecwid_inventory_basis(p_id);
 IF b IS NULL OR c.external_product_id IS NULL OR c.external_product_id !~ '^[0-9]+$' THEN
  RAISE EXCEPTION 'Reviewed numeric Ecwid owner mapping required'; END IF;
 IF EXISTS(SELECT 1 FROM public.mp_ecwid_inventory_publications WHERE ecommerce_id=p_id) THEN
  RAISE EXCEPTION 'Baseline already exists: inspect receipts instead of initializing again'; END IF;
 INSERT INTO public.mp_ecwid_inventory_publications VALUES(p_id,c.external_product_id,c.external_variation_id,
 b-(n-p_external_quantity),NULL,NULL,NULL,now());
 RETURN public.mp_ecwid_inventory_plan(p_id);
END $$;
CREATE OR REPLACE FUNCTION public.mp_ecwid_inventory_resolve(p_token uuid,p_outcome text)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE old public.mp_ecwid_inventory_publications%ROWTYPE; prior text;
BEGIN
 PERFORM pg_advisory_xact_lock(520052);
 IF p_outcome NOT IN ('applied','not_applied') THEN RAISE EXCEPTION 'Verified outcome required'; END IF;
 SELECT outcome INTO STRICT prior FROM public.mp_ecwid_inventory_receipts WHERE token=p_token FOR UPDATE;
 IF prior=p_outcome THEN RETURN 'duplicate'; END IF;
 IF prior<>'pending' THEN RAISE EXCEPTION 'Receipt outcome cannot change'; END IF;
 SELECT * INTO STRICT old FROM public.mp_ecwid_inventory_publications WHERE pending_token=p_token FOR UPDATE;
 UPDATE public.mp_ecwid_inventory_publications SET basis=CASE WHEN p_outcome='applied' THEN pending_basis ELSE basis END,
 pending_token=NULL,pending_basis=NULL,pending_delta=NULL,updated_at=now() WHERE ecommerce_id=old.ecommerce_id;
 UPDATE public.mp_ecwid_inventory_receipts SET outcome=p_outcome,resolved_at=now() WHERE token=p_token;
 RETURN p_outcome;
END $$;
REVOKE ALL ON FUNCTION public.mp_ecwid_inventory_initial_plan(bigint,bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mp_ecwid_inventory_initialize(bigint,bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mp_ecwid_inventory_plan(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mp_ecwid_inventory_resolve(uuid,text) FROM PUBLIC;
UPDATE public.mp_inventory_058_backup SET applied_definition=pg_get_functiondef(name::regprocedure);
SELECT c.ecommerce_id,c.external_product_id,c.external_sku,b.gross AS before_gross,
 b.net AS before_net,c.desired_quantity AS after_gross,n.available_quantity AS after_net,
 s.is_owner,c.desired_quantity-n.available_quantity AS holds_or_suppressed
 FROM public.mp_ecommerce_catalog_inventory() c JOIN public.mp_commerce_inventory() n USING(ecommerce_id)
 JOIN public.mp_inventory_specs() s USING(ecommerce_id) LEFT JOIN mp_inventory_before_058 b USING(ecommerce_id)
 ORDER BY c.ecommerce_id;
DROP TABLE mp_inventory_before_058;
COMMIT;
