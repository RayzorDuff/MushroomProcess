-- Independent of the unfinished Woo stack: requires installed inventory 058.
BEGIN;
SET LOCAL lock_timeout='10s';
SELECT pg_advisory_xact_lock(520052);
DO $$ BEGIN
 IF to_regprocedure('public.mp_inventory_units()') IS NULL THEN RAISE EXCEPTION 'Apply reviewed inventory 058 first'; END IF;
END $$;
CREATE TABLE IF NOT EXISTS public.mp_fulfillment_allocations (
 product_id bigint PRIMARY KEY REFERENCES public.products(nocopk),
 order_id bigint NOT NULL REFERENCES public.ecommerce_orders(nocopk),
 line_id text NOT NULL,pool_key text NOT NULL,operator text NOT NULL,
 allocated_at timestamptz NOT NULL DEFAULT now(),dispatched_at timestamptz,
 movement_reference text
);
CREATE TABLE IF NOT EXISTS public.mp_fulfillment_dispatches (
 reference text PRIMARY KEY,order_id bigint NOT NULL REFERENCES public.ecommerce_orders(nocopk),
 product_ids bigint[] NOT NULL,operator text NOT NULL,committed_at timestamptz NOT NULL DEFAULT now(),result jsonb NOT NULL
);
CREATE OR REPLACE FUNCTION public.mp_fulfillment_lines(p_order bigint)
RETURNS TABLE(line_id text,name text,sku text,quantity bigint,pool_key text) LANGUAGE sql STABLE AS $$
 SELECT coalesce(nullif(x.line->>'id',''),x.idx::text),coalesce(x.line->>'name',''),x.line->>'sku',
 CASE WHEN coalesce(x.line->>'quantity','') ~ '^[1-9][0-9]*$' THEN (x.line->>'quantity')::bigint ELSE 0 END,
 CASE WHEN count(DISTINCT s.pool_key)=1 THEN min(s.pool_key) END
 FROM public.ecommerce_orders o
 CROSS JOIN LATERAL jsonb_array_elements(coalesce(nullif(o.items_json,''),'[]')::jsonb) WITH ORDINALITY x(line,idx)
 LEFT JOIN public.ecommerce e ON coalesce(nullif(e.external_sku,''),e.ecwid_sku)=x.line->>'sku'
 AND coalesce(nullif(e.provider,''),'ecwid')=coalesce(nullif(o.provider,''),'ecwid')
 AND coalesce(nullif(e.site_key,''),'dank_mushrooms')=coalesce(nullif(o.site_key,''),'dank_mushrooms')
 LEFT JOIN public.mp_inventory_specs() s ON s.ecommerce_id=e.nocopk AND s.size_kind IS DISTINCT FROM 'review'
 WHERE o.nocopk=p_order GROUP BY o.nocopk,x.line,x.idx ORDER BY x.idx;
$$;
CREATE OR REPLACE FUNCTION public.mp_fulfillment_product_eligible(p_product bigint) RETURNS boolean LANGUAGE plpgsql STABLE AS $$
DECLARE claimed boolean;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.products p JOIN public.mp_inventory_units() u ON u.kind='product' AND u.unit_id=p.nocopk
 WHERE p.nocopk=p_product AND nullif(p.product_id,'') IS NOT NULL AND u.eligible) THEN RETURN false; END IF;
 IF EXISTS(SELECT 1 FROM public._m2m_products_ecommerce_orders_ecommerce_orders WHERE products_id=p_product)
 OR EXISTS(SELECT 1 FROM public._m2m_ecommerce_orders_products_products WHERE products_id=p_product)
 OR EXISTS(SELECT 1 FROM public.mp_fulfillment_allocations WHERE product_id=p_product) THEN RETURN false; END IF;
 IF to_regclass('public.mp_commerce_picks') IS NOT NULL THEN
  EXECUTE 'SELECT EXISTS(SELECT 1 FROM public.mp_commerce_picks WHERE product_id=$1)' INTO claimed USING p_product;
  IF claimed THEN RETURN false; END IF;
 END IF;
 RETURN true;
