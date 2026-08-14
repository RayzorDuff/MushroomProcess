BEGIN;

SET LOCAL statement_timeout = '60s';
SET LOCAL lock_timeout = '5s';
SET LOCAL idle_in_transaction_session_timeout = '60s';

DO $test$
DECLARE
  v_ecommerce_pk bigint;
  v_order_pk bigint;
  v_row public.ecommerce%ROWTYPE;
  v_order public.ecommerce_orders%ROWTYPE;
BEGIN
  INSERT INTO public.ecommerce (
    name,
    ecwid_sku,
    sync_to_ecwid,
    ecwid_category,
    ecwid_price,
    ecwid_stock,
    ecwid_url,
    ecwid_image,
    ecwid_upc
  )
  VALUES (
    '__ISSUE12_PROVIDER_ALIAS__',
    'ISSUE12-SKU',
    true,
    '12345',
    19.95,
    7,
    'https://example.invalid/ecwid/original',
    '[{"url":"https://example.invalid/image.jpg"}]'::jsonb,
    '012345678905'
  )
  RETURNING nocopk INTO v_ecommerce_pk;

  SELECT * INTO STRICT v_row
  FROM public.ecommerce
  WHERE nocopk = v_ecommerce_pk;

  IF v_row.provider <> 'ecwid'
     OR v_row.site_key <> 'dank_mushrooms'
     OR v_row.external_sku <> 'ISSUE12-SKU'
     OR v_row.sync_enabled IS DISTINCT FROM true
     OR v_row.external_category <> '12345'
     OR v_row.external_price <> 19.95
     OR v_row.external_stock <> 7
     OR v_row.public_url <> 'https://example.invalid/ecwid/original'
     OR v_row.upc <> '012345678905'
     OR v_row.is_primary_public_listing IS DISTINCT FROM true
  THEN
    RAISE EXCEPTION 'Legacy Ecwid ecommerce fields were not mirrored into provider-neutral aliases.';
  END IF;

  UPDATE public.ecommerce
  SET ecwid_url = 'https://example.invalid/ecwid/updated',
      ecwid_price = 21.50,
      ecwid_stock = 9
  WHERE nocopk = v_ecommerce_pk;

  SELECT * INTO STRICT v_row
  FROM public.ecommerce
  WHERE nocopk = v_ecommerce_pk;

  IF v_row.public_url <> 'https://example.invalid/ecwid/updated'
     OR v_row.external_price <> 21.50
     OR v_row.external_stock <> 9
  THEN
    RAISE EXCEPTION 'Legacy Ecwid updates were not propagated to provider-neutral aliases.';
  END IF;

  UPDATE public.ecommerce
  SET provider = 'woocommerce',
      site_key = 'dank_mushrooms',
      public_url = 'https://example.invalid/woocommerce/product',
      external_sku = 'WC-SKU'
  WHERE nocopk = v_ecommerce_pk;

  UPDATE public.ecommerce
  SET ecwid_url = 'https://example.invalid/ecwid/legacy-changed'
  WHERE nocopk = v_ecommerce_pk;

  SELECT * INTO STRICT v_row
  FROM public.ecommerce
  WHERE nocopk = v_ecommerce_pk;

  IF v_row.public_url <> 'https://example.invalid/woocommerce/product'
     OR v_row.external_sku <> 'WC-SKU'
  THEN
    RAISE EXCEPTION 'Legacy Ecwid aliases overwrote a non-Ecwid provider mapping.';
  END IF;

  INSERT INTO public.ecommerce_orders (
    name,
    ecwid_order_id,
    ecwid_skus
  )
  VALUES (
    '__ISSUE12_ORDER_ALIAS__',
    'ISSUE12-ORDER',
    'ISSUE12-SKU, ISSUE12-SKU-2'
  )
  RETURNING nocopk INTO v_order_pk;

  SELECT * INTO STRICT v_order
  FROM public.ecommerce_orders
  WHERE nocopk = v_order_pk;

  IF v_order.provider <> 'ecwid'
     OR v_order.site_key <> 'dank_mushrooms'
     OR v_order.external_order_id <> 'ISSUE12-ORDER'
     OR v_order.external_skus <> 'ISSUE12-SKU, ISSUE12-SKU-2'
  THEN
    RAISE EXCEPTION 'Legacy Ecwid order fields were not mirrored into provider-neutral aliases.';
  END IF;

  RAISE NOTICE 'Issue #12 provider-neutral ecommerce alias smoke tests passed.';
END;
$test$;

ROLLBACK;
