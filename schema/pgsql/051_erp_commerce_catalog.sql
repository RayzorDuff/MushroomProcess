-- Additive provider-neutral catalog link. No stock/lineage writes.
BEGIN;
ALTER TABLE public.ecommerce ADD COLUMN IF NOT EXISTS erp_item_code text;
CREATE INDEX IF NOT EXISTS ix_ecommerce_erp_item_code ON public.ecommerce(erp_item_code);
CREATE OR REPLACE FUNCTION public.mp_ecommerce_catalog_inventory()
RETURNS TABLE (
  ecommerce_id bigint,
  erp_item_code text,
  ecommerce_name text,
  ecommerce_status text,
  item_id bigint,
  strain_id bigint,
  provider text,
  site_key text,
  external_sku text,
  upc text,
  external_product_id text,
  external_variation_id text,
  available_from_products bigint,
  available_from_lots bigint,
  desired_quantity bigint
)
LANGUAGE sql
STABLE
AS $function$
  SELECT
    e.nocopk AS ecommerce_id,
    e.erp_item_code,
    e.name AS ecommerce_name,
    e.status AS ecommerce_status,
    e.item_id,
    e.strain_id,
    COALESCE(NULLIF(BTRIM(e.provider), ''), 'ecwid') AS provider,
    COALESCE(NULLIF(BTRIM(e.site_key), ''), 'dank_mushrooms') AS site_key,
    COALESCE(NULLIF(BTRIM(e.external_sku), ''), NULLIF(BTRIM(e.ecwid_sku), '')) AS external_sku,
    public.mp_normalize_gtin_text(COALESCE(NULLIF(e.upc, ''), NULLIF(e.ecwid_upc, ''))) AS upc,
    e.external_product_id,
    e.external_variation_id,
    COALESCE(product_inventory.available_count, 0)::bigint AS available_from_products,
    COALESCE(lot_inventory.available_count, 0)::bigint AS available_from_lots,
    (
      COALESCE(product_inventory.available_count, 0)
      + COALESCE(lot_inventory.available_count, 0)
    )::bigint AS desired_quantity
  FROM public.ecommerce e
  LEFT JOIN LATERAL (
    SELECT COUNT(*)::bigint AS available_count
    FROM public.products p
    LEFT JOIN public.locations loc
      ON loc.nocopk = p.storage_location_id
    WHERE p.item_id = e.item_id
      AND p.strain_id IS NOT DISTINCT FROM e.strain_id
      AND (p.use_by IS NULL OR p.use_by >= CURRENT_DATE)
      AND regexp_replace(
            lower(COALESCE(loc.name, '')),
            '[^a-z0-9]',
            '',
            'g'
          ) NOT IN (
            'shipped',
            'expired',
            'consumed',
            'compost',
            'composted',
            'retired',
            'missing',
            'missingorlost'
          )
  ) product_inventory ON true
  LEFT JOIN LATERAL (
    SELECT COUNT(*)::bigint AS available_count
    FROM public.lots l
    WHERE l.item_id = e.item_id
      AND l.strain_id IS NOT DISTINCT FROM e.strain_id
      AND (l.use_by IS NULL OR l.use_by >= CURRENT_DATE)
      AND (
        CASE regexp_replace(lower(COALESCE(e.status, '')), '[^a-z0-9]', '', 'g')
          WHEN 'sterilized' THEN
            regexp_replace(lower(COALESCE(l.status, '')), '[^a-z0-9]', '', 'g')
              IN ('sterilized', 'sealed')
          WHEN 'pasteurized' THEN
            regexp_replace(lower(COALESCE(l.status, '')), '[^a-z0-9]', '', 'g')
              IN ('pasteurized')
          WHEN 'fullycolonized' THEN
            regexp_replace(lower(COALESCE(l.status, '')), '[^a-z0-9]', '', 'g')
              IN ('fullycolonized', 'fridge', 'coldshock')
          WHEN 'inoculated' THEN
            regexp_replace(lower(COALESCE(l.status, '')), '[^a-z0-9]', '', 'g')
              IN ('inoculated', 'colonizing')
          ELSE false
        END
      )
  ) lot_inventory ON true
  WHERE COALESCE(e.sync_enabled, e.sync_to_ecwid, false)
    AND e.item_id IS NOT NULL
    AND COALESCE(NULLIF(BTRIM(e.external_sku), ''), NULLIF(BTRIM(e.ecwid_sku), '')) IS NOT NULL
  ORDER BY e.nocopk;
$function$;


COMMENT ON FUNCTION public.mp_ecommerce_catalog_inventory() IS
'Operational availability snapshot. Missing ERP mapping must block publication. Quantities remain MushroomProcess-owned.';
COMMIT;
