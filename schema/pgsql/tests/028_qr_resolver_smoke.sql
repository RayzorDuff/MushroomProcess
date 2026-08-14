BEGIN;
SET LOCAL client_min_messages TO NOTICE;
SET LOCAL search_path = public, pg_catalog;

DO $test$
DECLARE
  v_item_id bigint;
  v_strain_id bigint;
  v_product_id bigint;
  v_lot_id bigint;
  v_ecommerce_id bigint;
  v_secondary_ecommerce_id bigint;
  v_row record;
BEGIN
  INSERT INTO public.items(item_id, active, name, category)
  VALUES ('ITEM-QR-ISSUE12-TEST', true, 'Issue 12 QR Test Item', 'test')
  RETURNING nocopk INTO v_item_id;

  INSERT INTO public.strains(strain_id, active, species_strain, regulated)
  VALUES ('STRAIN-QR-ISSUE12-TEST', true, 'Issue 12 QR Test Strain', false)
  RETURNING nocopk INTO v_strain_id;

  INSERT INTO public.products(product_id, item_id, strain_id, name_mat)
  VALUES ('PROD-QR-ISSUE12-AbCd', v_item_id, v_strain_id, 'Issue 12 QR Product')
  RETURNING nocopk INTO v_product_id;

  INSERT INTO public.lots(lot_id, item_id, strain_id, status)
  VALUES ('LOT-QR-ISSUE12-XyZ9', v_item_id, v_strain_id, 'Inoculated')
  RETURNING nocopk INTO v_lot_id;

  INSERT INTO public.ecommerce(
    name,
    item_id,
    strain_id,
    provider,
    site_key,
    external_sku,
    sync_enabled,
    public_url,
    is_primary_public_listing
  )
  VALUES (
    'Issue 12 QR Primary Mapping',
    v_item_id,
    v_strain_id,
    'ecwid',
    'dank_mushrooms',
    'QR-ISSUE12-PRIMARY',
    true,
    'https://example.invalid/products/issue-12-qr',
    true
  )
  RETURNING nocopk INTO v_ecommerce_id;

  SELECT * INTO v_row
  FROM public.mp_qr_resolve_inventory('PROD-QR-ISSUE12-AbCd');

  IF v_row.status <> 'ok'
     OR v_row.entity_type <> 'product'
     OR v_row.inventory_id <> 'PROD-QR-ISSUE12-AbCd'
     OR v_row.entity_nocopk <> v_product_id
     OR v_row.ecommerce_id <> v_ecommerce_id
     OR v_row.public_url <> 'https://example.invalid/products/issue-12-qr'
  THEN
    RAISE EXCEPTION 'Product QR resolution failed: %', row_to_json(v_row);
  END IF;

  -- Case-insensitive fallback should canonicalize to the stored identifier.
  SELECT * INTO v_row
  FROM public.mp_qr_resolve_inventory('prod-qr-issue12-abcd');

  IF v_row.status <> 'ok' OR v_row.inventory_id <> 'PROD-QR-ISSUE12-AbCd' THEN
    RAISE EXCEPTION 'Product QR case fallback failed: %', row_to_json(v_row);
  END IF;

  SELECT * INTO v_row
  FROM public.mp_qr_resolve_inventory('LOT-QR-ISSUE12-XyZ9');

  IF v_row.status <> 'ok'
     OR v_row.entity_type <> 'lot'
     OR v_row.inventory_id <> 'LOT-QR-ISSUE12-XyZ9'
     OR v_row.entity_nocopk <> v_lot_id
     OR v_row.public_url IS NOT NULL
  THEN
    RAISE EXCEPTION 'Lot QR resolution failed: %', row_to_json(v_row);
  END IF;

  SELECT * INTO v_row
  FROM public.mp_qr_resolve_inventory('PROD-QR-ISSUE12-MISSING');

  IF v_row.status <> 'not_found' OR v_row.entity_type <> 'product' THEN
    RAISE EXCEPTION 'Missing Product QR handling failed: %', row_to_json(v_row);
  END IF;

  SELECT * INTO v_row
  FROM public.mp_qr_resolve_inventory('SOMETHING-ELSE');

  IF v_row.status <> 'invalid_id' THEN
    RAISE EXCEPTION 'Invalid QR identifier handling failed: %', row_to_json(v_row);
  END IF;

  UPDATE public.ecommerce
  SET sync_enabled = false
  WHERE nocopk = v_ecommerce_id;

  SELECT * INTO v_row
  FROM public.mp_qr_resolve_inventory('PROD-QR-ISSUE12-AbCd');

  IF v_row.status <> 'product_unmapped' THEN
    RAISE EXCEPTION 'Disabled Product mapping should not resolve: %', row_to_json(v_row);
  END IF;

  UPDATE public.ecommerce
  SET sync_enabled = true
  WHERE nocopk = v_ecommerce_id;

  INSERT INTO public.ecommerce(
    name,
    item_id,
    strain_id,
    provider,
    site_key,
    external_sku,
    sync_enabled,
    public_url,
    is_primary_public_listing
  )
  VALUES (
    'Issue 12 QR Secondary Mapping',
    v_item_id,
    v_strain_id,
    'woocommerce',
    'dank_mushrooms',
    'QR-ISSUE12-SECONDARY',
    true,
    'https://example.invalid/woocommerce/issue-12-qr',
    false
  )
  RETURNING nocopk INTO v_secondary_ecommerce_id;

  SELECT * INTO v_row
  FROM public.mp_qr_resolve_inventory('PROD-QR-ISSUE12-AbCd');

  IF v_row.status <> 'ok' OR v_row.ecommerce_id <> v_ecommerce_id THEN
    RAISE EXCEPTION 'Primary public mapping selection failed: %', row_to_json(v_row);
  END IF;

  UPDATE public.ecommerce
  SET is_primary_public_listing = true
  WHERE nocopk = v_secondary_ecommerce_id;

  SELECT * INTO v_row
  FROM public.mp_qr_resolve_inventory('PROD-QR-ISSUE12-AbCd');

  IF v_row.status <> 'ambiguous_mapping' THEN
    RAISE EXCEPTION 'Duplicate primary mappings should be ambiguous: %', row_to_json(v_row);
  END IF;

  RAISE NOTICE 'Issue #12 stable QR resolver PostgreSQL smoke tests passed.';
END;
$test$;

ROLLBACK;