END $$;
CREATE OR REPLACE FUNCTION public.mp_fulfillment_progress(p_order bigint) RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE lines jsonb;linked_total bigint;required bigint;ready bigint;shipped bigint;
BEGIN
 WITH linked AS (
  SELECT products_id FROM public._m2m_products_ecommerce_orders_ecommerce_orders WHERE ecommerce_orders_id=p_order
  UNION SELECT products_id FROM public._m2m_ecommerce_orders_products_products WHERE ecommerce_orders_id=p_order
 ), pools AS (
  SELECT DISTINCT l.products_id,u.pool_key FROM linked l JOIN public.mp_inventory_units() u ON u.kind='product' AND u.unit_id=l.products_id
 ), grouped AS (
  SELECT l.*,coalesce((SELECT count(*) FROM public.mp_fulfillment_allocations a WHERE a.order_id=p_order AND a.line_id=l.line_id),0) AS exact_count
  FROM public.mp_fulfillment_lines(p_order) l
 ), counted AS (
  SELECT g.*,g.exact_count+coalesce((SELECT count(*) FROM pools p WHERE p.pool_key=g.pool_key
   AND NOT EXISTS(SELECT 1 FROM public.mp_fulfillment_allocations a WHERE a.product_id=p.products_id)),0) AS assigned
  FROM grouped g
 )
 SELECT coalesce(jsonb_agg(jsonb_build_object('line_id',line_id,'name',name,'sku',sku,'quantity',quantity,
  'assigned_quantity',assigned,'remaining_quantity',greatest(0,quantity-assigned),'mapping_review',pool_key IS NULL)
  ORDER BY line_id),'[]'),coalesce(sum(quantity),0)
 INTO lines,required FROM counted;
 SELECT count(DISTINCT products_id) INTO linked_total FROM (
 SELECT products_id FROM public._m2m_products_ecommerce_orders_ecommerce_orders WHERE ecommerce_orders_id=p_order
 UNION SELECT products_id FROM public._m2m_ecommerce_orders_products_products WHERE ecommerce_orders_id=p_order) x;
 SELECT count(*) INTO ready FROM public.mp_fulfillment_allocations WHERE order_id=p_order AND dispatched_at IS NULL;
 SELECT count(DISTINCT x.products_id) INTO shipped FROM (
 SELECT products_id FROM public._m2m_products_ecommerce_orders_ecommerce_orders WHERE ecommerce_orders_id=p_order
 UNION SELECT products_id FROM public._m2m_ecommerce_orders_products_products WHERE ecommerce_orders_id=p_order) x
 JOIN public.mp_inventory_units() u ON u.kind='product' AND u.unit_id=x.products_id AND u.shipped;
 RETURN jsonb_build_object('items',lines,'linked_count',linked_total,'required_count',required,'ready_to_dispatch',ready,
 'shipped_count',shipped,'product_assignment_complete',required>0 AND linked_total>=required
 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(lines) l WHERE (l->>'remaining_quantity')::bigint>0 OR (l->>'mapping_review')::boolean),
 'can_dispatch',ready>0,'dispatch_complete',required>0 AND shipped>=required);
