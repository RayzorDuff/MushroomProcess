-- psql -v api_role=REVIEWED_N8N_DATABASE_ROLE. Do not grant to PUBLIC.
BEGIN;
GRANT SELECT,INSERT,UPDATE,DELETE ON public.mp_fulfillment_allocations,public.mp_fulfillment_dispatches TO :"api_role";
GRANT EXECUTE ON FUNCTION public.mp_fulfillment_assign(text,text,text,text),public.mp_fulfillment_dispatch(text,text,text),public.mp_fulfillment_release(bigint,text) TO :"api_role";
COMMIT;
