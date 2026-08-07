SET search_path = public, pg_catalog;

BEGIN;

/*
 * Issue #12, Phase 1: provider-neutral ecommerce metadata.
 *
 * The legacy ecwid_* columns remain authoritative during the Ecwid transition.
 * Generic aliases are additive and are kept synchronized for provider='ecwid'.
 * A future WooCommerce sync can write the generic columns directly without
 * requiring physical QR labels to know which commerce provider is active.
 */
ALTER TABLE public.ecommerce
  ADD COLUMN IF NOT EXISTS provider text,
  ADD COLUMN IF NOT EXISTS site_key text,
  ADD COLUMN IF NOT EXISTS external_sku text,
  ADD COLUMN IF NOT EXISTS sync_enabled boolean,
  ADD COLUMN IF NOT EXISTS external_category text,
  ADD COLUMN IF NOT EXISTS external_price numeric,
  ADD COLUMN IF NOT EXISTS external_stock numeric,
  ADD COLUMN IF NOT EXISTS public_url text,
  ADD COLUMN IF NOT EXISTS external_image jsonb,
  ADD COLUMN IF NOT EXISTS upc text,
  ADD COLUMN IF NOT EXISTS external_product_id text,
  ADD COLUMN IF NOT EXISTS external_variation_id text,
  ADD COLUMN IF NOT EXISTS is_primary_public_listing boolean;

ALTER TABLE public.ecommerce_orders
  ADD COLUMN IF NOT EXISTS provider text,
  ADD COLUMN IF NOT EXISTS site_key text,
  ADD COLUMN IF NOT EXISTS external_order_id text,
  ADD COLUMN IF NOT EXISTS external_skus text;

CREATE INDEX IF NOT EXISTS ix_ecommerce_provider
  ON public.ecommerce(provider);
CREATE INDEX IF NOT EXISTS ix_ecommerce_external_sku
  ON public.ecommerce(external_sku);
CREATE INDEX IF NOT EXISTS ix_ecommerce_public_url
  ON public.ecommerce(public_url);
CREATE INDEX IF NOT EXISTS ix_ecommerce_orders_provider_external_order_id
  ON public.ecommerce_orders(provider, external_order_id);

CREATE OR REPLACE FUNCTION public.mp_ecommerce_sync_legacy_ecwid_aliases()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
  v_is_ecwid boolean;
BEGIN
  IF NULLIF(BTRIM(NEW.provider), '') IS NULL AND (
    NULLIF(BTRIM(NEW.ecwid_sku), '') IS NOT NULL
    OR COALESCE(NEW.sync_to_ecwid, false)
    OR NULLIF(BTRIM(NEW.ecwid_category), '') IS NOT NULL
    OR NEW.ecwid_price IS NOT NULL
    OR NEW.ecwid_stock IS NOT NULL
    OR NULLIF(BTRIM(NEW.ecwid_url), '') IS NOT NULL
    OR NEW.ecwid_image IS NOT NULL
    OR NULLIF(BTRIM(NEW.ecwid_upc), '') IS NOT NULL
  ) THEN
    NEW.provider := 'ecwid';
  END IF;

  v_is_ecwid := lower(COALESCE(NULLIF(BTRIM(NEW.provider), ''), '')) = 'ecwid';

  IF v_is_ecwid THEN
    NEW.site_key := COALESCE(NULLIF(BTRIM(NEW.site_key), ''), 'dank_mushrooms');
    NEW.is_primary_public_listing := COALESCE(NEW.is_primary_public_listing, true);

    IF TG_OP = 'INSERT' THEN
      NEW.external_sku := COALESCE(NEW.external_sku, NEW.ecwid_sku);
      NEW.sync_enabled := COALESCE(NEW.sync_enabled, NEW.sync_to_ecwid);
      NEW.external_category := COALESCE(NEW.external_category, NEW.ecwid_category);
      NEW.external_price := COALESCE(NEW.external_price, NEW.ecwid_price);
      NEW.external_stock := COALESCE(NEW.external_stock, NEW.ecwid_stock);
      NEW.public_url := COALESCE(NEW.public_url, NEW.ecwid_url);
      NEW.external_image := COALESCE(NEW.external_image, NEW.ecwid_image);
      NEW.upc := COALESCE(NEW.upc, NEW.ecwid_upc);
    ELSE
      IF NEW.ecwid_sku IS DISTINCT FROM OLD.ecwid_sku THEN
        NEW.external_sku := NEW.ecwid_sku;
      ELSIF NEW.external_sku IS NULL THEN
        NEW.external_sku := NEW.ecwid_sku;
      END IF;

      IF NEW.sync_to_ecwid IS DISTINCT FROM OLD.sync_to_ecwid THEN
        NEW.sync_enabled := NEW.sync_to_ecwid;
      ELSIF NEW.sync_enabled IS NULL THEN
        NEW.sync_enabled := NEW.sync_to_ecwid;
      END IF;

      IF NEW.ecwid_category IS DISTINCT FROM OLD.ecwid_category THEN
        NEW.external_category := NEW.ecwid_category;
      ELSIF NEW.external_category IS NULL THEN
        NEW.external_category := NEW.ecwid_category;
      END IF;

      IF NEW.ecwid_price IS DISTINCT FROM OLD.ecwid_price THEN
        NEW.external_price := NEW.ecwid_price;
      ELSIF NEW.external_price IS NULL THEN
        NEW.external_price := NEW.ecwid_price;
      END IF;

      IF NEW.ecwid_stock IS DISTINCT FROM OLD.ecwid_stock THEN
        NEW.external_stock := NEW.ecwid_stock;
      ELSIF NEW.external_stock IS NULL THEN
        NEW.external_stock := NEW.ecwid_stock;
      END IF;

      IF NEW.ecwid_url IS DISTINCT FROM OLD.ecwid_url THEN
        NEW.public_url := NEW.ecwid_url;
      ELSIF NEW.public_url IS NULL THEN
        NEW.public_url := NEW.ecwid_url;
      END IF;

      IF NEW.ecwid_image IS DISTINCT FROM OLD.ecwid_image THEN
        NEW.external_image := NEW.ecwid_image;
      ELSIF NEW.external_image IS NULL THEN
        NEW.external_image := NEW.ecwid_image;
      END IF;

      IF NEW.ecwid_upc IS DISTINCT FROM OLD.ecwid_upc THEN
        NEW.upc := NEW.ecwid_upc;
      ELSIF NEW.upc IS NULL THEN
        NEW.upc := NEW.ecwid_upc;
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_ecommerce_sync_legacy_ecwid_aliases
  ON public.ecommerce;
