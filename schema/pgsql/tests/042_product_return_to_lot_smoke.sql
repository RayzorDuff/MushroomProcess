\set ON_ERROR_STOP on

-- Issue #57 Phase 1 smoke test: Product -> returned Lot foundation.
-- Run after 001-006, 008_lot_actions.sql, 042_product_return_to_lot.sql,
-- and 043_product_return_lineage.sql. All fixtures and outputs are rolled back.
BEGIN;

DO $$
DECLARE
  v_products_loc bigint;
  v_consumed_loc bigint;
  v_grain_item bigint;
  v_sub_item bigint;
  v_lc_item bigint;
  v_lc_flask_item bigint;
  v_freeze_item bigint;
  v_freeze_product bigint;
  v_recipe bigint;
  v_strain bigint;
  v_origin_grain bigint;
  v_origin_sub bigint;
  v_origin_lc bigint;
  v_product_grain bigint;
  v_product_sub bigint;
  v_product_lc bigint;
  v_returned_grain bigint;
  v_returned_sub bigint;
  v_returned_lc bigint;
  v_component bigint;
  v_err text;
BEGIN
  SELECT nocopk INTO v_products_loc
  FROM public.locations
  WHERE lower(btrim(name)) = 'products storage'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  IF v_products_loc IS NULL THEN
    INSERT INTO public.locations(name, active, type)
    VALUES ('Products Storage', true, 'Storage')
    RETURNING nocopk INTO v_products_loc;
  END IF;

  SELECT nocopk INTO v_consumed_loc
  FROM public.locations
  WHERE lower(btrim(name)) = 'consumed'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  IF v_consumed_loc IS NULL THEN
    INSERT INTO public.locations(name, active, type)
    VALUES ('Consumed', true, 'Terminal')
    RETURNING nocopk INTO v_consumed_loc;
  END IF;

  INSERT INTO public.items(item_id, name, category, active)
  VALUES ('ITEM-ISS57-GRAIN', 'Issue 57 Grain', 'grain', true)
  RETURNING nocopk INTO v_grain_item;

  INSERT INTO public.items(item_id, name, category, active)
  VALUES ('ITEM-ISS57-SUB', 'Issue 57 Substrate', 'substrate', true)
  RETURNING nocopk INTO v_sub_item;

  INSERT INTO public.items(item_id, name, category, active)
  VALUES ('ITEM-ISS57-LC', 'Issue 57 LC Syringe', 'lc_syringe', true)
  RETURNING nocopk INTO v_lc_item;

  INSERT INTO public.items(item_id, name, category, active)
  VALUES ('ITEM-ISS57-LC-FLASK', 'Issue 57 LC Flask', 'lc_flask', true)
  RETURNING nocopk INTO v_lc_flask_item;

  INSERT INTO public.items(item_id, name, category, active)
  VALUES ('ITEM-ISS57-FD', 'Issue 57 Freeze Dried', 'freezedriedmushrooms', true)
  RETURNING nocopk INTO v_freeze_item;

  INSERT INTO public.products(
    product_id, item_id, name_mat, item_category_mat, net_weight_g,
    pack_date, use_by, storage_location_id
  ) VALUES (
    'PROD-ISS57-FD', v_freeze_item, 'Issue 57 Freeze Dried', 'freezedriedmushrooms', 14,
    date '2026-09-01', date '2027-09-01', v_products_loc
  ) RETURNING nocopk INTO v_freeze_product;

  IF EXISTS (
    SELECT 1
    FROM public.mp_product_cultivation_eligibility(v_freeze_product, date '2026-09-15')
    WHERE eligible_for_return OR can_inoculate_target OR can_inoculate_source OR can_spawn_substrate
  ) THEN
    RAISE EXCEPTION 'Freeze-dried Product was incorrectly exposed as eligible cultivation inventory.';
  END IF;

  INSERT INTO public.recipes(recipe_id, active, name, category)
  VALUES ('RECIPE-ISS57', true, 'Issue 57 substrate recipe', 'substrate')
  RETURNING nocopk INTO v_recipe;

  INSERT INTO public.strains(strain_id, active, species_strain, regulated)
  VALUES ('STRAIN-ISS57', true, 'Issue 57 Test Strain', false)
  RETURNING nocopk INTO v_strain;

  INSERT INTO public.lots(
    lot_id, item_id, item_name_mat, item_category_mat, recipe_id,
    qty, unit_size, status, location_id, created_at, sterilized_at,
    use_by, process_type_mat
  ) VALUES (
    'LOT-ISS57-GRAIN-ORIGIN', v_grain_item, 'Issue 57 Grain', 'grain', v_recipe,
    1, 2, 'Consumed', v_consumed_loc, timestamp '2026-08-01 10:00', timestamp '2026-08-01 10:00',
    date '2026-10-15', 'Sterilize'
  ) RETURNING nocopk INTO v_origin_grain;

  INSERT INTO public.products(
    product_id, item_id, name_mat, item_category_mat, net_weight_g,
    pack_date, use_by, storage_location_id, origin_lot_ids_json, process_type_mat
  ) VALUES (
    'PROD-ISS57-GRAIN', v_grain_item, 'Issue 57 Grain', 'grain', 907.18474,
    date '2026-08-15', date '2026-11-15', v_products_loc,
    to_jsonb(ARRAY['LOT-ISS57-GRAIN-ORIGIN'])::text, 'Sterilize'
  ) RETURNING nocopk INTO v_product_grain;

  INSERT INTO public._m2m_products_lots_origin_lots(products_id, lots_id)
  VALUES (v_product_grain, v_origin_grain);

  IF NOT (
    SELECT eligible_for_return AND can_inoculate_target
      AND NOT can_inoculate_source AND NOT can_spawn_substrate
    FROM public.mp_product_cultivation_eligibility(v_product_grain, date '2026-09-15')
  ) THEN
    RAISE EXCEPTION 'Grain Product eligibility/capability classification failed.';
  END IF;

  v_returned_grain := public.mp_product_return_to_lot(
    p_product_id => v_product_grain,
    p_operator => 'Issue 57 smoke',
    p_station => 'Lots',
    p_timestamp => timestamp '2026-09-15 12:00',
    p_note => 'farmers market return',
    p_label_type => NULL
  );

  IF NOT EXISTS (
    SELECT 1
    FROM public.lots l
    WHERE l.nocopk = v_returned_grain
      AND l.source_product_id = v_product_grain
      AND l.status = 'Sterilized'
      AND l.use_by = date '2026-10-15'
      AND abs(l.unit_size - 2) < 0.00001
  ) THEN
    RAISE EXCEPTION 'Returned grain Lot did not preserve Product lineage, size, state, or earliest expiration.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.products p
    WHERE p.nocopk = v_product_grain
      AND p.storage_location_id = v_consumed_loc
  ) THEN
    RAISE EXCEPTION 'Returned grain Product remained sellable instead of moving to Consumed.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public._m2m_lots_products_source_product_id x
    WHERE x.lots_id = v_returned_grain
      AND x.products_id = v_product_grain
  ) THEN
    RAISE EXCEPTION 'Returned grain canonical source_product_id was not mirrored to the retained compatibility junction.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.events e
    WHERE e.type = 'ReturnedToLotInventory'
      AND e.product_id = v_product_grain
      AND e.lot_id = v_returned_grain
  ) THEN
    RAISE EXCEPTION 'Returned grain transition event was not recorded against Product and Lot.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public._m2m_products_events_events pe
    JOIN public.events e ON e.nocopk = pe.events_id
    WHERE pe.products_id = v_product_grain
      AND e.type = 'ReturnedToLotInventory'
      AND e.lot_id = v_returned_grain
  ) THEN
    RAISE EXCEPTION 'Returned grain audit event was not linked into Product event history.';
  END IF;

  IF EXISTS (SELECT 1 FROM public.print_queue pq WHERE pq.lot_id = v_returned_grain) THEN
    RAISE EXCEPTION 'Raw Product return queued an intermediate label instead of deferring label policy to the consuming operation.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.v_reporting_lot_lineage x
    WHERE x.lot_nocopk = v_returned_grain
      AND x.direction = 'upstream'
      AND x.relationship_type = 'source_product'
      AND x.related_nocopk = v_product_grain
  ) OR NOT EXISTS (
    SELECT 1 FROM public.v_reporting_lot_lineage x
    WHERE x.lot_nocopk = v_returned_grain
      AND x.direction = 'upstream'
      AND x.relationship_type = 'product_origin_lot'
      AND x.related_nocopk = v_origin_grain
  ) THEN
    RAISE EXCEPTION 'Reporting lineage cannot traverse returned Lot -> Product -> origin Lot.';
  END IF;

  BEGIN
    PERFORM public.mp_product_return_to_lot(v_product_grain, 'Issue 57 smoke');
    RAISE EXCEPTION 'Expected second return of the same Product to fail.';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    IF v_err NOT ILIKE '%already been returned%' AND v_err NOT ILIKE '%unavailable storage location%' THEN
      RAISE;
    END IF;
  END;

  INSERT INTO public.lots(
    lot_id, item_id, item_name_mat, item_category_mat, recipe_id,
    qty, unit_size, status, location_id, created_at, sterilized_at,
    use_by, process_type_mat
  ) VALUES (
    'LOT-ISS57-SUB-ORIGIN', v_sub_item, 'Issue 57 Substrate', 'substrate', v_recipe,
    1, 5, 'Consumed', v_consumed_loc, timestamp '2026-08-05 10:00', timestamp '2026-08-05 10:00',
    date '2026-10-20', 'Pasteurize'
  ) RETURNING nocopk INTO v_origin_sub;

  INSERT INTO public.lot_recipe_components(
    lot_id, item_id, recipe_id, component_role, component_weight_lb,
    component_percent, sort_order, notes
  ) VALUES (
    v_origin_sub, v_sub_item, v_recipe, 'substrate', 5, 100, 1, 'Issue 57 source component'
  ) RETURNING nocopk INTO v_component;
  PERFORM public.mp_link_lot_recipe_component(v_component, v_origin_sub, v_sub_item, v_recipe, NULL);

  INSERT INTO public.products(
    product_id, item_id, name_mat, item_category_mat, net_weight_g,
    pack_date, use_by, storage_location_id, origin_lot_ids_json, process_type_mat
  ) VALUES (
    'PROD-ISS57-SUB', v_sub_item, 'Issue 57 Substrate', 'substrate', 2267.96185,
    date '2026-08-15', date '2026-10-25', v_products_loc,
    to_jsonb(ARRAY['LOT-ISS57-SUB-ORIGIN'])::text, 'Pasteurize'
  ) RETURNING nocopk INTO v_product_sub;
  INSERT INTO public._m2m_products_lots_origin_lots(products_id, lots_id)
  VALUES (v_product_sub, v_origin_sub);

  IF NOT (
    SELECT eligible_for_return AND can_spawn_substrate
    FROM public.mp_product_cultivation_eligibility(v_product_sub, date '2026-09-15')
  ) THEN
    RAISE EXCEPTION 'Substrate Product eligibility/capability classification failed.';
  END IF;

  v_returned_sub := public.mp_product_return_to_lot(
    p_product_id => v_product_sub,
    p_operator => 'Issue 57 smoke',
    p_station => 'Spawn to Bulk',
    p_timestamp => timestamp '2026-09-15 12:05',
    p_label_type => NULL
  );

  IF NOT EXISTS (
    SELECT 1 FROM public.lots l
    WHERE l.nocopk = v_returned_sub
      AND l.status = 'Pasteurized'
      AND l.use_by = date '2026-10-20'
  ) THEN
    RAISE EXCEPTION 'Returned substrate did not preserve process state or earliest expiration.';
  END IF;

  IF (SELECT count(*) FROM public.lot_recipe_components WHERE lot_id = v_returned_sub) <> 1 THEN
    RAISE EXCEPTION 'Returned substrate did not preserve recipe-component history.';
  END IF;

  IF EXISTS (SELECT 1 FROM public.print_queue pq WHERE pq.lot_id = v_returned_sub) THEN
    RAISE EXCEPTION 'Contextual substrate return queued an unnecessary intermediate Lot label.';
  END IF;

  INSERT INTO public.lots(
    lot_id, item_id, item_name_mat, item_category_mat, strain_id, strain_species_strain_mat,
    qty, unit_size, status, location_id, created_at, use_by
  ) VALUES (
    'LOT-ISS57-LC-ORIGIN', v_lc_flask_item, 'Issue 57 LC source', 'lc_flask', v_strain, 'Issue 57 Test Strain',
    1, 100, 'Consumed', v_consumed_loc, timestamp '2026-08-01 10:00', date '2026-12-01'
  ) RETURNING nocopk INTO v_origin_lc;

  INSERT INTO public.products(
    product_id, item_id, name_mat, item_category_mat, strain_id, net_volume_ml,
    pack_date, use_by, storage_location_id, origin_lot_ids_json
  ) VALUES (
    'PROD-ISS57-LC', v_lc_item, 'Issue 57 LC Syringe', 'lc_syringe', v_strain, 10,
    date '2026-08-20', date '2026-11-20', v_products_loc,
    to_jsonb(ARRAY['LOT-ISS57-LC-ORIGIN'])::text
  ) RETURNING nocopk INTO v_product_lc;
  INSERT INTO public._m2m_products_lots_origin_lots(products_id, lots_id)
  VALUES (v_product_lc, v_origin_lc);

  IF NOT (
    SELECT eligible_for_return AND can_inoculate_source
    FROM public.mp_product_cultivation_eligibility(v_product_lc, date '2026-09-15')
  ) THEN
    RAISE EXCEPTION 'LC syringe Product eligibility/capability classification failed.';
  END IF;

  v_returned_lc := public.mp_product_return_to_lot(
    p_product_id => v_product_lc,
    p_operator => 'Issue 57 smoke',
    p_station => 'Inoculation',
    p_timestamp => timestamp '2026-09-15 12:10',
    p_label_type => NULL
  );

  IF NOT EXISTS (
    SELECT 1 FROM public.lots l
    WHERE l.nocopk = v_returned_lc
      AND l.status = 'Fridge'
      AND l.source_product_id = v_product_lc
      AND l.total_volume_ml = 10
      AND l.remaining_volume_ml = 10
      AND l.strain_id = v_strain
      AND l.strain_species_strain_mat = 'Issue 57 Test Strain'
      AND l.use_by = date '2026-11-20'
  ) THEN
    RAISE EXCEPTION 'Returned LC syringe did not preserve packaged volume/expiration.';
  END IF;
END;
$$;

ROLLBACK;
