\set ON_ERROR_STOP on
BEGIN;
DO $$
BEGIN
 IF (SELECT count(*) FROM public.mp_fulfillment_063_backup b JOIN pg_proc p ON p.oid=b.name::regprocedure
     WHERE p.proconfig @> ARRAY['jit=off'])<>7 THEN
  RAISE EXCEPTION 'Expected function-local JIT settings';
 END IF;
 EXECUTE replace(pg_get_functiondef('public.mp_inventory_units()'::regprocedure),
  'public.mp_inventory_units()', 'pg_temp.t063_original_units()');
 EXECUTE replace(pg_get_functiondef('public.mp_fulfillment_progress(bigint)'::regprocedure),
  'public.mp_fulfillment_progress(p_order bigint)', 'pg_temp.t063_original_progress(p_order bigint)');
END $$;
CREATE OR REPLACE FUNCTION public.mp_inventory_units()
RETURNS TABLE(pool_key text,kind text,unit_id bigint,eligible boolean,shipped boolean)
LANGUAGE plpgsql STABLE AS $$
BEGIN
 PERFORM set_config('t063.units_calls',(coalesce(nullif(current_setting('t063.units_calls',true),''),'0')::int+1)::text,true);
 RETURN QUERY SELECT * FROM pg_temp.t063_original_units();
END $$;
CREATE OR REPLACE FUNCTION public.mp_fulfillment_progress(p_order bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE SET jit=off AS $$
BEGIN
 PERFORM set_config('t063.progress_calls',(coalesce(nullif(current_setting('t063.progress_calls',true),''),'0')::int+1)::text,true);
 RETURN pg_temp.t063_original_progress(p_order);
END $$;
-- Search must not invoke the row-by-row helper; mutation functions still do.
CREATE OR REPLACE FUNCTION public.mp_fulfillment_product_eligible(p_product bigint)
RETURNS boolean LANGUAGE plpgsql STABLE AS $$
BEGIN RAISE EXCEPTION 'Search called per-product inventory eligibility'; END $$;
DO $$
DECLARE item bigint;irrelevant bigint;loc bigint;ship bigint;oid bigint;other_order bigint;ec bigint;pid bigint;pool text;
 result jsonb;first_id text;units_calls integer;progress_calls integer;
BEGIN
 INSERT INTO public.items(item_id,name,category,active) VALUES('T063-ITEM','Search performance fixture','grain',true) RETURNING nocopk INTO item;
 INSERT INTO public.items(item_id,name,category,active) VALUES('T063-OTHER','Unmapped products','grain',true) RETURNING nocopk INTO irrelevant;
 INSERT INTO public.locations(name,active,type) VALUES('T063 Storage',true,'Storage') RETURNING nocopk INTO loc;
 SELECT nocopk INTO ship FROM public.locations WHERE active AND lower(name)='shipped' LIMIT 1;
 IF ship IS NULL THEN INSERT INTO public.locations(name,active,type) VALUES('Shipped',true,'Terminal') RETURNING nocopk INTO ship; END IF;
 INSERT INTO public.ecommerce(name,item_id,status,provider,site_key,external_sku,external_product_id,sync_enabled)
 VALUES('T063 listing',item,'Sterilized','ecwid','t063','T063-SKU','900630',true) RETURNING nocopk INTO ec;
 INSERT INTO public.ecommerce_orders(name,provider,site_key,external_order_id,ecwid_order_id,status,payment_status,items_json)
 VALUES('T063 order','ecwid','t063','900630','900630','AWAITING_PROCESSING','PAID','[{"id":"1","sku":"T063-SKU","quantity":200}]') RETURNING nocopk INTO oid;
 INSERT INTO public.ecommerce_orders(name,provider,site_key,external_order_id,ecwid_order_id,status,payment_status,items_json)
 VALUES('T063 other','ecwid','t063','900631','900631','AWAITING_PROCESSING','PAID','[{"id":"1","sku":"T063-SKU","quantity":200}]') RETURNING nocopk INTO other_order;
 INSERT INTO public.products(product_id,item_id,storage_location_id,use_by)
 SELECT 'T063-'||i,item,loc,CURRENT_DATE+5 FROM generate_series(1,100) i;
 INSERT INTO public.products(product_id,item_id,storage_location_id,use_by)
 SELECT 'T063-OTHER-'||i,irrelevant,loc,CURRENT_DATE+5 FROM generate_series(1,2000) i;
 INSERT INTO public.products(product_id,item_id,storage_location_id,use_by)
 VALUES('T063-SHIPPED',item,ship,CURRENT_DATE+5),('T063-EXPIRED',item,loc,CURRENT_DATE-1);
 SELECT nocopk INTO pid FROM public.products WHERE product_id='T063-1';
 INSERT INTO public._m2m_products_ecommerce_orders_ecommerce_orders(products_id,ecommerce_orders_id) VALUES(pid,other_order);
 SELECT nocopk INTO pid FROM public.products WHERE product_id='T063-2';
 INSERT INTO public._m2m_ecommerce_orders_products_products(products_id,ecommerce_orders_id) VALUES(pid,other_order);
 SELECT nocopk INTO pid FROM public.products WHERE product_id='T063-3';
 SELECT pool_key INTO pool FROM public.mp_inventory_specs() WHERE ecommerce_id=ec;
 INSERT INTO public.mp_fulfillment_allocations(product_id,order_id,line_id,pool_key,operator)
 VALUES(pid,other_order,'1',pool,'synthetic');
 PERFORM set_config('t063.units_calls','0',true);PERFORM set_config('t063.progress_calls','0',true);
 result:=public.mp_fulfillment_search(oid::text,'',1,25,'');
 units_calls:=current_setting('t063.units_calls')::integer;
 progress_calls:=current_setting('t063.progress_calls')::integer;
 IF (result->>'count')::integer<>97 OR jsonb_array_length(result->'products')<>25 OR NOT (result->>'has_next')::boolean THEN
  RAISE EXCEPTION 'Search eligibility or pagination changed: %',result;
 END IF;
 -- Existing progress uses three inventory reads; search adds one materialized read.
 IF progress_calls<>1 OR units_calls>4 THEN
  RAISE EXCEPTION 'Search repeated shared work: progress %, inventory %',progress_calls,units_calls;
 END IF;
 first_id:=result->'products'->0->>'product_id';
 result:=public.mp_fulfillment_search(oid::text,'',2,25,'');
 IF result->'products'->0->>'product_id'=first_id THEN RAISE EXCEPTION 'Pagination repeated first page'; END IF;
 result:=public.mp_fulfillment_search(oid::text,'T063-100',1,25,'1');
 IF (result->>'count')::integer<>1 THEN RAISE EXCEPTION 'Exact code search changed'; END IF;
 result:=public.mp_fulfillment_search(oid::text,'',1,25,'unknown');
 IF (result->>'count')::integer<>0 THEN RAISE EXCEPTION 'Unknown line gained candidates'; END IF;
END $$;
ROLLBACK;
