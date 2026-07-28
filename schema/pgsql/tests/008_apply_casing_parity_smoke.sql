\set ON_ERROR_STOP on

-- Transactional component test for issue #27 and the casing portion of #68.
-- Exercises mp_lots_modify exactly as the Appsmith Apply Casing action does.
BEGIN;

DO $test$
DECLARE
  v_item_id bigint;
  v_location_id bigint;
  v_lot_id bigint;
  v_first_ts timestamp without time zone := timestamp '2026-07-15 12:34:56';
  v_second_ts timestamp without time zone := timestamp '2026-07-15 13:45:07';
  v_modified integer;
  v_print_count_before integer;
  v_print_count_after integer;
  v_lot record;
  v_event record;
BEGIN
  SELECT nocopk INTO v_item_id
  FROM public.items
  WHERE lower(COALESCE(category, '')) = 'fruiting_block'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  SELECT nocopk INTO v_location_id
  FROM public.locations
  WHERE lower(btrim(name)) = 'dark room'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  IF v_item_id IS NULL OR v_location_id IS NULL THEN
    RAISE EXCEPTION 'Apply Casing fixtures are missing from imported data.';
  END IF;

  INSERT INTO public.lots (
    lot_id,
    item_id,
    item_name_mat,
    item_category_mat,
    qty,
    unit_size,
    status,
    location_id,
    created_at,
    spawned_at,
    label_template,
    notes,
    casing_notes
  )
  SELECT
    'LOT-RC5-APPLY-CASING',
    v_item_id,
    i.name,
    'fruiting_block',
    1,
    5,
    'Colonizing',
    v_location_id,
    v_first_ts - interval '10 days',
    v_first_ts - interval '7 days',
    'Bulk_Created',
    'Existing lot note',
    NULL
  FROM public.items i
  WHERE i.nocopk = v_item_id
  RETURNING nocopk INTO v_lot_id;

  SELECT count(*) INTO v_print_count_before
  FROM public.print_queue
  WHERE lot_id = v_lot_id;

  v_modified := public.mp_lots_modify(
    p_lot_ids => ARRAY[v_lot_id],
    p_actions => ARRAY['ApplyCasing'],
    p_operator => 'RC5 #27 smoke test',
    p_station => '  Dark Room  ',
    p_timestamp => v_first_ts,
    p_note => 'First casing note'
  );

  IF v_modified <> 1 THEN
    RAISE EXCEPTION 'Expected one modified fruiting block, got %.', v_modified;
  END IF;

  SELECT status, label_template, casing_applied_at, casing_notes, notes
  INTO v_lot
  FROM public.lots
  WHERE nocopk = v_lot_id;

  IF v_lot.status <> 'Colonizing'
     OR v_lot.label_template <> 'Bulk_Created'
     OR v_lot.casing_applied_at <> v_first_ts
     OR v_lot.casing_notes <> 'First casing note'
     OR v_lot.notes <> 'Existing lot note' || E'\n' || 'First casing note' THEN
    RAISE EXCEPTION 'First Apply Casing mutation is not parity-clean: %', row_to_json(v_lot);
  END IF;

  SELECT e.nocopk, e.type, e.timestamp, e.station, e.fields_json
  INTO v_event
  FROM public.events e
  WHERE e.lot_id = v_lot_id
    AND e.type = 'CasingApplied'
    AND e.operator = 'RC5 #27 smoke test'
  ORDER BY e.nocopk
  LIMIT 1;

  IF v_event.nocopk IS NULL
     OR v_event.timestamp <> v_first_ts
     OR v_event.station <> 'Dark Room'
     OR NOT (v_event.fields_json::jsonb ? 'casing_lot_id')
     OR NOT (v_event.fields_json::jsonb ? 'casing_item_id')
     OR v_event.fields_json::jsonb ->> 'action' <> 'ApplyCasing'
     OR v_event.fields_json::jsonb ->> 'note' <> 'First casing note' THEN
    RAISE EXCEPTION 'CasingApplied event is not parity-clean: %', row_to_json(v_event);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public._m2m_lots_events_events j
    WHERE j.lots_id = v_lot_id
      AND j.events_id = v_event.nocopk
  ) THEN
    RAISE EXCEPTION 'CasingApplied event is not linked through the lot/event relationship table.';
  END IF;

  -- A second application proves that casing_notes checks/appends casing_notes,
  -- preserves timestamp precision, and creates one event per action.
  v_modified := public.mp_lots_modify(
    p_lot_ids => ARRAY[v_lot_id],
    p_actions => ARRAY['ApplyCasing'],
    p_operator => 'RC5 #27 smoke test',
    p_station => NULL,
    p_timestamp => v_second_ts,
    p_note => 'Second casing note'
  );

  SELECT status, label_template, casing_applied_at, casing_notes
  INTO v_lot
  FROM public.lots
  WHERE nocopk = v_lot_id;

  IF v_modified <> 1
     OR v_lot.status <> 'Colonizing'
     OR v_lot.label_template <> 'Bulk_Created'
     OR v_lot.casing_applied_at <> v_second_ts
     OR v_lot.casing_notes <> 'First casing note' || E'\n' || 'Second casing note' THEN
    RAISE EXCEPTION 'Repeated Apply Casing did not append notes/preserve state: %', row_to_json(v_lot);
  END IF;

  IF (
    SELECT count(*)
    FROM public.events e
    WHERE e.lot_id = v_lot_id
      AND e.type = 'CasingApplied'
      AND e.station = 'Dark Room'
      AND e.operator = 'RC5 #27 smoke test'
  ) <> 2 THEN
    RAISE EXCEPTION 'Expected two Dark Room CasingApplied events.';
  END IF;

  SELECT count(*) INTO v_print_count_after
  FROM public.print_queue
  WHERE lot_id = v_lot_id;

  IF v_print_count_after <> v_print_count_before THEN
    RAISE EXCEPTION 'Apply Casing unexpectedly created a print queue row.';
  END IF;

  RAISE NOTICE 'Apply Casing status, timestamp, notes, event metadata, linkage, and no-print smoke tests passed.';
END;
$test$;

ROLLBACK;
