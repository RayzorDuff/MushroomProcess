\set ON_ERROR_STOP on

-- Transactional negative-path and multi-target regression coverage for #59 and #73.
-- Exercises the same mp_lots_inoculate_multiple mutation function used by Appsmith.
-- Run after 004_computed_views.sql, 005_helpers.sql, and 008_lot_actions.sql.
-- All fixtures and outputs are rolled back.
BEGIN;

DO $$
DECLARE
  v_grain_item_id bigint;
  v_lc_item_id bigint;
  v_strain_id bigint;
  v_dark_room_id bigint;
  v_now timestamp without time zone := timestamp '2026-07-15 18:30:00';

  v_null_source_id bigint;
  v_null_target_id bigint;
  v_short_source_id bigint;
  v_short_target_ids bigint[];
  v_grain_source_id bigint;
  v_grain_target_id bigint;
  v_multi_source_id bigint;
  v_multi_target_ids bigint[];

  v_count integer;
  v_remaining numeric;
  v_error text;
  v_event_count integer;
  v_print_count integer;
BEGIN
  SELECT nocopk INTO v_grain_item_id
  FROM public.items
  WHERE item_id = 'GRAIN-BAG'
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
     OR v_lc_item_id IS NULL
     OR v_strain_id IS NULL
     OR v_dark_room_id IS NULL THEN
    RAISE EXCEPTION 'Inoculation validation smoke-test fixtures are missing from imported data.';
  END IF;

  -- Liquid sources require a positive volume. A rejected request must not
  -- mutate the target or create event/print side effects.
  INSERT INTO public.lots (
    lot_id, item_id, item_name_mat, item_category_mat, strain_id,
    strain_species_strain_mat, status, total_volume_ml, remaining_volume_ml,
    created_at, inoculated_at
  )
  SELECT
    'LOT-RC5-INOC-NULL-SRC', v_lc_item_id, i.name, i.category,
    v_strain_id, s.species_strain, 'Colonizing', 10, 10,
    v_now - interval '2 days', v_now - interval '1 day'
  FROM public.items i
  CROSS JOIN public.strains s
  WHERE i.nocopk = v_lc_item_id
    AND s.nocopk = v_strain_id
  RETURNING nocopk INTO v_null_source_id;

  INSERT INTO public.lots (
    lot_id, item_id, item_name_mat, item_category_mat, status,
    unit_size, created_at, sterilized_at
  )
  SELECT
    'LOT-RC5-INOC-NULL-TGT', v_grain_item_id, i.name, i.category,
    'Sterilized', 5, v_now - interval '2 days', v_now - interval '1 day'
  FROM public.items i
  WHERE i.nocopk = v_grain_item_id
  RETURNING nocopk INTO v_null_target_id;

  v_count := public.mp_lots_inoculate_multiple(
    p_source_lot_id => v_null_source_id,
    p_target_lot_ids => ARRAY[v_null_target_id],
    p_storage_location_id => v_dark_room_id,
    p_lc_volume_ml => NULL,
    p_override_inoc_time => v_now,
    p_operator => 'RC5 inoculation validation smoke test',
    p_note => 'missing volume must fail'
  );

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'Missing-volume LC inoculation returned %, expected 0.', v_count;
  END IF;

  SELECT remaining_volume_ml, ui_error
  INTO v_remaining, v_error
  FROM public.lots
  WHERE nocopk = v_null_source_id;

  IF v_remaining IS DISTINCT FROM 10
     OR COALESCE(v_error, '') NOT ILIKE '%positive LC volume%' THEN
    RAISE EXCEPTION 'Missing-volume LC validation state is incorrect: remaining %, error %.', v_remaining, v_error;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.lots
    WHERE nocopk = v_null_target_id
      AND (status IS DISTINCT FROM 'Sterilized'
           OR source_lot_id IS NOT NULL
           OR inoculated_at IS NOT NULL)
  ) THEN
    RAISE EXCEPTION 'Missing-volume validation mutated its target lot.';
  END IF;

  IF EXISTS (SELECT 1 FROM public.events WHERE lot_id = v_null_target_id)
     OR EXISTS (SELECT 1 FROM public.print_queue WHERE lot_id = v_null_target_id) THEN
    RAISE EXCEPTION 'Missing-volume validation created event or print side effects.';
  END IF;

  -- The complete requested liquid volume is preflighted before any target is
  -- changed. Two 3 ml targets cannot be inoculated from a 4 ml source.
  INSERT INTO public.lots (
    lot_id, item_id, item_name_mat, item_category_mat, strain_id,
    strain_species_strain_mat, status, total_volume_ml, remaining_volume_ml,
    created_at, inoculated_at
  )
  SELECT
    'LOT-RC5-INOC-SHORT-SRC', v_lc_item_id, i.name, i.category,
    v_strain_id, s.species_strain, 'Colonizing', 4, 4,
    v_now - interval '2 days', v_now - interval '1 day'
  FROM public.items i
  CROSS JOIN public.strains s
  WHERE i.nocopk = v_lc_item_id
    AND s.nocopk = v_strain_id
  RETURNING nocopk INTO v_short_source_id;

  WITH inserted AS (
    INSERT INTO public.lots (
      lot_id, item_id, item_name_mat, item_category_mat, status,
      unit_size, created_at, sterilized_at
    )
    SELECT
      'LOT-RC5-INOC-SHORT-TGT-' || g.n,
      v_grain_item_id,
      i.name,
      i.category,
      'Sterilized',
      5,
      v_now - interval '2 days',
      v_now - interval '1 day'
    FROM public.items i
    CROSS JOIN generate_series(1, 2) AS g(n)
    WHERE i.nocopk = v_grain_item_id
    RETURNING nocopk
  )
  SELECT array_agg(nocopk ORDER BY nocopk)
  INTO v_short_target_ids
  FROM inserted;

  v_count := public.mp_lots_inoculate_multiple(
    p_source_lot_id => v_short_source_id,
    p_target_lot_ids => v_short_target_ids,
    p_storage_location_id => v_dark_room_id,
    p_lc_volume_ml => 3,
    p_override_inoc_time => v_now,
    p_operator => 'RC5 inoculation validation smoke test',
    p_note => 'insufficient volume must be atomic'
  );

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'Insufficient-volume inoculation returned %, expected 0.', v_count;
  END IF;

  SELECT remaining_volume_ml, ui_error
  INTO v_remaining, v_error
  FROM public.lots
  WHERE nocopk = v_short_source_id;

  IF v_remaining IS DISTINCT FROM 4
     OR COALESCE(v_error, '') NOT ILIKE '%only has 4%'
     OR COALESCE(v_error, '') NOT ILIKE '%needs 6%'
     OR COALESCE(v_error, '') NOT ILIKE '%2 targets%' THEN
    RAISE EXCEPTION 'Insufficient-volume validation state is incorrect: remaining %, error %.', v_remaining, v_error;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.lots
    WHERE nocopk = ANY(v_short_target_ids)
      AND (status IS DISTINCT FROM 'Sterilized'
           OR source_lot_id IS NOT NULL
           OR inoculated_at IS NOT NULL)
  ) THEN
    RAISE EXCEPTION 'Insufficient-volume preflight partially mutated target lots.';
  END IF;

  IF EXISTS (SELECT 1 FROM public.events WHERE lot_id = ANY(v_short_target_ids))
     OR EXISTS (SELECT 1 FROM public.print_queue WHERE lot_id = ANY(v_short_target_ids)) THEN
    RAISE EXCEPTION 'Insufficient-volume preflight created event or print side effects.';
  END IF;

  -- Solid sources must reject a liquid-volume value and preserve both source
  -- and target state.
  INSERT INTO public.lots (
    lot_id, item_id, item_name_mat, item_category_mat, strain_id,
    strain_species_strain_mat, status, remaining_volume_ml,
    created_at, inoculated_at
  )
  SELECT
    'LOT-RC5-INOC-GRAIN-REJECT-SRC', v_grain_item_id, i.name, i.category,
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
    'LOT-RC5-INOC-GRAIN-REJECT-TGT', v_grain_item_id, i.name, i.category,
    'Sterilized', 5, v_now - interval '2 days', v_now - interval '1 day'
  FROM public.items i
  WHERE i.nocopk = v_grain_item_id
  RETURNING nocopk INTO v_grain_target_id;

  v_count := public.mp_lots_inoculate_multiple(
    p_source_lot_id => v_grain_source_id,
    p_target_lot_ids => ARRAY[v_grain_target_id],
    p_storage_location_id => v_dark_room_id,
    p_lc_volume_ml => 1,
    p_override_inoc_time => v_now,
    p_operator => 'RC5 inoculation validation smoke test',
    p_note => 'solid source volume must fail'
  );

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'Grain source with liquid volume returned %, expected 0.', v_count;
  END IF;

  SELECT remaining_volume_ml, ui_error
  INTO v_remaining, v_error
  FROM public.lots
  WHERE nocopk = v_grain_source_id;

  IF v_remaining IS DISTINCT FROM 77
     OR COALESCE(v_error, '') NOT ILIKE '%do not enter LC volume%' THEN
    RAISE EXCEPTION 'Solid-source validation state is incorrect: remaining %, error %.', v_remaining, v_error;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.lots
    WHERE nocopk = v_grain_target_id
      AND (status IS DISTINCT FROM 'Sterilized'
           OR source_lot_id IS NOT NULL
           OR inoculated_at IS NOT NULL)
  ) THEN
    RAISE EXCEPTION 'Rejected solid-source request mutated its target lot.';
  END IF;

  -- Successful multi-target liquid inoculation returns the actual updated
  -- count, decrements once per successful target, and creates one audit event
  -- and one queued label per target.
  INSERT INTO public.lots (
    lot_id, item_id, item_name_mat, item_category_mat, strain_id,
    strain_species_strain_mat, status, total_volume_ml, remaining_volume_ml,
    created_at, inoculated_at, ui_error, ui_error_at
  )
  SELECT
    'LOT-RC5-INOC-MULTI-SRC', v_lc_item_id, i.name, i.category,
    v_strain_id, s.species_strain, 'Colonizing', 10, 10,
    v_now - interval '2 days', v_now - interval '1 day',
    'stale error', v_now - interval '1 hour'
  FROM public.items i
  CROSS JOIN public.strains s
  WHERE i.nocopk = v_lc_item_id
    AND s.nocopk = v_strain_id
  RETURNING nocopk INTO v_multi_source_id;

  WITH inserted AS (
    INSERT INTO public.lots (
      lot_id, item_id, item_name_mat, item_category_mat, status,
      unit_size, created_at, sterilized_at
    )
    SELECT
      'LOT-RC5-INOC-MULTI-TGT-' || g.n,
      v_grain_item_id,
      i.name,
      i.category,
      'Sterilized',
      5,
      v_now - interval '2 days',
      v_now - interval '1 day'
    FROM public.items i
    CROSS JOIN generate_series(1, 3) AS g(n)
    WHERE i.nocopk = v_grain_item_id
    RETURNING nocopk
  )
  SELECT array_agg(nocopk ORDER BY nocopk)
  INTO v_multi_target_ids
  FROM inserted;

  v_count := public.mp_lots_inoculate_multiple(
    p_source_lot_id => v_multi_source_id,
    p_target_lot_ids => v_multi_target_ids,
    p_storage_location_id => v_dark_room_id,
    p_lc_volume_ml => 1,
    p_override_inoc_time => v_now,
    p_operator => 'RC5 inoculation validation smoke test',
    p_station => 'Lab - Inoculate',
    p_note => 'three-target count and atomicity test'
  );

  IF v_count <> 3 THEN
    RAISE EXCEPTION 'Expected three successful target updates, got %.', v_count;
  END IF;

  SELECT remaining_volume_ml, ui_error
  INTO v_remaining, v_error
  FROM public.lots
  WHERE nocopk = v_multi_source_id;

  IF v_remaining IS DISTINCT FROM 7 OR v_error IS NOT NULL THEN
    RAISE EXCEPTION 'Successful multi-target source state is incorrect: remaining %, error %.', v_remaining, v_error;
  END IF;

  IF (
    SELECT count(*)
    FROM public.lots
    WHERE nocopk = ANY(v_multi_target_ids)
      AND status = 'Colonizing'
      AND source_lot_id = v_multi_source_id
      AND inoculated_at = v_now
      AND label_template = 'Grain_Inoculated'
      AND total_volume_ml = 1
      AND remaining_volume_ml = 1
      AND use_by = (v_now + interval '3 months')::date
  ) <> 3 THEN
    RAISE EXCEPTION 'Successful multi-target lot updates are incomplete.';
  END IF;

  SELECT count(*) INTO v_event_count
  FROM public.events e
  WHERE e.lot_id = ANY(v_multi_target_ids)
    AND e.type = 'Inoculated'
    AND e.operator = 'RC5 inoculation validation smoke test'
    AND e.station = 'Lab - Inoculate'
    AND e.timestamp = v_now
    AND e.fields_json::jsonb ->> 'source_category' = 'lc_flask'
    AND (e.fields_json::jsonb ->> 'source_lot_nocopk')::bigint = v_multi_source_id
    AND (e.fields_json::jsonb ->> 'volume_ml')::numeric = 1
    AND e.fields_json::jsonb ->> 'note' = 'three-target count and atomicity test';

  IF v_event_count <> 3 THEN
    RAISE EXCEPTION 'Expected three complete inoculation events, got %.', v_event_count;
  END IF;

  SELECT count(*) INTO v_print_count
  FROM public.print_queue pq
  WHERE pq.lot_id = ANY(v_multi_target_ids)
    AND pq.source_kind = 'lot'
    AND pq.label_type = 'Grain_Inoculated'
    AND pq.print_status = 'Queued';

  IF v_print_count <> 3 THEN
    RAISE EXCEPTION 'Expected three queued inoculation labels, got %.', v_print_count;
  END IF;

  RAISE NOTICE 'Inoculation validation, atomicity, multi-target count, event, and print smoke tests passed.';
END;
$$;

ROLLBACK;