END $$;
CREATE OR REPLACE FUNCTION public.mp_fulfillment_search(p_order text,p_query text DEFAULT '',p_page integer DEFAULT 1,p_size integer DEFAULT 25,p_line text DEFAULT '')
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE oid bigint;result jsonb;page_no integer:=greatest(1,coalesce(p_page,1));page_size integer:=least(100,greatest(1,coalesce(p_size,25)));
BEGIN
 SELECT nocopk INTO STRICT oid FROM public.ecommerce_orders WHERE coalesce(airtable_id,nocopk::text)=p_order OR nocopk::text=p_order;
 WITH eligible AS MATERIALIZED (
 SELECT p.*,loc.name AS location_name FROM public.products p LEFT JOIN public.locations loc ON loc.nocopk=p.storage_location_id
 WHERE public.mp_fulfillment_product_eligible(p.nocopk)
 AND (coalesce(p_query,'')='' OR position(lower(p_query) IN lower(concat_ws(' ',p.product_id,p.name_mat,p.item_category_mat,p.notes)))>0)
 AND EXISTS(SELECT 1 FROM public.mp_fulfillment_lines(oid) l JOIN public.mp_inventory_units() u ON u.pool_key=l.pool_key AND u.kind='product' AND u.unit_id=p.nocopk AND u.eligible
  JOIN LATERAL jsonb_array_elements(public.mp_fulfillment_progress(oid)->'items') progress ON progress->>'line_id'=l.line_id
  WHERE (p_line='' OR l.line_id=p_line) AND (progress->>'remaining_quantity')::bigint>0)
 ), page AS (SELECT * FROM eligible ORDER BY nocopk LIMIT page_size OFFSET (page_no-1)*page_size)
 SELECT jsonb_build_object('ok',true,'products',coalesce((SELECT jsonb_agg(jsonb_build_object(
 'airtable_record_id',coalesce(airtable_id,nocopk::text),'product_id',product_id,'name_mat',name_mat,
 'unit_size',coalesce(net_weight_oz,net_weight_g,net_volume_ml),'item_category_mat',item_category_mat,
 'storage_location_name',location_name,'notes',notes) ORDER BY nocopk) FROM page),'[]'),
 'count',(SELECT count(*) FROM eligible),'page',page_no,'page_size',page_size,
 'has_next',(SELECT count(*) FROM eligible)>page_no*page_size) INTO result;
 RETURN result;
END $$;
CREATE OR REPLACE FUNCTION public.mp_fulfillment_assign(p_order text,p_product text,p_operator text,p_line text DEFAULT '') RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE o public.ecommerce_orders%ROWTYPE;p public.products%ROWTYPE;l record;old public.mp_fulfillment_allocations%ROWTYPE;progress jsonb;
BEGIN
 PERFORM pg_advisory_xact_lock(520052);
 IF nullif(trim(p_operator),'') IS NULL OR p_operator='system' THEN RAISE EXCEPTION 'Named operator required'; END IF;
 SELECT * INTO STRICT o FROM public.ecommerce_orders WHERE coalesce(airtable_id,nocopk::text)=p_order OR nocopk::text=p_order FOR UPDATE;
 SELECT * INTO STRICT p FROM public.products WHERE coalesce(airtable_id,nocopk::text)=p_product OR nocopk::text=p_product FOR UPDATE;
 SELECT * INTO old FROM public.mp_fulfillment_allocations WHERE product_id=p.nocopk;
 IF FOUND THEN
  IF old.order_id=o.nocopk AND (p_line='' OR p_line=old.line_id) THEN RETURN jsonb_build_object('ok',true,'status','duplicate','progress',public.mp_fulfillment_progress(o.nocopk)); END IF;
  RAISE EXCEPTION 'Product assigned elsewhere';
 END IF;
 IF upper(coalesce(o.status,'')) IN('SHIPPED','DELIVERED','WILL_NOT_DELIVER','RETURNED','CANCELLED') THEN RAISE EXCEPTION 'Closed order cannot receive products'; END IF;
 IF o.provider='woocommerce' THEN RAISE EXCEPTION 'Use the Woo package/dispatch interface for Woo ledger orders'; END IF;
 IF NOT public.mp_fulfillment_product_eligible(p.nocopk) THEN RAISE EXCEPTION 'Product no longer eligible or assigned elsewhere'; END IF;
 progress:=public.mp_fulfillment_progress(o.nocopk);
 IF p_line='' AND EXISTS(SELECT 1 FROM public.mp_fulfillment_lines(o.nocopk) a JOIN public.mp_fulfillment_lines(o.nocopk) b
 ON a.pool_key=b.pool_key AND a.line_id<>b.line_id) THEN RAISE EXCEPTION 'Select the exact order line for overlapping items'; END IF;
 SELECT a.* INTO STRICT l FROM public.mp_fulfillment_lines(o.nocopk) a
 JOIN LATERAL jsonb_array_elements(progress->'items') v ON v->>'line_id'=a.line_id
 WHERE (p_line='' OR a.line_id=p_line) AND (v->>'remaining_quantity')::bigint>0
 AND EXISTS(SELECT 1 FROM public.mp_inventory_units() u WHERE u.kind='product' AND u.unit_id=p.nocopk AND u.pool_key=a.pool_key AND u.eligible);
 INSERT INTO public.mp_fulfillment_allocations(product_id,order_id,line_id,pool_key,operator) VALUES(p.nocopk,o.nocopk,l.line_id,l.pool_key,p_operator);
 INSERT INTO public._m2m_products_ecommerce_orders_ecommerce_orders(products_id,ecommerce_orders_id) VALUES(p.nocopk,o.nocopk);
 RETURN jsonb_build_object('ok',true,'status','assigned','message','Product allocated; dispatch separately.','progress',public.mp_fulfillment_progress(o.nocopk));
