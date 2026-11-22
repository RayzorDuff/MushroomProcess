-- Restrict Fulfillment and restore the previous workflow/Appsmith export first.
-- History is retained. Never restore a pre-sale database over newer orders.
BEGIN;
SELECT pg_advisory_xact_lock(520052);
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM public.mp_fulfillment_allocations WHERE dispatched_at IS NULL) THEN
  RAISE EXCEPTION 'Resolve allocated units with dispatch or reviewed cancellation before rollback'; END IF;
END $$;
DROP TRIGGER IF EXISTS mp_fulfillment_guard_allocated_product ON public.products;
DROP TRIGGER IF EXISTS mp_fulfillment_release_cancelled ON public.ecommerce_orders;
DROP FUNCTION IF EXISTS public.mp_fulfillment_guard_allocated_product();
DROP FUNCTION IF EXISTS public.mp_fulfillment_cancel_guard();
DROP FUNCTION IF EXISTS public.mp_fulfillment_release(bigint,text);
DROP FUNCTION IF EXISTS public.mp_fulfillment_dispatch(text,text,text);
DROP FUNCTION IF EXISTS public.mp_fulfillment_assign(text,text,text,text);
DROP FUNCTION IF EXISTS public.mp_fulfillment_search(text,text,integer,integer,text);
DROP FUNCTION IF EXISTS public.mp_fulfillment_progress(bigint);
DROP FUNCTION IF EXISTS public.mp_fulfillment_product_eligible(bigint);
DROP FUNCTION IF EXISTS public.mp_fulfillment_lines(bigint);
COMMIT;
