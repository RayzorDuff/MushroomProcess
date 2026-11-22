-- Read-only; no customer fields or private webhook bodies.
SELECT c.ecommerce_id,c.ecommerce_name,c.external_sku,c.external_product_id,
 c.available_from_products,c.available_from_lots,c.desired_quantity AS gross,
 public.mp_inventory_reserved(c.ecommerce_id) AS ledger_reserved,
 public.mp_inventory_legacy_hold(c.ecommerce_id) AS ecwid_unshipped,
 n.available_quantity AS net,s.is_owner,s.pool_key,
 CASE WHEN s.size_kind='review' THEN 'STOP: unresolved package/material specification'
 WHEN p.pending_token IS NOT NULL THEN 'STOP: unknown API outcome'
 WHEN p.ecommerce_id IS NULL THEN 'Review opening baseline'
 ELSE 'Initialized' END AS publication
FROM public.mp_ecommerce_catalog_inventory() c JOIN public.mp_commerce_inventory() n USING(ecommerce_id)
JOIN public.mp_inventory_specs() s USING(ecommerce_id)
LEFT JOIN public.mp_ecwid_inventory_publications p USING(ecommerce_id)
WHERE c.provider='ecwid' ORDER BY c.ecommerce_id;
SELECT token,ecommerce_id,old_basis,new_basis,delta,outcome,created_at,resolved_at
FROM public.mp_ecwid_inventory_receipts ORDER BY created_at DESC LIMIT 30;
