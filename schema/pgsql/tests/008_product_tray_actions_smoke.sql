\set ON_ERROR_STOP on

-- Transactional smoke test for Products tray lifecycle actions, #65 and #70.
-- Run after 005_helpers.sql and 008_lot_actions.sql.
-- All fixtures and outputs are rolled back.
BEGIN;

DO $$
DECLARE
  v_fresh_item_id bigint;
  v_freezer_item_id bigint;
  v_products_storage_id bigint;
  v_freeze_dryer_id bigint;
  v_expired_id bigint;
  v_compost_id bigint;
  v_retired_destination_id bigint;
  v_move_ids bigint[];
  v_spoil_id bigint;
  v_compost_product_id bigint;
  v_retire_id bigint;
  v_count integer;
  v_event record;
BEGIN
  SELECT nocopk INTO v_fresh_item_id
  FROM public.items
  WHERE item_id = 'TRAY-FRESH'
  LIMIT 1;

  SELECT nocopk INTO v_freezer_item_id
  FROM public.items
  WHERE item_id = 'TRAY-FREEZE'
  LIMIT 1;

  SELECT nocopk INTO v_products_storage_id
  FROM public.locations
  WHERE lower(btrim(name)) = 'products storage'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  SELECT nocopk INTO v_freeze_dryer_id
  FROM public.locations
  WHERE lower(btrim(name)) = 'freeze dryer'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  SELECT nocopk INTO v_expired_id
  FROM public.locations
  WHERE lower(btrim(name)) = 'expired'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  SELECT nocopk INTO v_compost_id
  FROM public.locations
  WHERE lower(btrim(name)) = 'compost'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  SELECT nocopk INTO v_retired_destination_id
  FROM public.locations
  WHERE lower(btrim(name)) IN ('retired', 'consumed')
  ORDER BY
    CASE lower(btrim(name)) WHEN 'retired' THEN 0 ELSE 1 END,
    CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END,
    nocopk
  LIMIT 1;

  IF v_fresh_item_id IS NULL
     OR v_freezer_item_id IS NULL
     OR v_products_storage_id IS NULL
     OR v_freeze_dryer_id IS NULL
     OR v_expired_id IS NULL
     OR v_compost_id IS NULL
     OR v_retired_destination_id IS NULL THEN
    RAISE EXCEPTION 'Product tray action smoke-test fixtures are missing from imported Airtable data.';
  END IF;

  WITH inserted AS (
    INSERT INTO public.products (
      product_id,
      item_id,
      name_mat,
      item_category_mat,
      net_weight_g,
      net_weight_oz,
      pack_date,
      storage_location_id,
      tray_state,
      notes
    )
    VALUES
      (
        'PROD-RC5-TRAY-MOVE-1',
        v_freezer_item_id,
        'Freezer Tray',
        'freezer_tray',
        100,
        100 / 28.349523125,
        current_date,
        v_products_storage_id,
        'Frozen',
        'RC5 product tray action fixture'
      ),
      (
        'PROD-RC5-TRAY-MOVE-2',
        v_freezer_item_id,
        'Freezer Tray',
        'freezer_tray',
        125,
        125 / 28.349523125,
        current_date,
        v_products_storage_id,
        'Frozen',
        'RC5 product tray action fixture'
      )
    RETURNING nocopk
  )
  SELECT array_agg(nocopk ORDER BY nocopk)
  INTO v_move_ids
  FROM inserted;

  INSERT INTO public.products (
    product_id,
    item_id,
    name_mat,
    item_category_mat,
    net_weight_g,
    net_weight_oz,
    pack_date,
    storage_location_id,
    tray_state,
    notes
  )
  VALUES
    (
      'PROD-RC5-TRAY-SPOIL',
      v_fresh_item_id,
      'Fresh Tray',
      'fresh_tray',
      50,
      50 / 28.349523125,
      current_date,
      v_products_storage_id,
      'Fresh',
      'RC5 product tray action fixture'
    )
  RETURNING nocopk INTO v_spoil_id;

  INSERT INTO public.products (
    product_id,
    item_id,
    name_mat,
    item_category_mat,
    net_weight_g,
    net_weight_oz,
    pack_date,
    storage_location_id,
    tray_state,
    notes
  )
  VALUES
    (
      'PROD-RC5-TRAY-COMPOST',
      v_fresh_item_id,
      'Fresh Tray',
      'fresh_tray',
      60,
      60 / 28.349523125,
      current_date,
      v_products_storage_id,
      'Fresh',
      'RC5 product tray action fixture'
    )
  RETURNING nocopk INTO v_compost_product_id;

  INSERT INTO public.products (
    product_id,
    item_id,
    name_mat,
    item_category_mat,
    net_weight_g,
    net_weight_oz,
    pack_date,
    storage_location_id,
    tray_state,
    notes
  )
  VALUES
    (
      'PROD-RC5-TRAY-RETIRE',
      v_freezer_item_id,
      'Freezer Tray',
      'freezer_tray',
      70,
      70 / 28.349523125,
      current_date,
      v_products_storage_id,
      'Frozen',
      'RC5 product tray action fixture'
    )
  RETURNING nocopk INTO v_retire_id;

  PERFORM public.mp_product_set_storage_location(u.product_id, v_products_storage_id)
  FROM unnest(v_move_ids || ARRAY[v_spoil_id, v_compost_product_id, v_retire_id]) AS u(product_id);

  v_count := public.mp_products_move_to_freeze_dryer(
    p_product_ids => v_move_ids,
    p_freeze_dryer_location_id => v_freeze_dryer_id,
    p_operator => 'RC5 product tray smoke test',
    p_station => 'Products',
    p_notes => 'Move two trays'
  );

  IF v_count <> 2 THEN
    RAISE EXCEPTION 'Expected two products moved to Freeze Dryer, got %.', v_count;
  END IF;

  IF (
    SELECT count(*)
    FROM public.products p
    WHERE p.nocopk = ANY(v_move_ids)
      AND p.tray_state = 'freeze_drying'
      AND p.storage_location_id = v_freeze_dryer_id
  ) <> 2 THEN
    RAISE EXCEPTION 'Freeze Dryer product updates were not applied.';
  END IF;

  IF (
    SELECT count(*)
    FROM public._m2m_products_locations_storage_location m
    WHERE m.products_id = ANY(v_move_ids)
      AND m.locations_id = v_freeze_dryer_id
  ) <> 2 THEN
    RAISE EXCEPTION 'Freeze Dryer storage-location relationships were not updated.';
  END IF;

  IF (
    SELECT count(*)
    FROM public.events e
    WHERE e.type = 'MovedToFreezeDryer'
      AND e.operator = 'RC5 product tray smoke test'
      AND e.fields_json::jsonb ->> 'notes' = 'Move two trays'
  ) <> 2 THEN
    RAISE EXCEPTION 'Expected one Move to Freeze Dryer event per product.';
  END IF;

  FOR v_event IN
    SELECT e.nocopk, e.fields_json::jsonb AS fields
    FROM public.events e
    WHERE e.type = 'MovedToFreezeDryer'
      AND e.operator = 'RC5 product tray smoke test'
      AND e.fields_json::jsonb ->> 'notes' = 'Move two trays'
  LOOP
    IF v_event.fields ->> 'previous_tray_state' <> 'Frozen'
       OR v_event.fields ->> 'new_tray_state' <> 'freeze_drying'
       OR (v_event.fields ->> 'previous_storage_location_id')::bigint <> v_products_storage_id
       OR (v_event.fields ->> 'new_storage_location_id')::bigint <> v_freeze_dryer_id
       OR v_event.fields ->> 'workflow' <> 'mp_products_move_to_freeze_dryer' THEN
      RAISE EXCEPTION 'Move event fields_json is incomplete: %', v_event.fields;
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM public._m2m_products_events_events m
      WHERE m.events_id = v_event.nocopk
        AND m.products_id = (v_event.fields ->> 'product_id')::bigint
    ) THEN
      RAISE EXCEPTION 'Move event is not linked to its product.';
    END IF;
  END LOOP;

  v_count := public.mp_products_retire_trays(
    p_product_ids => ARRAY[v_spoil_id],
    p_reason => 'spoiled',
    p_operator => 'RC5 product tray smoke test',
    p_station => 'Products',
    p_notes => 'Spoil one tray'
  );
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Expected one spoiled tray update, got %.', v_count;
  END IF;

  v_count := public.mp_products_retire_trays(
    p_product_ids => ARRAY[v_compost_product_id],
    p_reason => 'compost',
    p_operator => 'RC5 product tray smoke test',
    p_station => 'Products',
    p_notes => 'Compost one tray'
  );
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Expected one composted tray update, got %.', v_count;
  END IF;

  v_count := public.mp_products_retire_trays(
    p_product_ids => ARRAY[v_retire_id],
    p_reason => 'retired',
    p_operator => 'RC5 product tray smoke test',
    p_station => 'Products',
    p_notes => 'Retire one tray'
  );
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Expected one retired tray update, got %.', v_count;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.products
    WHERE nocopk = v_spoil_id
      AND tray_state = 'spoiled'
      AND storage_location_id = v_expired_id
  ) THEN
    RAISE EXCEPTION 'Spoiled tray did not move to Expired.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.products
    WHERE nocopk = v_compost_product_id
      AND tray_state = 'compost'
      AND storage_location_id = v_compost_id
  ) THEN
    RAISE EXCEPTION 'Composted tray did not move to Compost.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.products
    WHERE nocopk = v_retire_id
      AND tray_state = 'retired'
      AND storage_location_id = v_retired_destination_id
  ) THEN
    RAISE EXCEPTION 'Retired tray did not move to the resolved terminal location.';
  END IF;

  FOR v_event IN
    SELECT e.nocopk, e.type, e.fields_json::jsonb AS fields
    FROM public.events e
    WHERE e.operator = 'RC5 product tray smoke test'
      AND e.type IN ('ProductSpoiled', 'ProductComposted', 'ProductRetired')
  LOOP
    IF v_event.fields ->> 'previous_tray_state' NOT IN ('Fresh', 'Frozen')
       OR NULLIF(v_event.fields ->> 'new_tray_state', '') IS NULL
       OR (v_event.fields ->> 'previous_storage_location_id')::bigint <> v_products_storage_id
       OR NULLIF(v_event.fields ->> 'new_storage_location', '') IS NULL
       OR v_event.fields ->> 'workflow' <> 'mp_products_retire_trays' THEN
      RAISE EXCEPTION 'Terminal tray event fields_json is incomplete: %', v_event.fields;
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM public._m2m_products_events_events m
      WHERE m.events_id = v_event.nocopk
        AND m.products_id = (v_event.fields ->> 'product_id')::bigint
    ) THEN
      RAISE EXCEPTION 'Terminal tray event is not linked to its product.';
    END IF;
  END LOOP;

  IF (
    SELECT count(*)
    FROM public.events e
    WHERE e.operator = 'RC5 product tray smoke test'
      AND e.type IN ('ProductSpoiled', 'ProductComposted', 'ProductRetired')
  ) <> 3 THEN
    RAISE EXCEPTION 'Expected Spoiled, Composted, and Retired events.';
  END IF;

  RAISE NOTICE 'Products tray lifecycle event, Retired fallback, and count smoke tests passed.';
END;
$$;

ROLLBACK;
