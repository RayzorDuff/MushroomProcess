-- Performance only: preserve eligibility, allocations, movement and identities.
BEGIN;
SET LOCAL lock_timeout='10s';
SELECT pg_advisory_xact_lock(520052);
CREATE TABLE IF NOT EXISTS public.mp_fulfillment_063_backup (
 name text PRIMARY KEY,definition text NOT NULL,applied_definition text);
DO $$
DECLARE signature text;
BEGIN
 FOREACH signature IN ARRAY ARRAY[
  'public.mp_fulfillment_lines(bigint)',
  'public.mp_fulfillment_product_eligible(bigint)',
  'public.mp_fulfillment_progress(bigint)',
  'public.mp_fulfillment_search(text,text,integer,integer,text)',
  'public.mp_fulfillment_assign(text,text,text,text)',
  'public.mp_fulfillment_dispatch(text,text,text)',
  'public.mp_fulfillment_release(bigint,text)'
 ] LOOP
  IF to_regprocedure(signature) IS NULL THEN RAISE EXCEPTION '063 requires installed 060: %',signature; END IF;
  IF EXISTS(SELECT 1 FROM public.mp_fulfillment_063_backup b WHERE b.name=signature
   AND pg_get_functiondef(signature::regprocedure) IS DISTINCT FROM coalesce(b.applied_definition,b.definition)) THEN
   RAISE EXCEPTION 'Later fulfillment function change requires review: %',signature;
  END IF;
  INSERT INTO public.mp_fulfillment_063_backup(name,definition)
   VALUES(signature,pg_get_functiondef(signature::regprocedure)) ON CONFLICT DO NOTHING;
 END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.mp_fulfillment_search(
 p_order text,p_query text DEFAULT '',p_page integer DEFAULT 1,
 p_size integer DEFAULT 25,p_line text DEFAULT '')
RETURNS jsonb LANGUAGE plpgsql STABLE SET jit=off AS $$
DECLARE oid bigint;result jsonb;progress jsonb;claimed bigint[]:=ARRAY[]::bigint[];
 page_no integer:=greatest(1,coalesce(p_page,1));
 page_size integer:=least(100,greatest(1,coalesce(p_size,25)));
BEGIN
 SELECT nocopk INTO STRICT oid FROM public.ecommerce_orders
  WHERE coalesce(airtable_id,nocopk::text)=p_order OR nocopk::text=p_order;
 -- Once per request, not once per product candidate.
 progress:=public.mp_fulfillment_progress(oid);
 IF to_regclass('public.mp_commerce_picks') IS NOT NULL THEN
  EXECUTE 'SELECT coalesce(array_agg(product_id) FILTER(WHERE product_id IS NOT NULL),ARRAY[]::bigint[]) FROM public.mp_commerce_picks'
   INTO claimed;
 END IF;
 WITH inventory AS MATERIALIZED (
  SELECT pool_key,unit_id FROM public.mp_inventory_units()
   WHERE kind='product' AND eligible
 ), remaining AS MATERIALIZED (
  SELECT l.pool_key FROM public.mp_fulfillment_lines(oid) l
  JOIN jsonb_array_elements(progress->'items') v ON v->>'line_id'=l.line_id
  WHERE (p_line='' OR l.line_id=p_line) AND (v->>'remaining_quantity')::bigint>0
 ), candidates AS MATERIALIZED (
  SELECT DISTINCT u.unit_id FROM inventory u JOIN remaining r ON r.pool_key=u.pool_key
 ), eligible AS MATERIALIZED (
  SELECT p.*,loc.name AS location_name FROM candidates c
  JOIN public.products p ON p.nocopk=c.unit_id
  LEFT JOIN public.locations loc ON loc.nocopk=p.storage_location_id
  WHERE nullif(p.product_id,'') IS NOT NULL
   AND (coalesce(p_query,'')='' OR position(lower(p_query) IN lower(concat_ws(' ',p.product_id,p.name_mat,p.item_category_mat,p.notes)))>0)
   AND NOT EXISTS(SELECT 1 FROM public._m2m_products_ecommerce_orders_ecommerce_orders m WHERE m.products_id=p.nocopk)
   AND NOT EXISTS(SELECT 1 FROM public._m2m_ecommerce_orders_products_products m WHERE m.products_id=p.nocopk)
   AND NOT EXISTS(SELECT 1 FROM public.mp_fulfillment_allocations a WHERE a.product_id=p.nocopk)
   AND NOT (p.nocopk=ANY(claimed))
 ), page AS (
  SELECT * FROM eligible ORDER BY nocopk LIMIT page_size OFFSET (page_no-1)*page_size
 )
 SELECT jsonb_build_object('ok',true,'products',coalesce((SELECT jsonb_agg(jsonb_build_object(
  'airtable_record_id',coalesce(airtable_id,nocopk::text),'product_id',product_id,'name_mat',name_mat,
  'unit_size',coalesce(net_weight_oz,net_weight_g,net_volume_ml),'item_category_mat',item_category_mat,
  'storage_location_name',location_name,'notes',notes) ORDER BY nocopk) FROM page),'[]'),
  'count',(SELECT count(*) FROM eligible),'page',page_no,'page_size',page_size,
  'has_next',(SELECT count(*) FROM eligible)>page_no*page_size) INTO result;
 RETURN result;
END $$;

-- These interactive functions benefit from the same setting measured on the host.
-- It is local to each function call; no database-wide/role-wide change is made.
ALTER FUNCTION public.mp_fulfillment_lines(bigint) SET jit=off;
ALTER FUNCTION public.mp_fulfillment_product_eligible(bigint) SET jit=off;
ALTER FUNCTION public.mp_fulfillment_progress(bigint) SET jit=off;
ALTER FUNCTION public.mp_fulfillment_assign(text,text,text,text) SET jit=off;
ALTER FUNCTION public.mp_fulfillment_dispatch(text,text,text) SET jit=off;
ALTER FUNCTION public.mp_fulfillment_release(bigint,text) SET jit=off;
CREATE INDEX IF NOT EXISTS mp_fulfillment_allocations_order_line_idx
 ON public.mp_fulfillment_allocations(order_id,line_id);
UPDATE public.mp_fulfillment_063_backup SET applied_definition=pg_get_functiondef(name::regprocedure);
COMMIT;
