SET search_path = public, pg_catalog;

BEGIN;

/*
 * Issue #12, Phase 2: stable Product/Lot QR resolver contract.
 *
 * The public HTTP endpoint lives behind RootedOps/n8n. PostgreSQL owns the
 * inventory lookup and provider-neutral Product -> ecommerce mapping so the
 * HTTP layer never needs to understand Ecwid/WooCommerce schema details.
 *
 * Product resolution:
 *   PROD-* -> products.item_id/strain_id -> one active ecommerce public_url
 *
 * Lot resolution:
 *   LOT-* -> existence check only; the HTTP layer redirects to Appsmith Lots
 *            using MP_APP_LOTS_URL and appends ?lot=<LOT-ID>&source=qr.
 */

CREATE OR REPLACE FUNCTION public.mp_qr_resolve_inventory(p_inventory_id text)
RETURNS TABLE (
  status text,
  entity_type text,
  inventory_id text,
  entity_nocopk bigint,
  ecommerce_id bigint,
  provider text,
  site_key text,
  public_url text,
  message text
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
BEGIN
  IF v_input IS NULL THEN
    RETURN QUERY
    SELECT
      'invalid_id'::text,
      NULL::text,
      NULL::text,
      NULL::bigint,
      NULL::bigint,
      NULL::text,
      NULL::text,
      NULL::text,
      'Inventory identifier is required.'::text;
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
        'not_found'::text,
        'product'::text,
        v_input,
        NULL::bigint,
        NULL::bigint,
        NULL::text,
        NULL::text,
        NULL::text,
        format('Product not found: %s', v_input)::text;
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
        )::text;
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
        )::text;
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
      NULL::text;
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
        'not_found'::text,
        'lot'::text,
        v_input,
        NULL::bigint,
        NULL::bigint,
        NULL::text,
        NULL::text,
        NULL::text,
        format('Lot not found: %s', v_input)::text;
      RETURN;
    END IF;

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
    'Inventory identifier must be a PROD-* or LOT-* identifier.'::text;
END;
$function$;

COMMENT ON FUNCTION public.mp_qr_resolve_inventory(text) IS
'Issue #12 stable QR resolver contract. Resolves a Product to one provider-neutral ecommerce public URL or validates a Lot for Appsmith deep-link routing.';

COMMIT;
