BEGIN;

SET LOCAL search_path = public, pg_catalog;
SET LOCAL client_min_messages = notice;

DO $$
DECLARE
  v_item_id bigint;
  v_strain_id bigint;
  v_active_location_id bigint;
  v_shipped_location_id bigint;
  v_missing_location_id bigint;
  v_ecommerce_id bigint;
  v_candidate record;
  v_reserved_upc text;
  v_reserved_upc_again text;
  v_row public.ecommerce%ROWTYPE;
  v_provider_guarded boolean := false;
BEGIN
  INSERT INTO public.items(item_id, active, name, category)
  VALUES ('ITEM-ISSUE12-ECWID-SMOKE', true, 'Issue 12 Ecwid Sync Test Item', 'fruiting_block')
  RETURNING nocopk INTO v_item_id;

  INSERT INTO public.strains(strain_id, active, species_strain, regulated)
  VALUES ('STRAIN-ISSUE12-ECWID-SMOKE', true, 'Issue 12 Test Strain', false)
  RETURNING nocopk INTO v_strain_id;

  SELECT nocopk INTO v_active_location_id
  FROM public.locations
  WHERE lower(btrim(name)) = 'products storage'
  ORDER BY nocopk
  LIMIT 1;

  IF v_active_location_id IS NULL THEN
    INSERT INTO public.locations(name, active, type)
    VALUES ('Products Storage', true, 'Storage')
    RETURNING nocopk INTO v_active_location_id;
  END IF;

  SELECT nocopk INTO v_shipped_location_id
  FROM public.locations
  WHERE lower(btrim(name)) = 'shipped'
  ORDER BY nocopk
  LIMIT 1;

  IF v_shipped_location_id IS NULL THEN
    INSERT INTO public.locations(name, active, type)
    VALUES ('Shipped', true, 'Exception')
    RETURNING nocopk INTO v_shipped_location_id;
  END IF;

  SELECT nocopk INTO v_missing_location_id
  FROM public.locations
  WHERE regexp_replace(lower(COALESCE(name, '')), '[^a-z0-9]', '', 'g') = 'missingorlost'
  ORDER BY nocopk
  LIMIT 1;

  IF v_missing_location_id IS NULL THEN
    INSERT INTO public.locations(name, active, type)
    VALUES ('Missing or Lost', true, 'Exception')
    RETURNING nocopk INTO v_missing_location_id;
  END IF;

  INSERT INTO public.ecommerce(
    name,
    item_id,
    strain_id,
    status,
    ecwid_sku,
    sync_to_ecwid,
    provider,
    site_key,
    external_sku,
    sync_enabled,
    is_primary_public_listing
  )
  VALUES (
    'Issue 12 Ecwid Sync Test Listing',
    v_item_id,
    v_strain_id,
    'FullyColonized',
    'ISSUE12-ECWID-SMOKE-SKU',
    true,
    'ecwid',
    'dank_mushrooms',
    'ISSUE12-ECWID-SMOKE-SKU',
    true,
    true
  )
  RETURNING nocopk INTO v_ecommerce_id;

  /* One available Product. */
  INSERT INTO public.products(
    product_id, item_id, strain_id, name_mat, item_category_mat,
    use_by, storage_location_id
  )
  VALUES (
    'PROD-ISSUE12-ACTIVE',
    v_item_id,
    v_strain_id,
    'Issue 12 Product',
    'fruiting_block',
    CURRENT_DATE + 30,
    v_active_location_id
  );

  /* Terminal/missing/expired Products must not be sellable. */
  INSERT INTO public.products(
    product_id, item_id, strain_id, name_mat, item_category_mat,
    use_by, storage_location_id
  )
  VALUES
    (
      'PROD-ISSUE12-SHIPPED',
      v_item_id,
      v_strain_id,
      'Issue 12 Product',
      'fruiting_block',
      CURRENT_DATE + 30,
      v_shipped_location_id
    ),
    (
      'PROD-ISSUE12-MISSING',
      v_item_id,
      v_strain_id,
      'Issue 12 Product',
      'fruiting_block',
      CURRENT_DATE + 30,
      v_missing_location_id
    ),
    (
      'PROD-ISSUE12-EXPIRED',
      v_item_id,
      v_strain_id,
      'Issue 12 Product',
      'fruiting_block',
      CURRENT_DATE - 1,
      v_active_location_id
    );

  /* FullyColonized and Fridge are both valid for this ecommerce status. */
  INSERT INTO public.lots(
    lot_id, item_id, strain_id, item_name_mat, item_category_mat, status, use_by
  )
  VALUES
    (
      'LOT-ISSUE12-COLONIZED',
      v_item_id,
      v_strain_id,
      'Issue 12 Lot',
      'fruiting_block',
      'FullyColonized',
      CURRENT_DATE + 30
    ),
    (
      'LOT-ISSUE12-FRIDGE',
      v_item_id,
      v_strain_id,
      'Issue 12 Lot',
      'fruiting_block',
      'Fridge',
      CURRENT_DATE + 30
    ),
    (
      'LOT-ISSUE12-CONSUMED',
      v_item_id,
      v_strain_id,
      'Issue 12 Lot',
      'fruiting_block',
      'Consumed',
      CURRENT_DATE + 30
    ),
    (
      'LOT-ISSUE12-EXPIRED',
      v_item_id,
      v_strain_id,
      'Issue 12 Lot',
      'fruiting_block',
      'FullyColonized',
      CURRENT_DATE - 1
    );

  SELECT *
  INTO v_candidate
  FROM public.mp_ecommerce_ecwid_catalog_sync_candidates()
  WHERE ecommerce_id = v_ecommerce_id;

  IF v_candidate.ecommerce_id IS NULL THEN
    RAISE EXCEPTION 'Ecwid catalog candidate function did not return the enabled fixture.';
  END IF;

  IF v_candidate.available_from_products <> 1 THEN
    RAISE EXCEPTION
      'Expected 1 available Product, got %.',
      v_candidate.available_from_products;
  END IF;

  IF v_candidate.available_from_lots <> 2 THEN
    RAISE EXCEPTION
      'Expected 2 available Lots, got %.',
      v_candidate.available_from_lots;
  END IF;

  IF v_candidate.desired_quantity <> 3 THEN
    RAISE EXCEPTION
      'Expected desired Ecwid quantity 3, got %.',
      v_candidate.desired_quantity;
  END IF;

  IF public.mp_normalize_gtin_text('6.865787502055E12') <> '6865787502055' THEN
    RAISE EXCEPTION 'Scientific-notation UPC normalization failed.';
  END IF;

  v_reserved_upc := public.mp_ecommerce_reserve_upc(v_ecommerce_id);
  v_reserved_upc_again := public.mp_ecommerce_reserve_upc(v_ecommerce_id);

  IF v_reserved_upc IS NULL OR v_reserved_upc <> v_reserved_upc_again THEN
    RAISE EXCEPTION 'UPC reservation was null or not idempotent.';
  END IF;

  PERFORM *
  FROM public.mp_ecommerce_ecwid_catalog_sync_writeback(
    jsonb_build_object(
      'ecommerce_id', v_ecommerce_id,
      'site_key', 'dank_mushrooms',
      'external_sku', 'ISSUE12-ECWID-SMOKE-SKU',
      'external_product_id', '610274451',
      'external_variation_id', '987654321',
      'external_category', '160277251',
      'external_price', 14.95,
      'external_stock', 3,
      'public_url', 'https://example.invalid/products/issue-12-test',
      'upc', v_reserved_upc
    )
  );

  SELECT *
  INTO v_row
  FROM public.ecommerce
  WHERE nocopk = v_ecommerce_id;

  IF v_row.external_product_id <> '610274451'
     OR v_row.external_variation_id <> '987654321'
     OR v_row.public_url <> 'https://example.invalid/products/issue-12-test'
     OR v_row.ecwid_url <> v_row.public_url
     OR v_row.external_stock <> 3
     OR v_row.ecwid_stock <> 3
     OR v_row.upc <> v_reserved_upc
     OR v_row.ecwid_upc <> v_reserved_upc THEN
    RAISE EXCEPTION 'Ecwid catalog writeback did not persist legacy + provider-neutral metadata.';
  END IF;

  UPDATE public.ecommerce
  SET
    provider = 'woocommerce',
    site_key = 'future_store',
    public_url = 'https://example.invalid/woocommerce/issue-12-test'
  WHERE nocopk = v_ecommerce_id;

  BEGIN
    PERFORM *
    FROM public.mp_ecommerce_ecwid_catalog_sync_writeback(
      jsonb_build_object(
        'ecommerce_id', v_ecommerce_id,
        'external_sku', 'ISSUE12-ECWID-SMOKE-SKU',
        'external_stock', 99,
        'public_url', 'https://example.invalid/should-not-overwrite'
      )
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'Refusing Ecwid catalog writeback%' THEN
      v_provider_guarded := true;
    ELSE
      RAISE;
    END IF;
  END;

  IF NOT v_provider_guarded THEN
    RAISE EXCEPTION 'Ecwid catalog writeback did not protect a non-Ecwid provider mapping.';
  END IF;

  SELECT *
  INTO v_row
  FROM public.ecommerce
  WHERE nocopk = v_ecommerce_id;

  IF v_row.public_url <> 'https://example.invalid/woocommerce/issue-12-test' THEN
    RAISE EXCEPTION 'Protected WooCommerce URL was overwritten by Ecwid writeback.';
  END IF;

  RAISE NOTICE 'Issue #12 PostgreSQL-to-Ecwid catalog synchronization smoke tests passed.';
END $$;

ROLLBACK;