CREATE TRIGGER trg_ecommerce_sync_legacy_ecwid_aliases
BEFORE INSERT OR UPDATE ON public.ecommerce
FOR EACH ROW
EXECUTE FUNCTION public.mp_ecommerce_sync_legacy_ecwid_aliases();

CREATE OR REPLACE FUNCTION public.mp_ecommerce_order_sync_legacy_ecwid_aliases()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF NULLIF(BTRIM(NEW.provider), '') IS NULL AND NULLIF(BTRIM(NEW.ecwid_order_id), '') IS NOT NULL THEN
    NEW.provider := 'ecwid';
  END IF;

  IF lower(COALESCE(NULLIF(BTRIM(NEW.provider), ''), '')) = 'ecwid' THEN
    NEW.site_key := COALESCE(NULLIF(BTRIM(NEW.site_key), ''), 'dank_mushrooms');

    IF TG_OP = 'INSERT' THEN
      NEW.external_order_id := COALESCE(NEW.external_order_id, NEW.ecwid_order_id);
      NEW.external_skus := COALESCE(NEW.external_skus, NEW.ecwid_skus);
    ELSE
      IF NEW.ecwid_order_id IS DISTINCT FROM OLD.ecwid_order_id THEN
        NEW.external_order_id := NEW.ecwid_order_id;
      ELSIF NEW.external_order_id IS NULL THEN
        NEW.external_order_id := NEW.ecwid_order_id;
      END IF;

      IF NEW.ecwid_skus IS DISTINCT FROM OLD.ecwid_skus THEN
        NEW.external_skus := NEW.ecwid_skus;
      ELSIF NEW.external_skus IS NULL THEN
        NEW.external_skus := NEW.ecwid_skus;
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_ecommerce_orders_sync_legacy_ecwid_aliases
  ON public.ecommerce_orders;
CREATE TRIGGER trg_ecommerce_orders_sync_legacy_ecwid_aliases
BEFORE INSERT OR UPDATE ON public.ecommerce_orders
FOR EACH ROW
EXECUTE FUNCTION public.mp_ecommerce_order_sync_legacy_ecwid_aliases();

/* Backfill current Ecwid rows. Re-running the migration is intentionally safe. */
UPDATE public.ecommerce
SET
  provider = COALESCE(NULLIF(BTRIM(provider), ''), 'ecwid'),
  site_key = COALESCE(NULLIF(BTRIM(site_key), ''), 'dank_mushrooms'),
  external_sku = COALESCE(external_sku, ecwid_sku),
  sync_enabled = COALESCE(sync_enabled, sync_to_ecwid),
  external_category = COALESCE(external_category, ecwid_category),
  external_price = COALESCE(external_price, ecwid_price),
  external_stock = COALESCE(external_stock, ecwid_stock),
  public_url = COALESCE(public_url, ecwid_url),
  external_image = COALESCE(external_image, ecwid_image),
  upc = COALESCE(upc, ecwid_upc),
  is_primary_public_listing = COALESCE(is_primary_public_listing, true)
WHERE
  lower(COALESCE(NULLIF(BTRIM(provider), ''), 'ecwid')) = 'ecwid'
  AND (
    NULLIF(BTRIM(ecwid_sku), '') IS NOT NULL
    OR COALESCE(sync_to_ecwid, false)
    OR NULLIF(BTRIM(ecwid_category), '') IS NOT NULL
    OR ecwid_price IS NOT NULL
    OR ecwid_stock IS NOT NULL
    OR NULLIF(BTRIM(ecwid_url), '') IS NOT NULL
    OR ecwid_image IS NOT NULL
    OR NULLIF(BTRIM(ecwid_upc), '') IS NOT NULL
  );

UPDATE public.ecommerce_orders
SET
  provider = COALESCE(NULLIF(BTRIM(provider), ''), 'ecwid'),
  site_key = COALESCE(NULLIF(BTRIM(site_key), ''), 'dank_mushrooms'),
  external_order_id = COALESCE(external_order_id, ecwid_order_id),
  external_skus = COALESCE(external_skus, ecwid_skus)
WHERE
  NULLIF(BTRIM(ecwid_order_id), '') IS NOT NULL
  AND lower(COALESCE(NULLIF(BTRIM(provider), ''), 'ecwid')) = 'ecwid';

COMMIT;
