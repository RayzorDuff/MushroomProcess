-- Separate private roles: api_role records received cash; worker_role posts/acks.
BEGIN;
GRANT SELECT,INSERT ON public.mp_commerce_cash_receipts TO :"api_role";
GRANT EXECUTE ON FUNCTION public.mp_commerce_record_cash(jsonb) TO :"api_role";
GRANT SELECT,UPDATE ON public.mp_commerce_cash_receipts TO :"worker_role";
GRANT EXECUTE ON FUNCTION public.mp_commerce_ack_cash(uuid,jsonb),public.mp_commerce_confirm_cash(uuid) TO :"worker_role";
COMMIT;
