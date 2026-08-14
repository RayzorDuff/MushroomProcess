SET search_path = public, pg_catalog;

BEGIN;

/*
 * Issue #12, Phase 4 follow-up: route non-public Product classes safely.
 *
 * The stable QR resolver remains the only URL printed on labels. PostgreSQL
 * classifies the inventory and tells the HTTP layer which destination class
 * should be used:
 *
 *   ecommerce          normal Product -> provider-neutral public_url
 *   product_internal   fresh/freezer tray -> internal Products interface
 *   regulated_business regulated freeze-dried/capsule Product -> regulated
 *                      business base website (supplied by the HTTP layer)
 *   lot_internal       Lot -> internal Lots interface
 *
 * Company assignment is snapshotted from the current computed Product/Lot
 * presentation so scan logging can record the business assignment that was in
 * effect at resolution time.
 */

DROP FUNCTION IF EXISTS public.mp_qr_resolve_inventory(text);

CREATE FUNCTION public.mp_qr_resolve_inventory(p_inventory_id text)
RETURNS TABLE (
  status text,
  entity_type text,
  inventory_id text,
  entity_nocopk bigint,
  ecommerce_id bigint,
  provider text,
  site_key text,
  public_url text,
  message text,
  route_kind text,
  company_key text,
  company_name text,
  item_category text,
  regulated boolean,
  package_class text
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_input text := NULLIF(BTRIM(p_inventory_id), '');
  v_product public.products%ROWTYPE;
  v_lot public.lots%ROWTYPE;
  v_mapping public.ecommerce%ROWTYPE;
  v_candidate_count integer := 0;
  v_primary_count integer := 0;
  v_item_category text;
  v_regulated boolean := false;
  v_company_key text := 'primary';
  v_company_name text;
BEGIN
  IF v_input IS NULL THEN
    RETURN QUERY
    SELECT
      'invalid_id'::text, NULL::text, NULL::text, NULL::bigint,
      NULL::bigint, NULL::text, NULL::text, NULL::text,
      'Inventory identifier is required.'::text,
      NULL::text, NULL::text, NULL::text, NULL::text, NULL::boolean, NULL::text;
    RETURN;
  END IF;

  IF v_input ~* '^PROD-[A-Za-z0-9-]+$' THEN
    SELECT p.*
    INTO v_product
    FROM public.products p
    WHERE p.product_id = v_input
    LIMIT 1;

    IF NOT FOUND THEN
      SELECT p.*
      INTO v_product
      FROM public.products p
      WHERE lower(BTRIM(p.product_id)) = lower(v_input)
      ORDER BY p.nocopk
      LIMIT 1;
    END IF;

    IF v_product.nocopk IS NULL THEN
      RETURN QUERY
      SELECT
        'not_found'::text, 'product'::text, v_input, NULL::bigint,
        NULL::bigint, NULL::text, NULL::text, NULL::text,
        format('Product not found: %s', v_input)::text,
        NULL::text, NULL::text, NULL::text, NULL::text, NULL::boolean, NULL::text;
      RETURN;
    END IF;

    v_item_category := lower(BTRIM(COALESCE(v_product.item_category_mat, '')));

    SELECT COALESCE(s.regulated, false)
    INTO v_regulated
    FROM public.strains s
    WHERE s.nocopk = v_product.strain_id;

    v_regulated := COALESCE(v_regulated, false);

    IF v_regulated
       AND v_item_category IN (
         'freezedriedmushrooms',
         'fresh_mushrooms',
         'freezer_tray',
         'fresh_tray'
       )
    THEN
      v_company_key := 'regulated';
    ELSE
      v_company_key := 'primary';
    END IF;

    SELECT NULLIF(BTRIM(vp.label_company_prod), '')
    INTO v_company_name
    FROM public.vc_products vp
    WHERE vp.nocopk = v_product.nocopk
    LIMIT 1;

    /* Trays are operational inventory rather than customer-facing listings. */
    IF v_item_category IN ('freezer_tray', 'fresh_tray') THEN
      RETURN QUERY
      SELECT
        'ok'::text,
        'product'::text,
        v_product.product_id,
        v_product.nocopk,
        NULL::bigint,
        NULL::text,
        NULL::text,
        NULL::text,
        NULL::text,
        'product_internal'::text,
        v_company_key,
        v_company_name,
        v_item_category,
        v_regulated,
        v_product.package_class;
      RETURN;
    END IF;

    /*
     * Regulated freeze-dried mushrooms and capsules are not ecommerce items.
     * Capsules share the freezedriedmushrooms item category in the current
     * schema, so the category + regulated-strain rule intentionally covers
     * both package forms and both Retail/Sample package classes.
     */
    IF v_regulated AND v_item_category = 'freezedriedmushrooms' THEN
      RETURN QUERY
      SELECT
        'ok'::text,
        'product'::text,
        v_product.product_id,
        v_product.nocopk,
        NULL::bigint,
        NULL::text,
        NULL::text,
        NULL::text,
        NULL::text,
        'regulated_business'::text,
        v_company_key,
        v_company_name,
        v_item_category,
        v_regulated,
        v_product.package_class;
      RETURN;
    END IF;

    SELECT
      COUNT(*)::integer,
      COUNT(*) FILTER (WHERE COALESCE(e.is_primary_public_listing, false))::integer
    INTO v_candidate_count, v_primary_count
    FROM public.ecommerce e
    WHERE e.item_id = v_product.item_id
      AND e.strain_id IS NOT DISTINCT FROM v_product.strain_id
      AND COALESCE(e.sync_enabled, e.sync_to_ecwid, false)
      AND NULLIF(BTRIM(e.public_url), '') IS NOT NULL;

    IF v_candidate_count = 0 THEN
      RETURN QUERY
      SELECT
        'product_unmapped'::text,
        'product'::text,
        v_product.product_id,
        v_product.nocopk,
        NULL::bigint,
        NULL::text,
        NULL::text,
        NULL::text,
        format(
          'Product %s has no enabled ecommerce mapping with a public URL.',
          v_product.product_id
        )::text,
        'ecommerce'::text,
        v_company_key,
        v_company_name,
        v_item_category,
        v_regulated,
        v_product.package_class;
      RETURN;
    END IF;

    IF v_primary_count > 1 OR (v_primary_count = 0 AND v_candidate_count > 1) THEN
      RETURN QUERY
      SELECT
        'ambiguous_mapping'::text,
        'product'::text,
        v_product.product_id,
        v_product.nocopk,
        NULL::bigint,
        NULL::text,
        NULL::text,
        NULL::text,
        format(
          'Product %s has multiple eligible ecommerce mappings; select exactly one primary public listing.',
          v_product.product_id
        )::text,
        'ecommerce'::text,
        v_company_key,
        v_company_name,
        v_item_category,
        v_regulated,
        v_product.package_class;
      RETURN;
    END IF;

    SELECT e.*
    INTO v_mapping
    FROM public.ecommerce e
    WHERE e.item_id = v_product.item_id
      AND e.strain_id IS NOT DISTINCT FROM v_product.strain_id
      AND COALESCE(e.sync_enabled, e.sync_to_ecwid, false)
      AND NULLIF(BTRIM(e.public_url), '') IS NOT NULL
      AND (
        (v_primary_count = 1 AND COALESCE(e.is_primary_public_listing, false))
        OR
        (v_primary_count = 0)
      )
    ORDER BY e.nocopk
    LIMIT 1;

    RETURN QUERY
    SELECT
      'ok'::text,
      'product'::text,
      v_product.product_id,
      v_product.nocopk,
      v_mapping.nocopk,
      NULLIF(BTRIM(v_mapping.provider), ''),
      NULLIF(BTRIM(v_mapping.site_key), ''),
      NULLIF(BTRIM(v_mapping.public_url), ''),
      NULL::text,
      'ecommerce'::text,
      v_company_key,
      v_company_name,
      v_item_category,
      v_regulated,
      v_product.package_class;
    RETURN;
  END IF;

  IF v_input ~* '^LOT-[A-Za-z0-9-]+$' THEN
    SELECT l.*
    INTO v_lot
    FROM public.lots l
    WHERE l.lot_id = v_input
    LIMIT 1;

    IF NOT FOUND THEN
      SELECT l.*
      INTO v_lot
      FROM public.lots l
      WHERE lower(BTRIM(l.lot_id)) = lower(v_input)
      ORDER BY l.nocopk
      LIMIT 1;
    END IF;

    IF v_lot.nocopk IS NULL THEN
      RETURN QUERY
      SELECT
        'not_found'::text, 'lot'::text, v_input, NULL::bigint,
        NULL::bigint, NULL::text, NULL::text, NULL::text,
        format('Lot not found: %s', v_input)::text,
        'lot_internal'::text, NULL::text, NULL::text, NULL::text, NULL::boolean, NULL::text;
      RETURN;
    END IF;

    SELECT NULLIF(BTRIM(vl.label_company_lot), '')
    INTO v_company_name
    FROM public.vc_lots vl
    WHERE vl.nocopk = v_lot.nocopk
    LIMIT 1;

    SELECT COALESCE(s.regulated, false)
    INTO v_regulated
    FROM public.strains s
    WHERE s.nocopk = v_lot.strain_id;

    RETURN QUERY
    SELECT
      'ok'::text,
      'lot'::text,
      v_lot.lot_id,
      v_lot.nocopk,
      NULL::bigint,
      NULL::text,
      NULL::text,
      NULL::text,
      NULL::text,
      'lot_internal'::text,
      'primary'::text,
      v_company_name,
      lower(BTRIM(COALESCE(v_lot.item_category_mat, ''))),
      COALESCE(v_regulated, false),
      NULL::text;
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    'invalid_id'::text,
    NULL::text,
    v_input,
    NULL::bigint,
    NULL::bigint,
    NULL::text,
    NULL::text,
    NULL::text,
    'Inventory identifier must be a PROD-* or LOT-* identifier.'::text,
    NULL::text,
    NULL::text,
    NULL::text,
    NULL::text,
    NULL::boolean,
    NULL::text;
END;
$function$;

COMMENT ON FUNCTION public.mp_qr_resolve_inventory(text) IS
'Issue #12 stable QR resolver. Classifies ecommerce Products, internal tray Products, regulated freeze-dried Products, and Lots while snapshotting current company/category metadata.';

COMMIT;
