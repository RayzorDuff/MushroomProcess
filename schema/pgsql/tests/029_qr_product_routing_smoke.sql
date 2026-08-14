BEGIN;
SET LOCAL client_min_messages TO NOTICE;
SET LOCAL search_path = public, pg_catalog;

DO $test$
DECLARE
  v_item_normal bigint;
  v_item_fd bigint;
  v_item_tray bigint;
  v_strain_normal bigint;
  v_strain_reg bigint;
  v_product_normal bigint;
  v_product_fd bigint;
  v_product_tray bigint;
  v_product_fresh_tray bigint;
  v_mapping bigint;
  v_row record;
BEGIN
  INSERT INTO public.items(item_id, active, name, category)
  VALUES
    ('ITEM-QR29-NORMAL', true, 'QR29 Normal', 'lc_syringe'),
    ('ITEM-QR29-FD', true, 'QR29 Freeze Dried', 'freezedriedmushrooms'),
    ('ITEM-QR29-TRAY', true, 'QR29 Tray', 'freezer_tray');

  SELECT nocopk INTO v_item_normal FROM public.items WHERE item_id = 'ITEM-QR29-NORMAL';
  SELECT nocopk INTO v_item_fd FROM public.items WHERE item_id = 'ITEM-QR29-FD';
  SELECT nocopk INTO v_item_tray FROM public.items WHERE item_id = 'ITEM-QR29-TRAY';

  INSERT INTO public.strains(strain_id, active, species_strain, regulated)
  VALUES
    ('STRAIN-QR29-NORMAL', true, 'QR29 Normal', false),
    ('STRAIN-QR29-REG', true, 'QR29 Regulated', true);

  SELECT nocopk INTO v_strain_normal FROM public.strains WHERE strain_id = 'STRAIN-QR29-NORMAL';
  SELECT nocopk INTO v_strain_reg FROM public.strains WHERE strain_id = 'STRAIN-QR29-REG';

  INSERT INTO public.products(product_id, item_id, strain_id, name_mat, item_category_mat, package_class)
  VALUES
    ('PROD-QR29-NORMAL', v_item_normal, v_strain_normal, 'QR29 Normal', 'lc_syringe', 'Retail'),
    ('PROD-QR29-FDREG', v_item_fd, v_strain_reg, 'QR29 Regulated FD', 'freezedriedmushrooms', 'Sample'),
    ('PROD-QR29-FREEZER', v_item_tray, v_strain_reg, 'QR29 Freezer Tray', 'freezer_tray', NULL),
    ('PROD-QR29-FRESH', v_item_tray, v_strain_normal, 'QR29 Fresh Tray', 'fresh_tray', NULL);

  SELECT nocopk INTO v_product_normal FROM public.products WHERE product_id = 'PROD-QR29-NORMAL';
  SELECT nocopk INTO v_product_fd FROM public.products WHERE product_id = 'PROD-QR29-FDREG';
  SELECT nocopk INTO v_product_tray FROM public.products WHERE product_id = 'PROD-QR29-FREEZER';
  SELECT nocopk INTO v_product_fresh_tray FROM public.products WHERE product_id = 'PROD-QR29-FRESH';

  INSERT INTO public.ecommerce(
    name, item_id, strain_id, provider, site_key, external_sku,
    sync_enabled, public_url, is_primary_public_listing
  ) VALUES (
    'QR29 Normal Mapping', v_item_normal, v_strain_normal,
    'ecwid', 'dank_mushrooms', 'QR29-NORMAL', true,
    'https://example.invalid/qr29-normal', true
  ) RETURNING nocopk INTO v_mapping;

  SELECT * INTO v_row FROM public.mp_qr_resolve_inventory('PROD-QR29-NORMAL');
  IF v_row.status <> 'ok'
     OR v_row.route_kind <> 'ecommerce'
     OR v_row.public_url <> 'https://example.invalid/qr29-normal'
     OR v_row.entity_nocopk <> v_product_normal
  THEN
    RAISE EXCEPTION 'Normal ecommerce routing failed: %', row_to_json(v_row);
  END IF;

  SELECT * INTO v_row FROM public.mp_qr_resolve_inventory('PROD-QR29-FDREG');
  IF v_row.status <> 'ok'
     OR v_row.route_kind <> 'regulated_business'
     OR v_row.public_url IS NOT NULL
     OR v_row.regulated IS DISTINCT FROM true
     OR v_row.item_category <> 'freezedriedmushrooms'
     OR v_row.package_class <> 'Sample'
     OR v_row.company_key <> 'regulated'
     OR v_row.entity_nocopk <> v_product_fd
  THEN
    RAISE EXCEPTION 'Regulated freeze-dried routing failed: %', row_to_json(v_row);
  END IF;

  SELECT * INTO v_row FROM public.mp_qr_resolve_inventory('PROD-QR29-FREEZER');
  IF v_row.status <> 'ok'
     OR v_row.route_kind <> 'product_internal'
     OR v_row.public_url IS NOT NULL
     OR v_row.company_key <> 'regulated'
     OR v_row.entity_nocopk <> v_product_tray
  THEN
    RAISE EXCEPTION 'Regulated freezer tray routing failed: %', row_to_json(v_row);
  END IF;

  SELECT * INTO v_row FROM public.mp_qr_resolve_inventory('PROD-QR29-FRESH');
  IF v_row.status <> 'ok'
     OR v_row.route_kind <> 'product_internal'
     OR v_row.public_url IS NOT NULL
     OR v_row.company_key <> 'primary'
     OR v_row.entity_nocopk <> v_product_fresh_tray
  THEN
    RAISE EXCEPTION 'Unregulated fresh tray routing failed: %', row_to_json(v_row);
  END IF;

  RAISE NOTICE 'Issue #12 Product routing class smoke tests passed.';
END;
$test$;

ROLLBACK;
