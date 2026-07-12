\set ON_ERROR_STOP on

-- Transactional smoke test for #68 AIO package/productize behavior.
-- Run after 004_computed_views.sql, 005_helpers.sql, and 008_lot_actions.sql.
-- All fixtures and outputs are rolled back.
BEGIN;

DO $$
DECLARE
  v_aio_item_id bigint;
  v_storage_id bigint;
  v_strain_id bigint;
  v_lot_id bigint;
  v_product_id bigint;
  v_count integer;
  v_product record;
  v_lot_status text;
  v_title text;
  v_subtitle text;
  c_lb_to_g constant numeric := 453.59237;
BEGIN
  SELECT nocopk INTO v_aio_item_id
  FROM public.items
  WHERE item_id = 'AIO-BAG'
    AND COALESCE(active, false)
  LIMIT 1;

  SELECT nocopk INTO v_storage_id
  FROM public.locations
  WHERE lower(btrim(name)) = 'products storage'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  SELECT nocopk INTO v_strain_id
  FROM public.strains
  WHERE COALESCE(active, false)
  ORDER BY nocopk
  LIMIT 1;

  IF v_aio_item_id IS NULL OR v_storage_id IS NULL THEN
    RAISE EXCEPTION 'AIO package smoke-test fixtures are missing from the imported Airtable data.';
  END IF;

  INSERT INTO public.lots (
    lot_id,
    item_id,
    item_name_mat,
    item_category_mat,
    strain_id,
    strain_species_strain_mat,
    status,
    unit_size,
    process_type_mat,
    created_at,
    inoculated_at,
    spawned_at
  )
  SELECT
    'LOT-RC5-AIO-PACKAGE',
    v_aio_item_id,
    i.name,
    i.category,
    v_strain_id,
    s.species_strain,
    'Fruiting',
    5,
    'Sterilize',
    clock_timestamp()::timestamp without time zone - interval '30 days',
    clock_timestamp()::timestamp without time zone - interval '28 days',
    clock_timestamp()::timestamp without time zone - interval '21 days'
  FROM public.items i
  LEFT JOIN public.strains s ON s.nocopk = v_strain_id
  WHERE i.nocopk = v_aio_item_id
  RETURNING nocopk INTO v_lot_id;

  v_count := public.mp_lots_package_basic(
    p_lot_ids => ARRAY[v_lot_id],
    p_package_count => 1,
    p_package_size_g => round(5 * c_lb_to_g, 2),
    p_storage_location_id => v_storage_id,
    p_operator => 'RC5 smoke test',
    p_station => 'Lots',
    p_timestamp => clock_timestamp()::timestamp without time zone,
    p_note => 'Rollback-only AIO package smoke test'
  );

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Expected one packaged AIO lot, got %.', v_count;
  END IF;

  SELECT p.nocopk INTO v_product_id
  FROM public.products p
  JOIN public._m2m_products_lots_origin_lots j
    ON j.products_id = p.nocopk
  WHERE j.lots_id = v_lot_id
    AND p.notes = 'Rollback-only AIO package smoke test'
  ORDER BY p.nocopk DESC
  LIMIT 1;

  IF v_product_id IS NULL THEN
    RAISE EXCEPTION 'AIO package product or origin-lot link was not created.';
  END IF;

  SELECT
    item_category_mat,
    net_weight_g,
    net_weight_oz,
    package_count,
    package_size_g,
    process_type_mat
  INTO v_product
  FROM public.products
  WHERE nocopk = v_product_id;

  IF v_product.item_category_mat <> 'all_in_one_bag'
     OR abs(v_product.net_weight_g - round(5 * c_lb_to_g, 2)) > 0.01
     OR abs(v_product.net_weight_oz - 80) > 0.01
     OR v_product.package_count <> 1
     OR abs(v_product.package_size_g - round(5 * c_lb_to_g, 2)) > 0.01
     OR lower(COALESCE(v_product.process_type_mat, '')) <> 'sterilize' THEN
    RAISE EXCEPTION 'AIO packaged product fields are incorrect: %', row_to_json(v_product);
  END IF;

  SELECT status INTO v_lot_status
  FROM public.lots
  WHERE nocopk = v_lot_id;

  IF v_lot_status <> 'Consumed' THEN
    RAISE EXCEPTION 'AIO source lot was not consumed after packaging: %', v_lot_status;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public._m2m_products_locations_storage_location j
    WHERE j.products_id = v_product_id
      AND j.locations_id = v_storage_id
  ) THEN
    RAISE EXCEPTION 'AIO product storage location link is missing.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.events e
    WHERE e.lot_id = v_lot_id
      AND e.product_id = v_product_id
      AND e.type = 'Package'
  ) THEN
    RAISE EXCEPTION 'AIO package event is missing.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.print_queue pq
    WHERE pq.product_id = v_product_id
      AND pq.source_kind = 'product'
      AND pq.label_type = 'Product_Package'
      AND pq.print_status = 'Queued'
  ) THEN
    RAISE EXCEPTION 'AIO product print-queue row is missing.';
  END IF;

  SELECT label_title_prod, label_subtitle_prod
  INTO v_title, v_subtitle
  FROM public.vc_products
  WHERE nocopk = v_product_id;

  IF NULLIF(btrim(v_title), '') IS NULL
     OR position('5 lb' IN COALESCE(v_subtitle, '')) = 0
     OR position('Sterilized' IN COALESCE(v_subtitle, '')) = 0 THEN
    RAISE EXCEPTION 'AIO product label fields are incorrect: title %, subtitle %', v_title, v_subtitle;
  END IF;

  RAISE NOTICE 'AIO package/productize smoke tests passed.';
END;
$$;

ROLLBACK;
