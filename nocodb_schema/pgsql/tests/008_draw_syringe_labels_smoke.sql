\set ON_ERROR_STOP on

BEGIN;

DO $$
DECLARE
  v_location_id bigint;
  v_strain_id bigint;
  v_flask_item_id bigint;
  v_syringe_item_id bigint;
  v_source_lot_id bigint;
  v_drawn_lot_id bigint;
  v_received_lot_id bigint;
  v_product_id bigint;
  v_created integer;
  v_title text;
  v_subtitle text;
  v_queue_title text;
  v_queue_subtitle text;
  v_drawn_vendor_name text;
  v_drawn_vendor_batch text;
BEGIN
  INSERT INTO public.locations(name, active, type, notes)
  VALUES ('RC5 Draw Syringe Fridge', true, 'Storage', 'Rollback-only #60 smoke fixture')
  RETURNING nocopk INTO v_location_id;

  INSERT INTO public.strains(strain_id, active, species_strain, regulated)
  VALUES ('STRAIN-RC5-DRAW-SYRINGE', true, 'RC5 Test Strain', false)
  RETURNING nocopk INTO v_strain_id;

  INSERT INTO public.items(item_id, active, name, category, default_unit_size_ml, component_mode, size_source)
  VALUES ('ITEM-RC5-LC-FLASK', true, 'RC5 LC Flask', 'lc_flask', 100, 'single_recipe', 'lot_unit_size')
  RETURNING nocopk INTO v_flask_item_id;

  INSERT INTO public.items(item_id, active, name, category, default_unit_size_ml, component_mode, size_source)
  VALUES ('ITEM-RC5-LC-SYRINGE', true, 'RC5 LC Syringe', 'lc_syringe', 10, 'single_recipe', 'lot_unit_size')
  RETURNING nocopk INTO v_syringe_item_id;

  INSERT INTO public.lots(
    lot_id,
    item_id,
    item_name_mat,
    item_category_mat,
    strain_id,
    strain_species_strain_mat,
    vendor_name_mat,
    vendor_batch,
    source_type,
    status,
    operator,
    created_at,
    qty,
    unit_size,
    total_volume_ml,
    remaining_volume_ml,
    received_date,
    use_by,
    label_template
  )
  VALUES (
    'LOT-RC5-DRAW-SOURCE',
    v_flask_item_id,
    'RC5 LC Flask',
    'lc_flask',
    v_strain_id,
    'RC5 Test Strain',
    'RC5 Vendor',
    'BATCH-RC5-DRAW',
    'Produced',
    'Fridge',
    'RC5 smoke test',
    timestamp '2026-07-13 08:00:00',
    1,
    100,
    100,
    100,
    date '2026-07-13',
    date '2026-10-13',
    'LC_Flask_Inoculated'
  )
  RETURNING nocopk INTO v_source_lot_id;

  INSERT INTO public._m2m_lots_items_item_id(lots_id, items_id)
  VALUES (v_source_lot_id, v_flask_item_id)
  ON CONFLICT DO NOTHING;

  INSERT INTO public._m2m_lots_strains_strain_id(lots_id, strains_id)
  VALUES (v_source_lot_id, v_strain_id)
  ON CONFLICT DO NOTHING;

  v_created := public.mp_lots_draw_syringes(
    p_source_lc_flask_lot_id => v_source_lot_id,
    p_syringe_item_id => v_syringe_item_id,
    p_syringe_count => 1,
    p_ml_each => 10,
    p_storage_location_id => v_location_id,
    p_operator => 'RC5 smoke test',
    p_timestamp => timestamp '2026-07-13 09:00:00',
    p_notes => 'Rollback-only #60 smoke test'
  );

  IF v_created <> 1 THEN
    RAISE EXCEPTION 'Expected one drawn syringe lot, got %', v_created;
  END IF;

  SELECT l.nocopk
  INTO v_drawn_lot_id
  FROM public.lots l
  WHERE l.source_lot_id = v_source_lot_id
    AND l.label_template = 'LC_Syringe_Drawn'
  ORDER BY l.nocopk DESC
  LIMIT 1;

  SELECT label_title_lot, label_subtitle_lot, vendor_name, vendor_batch
  INTO v_title, v_subtitle, v_drawn_vendor_name, v_drawn_vendor_batch
  FROM public.vc_lots
  WHERE nocopk = v_drawn_lot_id;

  IF v_title <> 'RC5 LC Syringe' THEN
    RAISE EXCEPTION 'Drawn syringe title is incorrect: %', v_title;
  END IF;

  IF v_drawn_vendor_name <> 'RC5 Vendor'
     OR v_drawn_vendor_batch <> 'BATCH-RC5-DRAW' THEN
    RAISE EXCEPTION 'Drawn syringe vendor lineage is incorrect: vendor %, batch %',
      v_drawn_vendor_name, v_drawn_vendor_batch;
  END IF;

  IF COALESCE(v_subtitle, '') NOT LIKE '10%ml%RC5 Test Strain%RC5 Vendor%BATCH-RC5-DRAW%' THEN
    RAISE EXCEPTION 'Drawn syringe subtitle is incorrect: %', v_subtitle;
  END IF;

  SELECT
    (label_title_lot_from_lot_id)[1],
    (label_subtitle_lot_from_lot_id)[1]
  INTO v_queue_title, v_queue_subtitle
  FROM public.vc_print_queue
  WHERE lot_id = v_drawn_lot_id
    AND label_type = 'LC_Syringe_Drawn'
  ORDER BY nocopk DESC
  LIMIT 1;

  IF v_queue_title <> v_title OR v_queue_subtitle <> v_subtitle THEN
    RAISE EXCEPTION 'Print queue label mismatch: title %, subtitle %', v_queue_title, v_queue_subtitle;
  END IF;

  INSERT INTO public.lots(
    lot_id,
    item_id,
    item_name_mat,
    item_category_mat,
    strain_id,
    strain_species_strain_mat,
    vendor_name,
    vendor_batch,
    source_type,
    status,
    created_at,
    qty,
    unit_size,
    total_volume_ml,
    remaining_volume_ml,
    received_date,
    use_by,
    label_template
  )
  VALUES (
    'LOT-RC5-RECEIVED-SYRINGE',
    v_syringe_item_id,
    'Purchased LC Syringe',
    'lc_syringe',
    v_strain_id,
    'RC5 Test Strain',
    'RC5 Supplier',
    'BATCH-RC5',
    'Purchased',
    'Fridge',
    timestamp '2026-07-13 09:30:00',
    1,
    10,
    10,
    10,
    date '2026-07-13',
    date '2026-10-13',
    'LC_Syringe_Received'
  )
  RETURNING nocopk INTO v_received_lot_id;

  INSERT INTO public._m2m_lots_strains_strain_id(lots_id, strains_id)
  VALUES (v_received_lot_id, v_strain_id)
  ON CONFLICT DO NOTHING;

  SELECT label_title_lot, label_subtitle_lot
  INTO v_title, v_subtitle
  FROM public.vc_lots
  WHERE nocopk = v_received_lot_id;

  IF v_title <> 'Purchased LC Syringe'
     OR COALESCE(v_subtitle, '') NOT LIKE '10%ml%RC5 Test Strain%RC5 Supplier%BATCH-RC5%' THEN
    RAISE EXCEPTION 'Received syringe labels regressed: title %, subtitle %', v_title, v_subtitle;
  END IF;

  INSERT INTO public.products(
    product_id,
    item_id,
    name_mat,
    item_category_mat,
    net_volume_ml,
    strain_id,
    operator
  )
  VALUES (
    'PROD-RC5-DRAW-SYRINGE',
    v_syringe_item_id,
    'RC5 LC Syringe',
    'lc_syringe',
    10,
    v_strain_id,
    'RC5 smoke test'
  )
  RETURNING nocopk INTO v_product_id;

  INSERT INTO public._m2m_products_strains_strain_id(products_id, strains_id)
  VALUES (v_product_id, v_strain_id)
  ON CONFLICT DO NOTHING;

  SELECT label_title_prod, label_subtitle_prod
  INTO v_title, v_subtitle
  FROM public.vc_products
  WHERE nocopk = v_product_id;

  IF v_title <> 'RC5 LC Syringe'
     OR COALESCE(v_subtitle, '') NOT LIKE '10%ml%RC5 Test Strain%' THEN
    RAISE EXCEPTION 'Product-output syringe labels regressed: title %, subtitle %', v_title, v_subtitle;
  END IF;

  RAISE NOTICE 'Draw Syringes Create Lots label smoke tests passed.';
END;
$$;

ROLLBACK;
