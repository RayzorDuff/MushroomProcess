\set ON_ERROR_STOP on

-- Transactional regression test for #59 inoculation source-mode behavior.
-- Run after 005_helpers.sql and 008_lot_actions.sql. All fixtures and outputs roll back.
BEGIN;

DO $$
DECLARE
  v_grain_item_id bigint;
  v_plate_item_id bigint;
  v_lc_item_id bigint;
  v_strain_id bigint;
  v_dark_room_id bigint;
  v_grain_source_id bigint;
  v_plate_source_id bigint;
  v_lc_source_id bigint;
  v_grain_target_id bigint;
  v_plate_target_id bigint;
  v_lc_target_id bigint;
  v_count integer;
  v_now timestamp without time zone := clock_timestamp()::timestamp without time zone;
  v_remaining numeric;
  v_fields jsonb;
BEGIN
  SELECT nocopk INTO v_grain_item_id
  FROM public.items
  WHERE item_id = 'GRAIN-BAG'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  SELECT nocopk INTO v_plate_item_id
  FROM public.items
  WHERE item_id = 'AGAR-PLATE'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  SELECT nocopk INTO v_lc_item_id
  FROM public.items
  WHERE item_id = 'LC-FLASK'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

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

  IF v_grain_item_id IS NULL
     OR v_plate_item_id IS NULL
     OR v_lc_item_id IS NULL
     OR v_strain_id IS NULL
     OR v_dark_room_id IS NULL THEN
    RAISE EXCEPTION 'Inoculation source-mode smoke-test fixtures are missing from imported data.';
  END IF;

  -- Grain source: no volume is required and existing remaining volume is unchanged.
  INSERT INTO public.lots (
    lot_id, item_id, item_name_mat, item_category_mat, strain_id,
    strain_species_strain_mat, status, remaining_volume_ml,
    created_at, inoculated_at
  )
  SELECT
    'LOT-RC5-INOC-GRAIN-SRC', v_grain_item_id, i.name, i.category,
    v_strain_id, s.species_strain, 'Colonizing', 77,
    v_now - interval '2 days', v_now - interval '1 day'
  FROM public.items i
  CROSS JOIN public.strains s
  WHERE i.nocopk = v_grain_item_id
    AND s.nocopk = v_strain_id
  RETURNING nocopk INTO v_grain_source_id;

  INSERT INTO public.lots (
    lot_id, item_id, item_name_mat, item_category_mat, status,
    unit_size, created_at, sterilized_at
  )
  SELECT
    'LOT-RC5-INOC-GRAIN-TGT', v_grain_item_id, i.name, i.category,
    'Sterilized', 5, v_now - interval '2 days', v_now - interval '1 day'
  FROM public.items i
  WHERE i.nocopk = v_grain_item_id
  RETURNING nocopk INTO v_grain_target_id;

  v_count := public.mp_lots_inoculate_multiple(
    p_source_lot_id => v_grain_source_id,
    p_target_lot_ids => ARRAY[v_grain_target_id],
    p_storage_location_id => v_dark_room_id,
    p_lc_volume_ml => NULL,
    p_override_inoc_time => v_now,
    p_operator => 'RC5 smoke test',
    p_note => 'grain source test'
  );

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Expected one grain-source inoculation, got %.', v_count;
  END IF;

  SELECT remaining_volume_ml INTO v_remaining
  FROM public.lots
  WHERE nocopk = v_grain_source_id;

  IF v_remaining IS DISTINCT FROM 77 THEN
    RAISE EXCEPTION 'Grain source remaining volume changed unexpectedly: %.', v_remaining;
  END IF;

  SELECT fields_json::jsonb INTO v_fields
  FROM public.events
  WHERE lot_id = v_grain_target_id
    AND type = 'Inoculated'
  ORDER BY nocopk DESC
  LIMIT 1;

  IF v_fields IS NULL
     OR v_fields ->> 'source_category' <> 'grain'
     OR v_fields ->> 'volume_ml' IS NOT NULL THEN
    RAISE EXCEPTION 'Grain-source event fields are incorrect: %.', v_fields;
  END IF;

  -- Agar plate source: no volume is required and existing remaining volume is unchanged.
  INSERT INTO public.lots (
    lot_id, item_id, item_name_mat, item_category_mat, strain_id,
    strain_species_strain_mat, status, remaining_volume_ml,
    created_at, inoculated_at
  )
  SELECT
    'LOT-RC5-INOC-PLATE-SRC', v_plate_item_id, i.name, i.category,
    v_strain_id, s.species_strain, 'Colonizing', 55,
    v_now - interval '2 days', v_now - interval '1 day'
  FROM public.items i
  CROSS JOIN public.strains s
  WHERE i.nocopk = v_plate_item_id
    AND s.nocopk = v_strain_id
  RETURNING nocopk INTO v_plate_source_id;

  INSERT INTO public.lots (
    lot_id, item_id, item_name_mat, item_category_mat, status,
    unit_size, created_at, sterilized_at
  )
  SELECT
    'LOT-RC5-INOC-PLATE-TGT', v_grain_item_id, i.name, i.category,
    'Sterilized', 5, v_now - interval '2 days', v_now - interval '1 day'
  FROM public.items i
  WHERE i.nocopk = v_grain_item_id
  RETURNING nocopk INTO v_plate_target_id;

  v_count := public.mp_lots_inoculate_multiple(
    p_source_lot_id => v_plate_source_id,
    p_target_lot_ids => ARRAY[v_plate_target_id],
    p_storage_location_id => v_dark_room_id,
    p_lc_volume_ml => NULL,
    p_override_inoc_time => v_now,
    p_operator => 'RC5 smoke test',
    p_note => 'plate source test'
  );

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Expected one plate-source inoculation, got %.', v_count;
  END IF;

  SELECT remaining_volume_ml INTO v_remaining
  FROM public.lots
  WHERE nocopk = v_plate_source_id;

  IF v_remaining IS DISTINCT FROM 55 THEN
    RAISE EXCEPTION 'Plate source remaining volume changed unexpectedly: %.', v_remaining;
  END IF;

  SELECT fields_json::jsonb INTO v_fields
  FROM public.events
  WHERE lot_id = v_plate_target_id
    AND type = 'Inoculated'
  ORDER BY nocopk DESC
  LIMIT 1;

  IF v_fields IS NULL
     OR v_fields ->> 'source_category' <> 'plate'
     OR v_fields ->> 'volume_ml' IS NOT NULL THEN
    RAISE EXCEPTION 'Plate-source event fields are incorrect: %.', v_fields;
  END IF;

  -- Liquid culture source: volume is required, recorded, and decremented.
  INSERT INTO public.lots (
    lot_id, item_id, item_name_mat, item_category_mat, strain_id,
    strain_species_strain_mat, status, total_volume_ml, remaining_volume_ml,
    created_at, inoculated_at
  )
  SELECT
    'LOT-RC5-INOC-LC-SRC', v_lc_item_id, i.name, i.category,
    v_strain_id, s.species_strain, 'Colonizing', 20, 20,
    v_now - interval '2 days', v_now - interval '1 day'
  FROM public.items i
  CROSS JOIN public.strains s
  WHERE i.nocopk = v_lc_item_id
    AND s.nocopk = v_strain_id
  RETURNING nocopk INTO v_lc_source_id;

  INSERT INTO public.lots (
    lot_id, item_id, item_name_mat, item_category_mat, status,
    unit_size, created_at, sterilized_at
  )
  SELECT
    'LOT-RC5-INOC-LC-TGT', v_grain_item_id, i.name, i.category,
    'Sterilized', 5, v_now - interval '2 days', v_now - interval '1 day'
  FROM public.items i
  WHERE i.nocopk = v_grain_item_id
  RETURNING nocopk INTO v_lc_target_id;

  v_count := public.mp_lots_inoculate_multiple(
    p_source_lot_id => v_lc_source_id,
    p_target_lot_ids => ARRAY[v_lc_target_id],
    p_storage_location_id => v_dark_room_id,
    p_lc_volume_ml => 3,
    p_override_inoc_time => v_now,
    p_operator => 'RC5 smoke test',
    p_note => 'liquid source test'
  );

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Expected one LC-source inoculation, got %.', v_count;
  END IF;

  SELECT remaining_volume_ml INTO v_remaining
  FROM public.lots
  WHERE nocopk = v_lc_source_id;

  IF v_remaining IS DISTINCT FROM 17 THEN
    RAISE EXCEPTION 'LC source remaining volume was not decremented correctly: %.', v_remaining;
  END IF;

  SELECT fields_json::jsonb INTO v_fields
  FROM public.events
  WHERE lot_id = v_lc_target_id
    AND type = 'Inoculated'
  ORDER BY nocopk DESC
  LIMIT 1;

  IF v_fields IS NULL
     OR v_fields ->> 'source_category' <> 'lc_flask'
     OR (v_fields ->> 'volume_ml')::numeric <> 3 THEN
    RAISE EXCEPTION 'LC-source event fields are incorrect: %.', v_fields;
  END IF;

  RAISE NOTICE 'Inoculation liquid/solid source and event smoke tests passed.';
END;
$$;

ROLLBACK;
