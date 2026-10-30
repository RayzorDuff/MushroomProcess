\set ON_ERROR_STOP on

-- Regression coverage for Product-backed inoculation targets.
-- A packaged grain Product may have no storage_location_id. The contextual
-- inoculation wrapper must return each Product to the selected inoculation
-- destination before passing those returned Lots to the normal inoculation
-- operation. All fixtures and outputs are rolled back.

BEGIN;

DO $test$
DECLARE
  v_dark_loc bigint;
  v_consumed_loc bigint;
  v_grain_item bigint;
  v_lc_item bigint;
  v_strain bigint;
  v_lc_source bigint;
  v_origin_1 bigint;
  v_origin_2 bigint;
  v_product_1 bigint;
  v_product_2 bigint;
  v_returned_ids bigint[];
  v_inoculated_count integer;
  v_now timestamp without time zone := now();
BEGIN
  SELECT nocopk INTO v_dark_loc
  FROM public.locations
  WHERE regexp_replace(lower(btrim(name)), '[^a-z0-9]', '', 'g') = 'darkroom'
    AND COALESCE(active, false)
  ORDER BY nocopk
  LIMIT 1;

  SELECT nocopk INTO v_consumed_loc
  FROM public.locations
  WHERE regexp_replace(lower(btrim(name)), '[^a-z0-9]', '', 'g') = 'consumed'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  SELECT nocopk INTO v_grain_item
  FROM public.items
  WHERE item_id = 'GRAIN-BAG'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  SELECT nocopk INTO v_lc_item
  FROM public.items
  WHERE item_id = 'LC-SYRINGE'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  SELECT nocopk INTO v_strain
  FROM public.strains
  WHERE COALESCE(active, false)
    AND NULLIF(btrim(species_strain), '') IS NOT NULL
  ORDER BY nocopk
  LIMIT 1;

  IF v_dark_loc IS NULL OR v_consumed_loc IS NULL
     OR v_grain_item IS NULL OR v_lc_item IS NULL OR v_strain IS NULL THEN
    RAISE EXCEPTION 'Product-target inoculation smoke fixtures are missing required imported data.';
  END IF;

  -- Use a normal LC Lot as the source so this test isolates the Product-target
  -- return path rather than also exercising Product-source deproductization.
  INSERT INTO public.lots(
    lot_id, item_id, item_name_mat, item_category_mat, strain_id,
    strain_species_strain_mat, qty, unit_size, status, location_id,
    total_volume_ml, remaining_volume_ml, created_at, inoculated_at, use_by
  )
  SELECT
    'LOT-ISS57-048-LC-SOURCE', v_lc_item, i.name, i.category, v_strain,
    s.species_strain, 1, 2, 'Colonizing', v_dark_loc,
    2, 2, v_now - interval '5 days', v_now - interval '4 days',
    v_now::date + 30
  FROM public.items i
  CROSS JOIN public.strains s
  WHERE i.nocopk = v_lc_item
    AND s.nocopk = v_strain
  RETURNING nocopk INTO v_lc_source;

  -- Both packaged grain Products intentionally have NULL storage_location_id.
  -- This reproduces the production failure reported for two Product targets.
  INSERT INTO public.lots(
    lot_id, item_id, item_name_mat, item_category_mat,
    qty, unit_size, status, location_id, created_at, sterilized_at, use_by
  )
  SELECT
    'LOT-ISS57-048-GRAIN-ORIGIN-1', v_grain_item, i.name, 'grain',
    1, 2, 'Consumed', v_consumed_loc, v_now - interval '20 days',
    v_now - interval '20 days', v_now::date + 20
  FROM public.items i
  WHERE i.nocopk = v_grain_item
  RETURNING nocopk INTO v_origin_1;

  INSERT INTO public.lots(
    lot_id, item_id, item_name_mat, item_category_mat,
    qty, unit_size, status, location_id, created_at, sterilized_at, use_by
  )
  SELECT
    'LOT-ISS57-048-GRAIN-ORIGIN-2', v_grain_item, i.name, 'grain',
    1, 2, 'Consumed', v_consumed_loc, v_now - interval '21 days',
    v_now - interval '21 days', v_now::date + 25
  FROM public.items i
  WHERE i.nocopk = v_grain_item
  RETURNING nocopk INTO v_origin_2;

  INSERT INTO public.products(
    product_id, item_id, name_mat, item_category_mat, net_weight_g,
    pack_date, use_by, storage_location_id, origin_lot_ids_json, process_type_mat
  )
  SELECT
    'PROD-ISS57-048-GRAIN-1', v_grain_item, i.name, 'grain', 907.18474,
    v_now::date - 5, v_now::date + 20, NULL,
    to_jsonb(ARRAY['LOT-ISS57-048-GRAIN-ORIGIN-1'])::text, 'Sterilize'
  FROM public.items i
  WHERE i.nocopk = v_grain_item
  RETURNING nocopk INTO v_product_1;

  INSERT INTO public.products(
    product_id, item_id, name_mat, item_category_mat, net_weight_g,
    pack_date, use_by, storage_location_id, origin_lot_ids_json, process_type_mat
  )
  SELECT
    'PROD-ISS57-048-GRAIN-2', v_grain_item, i.name, 'grain', 907.18474,
    v_now::date - 4, v_now::date + 25, NULL,
    to_jsonb(ARRAY['LOT-ISS57-048-GRAIN-ORIGIN-2'])::text, 'Sterilize'
  FROM public.items i
  WHERE i.nocopk = v_grain_item
  RETURNING nocopk INTO v_product_2;

  INSERT INTO public._m2m_products_lots_origin_lots(products_id, lots_id)
  VALUES (v_product_1, v_origin_1), (v_product_2, v_origin_2);

  SELECT r.inoculated_count, r.returned_target_lot_ids
  INTO v_inoculated_count, v_returned_ids
  FROM public.mp_inoculate_with_products_result(
    p_source_lot_id => v_lc_source,
    p_target_product_ids => ARRAY[v_product_1, v_product_2],
    p_storage_location_id => v_dark_loc,
    p_lc_volume_ml => 1,
    p_operator => 'Issue 57 Product target storage smoke',
    p_station => 'Lab - Inoculate',
    p_timestamp => v_now,
    p_note => 'Two Product grain targets with no Product storage location'
  ) r;

  IF v_inoculated_count <> 2 THEN
    RAISE EXCEPTION 'Expected two Product-backed inoculation targets, got %.', v_inoculated_count;
  END IF;

  IF cardinality(v_returned_ids) <> 2 THEN
    RAISE EXCEPTION 'Expected two returned target Lots, got %.', cardinality(v_returned_ids);
  END IF;

  IF (
    SELECT count(*)
    FROM public.lots l
    WHERE l.nocopk = ANY(v_returned_ids)
      AND l.status = 'Colonizing'
      AND l.location_id = v_dark_loc
      AND l.label_template = 'Grain_Inoculated'
      AND l.strain_id = v_strain
      AND l.inoculated_at = v_now
  ) <> 2 THEN
    RAISE EXCEPTION 'Both Product-backed target Lots did not complete normal inoculation at the selected storage location.';
  END IF;

  IF (
    SELECT count(*)
    FROM public.lots l
    WHERE l.nocopk = ANY(v_returned_ids)
      AND l.source_product_id IN (v_product_1, v_product_2)
  ) <> 2 THEN
    RAISE EXCEPTION 'Returned Product target genealogy is incomplete.';
  END IF;

  IF (
    SELECT count(*)
    FROM public.products p
    WHERE p.nocopk IN (v_product_1, v_product_2)
      AND p.storage_location_id = v_consumed_loc
  ) <> 2 THEN
    RAISE EXCEPTION 'Both consumed Product targets were not moved to Consumed.';
  END IF;

  IF (
    SELECT count(*)
    FROM public.print_queue q
    WHERE q.lot_id = ANY(v_returned_ids)
      AND q.label_type = 'Grain_Inoculated'
  ) <> 2 THEN
    RAISE EXCEPTION 'Expected two normal Grain_Inoculated labels for the Product targets.';
  END IF;

  RAISE NOTICE 'Product-backed inoculation target storage regression passed for two Product grains.';
END;
$test$;

ROLLBACK;