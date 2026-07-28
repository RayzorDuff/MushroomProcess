\set ON_ERROR_STOP on

-- Transactional smoke test for #68 AIO behavior after Sterilizer OUT.
-- Run after 004_computed_views.sql, 005_helpers.sql, 008_lot_actions.sql,
-- and 009_harvest_actions.sql. All fixtures and outputs are rolled back.
BEGIN;

DO $$
DECLARE
  v_aio_item_id bigint;
  v_lc_item_id bigint;
  v_fresh_item_id bigint;
  v_strain_id bigint;
  v_dark_room_id bigint;
  v_products_storage_id bigint;
  v_source_lot_id bigint;
  v_target_lot_id bigint;
  v_inoculated integer;
  v_modified integer;
  v_harvested integer;
  v_inoc_time timestamp without time zone := clock_timestamp()::timestamp without time zone;
  v_source_remaining numeric;
  v_target record;
  v_title text;
  v_subtitle text;
  v_created_product_id bigint;
BEGIN
  SELECT nocopk INTO v_aio_item_id
  FROM public.items
  WHERE item_id = 'AIO-BAG'
    AND COALESCE(active, false);

  SELECT nocopk INTO v_lc_item_id
  FROM public.items
  WHERE item_id = 'LC-FLASK'
    AND COALESCE(active, false);

  SELECT nocopk INTO v_fresh_item_id
  FROM public.items
  WHERE item_id = 'TRAY-FRESH'
    AND COALESCE(active, false);

  SELECT nocopk INTO v_strain_id
  FROM public.strains
  WHERE COALESCE(active, false)
  ORDER BY nocopk
  LIMIT 1;

  SELECT nocopk INTO v_dark_room_id
  FROM public.locations
  WHERE lower(btrim(name)) = 'dark room'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  SELECT nocopk INTO v_products_storage_id
  FROM public.locations
  WHERE lower(btrim(name)) = 'products storage'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  IF v_aio_item_id IS NULL
     OR v_lc_item_id IS NULL
     OR v_fresh_item_id IS NULL
     OR v_strain_id IS NULL
     OR v_dark_room_id IS NULL
     OR v_products_storage_id IS NULL THEN
    RAISE EXCEPTION 'AIO lifecycle smoke-test fixtures are missing from the imported Airtable data.';
  END IF;

  INSERT INTO public.lots (
    lot_id,
    item_id,
    item_name_mat,
    item_category_mat,
    strain_id,
    strain_species_strain_mat,
    vendor_name_mat,
    status,
    unit_size,
    total_volume_ml,
    remaining_volume_ml,
    created_at,
    inoculated_at
  )
  SELECT
    'LOT-RC5-AIO-SOURCE',
    v_lc_item_id,
    i.name,
    i.category,
    v_strain_id,
    s.species_strain,
    'RC5 Test Vendor',
    'Colonizing',
    100,
    100,
    100,
    v_inoc_time - interval '2 hours',
    v_inoc_time - interval '1 hour'
  FROM public.items i
  CROSS JOIN public.strains s
  WHERE i.nocopk = v_lc_item_id
    AND s.nocopk = v_strain_id
  RETURNING nocopk INTO v_source_lot_id;

  INSERT INTO public.lots (
    lot_id,
    item_id,
    item_name_mat,
    item_category_mat,
    status,
    unit_size,
    created_at,
    sterilized_at
  )
  SELECT
    'LOT-RC5-AIO-TARGET',
    v_aio_item_id,
    i.name,
    i.category,
    'Sterilized',
    5,
    v_inoc_time - interval '2 hours',
    v_inoc_time - interval '1 hour'
  FROM public.items i
  WHERE i.nocopk = v_aio_item_id
  RETURNING nocopk INTO v_target_lot_id;

  v_inoculated := public.mp_lots_inoculate_multiple(
    p_source_lot_id => v_source_lot_id,
    p_target_lot_ids => ARRAY[v_target_lot_id],
    p_storage_location_id => v_dark_room_id,
    p_lc_volume_ml => 5,
    p_override_inoc_time => v_inoc_time,
    p_operator => 'RC5 smoke test',
    p_station => 'Inoculation',
    p_note => 'Rollback-only AIO lifecycle smoke test'
  );

  IF v_inoculated <> 1 THEN
    RAISE EXCEPTION 'Expected one inoculated AIO lot, got %.', v_inoculated;
  END IF;

  SELECT
    status,
    label_template,
    use_by,
    inoculated_at,
    strain_id,
    source_lot_id
  INTO v_target
  FROM public.lots
  WHERE nocopk = v_target_lot_id;

  IF v_target.status <> 'Colonizing'
     OR v_target.label_template <> 'All_In_One_Inoculated'
     OR v_target.use_by <> (v_inoc_time + interval '3 months')::date
     OR v_target.inoculated_at <> v_inoc_time
     OR v_target.strain_id <> v_strain_id
     OR v_target.source_lot_id <> v_source_lot_id THEN
    RAISE EXCEPTION 'AIO inoculation fields are incorrect: %', row_to_json(v_target);
  END IF;

  SELECT remaining_volume_ml INTO v_source_remaining
  FROM public.lots
  WHERE nocopk = v_source_lot_id;

  IF v_source_remaining <> 95 THEN
    RAISE EXCEPTION 'AIO inoculation did not decrement source volume correctly: %', v_source_remaining;
  END IF;

  SELECT label_title_lot, label_subtitle_lot
  INTO v_title, v_subtitle
  FROM public.vc_lots
  WHERE nocopk = v_target_lot_id;

  IF v_title <> 'All-in-One: All-in-One Bag'
     OR NULLIF(btrim(v_subtitle), '') IS NULL
     OR position('5' IN v_subtitle) = 0 THEN
    RAISE EXCEPTION 'AIO computed label fields are incorrect: title %, subtitle %', v_title, v_subtitle;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.print_queue
    WHERE lot_id = v_target_lot_id
      AND source_kind = 'lot'
      AND label_type = 'All_In_One_Inoculated'
      AND print_status = 'Queued'
  ) THEN
    RAISE EXCEPTION 'AIO inoculation print-queue row is missing or has the wrong label type.';
  END IF;

  v_modified := public.mp_lots_modify(
    p_lot_ids => ARRAY[v_target_lot_id],
    p_actions => ARRAY['ApplyCasing'],
    p_operator => 'RC5 smoke test',
    p_station => 'Dark Room',
    p_timestamp => v_inoc_time + interval '1 day',
    p_note => 'Rollback-only AIO casing test'
  );

  IF v_modified <> 1 OR NOT EXISTS (
    SELECT 1
    FROM public.lots
    WHERE nocopk = v_target_lot_id
      AND casing_applied_at = v_inoc_time + interval '1 day'
  ) THEN
    RAISE EXCEPTION 'ApplyCasing did not update the AIO lot.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.events
    WHERE lot_id = v_target_lot_id
      AND type = 'CasingApplied'
  ) THEN
    RAISE EXCEPTION 'ApplyCasing did not create an AIO lot event.';
  END IF;

  BEGIN
    PERFORM public.mp_lots_modify(
      p_lot_ids => ARRAY[v_source_lot_id],
      p_actions => ARRAY['ApplyCasing'],
      p_operator => 'RC5 smoke test'
    );
    RAISE EXCEPTION 'Expected ApplyCasing category validation did not occur.';
  EXCEPTION WHEN OTHERS THEN
    IF position('ApplyCasing requires fruiting_block or all_in_one_bag' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
  END;

  UPDATE public.lots
  SET status = 'Fruiting',
      beganfruiting_at = v_inoc_time + interval '2 days'
  WHERE nocopk = v_target_lot_id;

  v_harvested := public.mp_lots_harvest_create_tray_products(
    p_block_lot_id => v_target_lot_id,
    p_harvest_weight_g => 100,
    p_flush_no => 1,
    p_fresh_tray_count => 1,
    p_frozen_tray_count => 0,
    p_operator => 'RC5 smoke test',
    p_timestamp => v_inoc_time + interval '10 days',
    p_notes => 'Rollback-only AIO harvest test',
    p_fresh_harvest_item_id => v_fresh_item_id,
    p_fresh_storage_location_id => v_products_storage_id
  );

  IF v_harvested <> 1 THEN
    RAISE EXCEPTION 'Expected one fresh tray product from AIO harvest, got %.', v_harvested;
  END IF;

  SELECT p.nocopk INTO v_created_product_id
  FROM public.products p
  JOIN public._m2m_products_lots_origin_lots j
    ON j.products_id = p.nocopk
  WHERE j.lots_id = v_target_lot_id
    AND p.harvested_at = v_inoc_time + interval '10 days'
  ORDER BY p.nocopk DESC
  LIMIT 1;

  IF v_created_product_id IS NULL THEN
    RAISE EXCEPTION 'AIO harvest product or origin-lot link is missing.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.events e
    JOIN public._m2m_products_events_events ep
      ON ep.events_id = e.nocopk
    WHERE e.lot_id = v_target_lot_id
      AND e.type = 'Harvest'
      AND ep.products_id = v_created_product_id
  ) THEN
    RAISE EXCEPTION 'AIO harvest event is not linked to the created product.';
  END IF;

  RAISE NOTICE 'AIO inoculation, label, casing, and harvest smoke tests passed.';
END;
$$;

ROLLBACK;
