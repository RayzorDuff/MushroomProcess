-- psql -v publisher_role=THE_EXISTING_N8N_POSTGRES_USERNAME
-- Run as database owner. This is a role name, never a password.
SELECT format('GRANT SELECT ON public.mp_inventory_item_rules,public.mp_ecwid_inventory_publications,public.mp_ecwid_inventory_receipts TO %I', :'publisher_role') \gexec
SELECT format('GRANT INSERT,UPDATE ON public.mp_ecwid_inventory_publications,public.mp_ecwid_inventory_receipts TO %I', :'publisher_role') \gexec
SELECT format('GRANT EXECUTE ON FUNCTION public.mp_ecwid_inventory_plan(bigint),public.mp_ecwid_inventory_resolve(uuid,text) TO %I', :'publisher_role') \gexec
