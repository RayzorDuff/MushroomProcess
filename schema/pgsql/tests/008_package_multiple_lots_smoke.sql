\set ON_ERROR_STOP on

-- Transactional smoke test for #69 multi-lot Package Lots behavior.
-- Run after 004_computed_views.sql, 005_helpers.sql, and 008_lot_actions.sql.
-- All fixtures and outputs are rolled back.
BEGIN;

DO $$
DECLARE
  v_item_id bigint;
  v_invalid_item_id bigint;
  v_storage_id bigint;
  v_strain_id bigint;
  v_lot_3_id bigint;
  v_lot_5_id bigint;
  v_valid_preflight_lot_id bigint;
  v_invalid_lot_id bigint;
  v_count integer;
  v_expected_error text;
  v_note constant text := 'RC5 multi-lot package smoke note';
  c_lb_to_g constant numeric := 453.59237;
BEGIN
  SELECT nocopk INTO v_item_id
  FROM public.items
  WHERE lower(COALESCE(category, '')) = 'fruiting_block'
    AND COALESCE(active, false)
  ORDER BY nocopk
  LIMIT 1;

  SELECT nocopk INTO v_storage_id
  FROM public.locations
  WHERE lower(btrim(name)) = 'products storage'
    AND COALESCE(active, false)
  ORDER BY nocopk
  LIMIT 1;

  SELECT nocopk INTO v_strain_id
  FROM public.strains
  WHERE COALESCE(active, false)
  ORDER BY nocopk
  LIMIT 1;

  IF v_item_id IS NULL OR v_storage_id IS NULL THEN
    RAISE EXCEPTION 'Multi-lot package smoke-test fixtures are missing from the imported data.';
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
    'LOT-RC5-PACKAGE-3LB',
    v_item_id,
    i.name,
    i.category,
    v_strain_id,
    s.species_strain,
    'Fruiting',
    3,
    'Sterilize',
    clock_timestamp()::timestamp without time zone - interval '30 days',
    clock_timestamp()::timestamp without time zone - interval '28 days',
    clock_timestamp()::timestamp without time zone - interval '21 days'
  FROM public.items i
  LEFT JOIN public.strains s ON s.nocopk = v_strain_id
  WHERE i.nocopk = v_item_id
  RETURNING nocopk INTO v_lot_3_id;

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
    'LOT-RC5-PACKAGE-5LB',
    v_item_id,
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
  WHERE i.nocopk = v_item_id
  RETURNING nocopk INTO v_lot_5_id;

  v_count := public.mp_lots_package_basic(
    p_lot_ids => ARRAY[v_lot_3_id, v_lot_5_id],
    p_package_count => 1,
    p_package_size_g => NULL,
    p_storage_location_id => v_storage_id,
    p_operator => 'RC5 smoke test',
    p_station => 'Lots',
    p_timestamp => clock_timestamp()::timestamp without time zone,
    p_note => v_note
  );

  IF v_count <> 2 THEN
    RAISE EXCEPTION 'Expected two independently packaged lots, got %.', v_count;
  END IF;

  IF (
    SELECT count(*)
    FROM public.products p
    JOIN public._m2m_products_lots_origin_lots j
      ON j.products_id = p.nocopk
    WHERE j.lots_id IN (v_lot_3_id, v_lot_5_id)
      AND p.notes = v_note
  ) <> 2 THEN
    RAISE EXCEPTION 'Expected one independent product for each selected lot.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.lots l
    JOIN public._m2m_products_lots_origin_lots j
      ON j.lots_id = l.nocopk
    JOIN public.products p
      ON p.nocopk = j.products_id
    WHERE l.nocopk IN (v_lot_3_id, v_lot_5_id)
      AND (
        abs(p.net_weight_g - round(l.unit_size * c_lb_to_g, 2)) > 0.01
        OR abs(p.net_weight_oz - round(l.unit_size * 16, 2)) > 0.01
        OR p.package_count <> 1
        OR p.notes IS DISTINCT FROM v_note
      )
  ) THEN
    RAISE EXCEPTION 'Multi-lot products did not preserve independent source weights or operator notes.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.lots
    WHERE nocopk IN (v_lot_3_id, v_lot_5_id)
      AND status IS DISTINCT FROM 'Consumed'
  ) THEN
    RAISE EXCEPTION 'Every successfully packaged source lot must be Consumed.';
  END IF;

  IF (
    SELECT count(*)
    FROM public.events e
    WHERE e.type = 'Package'
      AND e.lot_id IN (v_lot_3_id, v_lot_5_id)
      AND e.product_id IS NOT NULL
      AND e.fields_json::jsonb ->> 'note' = v_note
  ) <> 2 THEN
    RAISE EXCEPTION 'Expected one Package event per selected lot.';
  END IF;

  IF (
    SELECT count(*)
    FROM public.print_queue pq
    WHERE pq.lot_id IN (v_lot_3_id, v_lot_5_id)
      AND pq.source_kind = 'product'
      AND pq.label_type = 'Product_Package'
      AND pq.print_status = 'Queued'
  ) <> 2 THEN
    RAISE EXCEPTION 'Expected one Product_Package print job per selected lot.';
  END IF;

  -- Create one valid and one deliberately unpackageable lot. The complete
  -- selection must fail before the valid lot is mutated.
  INSERT INTO public.items (
    item_id,
    name,
    category,
    active
  ) VALUES (
    'ITEM-RC5-PACK-NOSIZE',
    'RC5 Package Item Without Size',
    'fruiting_block',
    true
  )
  RETURNING nocopk INTO v_invalid_item_id;

  INSERT INTO public.lots (
    lot_id,
    item_id,
    item_name_mat,
    item_category_mat,
    status,
    unit_size,
    created_at
  )
  SELECT
    'LOT-RC5-PACKAGE-PREFLIGHT-VALID',
    v_item_id,
    i.name,
    i.category,
    'Fruiting',
    3,
    clock_timestamp()::timestamp without time zone
  FROM public.items i
  WHERE i.nocopk = v_item_id
  RETURNING nocopk INTO v_valid_preflight_lot_id;

  INSERT INTO public.lots (
    lot_id,
    item_id,
    item_name_mat,
    item_category_mat,
    status,
    unit_size,
    created_at
  ) VALUES (
    'LOT-RC5-PACKAGE-PREFLIGHT-INVALID',
    v_invalid_item_id,
    'RC5 Package Item Without Size',
    'fruiting_block',
    'Fruiting',
    NULL,
    clock_timestamp()::timestamp without time zone
  )
  RETURNING nocopk INTO v_invalid_lot_id;

  BEGIN
    PERFORM public.mp_lots_package_basic(
      p_lot_ids => ARRAY[v_valid_preflight_lot_id, v_invalid_lot_id],
      p_package_count => 1,
      p_package_size_g => NULL,
      p_storage_location_id => v_storage_id,
      p_operator => 'RC5 smoke test',
      p_station => 'Lots',
      p_timestamp => clock_timestamp()::timestamp without time zone,
      p_note => 'This note must not be confused with validation text'
    );

    RAISE EXCEPTION 'Expected invalid multi-lot package selection to fail.';
  EXCEPTION WHEN OTHERS THEN
    v_expected_error := SQLERRM;
    IF v_expected_error = 'Expected invalid multi-lot package selection to fail.' THEN
      RAISE;
    END IF;
    IF position('does not have a packageable weight' in v_expected_error) = 0 THEN
      RAISE EXCEPTION 'Unexpected preflight validation error: %', v_expected_error;
    END IF;
  END;

  IF (SELECT status FROM public.lots WHERE nocopk = v_valid_preflight_lot_id) IS DISTINCT FROM 'Fruiting' THEN
    RAISE EXCEPTION 'Valid lot was mutated before the complete selection passed validation.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public._m2m_products_lots_origin_lots
    WHERE lots_id IN (v_valid_preflight_lot_id, v_invalid_lot_id)
  ) THEN
    RAISE EXCEPTION 'Products were created for a selection that failed preflight validation.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.products
    WHERE notes ILIKE '%does not have a packageable weight%'
  ) THEN
    RAISE EXCEPTION 'Validation text was persisted as a product note.';
  END IF;

  RAISE NOTICE 'Multi-lot independent package, summary-state, and preflight smoke tests passed.';
END;
$$;

ROLLBACK;
