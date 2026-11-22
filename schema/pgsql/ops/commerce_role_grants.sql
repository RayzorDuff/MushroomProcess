-- Apply as the migration owner after 054-057, with two reviewed service roles.
\set ON_ERROR_STOP on
\if :{?worker_role}
\else
 SELECT 1/0 AS supply_worker_role;
\endif
\if :{?fulfillment_role}
\else
 SELECT 1/0 AS supply_fulfillment_role;
\endif
BEGIN;
SELECT format('GRANT USAGE ON SCHEMA public TO %I, %I', :'worker_role', :'fulfillment_role') \gexec
SELECT format('GRANT SELECT ON public.mp_commerce_orders, public.mp_commerce_reservations,
 public.mp_commerce_events, public.mp_commerce_payment_matches, public.mp_commerce_erp_links,
 public.mp_commerce_shipments, public.mp_commerce_shipped_products, public.mp_commerce_shipped_lots,
 public.mp_commerce_shipped_units, public.mp_commerce_packages, public.mp_commerce_picks,
 public.mp_commerce_lot_picks, public.mp_commerce_picked_units, public.mp_commerce_shipment_delivery
 TO %I, %I', :'worker_role', :'fulfillment_role') \gexec
SELECT format('GRANT SELECT ON public.ecommerce, public.products, public.lots, public.locations,
 public._m2m_products_ecommerce_orders_ecommerce_orders, public._m2m_ecommerce_orders_products_products
 TO %I, %I', :'worker_role', :'fulfillment_role') \gexec
SELECT format('GRANT INSERT, UPDATE, DELETE ON public.mp_commerce_orders, public.mp_commerce_reservations,
 public.mp_commerce_events, public.mp_commerce_payment_matches, public.mp_commerce_erp_links TO %I', :'worker_role') \gexec
SELECT format('GRANT UPDATE ON public.mp_commerce_packages, public.mp_commerce_shipment_delivery TO %I', :'worker_role') \gexec
SELECT format('GRANT DELETE ON public.mp_commerce_picks, public.mp_commerce_lot_picks TO %I', :'worker_role') \gexec
SELECT format('GRANT USAGE ON SEQUENCE public.mp_commerce_inventory_revision TO %I', :'worker_role') \gexec
SELECT format('GRANT EXECUTE ON FUNCTION public.mp_commerce_ingest(jsonb), public.mp_commerce_match_payment(jsonb),
 public.mp_commerce_link_erp(jsonb), public.mp_commerce_confirm_reservation(text,text,text),
 public.mp_commerce_release_picks() TO %I', :'worker_role') \gexec
SELECT format('GRANT INSERT, UPDATE, DELETE ON public.mp_commerce_packages, public.mp_commerce_picks,
 public.mp_commerce_lot_picks, public.mp_commerce_shipments, public.mp_commerce_shipped_products,
 public.mp_commerce_shipped_lots, public.mp_commerce_shipment_delivery, public.mp_commerce_reservations
 TO %I', :'fulfillment_role') \gexec
SELECT format('GRANT UPDATE ON public.mp_commerce_orders, public.products, public.lots TO %I', :'fulfillment_role') \gexec
SELECT format('GRANT EXECUTE ON FUNCTION public.mp_commerce_pick(jsonb), public.mp_commerce_pick_lot(jsonb),
 public.mp_commerce_package_tracking(jsonb), public.mp_commerce_unpick(jsonb), public.mp_commerce_dispatch_request(jsonb),
 public.mp_commerce_dispatch(text,text,text), public.mp_commerce_dispatch_products(text,text,text),
 public.mp_commerce_ship_products(text,text,text,text,jsonb),public.mp_commerce_acknowledge_products(text,text,text,text,jsonb)
 TO %I', :'fulfillment_role') \gexec
-- Physical helper functions retain the existing trusted MP role's base-table and
-- location-link permissions. Verify those with the same role before activation.
COMMIT;