END $$;
CREATE OR REPLACE FUNCTION public.mp_fulfillment_dispatch(p_order text,p_reference text,p_operator text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE oid bigint;ids bigint[];pid bigint;ship bigint;result jsonb;prior public.mp_fulfillment_dispatches%ROWTYPE;
BEGIN
 PERFORM pg_advisory_xact_lock(520052);
 IF nullif(trim(p_operator),'') IS NULL OR p_operator='system' OR length(coalesce(p_reference,'')) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'Named operator and stable movement reference required'; END IF;
 SELECT nocopk INTO STRICT oid FROM public.ecommerce_orders WHERE coalesce(airtable_id,nocopk::text)=p_order OR nocopk::text=p_order FOR UPDATE;
 SELECT * INTO prior FROM public.mp_fulfillment_dispatches WHERE reference=p_reference;
 IF FOUND THEN
  IF prior.order_id<>oid THEN RAISE EXCEPTION 'Movement reference belongs to another order'; END IF;
  RETURN prior.result||'{"status":"duplicate"}'::jsonb;
 END IF;
 IF EXISTS(SELECT 1 FROM public.ecommerce_orders WHERE nocopk=oid AND upper(coalesce(status,'')) IN('WILL_NOT_DELIVER','RETURNED','CANCELLED')) THEN RAISE EXCEPTION 'Cancelled order requires release, not dispatch'; END IF;
 SELECT array_agg(product_id ORDER BY product_id) INTO ids FROM public.mp_fulfillment_allocations WHERE order_id=oid AND dispatched_at IS NULL;
 IF ids IS NULL THEN RAISE EXCEPTION 'No allocated units await dispatch'; END IF;
 SELECT nocopk INTO STRICT ship FROM public.locations WHERE active AND regexp_replace(lower(name),'[^a-z0-9]','','g')='shipped';
 FOREACH pid IN ARRAY ids LOOP
  PERFORM 1 FROM public.products WHERE nocopk=pid FOR UPDATE;
  IF NOT EXISTS(SELECT 1 FROM public.mp_inventory_units() u JOIN public.mp_fulfillment_allocations a ON a.pool_key=u.pool_key
    WHERE a.product_id=pid AND a.order_id=oid AND u.kind='product' AND u.unit_id=pid AND u.eligible) THEN RAISE EXCEPTION 'Allocated unit moved, expired or changed specification'; END IF;
  PERFORM set_config('rootedops.legacy_dispatch','true',true);
  PERFORM public.mp_product_set_storage_location(pid,ship);
  PERFORM set_config('rootedops.legacy_dispatch','false',true);
  INSERT INTO public.events(product_id,type,timestamp,operator,station,fields_json)
   VALUES(pid,'fulfillment_dispatch',now(),p_operator,'Fulfillment',jsonb_build_object('reference',p_reference,'order_id',oid)::text);
 END LOOP;
 UPDATE public.mp_fulfillment_allocations SET dispatched_at=now(),movement_reference=p_reference WHERE product_id=ANY(ids);
 result:=jsonb_build_object('ok',true,'status','dispatched','reference',p_reference,'product_ids',to_jsonb(ids),'progress',public.mp_fulfillment_progress(oid));
 INSERT INTO public.mp_fulfillment_dispatches(reference,order_id,product_ids,operator,result) VALUES(p_reference,oid,ids,p_operator,result);
 IF (result->'progress'->>'dispatch_complete')::boolean THEN UPDATE public.ecommerce_orders SET status='SHIPPED',nc_updated_at=now() WHERE nocopk=oid; END IF;
 RETURN result;
END $$;
CREATE OR REPLACE FUNCTION public.mp_fulfillment_release(p_order bigint,p_operator text) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE ids bigint[];
BEGIN
 PERFORM pg_advisory_xact_lock(520052);
 IF NOT EXISTS(SELECT 1 FROM public.ecommerce_orders WHERE nocopk=p_order
 AND (upper(coalesce(status,'')) IN('CANCELLED','WILL_NOT_DELIVER','RETURNED') OR upper(coalesce(payment_status,'')) IN('CANCELLED','CANCELED','REFUNDED'))) THEN
  RAISE EXCEPTION 'Only cancelled/refunded unshipped allocations may be released'; END IF;
 SELECT array_agg(product_id) INTO ids FROM public.mp_fulfillment_allocations WHERE order_id=p_order AND dispatched_at IS NULL;
 IF ids IS NULL THEN RETURN 0; END IF;
 INSERT INTO public.events(product_id,type,timestamp,operator,station,fields_json)
 SELECT unnest(ids),'fulfillment_release',now(),p_operator,'Fulfillment',jsonb_build_object('order_id',p_order)::text;
 DELETE FROM public._m2m_products_ecommerce_orders_ecommerce_orders WHERE ecommerce_orders_id=p_order AND products_id=ANY(ids);
 DELETE FROM public._m2m_ecommerce_orders_products_products WHERE ecommerce_orders_id=p_order AND products_id=ANY(ids);
 DELETE FROM public.mp_fulfillment_allocations WHERE order_id=p_order AND product_id=ANY(ids);
 RETURN cardinality(ids);
END $$;
CREATE OR REPLACE FUNCTION public.mp_fulfillment_cancel_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF upper(coalesce(NEW.status,'')) IN('CANCELLED','WILL_NOT_DELIVER','RETURNED') OR upper(coalesce(NEW.payment_status,'')) IN('CANCELLED','CANCELED','REFUNDED') THEN
  PERFORM public.mp_fulfillment_release(NEW.nocopk,'order-cancellation');
 END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS mp_fulfillment_release_cancelled ON public.ecommerce_orders;
CREATE TRIGGER mp_fulfillment_release_cancelled AFTER UPDATE OF status,payment_status ON public.ecommerce_orders
 FOR EACH ROW EXECUTE FUNCTION public.mp_fulfillment_cancel_guard();
CREATE OR REPLACE FUNCTION public.mp_fulfillment_guard_allocated_product() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.storage_location_id IS DISTINCT FROM OLD.storage_location_id AND EXISTS(SELECT 1 FROM public.mp_fulfillment_allocations
 WHERE product_id=OLD.nocopk AND dispatched_at IS NULL)
 AND current_setting('rootedops.legacy_dispatch',true) IS DISTINCT FROM 'true' THEN
  RAISE EXCEPTION 'Allocated product requires dispatch or cancellation before movement';
 END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS mp_fulfillment_guard_allocated_product ON public.products;
CREATE TRIGGER mp_fulfillment_guard_allocated_product BEFORE UPDATE OF storage_location_id ON public.products
 FOR EACH ROW EXECUTE FUNCTION public.mp_fulfillment_guard_allocated_product();
REVOKE ALL ON FUNCTION public.mp_fulfillment_release(bigint,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mp_fulfillment_assign(text,text,text,text),public.mp_fulfillment_dispatch(text,text,text) FROM PUBLIC;
COMMIT;
