/*
  008_lot_actions.sql

  Restores mp_lots_shake, and updates shake/retire to:
    - use the canonical events insert function (mp_events_insert or mp_events_insert_and_link_lot)
    - link created events to lots via mp_events_link_lot (defined elsewhere; if missing, it won't fail)

  Schema assumptions:
    - public.lots has: nocopk (PK), lot_id, status, location_id (FK 1:1), notes, inoculated_at, beganfruiting_at, item_name_mat, strain_species_strain_mat
    - public.locations has: nocopk (PK), name
    - public.events table exists
*/

ALTER TABLE public.lots
  ADD COLUMN IF NOT EXISTS beganfruiting_at timestamp without time zone;

-- 1) SHAKE: logs a ShakeBreak event for each lot, clears ui_error fields (if present), optional note append
CREATE OR REPLACE FUNCTION public.mp_lots_shake(
  p_lot_ids   bigint[],
  p_operator  text,
  p_station   text DEFAULT 'Lots',
  p_timestamp timestamp without time zone DEFAULT NULL,
  p_note      text DEFAULT NULL
)
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE
  v_lot_id bigint;
  v_event_id bigint;
  v_fields jsonb;
  v_counter integer := 0;
BEGIN
  IF p_lot_ids IS NULL OR array_length(p_lot_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;

  FOREACH v_lot_id IN ARRAY p_lot_ids LOOP
    v_fields := jsonb_build_object(
      'action', 'ShakeBreak',
      'note', p_note
    );

    -- Insert + link
    BEGIN
      v_event_id := public.mp_events_insert_and_link_lot(
	v_lot_id::bigint,
	'ShakeBreak'::text, 
	COALESCE(p_timestamp, now())::timestamp, 
	p_operator::text, 
	p_station::text, 
	v_fields::jsonb
    );
    EXCEPTION WHEN undefined_function THEN
	NULL;
    END;

    -- Clear ui error fields if they exist
    BEGIN
      EXECUTE 'UPDATE public.lots SET action = NULL, ui_error = NULL, ui_error_at = NULL WHERE nocopk = $1'
      USING v_lot_id;
    EXCEPTION WHEN undefined_column THEN
      -- schema might not include these columns; ignore
      NULL;
    END;

    -- Optional notes append
    IF p_note IS NOT NULL AND btrim(p_note) <> '' THEN
      UPDATE public.lots
      SET notes = CASE
        WHEN notes IS NULL OR notes = '' THEN p_note
        ELSE notes || E'\n' || p_note
      END
      WHERE nocopk = v_lot_id;
    END IF;
    v_counter := v_counter + 1;

  END LOOP;
  RETURN v_counter;
END;
$$;

-- 2) RETIRE: supports multiple terminal reasons; logs one event per reason per lot.
--    Airtable-equivalent terminal status/event rules:
--      - Contaminated -> event Contaminated, status Retired, optional location Compost
--      - Inviable -> event Inviable, status Retired, optional location Compost
--      - Compost/Composted -> event Composted, status Retired, optional location Compost
--      - Expire/Expired -> event Expired, status Expired, optional location Expired
--    Station defaults from current lot location when p_station is NULL/blank/'Lots'.
--    Also sets retired_at and appends note.
CREATE OR REPLACE FUNCTION public.mp_lots_retire(
  p_lot_ids   bigint[],
  p_reasons   text[],
  p_operator  text,
  p_station   text DEFAULT NULL,
  p_timestamp timestamp without time zone DEFAULT NULL,
  p_note      text DEFAULT NULL
)
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE
  v_lot_id bigint;
  v_reason text;
  v_reason_key text;
  v_event_type text;
  v_event_id bigint;
  v_fields jsonb;
  v_reasons_lower text[];
  v_terminal_status text;
  v_terminal_location text;
  v_station text;
  v_current_location text;
  v_ts timestamp without time zone;
  v_counter integer := 0;
BEGIN
  IF p_lot_ids IS NULL OR array_length(p_lot_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;

  v_ts := COALESCE(p_timestamp, now())::timestamp without time zone;

  v_reasons_lower := ARRAY(
    SELECT lower(btrim(x))
    FROM unnest(COALESCE(p_reasons, ARRAY[]::text[])) AS x
    WHERE x IS NOT NULL AND btrim(x) <> ''
  );

  -- Decide terminal status + optional terminal location. For Airtable parity,
  -- Contaminated, Inviable, and Compost are Retired statuses, not Composted.
  IF ('expired' = ANY(v_reasons_lower)) OR ('expire' = ANY(v_reasons_lower)) THEN
    v_terminal_status := 'Expired';
    v_terminal_location := 'Expired';
  ELSIF ('compost' = ANY(v_reasons_lower))
     OR ('composted' = ANY(v_reasons_lower))
     OR ('contaminated' = ANY(v_reasons_lower))
     OR ('inviable' = ANY(v_reasons_lower)) THEN
    v_terminal_status := 'Retired';
    v_terminal_location := 'Compost';
  ELSE
    v_terminal_status := 'Retired';
    v_terminal_location := NULL;
  END IF;

  FOREACH v_lot_id IN ARRAY p_lot_ids LOOP
    SELECT COALESCE(loc.name, '')
    INTO v_current_location
    FROM public.lots lot
    LEFT JOIN public.locations loc ON loc.nocopk = lot.location_id
    WHERE lot.nocopk = v_lot_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Lot not found: %', v_lot_id;
    END IF;

    v_station := CASE
      WHEN p_station IS NULL OR btrim(p_station) = '' OR btrim(p_station) = 'Lots'
        THEN COALESCE(NULLIF(v_current_location, ''), 'Lots')
      ELSE p_station
    END;

    -- log one event per reason
    FOREACH v_reason IN ARRAY COALESCE(p_reasons, ARRAY[]::text[]) LOOP
      IF v_reason IS NULL OR btrim(v_reason) = '' THEN
        CONTINUE;
      END IF;

      v_reason_key := lower(btrim(v_reason));
      v_event_type := CASE
        WHEN v_reason_key IN ('compost', 'composted') THEN 'Composted'
        WHEN v_reason_key IN ('expire', 'expired') THEN 'Expired'
        WHEN v_reason_key = 'contaminated' THEN 'Contaminated'
        WHEN v_reason_key = 'inviable' THEN 'Inviable'
        ELSE btrim(v_reason)
      END;

      v_fields := jsonb_build_object(
        'reason', v_reason,
        'event_type', v_event_type,
        'reasons', COALESCE(p_reasons, ARRAY[]::text[]),
        'terminal_status', v_terminal_status,
        'terminal_location', v_terminal_location,
        'note', p_note
      );

      BEGIN
        v_event_id := public.mp_events_insert_and_link_lot(
          v_lot_id::bigint,
          v_event_type::text,
          v_ts,
          p_operator::text,
          v_station::text,
          v_fields::jsonb
        );
      EXCEPTION WHEN undefined_function THEN
        NULL;
      END;

    END LOOP;

    -- terminal updates
    UPDATE public.lots
    SET status = v_terminal_status,
        retired_at = v_ts
    WHERE nocopk = v_lot_id;

    IF v_terminal_location IS NOT NULL THEN
      PERFORM public.mp_lot_set_location_by_name(v_lot_id, v_terminal_location);
    END IF;

    IF p_note IS NOT NULL AND btrim(p_note) <> '' THEN
      UPDATE public.lots
      SET notes = CASE
        WHEN notes IS NULL OR notes = '' THEN p_note
        ELSE notes || E'\n' || p_note
      END
      WHERE nocopk = v_lot_id;
    END IF;

    -- Clear ui error fields if present
    BEGIN
      EXECUTE 'UPDATE public.lots SET action = NULL, ui_error = NULL, ui_error_at = NULL WHERE nocopk = $1'
      USING v_lot_id;
    EXCEPTION WHEN undefined_column THEN
      NULL;
    END;
    v_counter := v_counter + 1;

  END LOOP;
  RETURN v_counter;
END;
$$;

-- 3) MOVE / TRANSITION: transitions selected lots through Fully Colonized, Fridge,
--    Cold Shock, Fruiting, or a simple location move.
--
--    p_fridge_mode is retained for backward compatibility with the earlier Fridge
--    modal, but now represents the requested transition mode:
--      - FullyColonized: set status, move to Dark Room by default, and log FullyColonized
--      - Fridge: ensure/log FullyColonized, move to the selected fridge location, set status Fridge
--      - ColdShock: ensure/log FullyColonized, move to the selected fridge location, set status ColdShock
--      - Fruiting / StartFruiting: move to the selected fruiting location, set status Fruiting, log FruitingStart
--      - any other value: simple location Move
CREATE OR REPLACE FUNCTION public.mp_lots_move(
  p_lot_ids   bigint[],
  p_location_id bigint DEFAULT NULL,
  p_fridge_mode text DEFAULT 'Fridge',
  p_operator  text DEFAULT 'system',
  p_station   text DEFAULT 'Transition/Move',
  p_timestamp timestamp without time zone DEFAULT NULL,
  p_note      text DEFAULT NULL
)
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE
  v_lot_id bigint;
  v_event_id bigint;
  v_fields jsonb;
  v_counter integer := 0;
  v_old_status text;
  v_new_status text;
  v_effective_location_id bigint;
  v_location_name text;
  v_mode text;
  v_ts timestamp without time zone;
BEGIN
  IF p_lot_ids IS NULL OR array_length(p_lot_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;

  v_mode := COALESCE(NULLIF(btrim(p_fridge_mode), ''), 'Fridge');
  v_ts := COALESCE(p_timestamp, now())::timestamp without time zone;

  IF p_location_id IS NOT NULL THEN
    SELECT l.nocopk, l.name INTO v_effective_location_id, v_location_name
    FROM public.locations l
    WHERE l.nocopk = p_location_id;

    IF v_location_name IS NULL THEN
      RAISE EXCEPTION 'Location not found for nocopk: %', p_location_id;
    END IF;
  END IF;

  IF v_mode = 'FullyColonized' AND v_effective_location_id IS NULL THEN
    SELECT l.nocopk, l.name INTO v_effective_location_id, v_location_name
    FROM public.locations l
    WHERE COALESCE(l.active, true)
      AND l.name ILIKE '%Dark Room%'
    ORDER BY
      CASE WHEN lower(btrim(l.name)) = 'dark room' THEN 0 ELSE 1 END,
      l.nocopk
    LIMIT 1;
  END IF;

  IF v_mode IN ('FullyColonized', 'Fridge', 'ColdShock', 'Fruiting', 'StartFruiting')
     AND (v_effective_location_id IS NULL OR v_location_name IS NULL) THEN
    RAISE EXCEPTION 'Location is required for % transition', v_mode;
  END IF;

  FOREACH v_lot_id IN ARRAY p_lot_ids LOOP
    SELECT status INTO v_old_status
    FROM public.lots
    WHERE nocopk = v_lot_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Lot not found: %', v_lot_id;
    END IF;

    IF v_mode = 'FullyColonized' THEN
      PERFORM public.mp_lot_set_location(v_lot_id, v_effective_location_id);

      UPDATE public.lots
      SET status = 'FullyColonized'
      WHERE nocopk = v_lot_id;

      BEGIN
        v_event_id := public.mp_events_insert_and_link_lot(
          v_lot_id::bigint,
          'FullyColonized'::text,
          v_ts,
          p_operator::text,
          COALESCE(v_location_name, 'Dark Room')::text,
          jsonb_build_object(
            'action', 'FullyColonized',
            'from_status', v_old_status,
            'to_status', 'FullyColonized',
            'to_location', v_location_name,
            'to_location_id', v_effective_location_id,
            'note', p_note
          )
        );
      EXCEPTION WHEN undefined_function THEN
        NULL;
      END;

    ELSIF v_mode IN ('Fridge', 'ColdShock') THEN
      IF COALESCE(v_old_status, '') NOT IN ('FullyColonized','Fridge','ColdShock') THEN
        UPDATE public.lots
        SET status = 'FullyColonized'
        WHERE nocopk = v_lot_id;

        BEGIN
          v_event_id := public.mp_events_insert_and_link_lot(
            v_lot_id::bigint,
            'FullyColonized'::text,
            v_ts,
            p_operator::text,
            'Dark Room'::text,
            '{}'::jsonb
          );
        EXCEPTION WHEN undefined_function THEN
          NULL;
        END;
      END IF;

      PERFORM public.mp_lot_set_location(v_lot_id, v_effective_location_id);

      v_new_status := CASE WHEN v_mode = 'ColdShock' THEN 'ColdShock' ELSE 'Fridge' END;
      UPDATE public.lots
      SET status = v_new_status
      WHERE nocopk = v_lot_id;

      v_fields := jsonb_build_object(
        'action', v_new_status,
        'from_status', v_old_status,
        'to_status', v_new_status,
        'to_location', v_location_name,
        'to_location_id', v_effective_location_id,
        'note', p_note
      );

      BEGIN
        v_event_id := public.mp_events_insert_and_link_lot(
          v_lot_id::bigint,
          v_new_status::text,
          v_ts,
          p_operator::text,
          COALESCE(NULLIF(btrim(p_station), ''), 'Transition/Move')::text,
          v_fields::jsonb
        );
      EXCEPTION WHEN undefined_function THEN
        NULL;
      END;

    ELSIF v_mode IN ('Fruiting', 'StartFruiting') THEN
      PERFORM public.mp_lot_set_location(v_lot_id, v_effective_location_id);

      UPDATE public.lots
      SET status = 'Fruiting',
          beganfruiting_at = COALESCE(beganfruiting_at, v_ts)
      WHERE nocopk = v_lot_id;

      v_fields := jsonb_build_object(
        'action', 'StartFruiting',
        'from_status', v_old_status,
        'to_status', 'Fruiting',
        'to_location', v_location_name,
        'to_location_id', v_effective_location_id,
        'beganfruiting_at_set', true,
        'note', p_note
      );

      BEGIN
        v_event_id := public.mp_events_insert_and_link_lot(
          v_lot_id::bigint,
          'FruitingStart'::text,
          v_ts,
          p_operator::text,
          'Fruiting'::text,
          v_fields::jsonb
        );
      EXCEPTION WHEN undefined_function THEN
        NULL;
      END;

    ELSE
      IF v_effective_location_id IS NULL OR v_location_name IS NULL THEN
        RAISE EXCEPTION 'Location is required for Move transition';
      END IF;

      PERFORM public.mp_lot_set_location(v_lot_id, v_effective_location_id);

      v_fields := jsonb_build_object(
        'action', 'Move',
        'to_location', v_location_name,
        'to_location_id', v_effective_location_id,
        'note', p_note
      );

      BEGIN
        v_event_id := public.mp_events_insert_and_link_lot(
          v_lot_id::bigint,
          'Move'::text,
          v_ts,
          p_operator::text,
          COALESCE(NULLIF(btrim(p_station), ''), 'Transition/Move')::text,
          v_fields::jsonb
        );
      EXCEPTION WHEN undefined_function THEN
        NULL;
      END;
    END IF;

    IF p_note IS NOT NULL AND btrim(p_note) <> '' THEN
      UPDATE public.lots
      SET notes = CASE
        WHEN notes IS NULL OR notes = '' THEN p_note
        ELSE notes || E'\n' || p_note
      END
      WHERE nocopk = v_lot_id;
    END IF;

    v_counter := v_counter + 1;
  END LOOP;

  RETURN v_counter;
END;
$$;

-- 4) MODIFY: creates a modification/treatment event for each lot (does not change status by default)
CREATE OR REPLACE FUNCTION public.mp_lots_modify(
  p_lot_ids   bigint[],
  p_actions   text[],
  p_operator  text,
  p_station   text DEFAULT 'Dark Room',
  p_timestamp timestamp without time zone DEFAULT NULL,
  p_note      text DEFAULT NULL
)
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE
  v_lot_id bigint;
  v_event_id bigint;
  v_action text;
  v_event_type text;
  v_station text;
  v_ts timestamp without time zone;
  v_fields jsonb;
  v_counter integer := 0;
  v_item_category text;
  v_lot_display_id text;
BEGIN
  IF p_lot_ids IS NULL OR array_length(p_lot_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;

  v_ts := COALESCE(p_timestamp, now())::timestamp without time zone;
  v_station := COALESCE(NULLIF(btrim(p_station), ''), 'Dark Room');

  FOREACH v_lot_id IN ARRAY p_lot_ids LOOP
    SELECT
      lower(COALESCE(NULLIF(btrim(l.item_category_mat), ''), NULLIF(btrim(i.category), ''), '')),
      COALESCE(NULLIF(btrim(l.lot_id), ''), v_lot_id::text)
    INTO v_item_category, v_lot_display_id
    FROM public.lots l
    LEFT JOIN public.items i ON i.nocopk = l.item_id
    WHERE l.nocopk = v_lot_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Lot not found: %', v_lot_id;
    END IF;

    -- log one event per selected action
    FOREACH v_action IN ARRAY COALESCE(p_actions, ARRAY[]::text[]) LOOP
      v_action := NULLIF(btrim(v_action), '');
      IF v_action IS NULL THEN
        CONTINUE;
      END IF;

      v_event_type := CASE v_action
        WHEN 'ApplyCasing' THEN 'CasingApplied'
        WHEN 'ApplyDiatomaceousEarth' THEN 'DiatomaceousEarthApplied'
        WHEN 'ApplyNematodes' THEN 'NematodesApplied'
        WHEN 'ApplyBeneficialTrichoderma' THEN 'BeneficialTrichodermaApplied'
        WHEN 'ModifyFAE' THEN 'FAEModified'
        ELSE v_action
      END;

      v_fields := jsonb_build_object(
        'action', v_action,
        'note', p_note
      );

      IF v_action = 'ApplyCasing' THEN
        IF v_item_category NOT IN ('fruiting_block', 'all_in_one_bag') THEN
          RAISE EXCEPTION 'ApplyCasing requires fruiting_block or all_in_one_bag; lot % has category %',
            v_lot_display_id,
            COALESCE(NULLIF(v_item_category, ''), '(blank)');
        END IF;

        v_fields := v_fields || jsonb_build_object(
          'casing_lot_id', NULL,
          'casing_item_id', NULL
        );
      END IF;

      BEGIN
        v_event_id := public.mp_events_insert_and_link_lot(
          v_lot_id::bigint,
          v_event_type::text,
          v_ts::timestamp,
          p_operator::text,
          v_station::text,
          v_fields::jsonb
        );
      EXCEPTION WHEN undefined_function THEN NULL;
      END;

      IF v_action = 'ApplyCasing' THEN
        UPDATE public.lots
        SET
          casing_applied_at = v_ts,
          casing_notes = CASE
            WHEN p_note IS NULL OR btrim(p_note) = '' THEN casing_notes
            WHEN casing_notes IS NULL OR casing_notes = '' THEN p_note
            ELSE casing_notes || E'\n' || p_note
          END
        WHERE nocopk = v_lot_id;
      END IF;

    END LOOP;

    IF p_note IS NOT NULL AND btrim(p_note) <> '' THEN
      UPDATE public.lots
      SET notes = CASE
        WHEN notes IS NULL OR notes = '' THEN p_note
        ELSE notes || E'\n' || p_note
      END
      WHERE nocopk = v_lot_id;
    END IF;

    v_counter := v_counter + 1;
  END LOOP;

  RETURN v_counter;
END;
$$;

-- Helper: set product storage location by name


-- Batch inoculation (from Airtable inoculate_multiple.js)

CREATE OR REPLACE FUNCTION public.mp_lots_inoculate_multiple(
  p_source_lot_id bigint,
  p_target_lot_ids bigint[],
  p_storage_location_id bigint DEFAULT NULL,
  p_lc_volume_ml numeric DEFAULT NULL,
  p_override_inoc_time timestamp without time zone DEFAULT NULL,
  p_operator text DEFAULT 'system',
  p_station text DEFAULT 'Inoculation',
  p_timestamp timestamp without time zone DEFAULT NULL,
  p_note text DEFAULT NULL
)
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE
  v_source_item_id bigint;
  v_source_item_category text;
  v_source_item_name text;
  v_source_strain_id bigint;
  v_source_vendor_name text;
  v_source_vendor_batch text;
  v_source_vendor_name_mat text;
  v_source_species_strain_mat text;
  v_source_remaining_ml numeric;
  v_source_notes text;
  v_source_created_at timestamp without time zone;
  v_source_sterilized_at timestamp without time zone;
  v_source_received_date date;
  v_source_inoculated_at timestamp without time zone;
  v_source_available_at timestamp without time zone;
  v_source_status text;
  v_source_lot_id text;
  v_source_airtable_id text;

  v_inoc_time timestamp without time zone;

  v_is_liquid_source boolean;
  v_is_solid_source boolean;
  v_is_untracked_source boolean;

  v_target_id bigint;
  v_target_item_id bigint;
  v_target_item_category text;
  v_target_item_name text;
  v_target_unit_size numeric;
  v_target_total_ml numeric;
  v_target_remaining_ml numeric;
  v_target_lot_id text;
  v_target_airtable_id text;
  v_target_status text;
  v_target_inoculated_at timestamp without time zone;
  v_target_strain_id bigint;
  v_target_strain_species_strain_mat text;

  v_label_type text;
  
  v_new_total_ml numeric;
  v_new_remaining_ml numeric;

  v_total_used_ml numeric := 0;
  v_success integer := 0;

  v_event_id bigint;
  v_fields jsonb;

  v_loc_id bigint;
BEGIN
  IF p_source_lot_id IS NULL THEN
    RAISE EXCEPTION 'p_source_lot_id is required';
  END IF;

  IF p_target_lot_ids IS NULL OR array_length(p_target_lot_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'p_target_lot_ids must contain at least one lot id';
  END IF;

  v_inoc_time := COALESCE(p_override_inoc_time, COALESCE(p_timestamp, now()));

  v_loc_id := COALESCE(
    p_storage_location_id,
    (
      SELECT l.nocopk
      FROM public.locations l
      WHERE lower(btrim(l.name)) = lower(btrim('Dark Room'))
      ORDER BY CASE WHEN COALESCE(l.active, false) THEN 0 ELSE 1 END, l.nocopk
      LIMIT 1
    )
  );

  -- Load source lot + item
  SELECT
    l.item_id,
    l.strain_id,
    l.vendor_name,
    l.vendor_batch,
    l.vendor_name_mat,
    l.strain_species_strain_mat,
    l.remaining_volume_ml,
    l.notes,
    l.created_at,
    l.sterilized_at,
    l.received_date,
    l.inoculated_at,
    l.status,
    l.lot_id,
    l.airtable_id,
    i.category,
    i.name
  INTO
    v_source_item_id,
    v_source_strain_id,
    v_source_vendor_name,
    v_source_vendor_batch,
    v_source_vendor_name_mat,
    v_source_species_strain_mat,
    v_source_remaining_ml,
    v_source_notes,
    v_source_created_at,
    v_source_sterilized_at,
    v_source_received_date,
    v_source_inoculated_at,
    v_source_status,
    v_source_lot_id,
    v_source_airtable_id,
    v_source_item_category,
    v_source_item_name
  FROM public.lots l
  LEFT JOIN public.items i ON i.nocopk = l.item_id
  WHERE l.nocopk = p_source_lot_id
  FOR UPDATE OF l;

  IF v_source_item_id IS NULL THEN
    UPDATE public.lots
      SET ui_error = 'Inoculate validation: Source lot must be linked to an item.',
          ui_error_at = now()
    WHERE nocopk = p_source_lot_id;
    RETURN 0;
  END IF;

  v_source_item_category := lower(COALESCE(v_source_item_category, ''));
  v_source_status := regexp_replace(lower(COALESCE(v_source_status, '')), '[^a-z0-9]', '', 'g');
  v_is_liquid_source := v_source_item_category IN ('lc_syringe','lc_flask');
  v_is_solid_source := v_source_item_category IN ('plate','agar_plate','grain');
  v_is_untracked_source := v_source_item_category = 'untracked_source';

  SELECT max(source_date)
    INTO v_source_available_at
  FROM (
    VALUES
      (v_source_created_at),
      (v_source_sterilized_at),
      (v_source_received_date::timestamp without time zone),
      (v_source_inoculated_at)
  ) AS source_dates(source_date)
  WHERE source_date IS NOT NULL;

  IF v_source_available_at IS NOT NULL AND v_inoc_time < v_source_available_at THEN
    UPDATE public.lots
      SET ui_error = format(
            'Inoculate validation: Inoculation time %s cannot be before source lot availability time %s.',
            v_inoc_time,
            v_source_available_at
          ),
          ui_error_at = now()
    WHERE nocopk = p_source_lot_id;
    RETURN 0;
  END IF;

  IF NOT (v_is_liquid_source OR v_is_solid_source OR v_is_untracked_source) THEN
    UPDATE public.lots
      SET ui_error = format('Inoculate validation: Source must be lc_syringe, lc_flask, plate, agar_plate, grain, or untracked_source (got "%s").', v_source_item_category),
          ui_error_at = now()
    WHERE nocopk = p_source_lot_id;
    RETURN 0;
  END IF;

  IF v_source_status NOT IN (
    'inoculated',
    'colonizing',
    'fullycolonized',
    'fridge',
    'coldshock'
  ) THEN
    UPDATE public.lots
      SET ui_error = format(
            'Inoculate validation: Source lot %s is not eligible. Status: %s.',
            COALESCE(NULLIF(v_source_lot_id, ''), p_source_lot_id::text),
            COALESCE(NULLIF(v_source_status, ''), '(blank)')
          ),
          ui_error_at = now()
    WHERE nocopk = p_source_lot_id;
    RETURN 0;
  END IF;

  IF v_is_solid_source AND v_source_inoculated_at IS NULL THEN
    UPDATE public.lots
      SET ui_error = format(
            'Inoculate validation: Solid source lot %s has no inoculated date.',
            COALESCE(NULLIF(v_source_lot_id, ''), p_source_lot_id::text)
          ),
          ui_error_at = now()
    WHERE nocopk = p_source_lot_id;
    RETURN 0;
  END IF;

  -- Category-specific validation
  IF v_is_liquid_source THEN
    IF p_lc_volume_ml IS NULL OR p_lc_volume_ml <= 0 THEN
      UPDATE public.lots
        SET ui_error = 'Inoculate validation: Must enter a positive LC volume (ml) for lc_syringe/lc_flask sources.',
            ui_error_at = now()
      WHERE nocopk = p_source_lot_id;
      RETURN 0;
    END IF;

    IF v_source_remaining_ml IS NOT NULL THEN
      IF (p_lc_volume_ml * array_length(p_target_lot_ids, 1)) > v_source_remaining_ml THEN
        UPDATE public.lots
          SET ui_error = format('Inoculate validation: Source only has %s ml remaining; needs %s ml for %s targets.',
                                v_source_remaining_ml,
                                (p_lc_volume_ml * array_length(p_target_lot_ids, 1)),
                                array_length(p_target_lot_ids, 1)),
              ui_error_at = now()
        WHERE nocopk = p_source_lot_id;
        RETURN 0;
      END IF;
    END IF;

  ELSIF v_is_solid_source THEN
    IF p_lc_volume_ml IS NOT NULL AND p_lc_volume_ml > 0 THEN
      UPDATE public.lots
        SET ui_error = 'Inoculate validation: Do not enter LC volume for plate or grain as source.',
            ui_error_at = now()
      WHERE nocopk = p_source_lot_id;
      RETURN 0;
    END IF;

  ELSIF v_is_untracked_source THEN
    IF v_source_notes IS NULL OR btrim(v_source_notes) = '' THEN
      UPDATE public.lots
        SET ui_error = 'Inoculate validation: For untracked_source, you must enter a description in notes on the source lot.',
            ui_error_at = now()
      WHERE nocopk = p_source_lot_id;
      RETURN 0;
    END IF;
  END IF;

  -- Lock and validate every target before changing any lot. This prevents a
  -- stale browser selection from inoculating a target that was retired,
  -- consumed, or inoculated in another session after it was selected.
  PERFORM 1
  FROM public.lots l
  WHERE l.nocopk = ANY(p_target_lot_ids)
  ORDER BY l.nocopk
  FOR UPDATE;

  IF cardinality(p_target_lot_ids) <> (
    SELECT count(DISTINCT target_id)
    FROM unnest(p_target_lot_ids) AS requested(target_id)
  ) THEN
    UPDATE public.lots
      SET ui_error = 'Inoculate validation: Target lot IDs must be unique.',
          ui_error_at = now()
    WHERE nocopk = p_source_lot_id;
    RETURN 0;
  END IF;

  IF cardinality(p_target_lot_ids) <> (
    SELECT count(*)
    FROM public.lots l
    WHERE l.nocopk = ANY(p_target_lot_ids)
  ) THEN
    UPDATE public.lots
      SET ui_error = 'Inoculate validation: One or more selected target lots no longer exist.',
          ui_error_at = now()
    WHERE nocopk = p_source_lot_id;
    RETURN 0;
  END IF;

  FOREACH v_target_id IN ARRAY p_target_lot_ids LOOP
    SELECT
      l.item_id,
      l.lot_id,
      l.status,
      l.inoculated_at,
      l.strain_id,
      l.strain_species_strain_mat,
      i.category
    INTO
      v_target_item_id,
      v_target_lot_id,
      v_target_status,
      v_target_inoculated_at,
      v_target_strain_id,
      v_target_strain_species_strain_mat,
      v_target_item_category
    FROM public.lots l
    LEFT JOIN public.items i ON i.nocopk = l.item_id
    WHERE l.nocopk = v_target_id;

    IF v_target_item_id IS NULL THEN
      UPDATE public.lots
        SET ui_error = format(
              'Inoculate validation: Target lot %s is missing an item.',
              COALESCE(NULLIF(v_target_lot_id, ''), v_target_id::text)
            ),
            ui_error_at = now()
      WHERE nocopk = p_source_lot_id;
      RETURN 0;
    END IF;

    v_target_item_category := lower(COALESCE(v_target_item_category, ''));
    v_target_status := regexp_replace(lower(COALESCE(v_target_status, '')), '[^a-z0-9]', '', 'g');

    IF v_target_item_category NOT IN (
      'grain',
      'lc_flask',
      'plate',
      'cordyceps_substrate',
      'all_in_one_bag'
    ) THEN
      UPDATE public.lots
        SET ui_error = format(
              'Inoculate validation: Target lot %s has ineligible category "%s".',
              COALESCE(NULLIF(v_target_lot_id, ''), v_target_id::text),
              v_target_item_category
            ),
            ui_error_at = now()
      WHERE nocopk = p_source_lot_id;
      RETURN 0;
    END IF;

    IF v_target_status NOT IN (
      'planned',
      'sterilized',
      'pasteurized',
      'sealed',
      'new',
      'fridge'
    ) THEN
      UPDATE public.lots
        SET ui_error = format(
              'Inoculate validation: Target lot %s is not eligible. Status: %s.',
              COALESCE(NULLIF(v_target_lot_id, ''), v_target_id::text),
              COALESCE(NULLIF(v_target_status, ''), '(blank)')
            ),
            ui_error_at = now()
      WHERE nocopk = p_source_lot_id;
      RETURN 0;
    END IF;

    IF v_target_inoculated_at IS NOT NULL
       OR v_target_strain_id IS NOT NULL
       OR NULLIF(btrim(COALESCE(v_target_strain_species_strain_mat, '')), '') IS NOT NULL THEN
      UPDATE public.lots
        SET ui_error = format(
              'Inoculate validation: Target lot %s has already been inoculated or assigned a strain.',
              COALESCE(NULLIF(v_target_lot_id, ''), v_target_id::text)
            ),
            ui_error_at = now()
      WHERE nocopk = p_source_lot_id;
      RETURN 0;
    END IF;
  END LOOP;

  -- Clear any prior errors only after source and all target validation passes.
  UPDATE public.lots SET ui_error = NULL, ui_error_at = NULL WHERE nocopk = p_source_lot_id;

  -- Apply inoculation to each target
  FOREACH v_target_id IN ARRAY p_target_lot_ids LOOP
    -- load target + item
    SELECT
      l.item_id,
      l.unit_size,
      l.total_volume_ml,
      l.remaining_volume_ml,
      l.lot_id,
      l.airtable_id,
      i.category,
      i.name
    INTO
      v_target_item_id,
      v_target_unit_size,
      v_target_total_ml,
      v_target_remaining_ml,
      v_target_lot_id,
      v_target_airtable_id,
      v_target_item_category,
      v_target_item_name
    FROM public.lots l
    LEFT JOIN public.items i ON i.nocopk = l.item_id
    WHERE l.nocopk = v_target_id;

    IF v_target_item_id IS NULL THEN
      UPDATE public.lots
        SET ui_error = format('Inoculate validation: Target lot %s is missing item.', v_target_id),
            ui_error_at = now()
      WHERE nocopk = p_source_lot_id;
      CONTINUE;
    END IF;

    v_target_item_category := lower(COALESCE(v_target_item_category,''));

    IF v_target_item_category NOT IN (
      'grain',
      'lc_flask',
      'plate',
      'cordyceps_substrate',
      'all_in_one_bag'
    ) THEN
      UPDATE public.lots
        SET ui_error = format('Inoculate validation: Target lot %s must be grain, lc_flask, plate, cordyceps_substrate, or all_in_one_bag (got "%s").', v_target_id, v_target_item_category),
            ui_error_at = now()
      WHERE nocopk = p_source_lot_id;
      CONTINUE;
    END IF;
    
    v_label_type := CASE 
        WHEN v_target_item_category IS NOT NULL AND btrim(v_target_item_category) = 'grain' THEN 'Grain_Inoculated'
        WHEN v_target_item_category IS NOT NULL AND btrim(v_target_item_category) = 'all_in_one_bag' THEN 'All_In_One_Inoculated'
        WHEN v_target_item_category IS NOT NULL AND btrim(v_target_item_category) = 'plate' THEN 'Plate_Inoculated'
        WHEN v_target_item_category IS NOT NULL AND btrim(v_target_item_category) = 'cordyceps_substrate' THEN 'Cordyceps_Substrate_Inoculated'
        ELSE 'LC_Flask_Inoculated'
    END;
    
    -- 1. Determine base volume based on target type
    IF v_target_item_category IN ('lc_flask', 'cordyceps_substrate') THEN
      v_new_total_ml := COALESCE(v_target_total_ml, COALESCE(v_target_unit_size, 0));
      v_new_remaining_ml := COALESCE(v_target_remaining_ml, COALESCE(v_target_unit_size, 0));
    ELSE
      -- For Grain/Plates, start at 0 so we only record the liquid added
      v_new_total_ml := COALESCE(v_target_total_ml, 0);
      v_new_remaining_ml := COALESCE(v_target_remaining_ml, 0);
    END IF;

    -- 2. Add inoculation volume if source is liquid
    IF v_is_liquid_source AND p_lc_volume_ml > 0 THEN
      v_new_total_ml := v_new_total_ml + p_lc_volume_ml;
      v_new_remaining_ml := v_new_remaining_ml + p_lc_volume_ml;
      -- This tracks how much to pull from the source container later
      v_total_used_ml := v_total_used_ml + p_lc_volume_ml;
    END IF;
    
    -- Update target lot fields
    UPDATE public.lots
    SET
      status = 'Colonizing',
      action = NULL,
      inoculated_at = v_inoc_time,
      total_volume_ml = v_new_total_ml,
      remaining_volume_ml = v_new_remaining_ml,
      source_lot_id = p_source_lot_id,
      strain_id = COALESCE(v_source_strain_id, strain_id),
      vendor_name = CASE WHEN COALESCE(v_source_vendor_name,'') <> '' THEN v_source_vendor_name ELSE vendor_name END,
      vendor_batch = CASE WHEN COALESCE(v_source_vendor_batch,'') <> '' THEN v_source_vendor_batch ELSE vendor_batch END,
      vendor_name_mat = CASE WHEN COALESCE(v_source_vendor_name_mat,'') <> '' THEN v_source_vendor_name_mat ELSE vendor_name_mat END,
      strain_species_strain_mat = CASE WHEN COALESCE(v_source_species_strain_mat,'') <> '' THEN v_source_species_strain_mat ELSE strain_species_strain_mat END,
      item_name_mat = COALESCE(item_name_mat, v_target_item_name),
      item_category_mat = COALESCE(item_category_mat, v_target_item_category),
      label_template = v_label_type,
      notes = CASE WHEN v_is_untracked_source THEN v_source_notes ELSE notes END,
      use_by = CASE
        WHEN v_target_item_category IN ('lc_flask','agar_flask','plate','agar_plate') THEN (v_inoc_time + interval '6 months')::date
        WHEN v_target_item_category IN ('grain', 'cordyceps_substrate', 'all_in_one_bag') THEN (v_inoc_time + interval '3 months')::date
        ELSE use_by
      END,
      ui_error = NULL,
      ui_error_at = NULL
    WHERE nocopk = v_target_id;

    -- Set target storage location
    BEGIN
      PERFORM public.mp_lot_set_location(v_target_id, v_loc_id);
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    -- Events
    v_fields := jsonb_build_object(
      'source_lot_id', COALESCE(NULLIF(v_source_airtable_id, ''), NULLIF(v_source_lot_id, ''), p_source_lot_id::text),
      'source_lot_nocopk', p_source_lot_id,
      'source_lot_display_id', COALESCE(NULLIF(v_source_lot_id, ''), p_source_lot_id::text),
      'source_lot_airtable_id', NULLIF(v_source_airtable_id, ''),
      'source_category', v_source_item_category,
      'volume_ml', CASE WHEN (NOT v_is_untracked_source) AND v_is_liquid_source THEN p_lc_volume_ml ELSE NULL END,
      'operator', COALESCE(p_operator, ''),
      'target_lot_id', COALESCE(NULLIF(v_target_lot_id, ''), v_target_id::text),
      'target_lot_nocopk', v_target_id,
      'target_lot_airtable_id', NULLIF(v_target_airtable_id, ''),
      'note', CASE WHEN v_is_untracked_source THEN v_source_notes ELSE p_note END
    );

    BEGIN
      v_event_id := public.mp_events_insert(
        v_target_id,
        NULL::bigint,
        'Inoculated',
        v_inoc_time,
        p_operator,
        p_station,
        v_fields
      );
      BEGIN
        PERFORM public.mp_events_link_lot(v_event_id, v_target_id);
      EXCEPTION WHEN undefined_function THEN NULL;
      END;
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    -- Print job for new inoculated lots (lot labels)
    BEGIN
      PERFORM public.mp_print_queue_enqueue(
        'lot'::text,
        btrim(v_label_type)::text,
        v_target_id,
        NULL::bigint,
        NULL::bigint,
        'Queued'::text
      );
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    v_success := v_success + 1;
  END LOOP;

  IF v_success = 0 THEN
    UPDATE public.lots
      SET ui_error = 'No target lots were successfully inoculated. Check target configuration and try again.',
          ui_error_at = now()
    WHERE nocopk = p_source_lot_id;
    RETURN 0;
  END IF;

  -- Update source lot: clear staging fields and decrement tracked liquid remaining_volume_ml
  UPDATE public.lots
  SET
    action = NULL,
    override_inoc_time = NULL,
    lc_volume_ml = NULL
  WHERE nocopk = p_source_lot_id;

  -- Clear multi-link "target_lot_ids" if present (matches Airtable)
  BEGIN
    DELETE FROM public._m2m_lots_lots_target_lot_ids WHERE lots_id = p_source_lot_id;
  EXCEPTION WHEN undefined_table THEN NULL;
  END;

  IF (NOT v_is_untracked_source) AND v_is_liquid_source AND v_total_used_ml > 0 THEN
    IF v_source_remaining_ml IS NOT NULL THEN
      UPDATE public.lots
      SET remaining_volume_ml = (v_source_remaining_ml - v_total_used_ml),
          status = CASE WHEN (v_source_remaining_ml - v_total_used_ml) <= 0 THEN 'Consumed' ELSE status END
      WHERE nocopk = p_source_lot_id;

      IF (v_source_remaining_ml - v_total_used_ml) <= 0 THEN
        BEGIN
          PERFORM public.mp_lot_set_location_by_name(p_source_lot_id, 'Consumed');
        EXCEPTION WHEN undefined_function THEN NULL;
        END;
      END IF;
    END IF;
  END IF;

  IF v_is_untracked_source THEN
    UPDATE public.lots SET notes = NULL WHERE nocopk = p_source_lot_id;
  END IF;

  RETURN v_success;
END;
$$;

-- Appsmith-facing wrapper that returns the exact validation diagnostic written
-- by mp_lots_inoculate_multiple in the same function call. Keeping the original
-- integer-returning function preserves compatibility for existing callers.
CREATE OR REPLACE FUNCTION public.mp_lots_inoculate_multiple_result(
  p_source_lot_id bigint,
  p_target_lot_ids bigint[],
  p_storage_location_id bigint DEFAULT NULL,
  p_lc_volume_ml numeric DEFAULT NULL,
  p_override_inoc_time timestamp without time zone DEFAULT NULL,
  p_operator text DEFAULT 'system',
  p_station text DEFAULT 'Inoculation',
  p_timestamp timestamp without time zone DEFAULT NULL,
  p_note text DEFAULT NULL
)
RETURNS TABLE(inoculated_count integer, diagnostic text)
LANGUAGE plpgsql
AS $$
BEGIN
  inoculated_count := public.mp_lots_inoculate_multiple(
    p_source_lot_id => p_source_lot_id,
    p_target_lot_ids => p_target_lot_ids,
    p_storage_location_id => p_storage_location_id,
    p_lc_volume_ml => p_lc_volume_ml,
    p_override_inoc_time => p_override_inoc_time,
    p_operator => p_operator,
    p_station => p_station,
    p_timestamp => p_timestamp,
    p_note => p_note
  );

  SELECT NULLIF(btrim(l.ui_error), '')
  INTO diagnostic
  FROM public.lots l
  WHERE l.nocopk = p_source_lot_id;

  RETURN NEXT;
END;
$$;


CREATE OR REPLACE FUNCTION public.mp_product_set_storage_location(p_product_id bigint, p_location_id bigint)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  IF p_location_id IS NULL THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.locations
    WHERE nocopk = p_location_id
  ) THEN
    RAISE EXCEPTION 'Location not found for nocopk: %', p_location_id;
  END IF;

  UPDATE public.products
  SET storage_location_id = p_location_id
  WHERE nocopk = p_product_id;

  BEGIN
    DELETE FROM public._m2m_products_locations_storage_location
    WHERE products_id = p_product_id;

    INSERT INTO public._m2m_products_locations_storage_location (products_id, locations_id)
    VALUES (p_product_id, p_location_id)
    ON CONFLICT DO NOTHING;
  EXCEPTION WHEN undefined_table THEN
    NULL;
  END;

  BEGIN
    DELETE FROM public._m2m_locations_products_products
    WHERE products_id = p_product_id;

    INSERT INTO public._m2m_locations_products_products (locations_id, products_id)
    VALUES (p_location_id, p_product_id)
    ON CONFLICT DO NOTHING;
  EXCEPTION WHEN undefined_table THEN
    NULL;
  END;
END;
$$;

CREATE OR REPLACE FUNCTION public.mp_product_set_storage_location_by_name(p_product_id bigint, p_location_name text)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_loc_id bigint;
BEGIN
  IF p_location_name IS NULL OR btrim(p_location_name) = '' THEN
    RETURN;
  END IF;

  SELECT nocopk INTO v_loc_id
  FROM public.locations
  WHERE lower(btrim(name)) = lower(btrim(p_location_name))
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  IF v_loc_id IS NULL THEN
    RAISE EXCEPTION 'Location not found: %', p_location_name;
  END IF;

  PERFORM public.mp_product_set_storage_location(p_product_id, v_loc_id);
END;
$$;

-- 5) PACKAGE (basic): create one independent product for each selected lot,
--    link each product to its origin lot, consume each source lot, and enqueue
--    one print job per product. All selected lots are validated before mutation.
CREATE OR REPLACE FUNCTION public.mp_lot_packageable_weight_g(
  p_lot_id bigint
)
RETURNS numeric
LANGUAGE sql
STABLE
AS $$
  SELECT round((
    CASE
      WHEN l.harvest_weight_g IS NOT NULL AND l.harvest_weight_g::numeric > 0
        THEN l.harvest_weight_g::numeric
      WHEN lower(COALESCE(NULLIF(btrim(l.item_category_mat), ''), NULLIF(btrim(i.category), ''), ''))
           IN ('all_in_one_bag', 'casing', 'fruiting_block', 'grain', 'substrate')
           AND l.unit_size IS NOT NULL
           AND l.unit_size::numeric > 0
        THEN l.unit_size::numeric * 453.59237
      WHEN i.default_unit_size_g IS NOT NULL AND i.default_unit_size_g::numeric > 0
        THEN i.default_unit_size_g::numeric
      WHEN i.default_unit_size_oz IS NOT NULL AND i.default_unit_size_oz::numeric > 0
        THEN i.default_unit_size_oz::numeric * 28.349523125
      WHEN i.default_unit_size_lb IS NOT NULL AND i.default_unit_size_lb::numeric > 0
        THEN i.default_unit_size_lb::numeric * 453.59237
      ELSE NULL
    END
  )::numeric, 2)
  FROM public.lots l
  LEFT JOIN public.items i ON i.nocopk = l.item_id
  WHERE l.nocopk = p_lot_id;
$$;

CREATE OR REPLACE FUNCTION public.mp_lots_package_basic(
  p_lot_ids   bigint[],
  p_package_count numeric DEFAULT 1,
  p_package_size_g numeric DEFAULT NULL,
  p_storage_location_id bigint DEFAULT NULL,
  p_operator  text DEFAULT 'system',
  p_station   text DEFAULT 'Lots',
  p_timestamp timestamp without time zone DEFAULT NULL,
  p_note      text DEFAULT NULL
)
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE
  v_lot_id bigint;
  v_product_id bigint;
  v_event_id bigint;
  v_fields jsonb;
  v_counter integer := 0;
  v_input_count integer;

  v_item_id bigint;
  v_name_mat text;
  v_item_category_mat text;
  v_item_category text;
  v_item_name text;
  v_lot_id_text text;
  v_lot_unit_size numeric;
  v_net_g numeric;
  v_net_oz numeric;
  v_pack_date date;
  v_use_by date;
  v_storage_location_id bigint;
  v_storage_location_name text;
  v_spawned_at timestamp without time zone;
  v_inoculated_at timestamp without time zone;
  v_status text;
  v_ts timestamp without time zone := COALESCE(p_timestamp, now()::timestamp without time zone);

  c_oz_to_g constant numeric := 28.349523125;
BEGIN
  IF p_lot_ids IS NULL OR cardinality(p_lot_ids) = 0 THEN
    RETURN 0;
  END IF;

  IF p_package_count IS NULL OR p_package_count <> 1 THEN
    RAISE EXCEPTION 'Package Lots creates exactly one independent product per selected lot.';
  END IF;

  IF EXISTS (SELECT 1 FROM unnest(p_lot_ids) AS x(id) WHERE id IS NULL) THEN
    RAISE EXCEPTION 'Package lot IDs cannot contain NULL values.';
  END IF;

  SELECT count(DISTINCT id) INTO v_input_count
  FROM unnest(p_lot_ids) AS x(id);

  IF v_input_count <> cardinality(p_lot_ids) THEN
    RAISE EXCEPTION 'Package lot IDs must be unique.';
  END IF;

  v_pack_date := v_ts::date;
  v_storage_location_id := COALESCE(
    p_storage_location_id,
    (
      SELECT l.nocopk
      FROM public.locations l
      WHERE lower(btrim(l.name)) = lower(btrim('Products Storage'))
      ORDER BY CASE WHEN COALESCE(l.active, false) THEN 0 ELSE 1 END, l.nocopk
      LIMIT 1
    )
  );

  SELECT l.name INTO v_storage_location_name
  FROM public.locations l
  WHERE l.nocopk = v_storage_location_id
    AND COALESCE(l.active, false);

  IF v_storage_location_id IS NULL OR v_storage_location_name IS NULL THEN
    RAISE EXCEPTION 'An active product storage location is required.';
  END IF;

  -- Validate and lock the complete selection before creating any product,
  -- consuming any lot, inserting any event, or enqueueing any label.
  FOREACH v_lot_id IN ARRAY p_lot_ids LOOP
    SELECT
      l.item_id,
      l.lot_id,
      COALESCE(NULLIF(btrim(l.item_category_mat), ''), NULLIF(btrim(i.category), ''), ''),
      l.status,
      public.mp_lot_packageable_weight_g(l.nocopk)
    INTO
      v_item_id,
      v_lot_id_text,
      v_item_category_mat,
      v_status,
      v_net_g
    FROM public.lots l
    LEFT JOIN public.items i ON i.nocopk = l.item_id
    WHERE l.nocopk = v_lot_id
    FOR UPDATE OF l;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Selected lot was not found: %', v_lot_id;
    END IF;

    IF v_item_id IS NULL THEN
      RAISE EXCEPTION 'Lot % requires an item before packaging.', COALESCE(v_lot_id_text, v_lot_id::text);
    END IF;

    IF lower(v_item_category_mat) NOT IN ('grain', 'substrate', 'casing', 'fruiting_block', 'all_in_one_bag') THEN
      RAISE EXCEPTION 'Lot % has non-packageable category %.', COALESCE(v_lot_id_text, v_lot_id::text), COALESCE(v_item_category_mat, '(blank)');
    END IF;

    IF regexp_replace(lower(COALESCE(v_status, '')), '[^a-z0-9]', '', 'g') IN
       ('retired', 'consumed', 'compost', 'composted', 'expired', 'deleted', 'spoiled') THEN
      RAISE EXCEPTION 'Lot % is not active for packaging (status %).', COALESCE(v_lot_id_text, v_lot_id::text), COALESCE(v_status, '(blank)');
    END IF;

    IF v_net_g IS NULL OR v_net_g <= 0 THEN
      RAISE EXCEPTION 'Lot % does not have a packageable weight. Set lot unit_size or an item default unit size.', COALESCE(v_lot_id_text, v_lot_id::text);
    END IF;
  END LOOP;

  FOREACH v_lot_id IN ARRAY p_lot_ids LOOP
    SELECT
      l.item_id,
      l.item_name_mat,
      COALESCE(NULLIF(btrim(l.item_category_mat), ''), NULLIF(btrim(i.category), ''), ''),
      l.lot_id,
      l.unit_size,
      l.spawned_at,
      l.inoculated_at,
      i.name,
      i.category,
      public.mp_lot_packageable_weight_g(l.nocopk)
    INTO
      v_item_id,
      v_name_mat,
      v_item_category_mat,
      v_lot_id_text,
      v_lot_unit_size,
      v_spawned_at,
      v_inoculated_at,
      v_item_name,
      v_item_category,
      v_net_g
    FROM public.lots l
    LEFT JOIN public.items i ON i.nocopk = l.item_id
    WHERE l.nocopk = v_lot_id;

    v_item_name := COALESCE(v_item_name, v_name_mat, '');
    v_net_oz := round(v_net_g / c_oz_to_g, 2);
    v_use_by := COALESCE(
      (v_spawned_at + interval '3 months')::date,
      (v_inoculated_at + interval '3 months')::date,
      (v_pack_date + interval '3 months')::date
    );

    INSERT INTO public.products (
      item_id,
      name_mat,
      item_category_mat,
      net_weight_g,
      net_weight_oz,
      net_volume_ml,
      pack_date,
      use_by,
      package_count,
      origin_lot_ids_json,
      strain_id,
      notes
    )
    SELECT
      l.item_id,
      COALESCE(l.item_name_mat, v_item_name),
      v_item_category_mat,
      v_net_g,
      v_net_oz,
      NULL::numeric,
      v_pack_date,
      v_use_by,
      1,
      to_jsonb(ARRAY[COALESCE(NULLIF(btrim(l.lot_id),''), l.nocopk::text)])::text,
      l.strain_id,
      NULLIF(btrim(COALESCE(p_note, '')), '')
    FROM public.lots l
    WHERE l.nocopk = v_lot_id
    RETURNING nocopk INTO v_product_id;

    IF EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'products'
        AND column_name = 'process_type_mat'
    ) THEN
      IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'lots'
          AND column_name = 'process_type_mat'
      ) THEN
        UPDATE public.products p
        SET process_type_mat = (
          SELECT l.process_type_mat
          FROM public.lots l
          WHERE l.nocopk = v_lot_id
        )
        WHERE p.nocopk = v_product_id;
      ELSIF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'lots'
          AND column_name = 'process_type'
      ) THEN
        UPDATE public.products p
        SET process_type_mat = (
          SELECT l.process_type
          FROM public.lots l
          WHERE l.nocopk = v_lot_id
        )
        WHERE p.nocopk = v_product_id;
      END IF;
    END IF;

    PERFORM public.mp_product_set_storage_location(v_product_id, v_storage_location_id);

    INSERT INTO public._m2m_products_lots_origin_lots (products_id, lots_id)
    VALUES (v_product_id, v_lot_id)
    ON CONFLICT DO NOTHING;

    UPDATE public.lots
    SET
      status = 'Consumed',
      ui_error = NULL,
      ui_error_at = NULL
    WHERE nocopk = v_lot_id;

    PERFORM public.mp_lot_set_location_by_name(v_lot_id, 'Consumed');

    v_fields := jsonb_build_object(
      'action', 'Package',
      'source_lot_id', v_lot_id_text,
      'derived_item_category', v_item_category_mat,
      'net_weight_g', v_net_g,
      'net_weight_oz', v_net_oz,
      'pack_date', v_pack_date,
      'use_by', v_use_by,
      'package_count', 1,
      'package_size_g', v_net_g,
      'legacy_requested_package_size_g', p_package_size_g,
      'product_storage_location_id', v_storage_location_id,
      'product_storage_location', v_storage_location_name,
      'source_lot_status', 'Consumed',
      'source_lot_location', 'Consumed',
      'note', NULLIF(btrim(COALESCE(p_note, '')), '')
    );

    v_event_id := public.mp_events_insert(
      v_lot_id::bigint,
      v_product_id::bigint,
      'Package'::text,
      v_ts,
      p_operator::text,
      p_station::text,
      v_fields::jsonb
    );
    PERFORM public.mp_events_link_lot(v_event_id, v_lot_id);

    PERFORM public.mp_print_queue_enqueue(
      'product'::text,
      'Product_Package'::text,
      v_lot_id,
      v_product_id,
      NULL::bigint,
      'Queued'::text
    );

    v_counter := v_counter + 1;
  END LOOP;

  RETURN v_counter;
END;
$$;

-- DRAW SYRINGES: create lc_syringe lots from a single lc_flask lot, decrement source remaining_volume_ml, events + print jobs

CREATE OR REPLACE FUNCTION public.mp_lots_draw_syringes(
  p_source_lc_flask_lot_id bigint,
  p_syringe_item_id bigint,
  p_syringe_count integer,
  p_ml_each numeric,
  p_storage_location_id bigint,
  p_operator text,
  p_station text DEFAULT 'LC – Make Syringes',
  p_timestamp timestamp without time zone DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
  v_ts timestamp without time zone := COALESCE(p_timestamp, now());
  v_src record;
  v_syringe_item record;
  v_strain record;
  v_new_lot_id bigint;
  v_event_id bigint;
  v_count integer := 0;
  v_created_lot_ids bigint[] := ARRAY[]::bigint[];
  v_loc_id bigint := COALESCE(
    p_storage_location_id,
    (
      SELECT l.nocopk
      FROM public.locations l
      WHERE lower(btrim(l.name)) IN ('fridge','refrigerator','refrigerated storage')
         OR lower(l.name) LIKE '%fridge%'
         OR lower(l.name) LIKE '%refrigerat%'
      ORDER BY
        CASE WHEN lower(btrim(l.name)) = 'fridge' THEN 0 ELSE 1 END,
        CASE WHEN COALESCE(l.active, false) THEN 0 ELSE 1 END,
        l.nocopk
      LIMIT 1
    )
  );
  v_total_ml numeric := COALESCE(p_ml_each,0) * COALESCE(p_syringe_count,0);
  v_remaining_ml numeric;
  v_use_by date := (v_ts + interval '3 months')::date;
  v_species_strain_mat text;
  v_vendor_name_mat text;
BEGIN
  IF p_source_lc_flask_lot_id IS NULL THEN
    RAISE EXCEPTION 'Source lc_flask lot is required';
  END IF;
  IF p_syringe_item_id IS NULL THEN
    RAISE EXCEPTION 'Syringe item is required';
  END IF;
  IF p_syringe_count IS NULL OR p_syringe_count <= 0 THEN
    RAISE EXCEPTION 'Syringe count must be > 0';
  END IF;
  IF p_ml_each IS NULL OR p_ml_each <= 0 THEN
    RAISE EXCEPTION 'ml_each must be > 0';
  END IF;

  SELECT * INTO v_src FROM public.lots WHERE nocopk = p_source_lc_flask_lot_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Source lot not found: %', p_source_lc_flask_lot_id;
  END IF;
  IF COALESCE(v_src.item_category_mat,'') <> 'lc_flask' THEN
    RAISE EXCEPTION 'Source lot must be lc_flask (got %)', v_src.item_category_mat;
  END IF;
  IF COALESCE(v_src.remaining_volume_ml, 0) < v_total_ml THEN
    RAISE EXCEPTION 'Not enough LC volume. Need % ml, have % ml.', v_total_ml, COALESCE(v_src.remaining_volume_ml, 0);
  END IF;
  IF v_loc_id IS NULL THEN
    RAISE EXCEPTION 'Refrigerated storage location is required for drawn syringe lots.';
  END IF;

  SELECT * INTO v_syringe_item FROM public.items WHERE nocopk = p_syringe_item_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Syringe item not found: %', p_syringe_item_id;
  END IF;

  IF v_src.strain_id IS NOT NULL THEN
    SELECT * INTO v_strain FROM public.strains WHERE nocopk = v_src.strain_id;
  END IF;

  v_species_strain_mat := COALESCE(v_src.strain_species_strain_mat, v_strain.species_strain);
  v_vendor_name_mat := COALESCE(v_src.vendor_name_mat, v_src.vendor_name);

  FOR i IN 1..p_syringe_count LOOP
    INSERT INTO public.lots(
      item_id, recipe_id, strain_id,
      item_name_mat, item_category_mat,
      strain_species_strain_mat, vendor_name_mat, vendor_name, vendor_batch, source_type,
      status, operator, created_at,
      source_lot_id, parent_lot_id,
      qty, unit_size, total_volume_ml, remaining_volume_ml, received_date, use_by,
      label_template,
      notes
    )
    VALUES (
      p_syringe_item_id,
      v_src.recipe_id,
      v_src.strain_id,
      COALESCE(v_syringe_item.name, v_src.item_name_mat, 'LC Syringe'),
      COALESCE(v_syringe_item.category, 'lc_syringe'),
      v_species_strain_mat,
      v_vendor_name_mat,
      v_vendor_name_mat,
      v_src.vendor_batch,
      'Produced',
      'Fridge',
      p_operator,
      v_ts,
      p_source_lc_flask_lot_id,
      p_source_lc_flask_lot_id,
      1,
      p_ml_each,
      p_ml_each,
      p_ml_each,
      v_ts::date,
      v_use_by,
      'LC_Syringe_Drawn',
      p_notes
    )
    RETURNING nocopk INTO v_new_lot_id;

    v_created_lot_ids := array_append(v_created_lot_ids, v_new_lot_id);

    BEGIN
      PERFORM public.mp_link_lot_item(v_new_lot_id, p_syringe_item_id);
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    IF v_src.recipe_id IS NOT NULL THEN
      BEGIN
        PERFORM public.mp_link_lot_recipe(v_new_lot_id, v_src.recipe_id);
      EXCEPTION WHEN undefined_function THEN NULL;
      END;
    END IF;

    IF v_src.strain_id IS NOT NULL THEN
      BEGIN
        PERFORM public.mp_link_lot_strain(v_new_lot_id, v_src.strain_id);
      EXCEPTION WHEN undefined_function THEN NULL;
      END;
    END IF;

    PERFORM public.mp_lot_set_location(v_new_lot_id, v_loc_id);

    BEGIN
      PERFORM public.mp_print_queue_enqueue(
        'lot'::text,
        'LC_Syringe_Drawn'::text,
        v_new_lot_id,
        NULL::bigint,
        NULL::bigint,
        'Queued'::text
      );
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    v_count := v_count + 1;
  END LOOP;

  UPDATE public.lots
    SET remaining_volume_ml = GREATEST(0, COALESCE(remaining_volume_ml,0) - v_total_ml),
        nc_updated_at = now()
    WHERE nocopk = p_source_lc_flask_lot_id
    RETURNING remaining_volume_ml INTO v_remaining_ml;

  IF COALESCE(v_remaining_ml,0) <= 0 THEN
    UPDATE public.lots
      SET status = 'Consumed',
          nc_updated_at = now()
      WHERE nocopk = p_source_lc_flask_lot_id;
    BEGIN
      PERFORM public.mp_lot_set_location_by_name(p_source_lc_flask_lot_id, 'Consumed');
    EXCEPTION WHEN undefined_function THEN NULL;
    END;
  END IF;

  BEGIN
    v_event_id := public.mp_events_insert(
      p_lot_id => p_source_lc_flask_lot_id,
      p_product_id => NULL::bigint,
      p_type => 'SyringesDrawn'::text,
      p_timestamp => v_ts,
      p_operator => COALESCE(p_operator,'')::text,
      p_station => COALESCE(NULLIF(p_station,''),'LC – Make Syringes')::text,
      p_fields_json => jsonb_build_object(
        'source_lot_id', p_source_lc_flask_lot_id,
        'output_type', 'lot',
        'syringe_item_id', p_syringe_item_id,
        'syringe_count', p_syringe_count,
        'ml_each', p_ml_each,
        'used_volume_ml', v_total_ml,
        'remaining_volume_ml', v_remaining_ml,
        'storage_location_id', v_loc_id,
        'output_lot_ids', to_jsonb(v_created_lot_ids),
        'use_by', v_use_by,
        'notes', p_notes
      )
    );

    BEGIN
      PERFORM public.mp_events_link_lot(v_event_id, p_source_lc_flask_lot_id);
      FOREACH v_new_lot_id IN ARRAY v_created_lot_ids LOOP
        PERFORM public.mp_events_link_lot(v_event_id, v_new_lot_id);
      END LOOP;
    EXCEPTION WHEN undefined_function THEN NULL;
    END;
  EXCEPTION WHEN undefined_function THEN NULL;
  END;

  RETURN v_count;
END;
$$;


-- RECEIVE PURCHASED SYRINGES: create N lc_syringe lots from vendor receipt, events + print jobs

CREATE OR REPLACE FUNCTION public.mp_lots_receive_purchased_syringes(
  p_item_id bigint,
  p_strain_id bigint,
  p_vendor_name text,
  p_vendor_batch text,
  p_received_date date,
  p_ml_each numeric,
  p_count integer,
  p_storage_location_id bigint,
  p_operator text,
  p_station text DEFAULT 'Receiving',
  p_notes text DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
  v_ts timestamp without time zone := now();
  v_new_lot_id bigint;
  v_event_id bigint;
  v_i integer;
  v_loc_id bigint := COALESCE(
    p_storage_location_id,
    (
      SELECT l.nocopk
      FROM public.locations l
      WHERE lower(btrim(l.name)) = lower(btrim('Fridge'))
      ORDER BY CASE WHEN COALESCE(l.active, false) THEN 0 ELSE 1 END, l.nocopk
      LIMIT 1
    )
  );
  v_rcv date := COALESCE(p_received_date, now()::date);
  v_strain record;
  v_item record;
BEGIN
  IF p_item_id IS NULL THEN RAISE EXCEPTION 'Item is required'; END IF;
  IF p_strain_id IS NULL THEN RAISE EXCEPTION 'Strain is required'; END IF;
  IF p_count IS NULL OR p_count <= 0 THEN RAISE EXCEPTION 'Count must be > 0'; END IF;
  IF p_ml_each IS NULL OR p_ml_each <= 0 THEN RAISE EXCEPTION 'ml_each must be > 0'; END IF;

  SELECT * INTO v_strain FROM public.strains WHERE nocopk = p_strain_id;
  SELECT * INTO v_item FROM public.items WHERE nocopk = p_item_id;

  FOR v_i IN 1..p_count LOOP
    INSERT INTO public.lots(
      item_id, recipe_id, strain_id, strain_species_strain_mat,
      item_name_mat, item_category_mat, status,
      vendor_name, vendor_name_mat, vendor_batch, source_type, received_date,
      qty, unit_size, total_volume_ml, remaining_volume_ml, use_by,
      label_template,
      operator, created_at, notes
    )
    VALUES(
      p_item_id,
      NULL,
      p_strain_id,
      v_strain.species_strain,
      v_item.name,
      v_item.category,
      'Fridge',
      p_vendor_name,
      p_vendor_name,
      p_vendor_batch,
      'Purchased',
      v_rcv,
      1,
      p_ml_each,
      p_ml_each,
      p_ml_each,
      NULL, -- Airtable parity: purchased syringe use_by remains blank on receipt.
      'LC_Syringe_Received',
      p_operator,
      v_ts,
      p_notes
    )
    RETURNING nocopk INTO v_new_lot_id;

    BEGIN
      PERFORM public.mp_link_lot_item(v_new_lot_id, p_item_id);
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    BEGIN
      PERFORM public.mp_link_lot_strain(v_new_lot_id, p_strain_id);
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    BEGIN
      PERFORM public.mp_lot_set_location(v_new_lot_id, v_loc_id);
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    BEGIN
      v_event_id := public.mp_events_insert_and_link_lot(
        v_new_lot_id,
        'Received'::text,
        v_ts,
        COALESCE(p_operator,'system')::text,
        COALESCE(NULLIF(btrim(p_station), ''), 'Receiving')::text,
        jsonb_build_object(
          'vendor_name', p_vendor_name,
          'vendor_batch', p_vendor_batch,
          'source_type', 'Purchased',
          'total_volume_ml', p_ml_each
        )
      );
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    BEGIN
      v_event_id := public.mp_events_insert_and_link_lot(
        v_new_lot_id,
        'FullyColonized'::text,
        v_ts,
        COALESCE(p_operator,'system')::text,
        'Dark Room'::text,
        '{}'::jsonb
      );
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    BEGIN
      PERFORM public.mp_print_queue_enqueue(
        'lot'::text,
        'LC_Syringe_Received'::text,
        v_new_lot_id,
        NULL::bigint,
        NULL::bigint,
        'Queued'::text
      );
    EXCEPTION WHEN undefined_function THEN NULL;
    END;
  END LOOP;

  RETURN p_count;
END;
$$;


-- POUR PLATES: create N plate lots from an agar_flask lot, events + print jobs, group_id assigned

CREATE OR REPLACE FUNCTION public.mp_lots_pour_plates(
  p_source_agar_flask_lot_id bigint,
  p_plate_item_id bigint,
  p_plate_count integer,
  p_storage_location_id bigint,
  p_operator text,
  p_station text DEFAULT 'Pour Plates',
  p_timestamp timestamp without time zone DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
  v_ts timestamp without time zone := COALESCE(p_timestamp, now());
  v_src record;
  v_plate_item record;
  v_new_lot_id bigint;
  v_new_lot_display_id text;
  v_event_id bigint;
  v_group_id text := gen_random_uuid()::text;
  v_loc_id bigint := COALESCE(
    p_storage_location_id,
    (
      SELECT l.nocopk
      FROM public.locations l
      WHERE lower(btrim(l.name)) = lower(btrim('Fridge'))
      ORDER BY CASE WHEN COALESCE(l.active, false) THEN 0 ELSE 1 END, l.nocopk
      LIMIT 1
    )
  );
  v_i integer;
  v_use_by date;
  v_source_available_at timestamp without time zone;
  v_created_plate_ids text[] := ARRAY[]::text[];
  v_created_plate_nocopks bigint[] := ARRAY[]::bigint[];
BEGIN
  IF p_source_agar_flask_lot_id IS NULL THEN RAISE EXCEPTION 'Source agar_flask lot required'; END IF;
  IF p_plate_item_id IS NULL THEN RAISE EXCEPTION 'Plate item required'; END IF;
  IF p_plate_count IS NULL OR p_plate_count <= 0 THEN RAISE EXCEPTION 'Plate count must be > 0'; END IF;
  IF v_loc_id IS NULL THEN RAISE EXCEPTION 'Storage location is required or Fridge must exist as a default location'; END IF;

  SELECT * INTO v_src FROM public.lots WHERE nocopk = p_source_agar_flask_lot_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Source lot not found: %', p_source_agar_flask_lot_id; END IF;
  IF COALESCE(v_src.item_category_mat,'') <> 'agar_flask' THEN
    RAISE EXCEPTION 'Source lot must be agar_flask (got %)', v_src.item_category_mat;
  END IF;
  IF lower(COALESCE(v_src.status, '')) IN ('consumed', 'retired', 'expired', 'compost', 'composted') THEN
    RAISE EXCEPTION 'Source agar flask is already unavailable with status %', v_src.status;
  END IF;

  SELECT max(source_date)
    INTO v_source_available_at
  FROM (
    VALUES
      (v_src.created_at::timestamp without time zone),
      (v_src.sterilized_at::timestamp without time zone),
      (v_src.received_date::timestamp without time zone)
  ) AS source_dates(source_date)
  WHERE source_date IS NOT NULL;

  IF v_source_available_at IS NOT NULL AND v_ts < v_source_available_at THEN
    RAISE EXCEPTION 'Pour date % cannot be before source agar flask availability date %',
      v_ts, v_source_available_at;
  END IF;

  SELECT nocopk, name, category INTO v_plate_item
  FROM public.items
  WHERE nocopk = p_plate_item_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Plate item not found: %', p_plate_item_id;
  END IF;
  IF COALESCE(v_plate_item.category, '') <> 'plate' THEN
    RAISE EXCEPTION 'Plate item must have category plate (got %)', v_plate_item.category;
  END IF;

  v_use_by := COALESCE(v_src.use_by, (v_ts + interval '6 months')::date);

  FOR v_i IN 1..p_plate_count LOOP
    INSERT INTO public.lots(
      item_id, recipe_id, strain_id,
      item_name_mat, item_category_mat,
      strain_species_strain_mat, vendor_name_mat,
      status, operator, created_at,
      source_lot_id, parent_lot_id,
      qty, plate_group_id, received_date, use_by,
      notes
    )
    VALUES(
      p_plate_item_id,
      v_src.recipe_id,
      v_src.strain_id,
      v_plate_item.name,
      COALESCE(v_plate_item.category, 'plate'),
      v_src.strain_species_strain_mat,
      v_src.vendor_name_mat,
      COALESCE(v_src.status, 'Sterilized'),
      p_operator,
      v_ts,
      p_source_agar_flask_lot_id,
      p_source_agar_flask_lot_id,
      1,
      v_group_id,
      v_ts::date,
      v_use_by,
      p_notes
    )
    RETURNING nocopk INTO v_new_lot_id;

    SELECT COALESCE(lot_id, v_new_lot_id::text)
    INTO v_new_lot_display_id
    FROM public.lots
    WHERE nocopk = v_new_lot_id;

    v_created_plate_nocopks := array_append(v_created_plate_nocopks, v_new_lot_id);
    v_created_plate_ids := array_append(v_created_plate_ids, v_new_lot_display_id);

    BEGIN
      PERFORM public.mp_link_lot_item(v_new_lot_id, p_plate_item_id);
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    BEGIN
      PERFORM public.mp_link_lot_recipe(v_new_lot_id, v_src.recipe_id);
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    IF v_src.strain_id IS NOT NULL THEN
      BEGIN
        PERFORM public.mp_link_lot_strain(v_new_lot_id, v_src.strain_id);
      EXCEPTION WHEN undefined_function THEN NULL;
      END;
    END IF;

    BEGIN
      PERFORM public.mp_lot_set_location(v_new_lot_id, v_loc_id);
    EXCEPTION WHEN undefined_function THEN NULL;
    END;
  END LOOP;

  UPDATE public.lots
  SET
    status = 'Consumed',
    notes = CASE
      WHEN NULLIF(btrim(COALESCE(p_notes, '')), '') IS NULL THEN notes
      WHEN NULLIF(btrim(COALESCE(notes, '')), '') IS NULL THEN p_notes
      ELSE notes || E'\n' || p_notes
    END
  WHERE nocopk = p_source_agar_flask_lot_id;

  BEGIN
    v_event_id := public.mp_events_insert_and_link_lot(
      p_source_agar_flask_lot_id,
      'PlatesPoured'::text,
      v_ts,
      COALESCE(p_operator,'system')::text,
      COALESCE(NULLIF(btrim(p_station), ''), 'Pour Plates')::text,
      jsonb_build_object(
        'plate_group_id', v_group_id,
        'plate_count', p_plate_count,
        'recipe_id', v_src.recipe_id,
        'created_plate_ids', to_jsonb(v_created_plate_ids),
        'created_plate_nocopks', to_jsonb(v_created_plate_nocopks),
        'storage_location_id', v_loc_id,
        'notes', p_notes
      )
    );
  EXCEPTION WHEN undefined_function THEN NULL;
  END;

  RETURN p_plate_count;
END;
$$;



-- SPAWN TO BULK: create bulk lots from one or more spawn (grain) lots, link sources->targets, consume sources, events + print jobs
CREATE OR REPLACE FUNCTION public.mp_lots_spawn_to_bulk(
  p_source_spawn_lot_ids bigint[],
  p_bulk_item_id bigint,
  p_recipe_id bigint,
  p_output_count integer,
  p_unit_size numeric,
  p_storage_location_id bigint,
  p_operator text,
  p_station text DEFAULT 'Spawn to Bulk',
  p_timestamp timestamp without time zone DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
  v_ts timestamp without time zone := COALESCE(p_timestamp, now());
  v_loc_id bigint := COALESCE(
    p_storage_location_id,
    (
      SELECT l.nocopk
      FROM public.locations l
      WHERE lower(btrim(l.name)) = lower(btrim('Dark Room'))
      ORDER BY CASE WHEN COALESCE(l.active, false) THEN 0 ELSE 1 END, l.nocopk
      LIMIT 1
    )
  );
  v_new_lot_id bigint;
  v_src_id bigint;
  v_event_id bigint;
  v_counter integer := 0;
  v_primary_src record;
BEGIN
  IF p_source_spawn_lot_ids IS NULL OR array_length(p_source_spawn_lot_ids,1) IS NULL THEN
    RAISE EXCEPTION 'At least one source spawn lot required';
  END IF;
  IF p_bulk_item_id IS NULL THEN RAISE EXCEPTION 'Bulk item required'; END IF;
  IF p_output_count IS NULL OR p_output_count <= 0 THEN RAISE EXCEPTION 'Output count must be > 0'; END IF;

  SELECT * INTO v_primary_src FROM public.lots WHERE nocopk = p_source_spawn_lot_ids[1];
  IF NOT FOUND THEN RAISE EXCEPTION 'Primary source lot not found: %', p_source_spawn_lot_ids[1]; END IF;

  FOR i IN 1..p_output_count LOOP
    INSERT INTO public.lots(
      item_id, recipe_id, strain_id,
      qty, unit_size,
      status, operator, created_at,
      spawned_at,
      label_template,
      notes
    )
    VALUES(
      p_bulk_item_id,
      p_recipe_id,
      v_primary_src.strain_id,
      1,
      p_unit_size,
      'Colonizing',
      p_operator,
      v_ts,
      v_ts,
      'Bulk_Created',
      p_notes
    )
    RETURNING nocopk INTO v_new_lot_id;

    BEGIN
      PERFORM public.mp_lot_set_location(v_new_lot_id, v_loc_id);
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    -- Link each source->new target
    FOREACH v_src_id IN ARRAY p_source_spawn_lot_ids LOOP
      INSERT INTO public._m2m_lots_lots_target_lot_ids(lots_id, lots1_id)
      VALUES (v_src_id, v_new_lot_id)
      ON CONFLICT DO NOTHING;
    END LOOP;

    -- Event for new lot
    BEGIN
      v_event_id := public.mp_events_insert(
        'Spawn to Bulk'::text,
        COALESCE(p_operator,'')::text,
        COALESCE(p_station,'Spawn to Bulk')::text,
        v_ts,
        jsonb_build_object(
          'source_lot_ids', p_source_spawn_lot_ids,
          'notes', p_notes
        )
      );
      BEGIN
        PERFORM public.mp_events_link_lot(v_event_id, v_new_lot_id);
      EXCEPTION WHEN undefined_function THEN NULL;
      END;
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    -- Print job
    BEGIN
      PERFORM public.mp_print_queue_enqueue(
        'lot'::text,
        'Bulk_Created'::text,
        v_new_lot_id,
        NULL::bigint,
        NULL::bigint,
        'Queued'::text
      );
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    v_counter := v_counter + 1;
  END LOOP;

  -- Consume sources
  UPDATE public.lots
    SET status = 'Consumed',
        nc_updated_at = now()
    WHERE nocopk = ANY(p_source_spawn_lot_ids);

  BEGIN
    FOREACH v_src_id IN ARRAY p_source_spawn_lot_ids LOOP
      PERFORM public.mp_lot_set_location_by_name(v_src_id, 'Consumed');
    END LOOP;
  EXCEPTION WHEN undefined_function THEN NULL;
  END;

  RETURN v_counter;
END;
$$;



CREATE OR REPLACE FUNCTION public.mp_products_draw_syringes(
  p_source_lc_flask_lot_id bigint,
  p_syringe_item_id bigint,
  p_syringe_count integer,
  p_ml_each numeric,
  p_storage_location_id bigint,
  p_operator text,
  p_station text DEFAULT 'LC – Make Syringes',
  p_timestamp timestamp without time zone DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
  v_ts timestamp without time zone := COALESCE(p_timestamp, now());
  v_src record;
  v_syringe_item record;
  v_new_product_id bigint;
  v_event_id bigint;
  v_count integer := 0;
  v_created_product_ids bigint[] := ARRAY[]::bigint[];
  v_loc_id bigint := COALESCE(
    p_storage_location_id,
    (
      SELECT l.nocopk
      FROM public.locations l
      WHERE lower(btrim(l.name)) IN ('fridge','refrigerator','refrigerated storage')
         OR lower(l.name) LIKE '%fridge%'
         OR lower(l.name) LIKE '%refrigerat%'
      ORDER BY
        CASE WHEN lower(btrim(l.name)) = 'fridge' THEN 0 ELSE 1 END,
        CASE WHEN COALESCE(l.active, false) THEN 0 ELSE 1 END,
        l.nocopk
      LIMIT 1
    )
  );
  v_total_ml numeric := COALESCE(p_ml_each,0) * COALESCE(p_syringe_count,0);
  v_remaining_ml numeric;
  v_use_by date := (v_ts + interval '3 months')::date;
BEGIN
  IF p_source_lc_flask_lot_id IS NULL THEN
    RAISE EXCEPTION 'Source lc_flask lot is required';
  END IF;
  IF p_syringe_item_id IS NULL THEN
    RAISE EXCEPTION 'Syringe item is required';
  END IF;
  IF p_syringe_count IS NULL OR p_syringe_count <= 0 THEN
    RAISE EXCEPTION 'Syringe count must be > 0';
  END IF;
  IF p_ml_each IS NULL OR p_ml_each <= 0 THEN
    RAISE EXCEPTION 'ml_each must be > 0';
  END IF;

  SELECT * INTO v_src FROM public.lots WHERE nocopk = p_source_lc_flask_lot_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Source lot not found: %', p_source_lc_flask_lot_id;
  END IF;
  IF COALESCE(v_src.item_category_mat,'') <> 'lc_flask' THEN
    RAISE EXCEPTION 'Source lot must be lc_flask (got %)', v_src.item_category_mat;
  END IF;
  IF COALESCE(v_src.remaining_volume_ml, 0) < v_total_ml THEN
    RAISE EXCEPTION 'Not enough LC volume. Need % ml, have % ml.', v_total_ml, COALESCE(v_src.remaining_volume_ml, 0);
  END IF;
  IF v_loc_id IS NULL THEN
    RAISE EXCEPTION 'Refrigerated storage location is required for drawn syringe products.';
  END IF;

  SELECT * INTO v_syringe_item FROM public.items WHERE nocopk = p_syringe_item_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Syringe item not found: %', p_syringe_item_id;
  END IF;

  FOR i IN 1..p_syringe_count LOOP
    INSERT INTO public.products (
      item_id,
      strain_id,
      name_mat,
      item_category_mat,
      origin_lot_ids_json,
      net_volume_ml,
      pack_date,
      use_by,
      notes
    )
    VALUES (
      p_syringe_item_id,
      v_src.strain_id,
      COALESCE(v_syringe_item.name, v_src.item_name_mat, 'LC Syringe'),
      COALESCE(v_syringe_item.category, 'lc_syringe'),
      to_jsonb(ARRAY[COALESCE(NULLIF(btrim(v_src.lot_id),''), p_source_lc_flask_lot_id::text)])::text,
      p_ml_each,
      v_ts::date,
      v_use_by,
      p_notes
    )
    RETURNING nocopk INTO v_new_product_id;

    v_created_product_ids := array_append(v_created_product_ids, v_new_product_id);

    IF EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'products' AND column_name = 'process_type_mat'
    ) THEN
      BEGIN
        UPDATE public.products p
        SET process_type_mat = COALESCE(
          (SELECT l.process_type_mat FROM public.lots l WHERE l.nocopk = p_source_lc_flask_lot_id),
          process_type_mat
        )
        WHERE p.nocopk = v_new_product_id;
      EXCEPTION WHEN undefined_column THEN NULL;
      END;
    END IF;

    PERFORM public.mp_product_set_storage_location(v_new_product_id, v_loc_id);

    BEGIN
      INSERT INTO public._m2m_products_lots_origin_lots(products_id, lots_id)
      VALUES (v_new_product_id, p_source_lc_flask_lot_id)
      ON CONFLICT DO NOTHING;
    EXCEPTION WHEN undefined_table THEN NULL;
    END;

    BEGIN
      INSERT INTO public._m2m_products_items_item_id(products_id, items_id)
      VALUES (v_new_product_id, p_syringe_item_id)
      ON CONFLICT DO NOTHING;
    EXCEPTION WHEN undefined_table THEN NULL;
    END;

    IF v_src.strain_id IS NOT NULL THEN
      BEGIN
        INSERT INTO public._m2m_products_strains_strain_id(products_id, strains_id)
        VALUES (v_new_product_id, v_src.strain_id)
        ON CONFLICT DO NOTHING;
      EXCEPTION WHEN undefined_table THEN NULL;
      END;
    END IF;

    BEGIN
      PERFORM public.mp_print_queue_enqueue(
        'product'::text,
        'Product_Package'::text,
        NULL::bigint,
        v_new_product_id,
        NULL::bigint,
        'Queued'::text
      );
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    v_count := v_count + 1;
  END LOOP;

  UPDATE public.lots
    SET remaining_volume_ml = GREATEST(0, COALESCE(remaining_volume_ml,0) - v_total_ml),
        nc_updated_at = now()
    WHERE nocopk = p_source_lc_flask_lot_id
    RETURNING remaining_volume_ml INTO v_remaining_ml;

  IF COALESCE(v_remaining_ml,0) <= 0 THEN
    UPDATE public.lots
      SET status = 'Consumed',
          nc_updated_at = now()
      WHERE nocopk = p_source_lc_flask_lot_id;
    BEGIN
      PERFORM public.mp_lot_set_location_by_name(p_source_lc_flask_lot_id, 'Consumed');
    EXCEPTION WHEN undefined_function THEN NULL;
    END;
  END IF;

  BEGIN
    v_event_id := public.mp_events_insert(
      p_lot_id => p_source_lc_flask_lot_id,
      p_product_id => NULL::bigint,
      p_type => 'SyringesDrawn'::text,
      p_timestamp => v_ts,
      p_operator => COALESCE(p_operator,'')::text,
      p_station => COALESCE(NULLIF(p_station,''),'LC – Make Syringes')::text,
      p_fields_json => jsonb_build_object(
        'source_lot_id', p_source_lc_flask_lot_id,
        'output_type', 'product',
        'syringe_item_id', p_syringe_item_id,
        'syringe_count', p_syringe_count,
        'ml_each', p_ml_each,
        'used_volume_ml', v_total_ml,
        'remaining_volume_ml', v_remaining_ml,
        'storage_location_id', v_loc_id,
        'created_product_ids', to_jsonb(v_created_product_ids),
        'use_by', v_use_by,
        'notes', p_notes
      )
    );

    BEGIN
      PERFORM public.mp_events_link_lot(v_event_id, p_source_lc_flask_lot_id);
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    BEGIN
      INSERT INTO public._m2m_products_events_events(products_id, events_id)
      SELECT unnest(v_created_product_ids), v_event_id
      ON CONFLICT DO NOTHING;
    EXCEPTION WHEN undefined_table THEN NULL;
    END;
  EXCEPTION WHEN undefined_function THEN NULL;
  END;

  RETURN v_count;
END;
$$;


-- PACKAGE FREEZE DRIED: create packaged products from selected freezer trays,
-- preserve source-product/origin-lot lineage, log one operation event, and queue labels.
DROP FUNCTION IF EXISTS public.mp_products_package_freeze_dried_basic(
  bigint[], bigint, numeric, numeric, bigint, date, text, text, date, text
);

CREATE OR REPLACE FUNCTION public.mp_products_package_freeze_dried_basic(
  p_source_product_ids bigint[],
  p_package_item_id bigint,
  p_package_size_g numeric,
  p_package_count numeric,
  p_storage_location_id bigint,
  p_use_by date,
  p_operator text,
  p_station text DEFAULT 'Products',
  p_pack_date date DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_package_class text DEFAULT 'Retail'
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
  v_pack_date date := COALESCE(p_pack_date, now()::date);
  v_loc_id bigint := COALESCE(
    p_storage_location_id,
    (
      SELECT l.nocopk
      FROM public.locations l
      WHERE lower(btrim(l.name)) = lower(btrim('Products Storage'))
      ORDER BY CASE WHEN COALESCE(l.active, false) THEN 0 ELSE 1 END, l.nocopk
      LIMIT 1
    )
  );
  v_consumed_location_id bigint;
  v_src_id bigint;
  v_created_product_id bigint;
  v_first_created_product_id bigint;
  v_event_id bigint;
  v_counter integer := 0;
  v_requested_count integer;
  v_selected_source_count integer;
  v_invalid_source_count integer;
  v_inactive_source_count integer;
  v_total_source_weight_g numeric;
  v_required_weight_g numeric;
  v_normalized_package_size_g numeric;
  v_package_size text;
  v_package_class text;
  v_label_type text;
  v_package_item_category text;
  v_package_item_name text;
  v_package_item_business_id text;
  v_source_product_business_ids text[];
  v_created_product_ids bigint[] := ARRAY[]::bigint[];
  v_created_product_business_ids text[];
  v_origin_lot_ids bigint[];
  v_origin_lot_id bigint;
  v_origin_lot_ids_json text;
  v_origin_lot_business_ids text[];
  v_strain_id bigint;
  v_strain_count integer;
  v_use_by date;
BEGIN
  IF p_source_product_ids IS NULL OR array_length(p_source_product_ids,1) IS NULL THEN
    RAISE EXCEPTION 'At least one source product required';
  END IF;
  IF p_package_item_id IS NULL THEN
    RAISE EXCEPTION 'Package item required';
  END IF;
  IF p_package_size_g IS NULL OR p_package_size_g <= 0 THEN
    RAISE EXCEPTION 'Package size must be greater than zero';
  END IF;
  IF p_package_count IS NULL OR p_package_count <= 0 THEN
    RAISE EXCEPTION 'Package count must be greater than zero';
  END IF;
  IF v_loc_id IS NULL THEN
    RAISE EXCEPTION 'Storage location is required';
  END IF;

  SELECT l.nocopk
  INTO v_consumed_location_id
  FROM public.locations l
  WHERE lower(btrim(l.name)) = 'consumed'
  ORDER BY CASE WHEN COALESCE(l.active, false) THEN 0 ELSE 1 END, l.nocopk
  LIMIT 1;

  IF v_consumed_location_id IS NULL THEN
    RAISE EXCEPTION 'Consumed location is required to retire source freezer trays';
  END IF;

  v_requested_count := p_package_count::integer;
  IF v_requested_count::numeric <> p_package_count THEN
    RAISE EXCEPTION 'Package count must be a whole number';
  END IF;

  v_package_class := CASE lower(btrim(COALESCE(p_package_class, 'Retail')))
    WHEN 'retail' THEN 'Retail'
    WHEN 'sample' THEN 'Sample'
    ELSE NULL
  END;
  IF v_package_class IS NULL THEN
    RAISE EXCEPTION 'Package class must be Retail or Sample';
  END IF;

  v_label_type := CASE v_package_class
    WHEN 'Sample' THEN 'Product_Package_Sample'
    ELSE 'Product_Package'
  END;

  -- Normalize the supported schema choices. The base products table stores the
  -- human-readable selector value; vc_products derives package_size_g from it.
  IF abs(p_package_size_g - 1) <= 0.01 THEN
    v_normalized_package_size_g := 1;
    v_package_size := '1 g';
  ELSIF abs(p_package_size_g - 5) <= 0.01 THEN
    v_normalized_package_size_g := 5;
    v_package_size := '5 g';
  ELSIF abs(p_package_size_g - 10) <= 0.01 THEN
    v_normalized_package_size_g := 10;
    v_package_size := '10 g';
  ELSIF abs(p_package_size_g - 28.349523125) <= 0.02 THEN
    v_normalized_package_size_g := 28.349523125;
    v_package_size := '1 oz';
  ELSE
    RAISE EXCEPTION 'Unsupported package size: % g. Use 1 g, 5 g, 10 g, or 1 oz (28.35 g).', p_package_size_g;
  END IF;

  SELECT i.category, i.name, i.item_id
  INTO v_package_item_category, v_package_item_name, v_package_item_business_id
  FROM public.items i
  WHERE i.nocopk = p_package_item_id
    AND COALESCE(i.active, true);

  IF v_package_item_category IS NULL THEN
    RAISE EXCEPTION 'Active package item not found: %', p_package_item_id;
  END IF;

  IF lower(COALESCE(v_package_item_category, '')) NOT IN (
    'freezedriedmushrooms',
    'freeze_dried',
    'freeze_dried_packaged'
  ) THEN
    RAISE EXCEPTION 'Selected package item is not a freeze-dried product item: %', v_package_item_business_id;
  END IF;

  -- Lock source trays so two packaging operations cannot consume the same
  -- freezer-tray inventory concurrently.
  PERFORM 1
  FROM public.products p
  WHERE p.nocopk = ANY(p_source_product_ids)
  FOR UPDATE;

  SELECT
    count(*),
    count(*) FILTER (WHERE lower(COALESCE(p.item_category_mat, '')) <> 'freezer_tray'),
    count(*) FILTER (
      WHERE COALESCE(p.net_weight_g, 0) <= 0
         OR regexp_replace(
              lower(COALESCE(p.tray_state::text, '')),
              '[^a-z0-9]',
              '',
              'g'
            ) IN (
              'emptytray',
              'consumed',
              'compost',
              'composted',
              'spoiled',
              'retired',
              'expired',
              'shipped'
            )
    ),
    COALESCE(sum(p.net_weight_g), 0),
    COALESCE(array_agg(p.product_id ORDER BY p.nocopk), ARRAY[]::text[])
  INTO
    v_selected_source_count,
    v_invalid_source_count,
    v_inactive_source_count,
    v_total_source_weight_g,
    v_source_product_business_ids
  FROM public.products p
  WHERE p.nocopk = ANY(p_source_product_ids);

  IF v_selected_source_count <> array_length(p_source_product_ids, 1) THEN
    RAISE EXCEPTION 'One or more selected source products are missing or duplicated';
  END IF;
  IF v_invalid_source_count > 0 THEN
    RAISE EXCEPTION 'Package Freeze Dried accepts freezer tray products only';
  END IF;
  IF v_inactive_source_count > 0 THEN
    RAISE EXCEPTION 'Package Freeze Dried accepts active freezer trays with positive remaining weight only';
  END IF;

  v_required_weight_g := v_normalized_package_size_g * v_requested_count;
  IF v_total_source_weight_g < v_required_weight_g THEN
    RAISE EXCEPTION 'Selected source products have % g available, but % g is required for % package(s) of %.',
      v_total_source_weight_g, v_required_weight_g, v_requested_count, v_package_size;
  END IF;


  SELECT COALESCE(array_agg(DISTINCT lot_id ORDER BY lot_id), ARRAY[]::bigint[])
  INTO v_origin_lot_ids
  FROM (
    SELECT m.lots_id AS lot_id
    FROM public._m2m_products_lots_origin_lots m
    WHERE m.products_id = ANY(p_source_product_ids)
    UNION
    SELECT l.nocopk AS lot_id
    FROM public.products p
    JOIN LATERAL jsonb_array_elements_text(
      CASE
        WHEN COALESCE(NULLIF(p.origin_lot_ids_json, ''), '[]') ~ '^[[:space:]]*\['
          THEN COALESCE(NULLIF(p.origin_lot_ids_json, ''), '[]')::jsonb
        ELSE '[]'::jsonb
      END
    ) AS origin_lot_id_text(value) ON true
    JOIN public.lots l
      ON l.lot_id = origin_lot_id_text.value
      OR l.airtable_id = origin_lot_id_text.value
      OR l.nocopk::text = origin_lot_id_text.value
    WHERE p.nocopk = ANY(p_source_product_ids)
  ) origin_lots
  WHERE lot_id IS NOT NULL;

  SELECT count(DISTINCT source_strain_id), min(source_strain_id)
  INTO v_strain_count, v_strain_id
  FROM (
    SELECT p.strain_id AS source_strain_id
    FROM public.products p
    WHERE p.nocopk = ANY(p_source_product_ids)
      AND p.strain_id IS NOT NULL
    UNION
    SELECT l.strain_id AS source_strain_id
    FROM public.lots l
    WHERE l.nocopk = ANY(v_origin_lot_ids)
      AND l.strain_id IS NOT NULL
  ) source_strains;

  IF COALESCE(v_strain_count, 0) > 1 THEN
    RAISE EXCEPTION 'Selected source products contain multiple strains; package one strain at a time.';
  END IF;

  SELECT
    COALESCE(jsonb_agg(COALESCE(NULLIF(btrim(l.lot_id), ''), l.nocopk::text) ORDER BY l.nocopk), '[]'::jsonb)::text,
    COALESCE(array_agg(COALESCE(NULLIF(btrim(l.lot_id), ''), l.nocopk::text) ORDER BY l.nocopk), ARRAY[]::text[])
  INTO v_origin_lot_ids_json, v_origin_lot_business_ids
  FROM public.lots l
  WHERE l.nocopk = ANY(v_origin_lot_ids);

  v_use_by := COALESCE(p_use_by, (v_pack_date + interval '2 years')::date);

  -- Create one product per physical package and retain the canonical item while
  -- storing package size and class explicitly on each product.
  FOR v_counter IN 1..v_requested_count LOOP
    INSERT INTO public.products(
      item_id,
      name_mat,
      item_category_mat,
      net_weight_g,
      net_weight_oz,
      net_volume_ml,
      pack_date,
      use_by,
      package_class,
      package_item_id,
      package_size,
      package_count,
      storage_location_id,
      origin_lot_ids_json,
      strain_id,
      notes
    )
    VALUES(
      p_package_item_id,
      v_package_item_name,
      COALESCE(NULLIF(v_package_item_category, ''), 'freezedriedmushrooms'),
      v_normalized_package_size_g,
      v_normalized_package_size_g / 28.349523125,
      NULL,
      v_pack_date,
      v_use_by,
      v_package_class,
      p_package_item_id,
      v_package_size,
      1,
      v_loc_id,
      COALESCE(v_origin_lot_ids_json, '[]'),
      v_strain_id,
      NULLIF(p_notes, '')
    )
    RETURNING nocopk INTO v_created_product_id;

    v_created_product_ids := array_append(v_created_product_ids, v_created_product_id);
    v_first_created_product_id := COALESCE(v_first_created_product_id, v_created_product_id);

    -- Materialize products.process_type_mat if the column exists. For merged
    -- source trays, retain the single shared source process type when present.
    IF EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'products'
        AND column_name = 'process_type_mat'
    ) THEN
      BEGIN
        UPDATE public.products p
        SET process_type_mat = (
          SELECT CASE WHEN count(DISTINCT NULLIF(psrc.process_type_mat, '')) = 1
                 THEN min(NULLIF(psrc.process_type_mat, ''))
                 ELSE NULL
                 END
          FROM public.products psrc
          WHERE psrc.nocopk = ANY(p_source_product_ids)
        )
        WHERE p.nocopk = v_created_product_id;
      EXCEPTION WHEN undefined_column THEN NULL;
      END;
    END IF;

    FOREACH v_src_id IN ARRAY p_source_product_ids LOOP
      INSERT INTO public._m2m_products_products_merge_tray_products(products_id, products1_id)
      VALUES (v_created_product_id, v_src_id)
      ON CONFLICT DO NOTHING;
    END LOOP;

    FOREACH v_origin_lot_id IN ARRAY v_origin_lot_ids LOOP
      INSERT INTO public._m2m_products_lots_origin_lots(products_id, lots_id)
      VALUES (v_created_product_id, v_origin_lot_id)
      ON CONFLICT DO NOTHING;
    END LOOP;

    IF v_strain_id IS NOT NULL THEN
      BEGIN
        INSERT INTO public._m2m_products_strains_strain_id(products_id, strains_id)
        VALUES (v_created_product_id, v_strain_id)
        ON CONFLICT DO NOTHING;
      EXCEPTION WHEN undefined_table THEN NULL;
      END;
    END IF;

    PERFORM public.mp_product_set_storage_location(v_created_product_id, v_loc_id);

    PERFORM public.mp_print_queue_enqueue(
      'product'::text,
      v_label_type,
      NULL::bigint,
      v_created_product_id,
      NULL::bigint,
      'Queued'::text
    );
  END LOOP;

  SELECT COALESCE(array_agg(p.product_id ORDER BY p.nocopk), ARRAY[]::text[])
  INTO v_created_product_business_ids
  FROM public.products p
  WHERE p.nocopk = ANY(v_created_product_ids);

  -- One event represents the packaging operation and links all inputs, outputs,
  -- and inherited origin lots.
  v_event_id := public.mp_events_insert(
    p_lot_id => NULL::bigint,
    p_product_id => v_first_created_product_id,
    p_type => 'Package Freeze Dried'::text,
    p_timestamp => v_pack_date::timestamp,
    p_operator => COALESCE(p_operator, '')::text,
    p_station => COALESCE(p_station, 'Products')::text,
    p_fields_json => jsonb_build_object(
      'source_product_ids', p_source_product_ids,
      'source_product_business_ids', v_source_product_business_ids,
      'created_product_ids', v_created_product_ids,
      'created_product_business_ids', v_created_product_business_ids,
      'origin_lot_ids', COALESCE(v_origin_lot_ids, ARRAY[]::bigint[]),
      'origin_lot_business_ids', COALESCE(v_origin_lot_business_ids, ARRAY[]::text[]),
      'strain_id', v_strain_id,
      'package_item_id', p_package_item_id,
      'package_item_business_id', v_package_item_business_id,
      'package_class', v_package_class,
      'label_type', v_label_type,
      'package_size', v_package_size,
      'package_size_g', v_normalized_package_size_g,
      'package_count', v_requested_count,
      'total_packaged_weight_g', v_required_weight_g,
      'selected_source_weight_g', v_total_source_weight_g,
      'unpackaged_source_weight_g', greatest(v_total_source_weight_g - v_required_weight_g, 0),
      'source_tray_state_after', 'empty_tray',
      'source_storage_location_id_after', v_consumed_location_id,
      'source_storage_location_after', 'Consumed',
      'source_net_weight_g_after', 0,
      'pack_date', v_pack_date,
      'use_by', v_use_by,
      'notes', p_notes
    )
  );

  FOREACH v_created_product_id IN ARRAY v_created_product_ids LOOP
    PERFORM public.mp_events_link_product(v_event_id, v_created_product_id);
  END LOOP;
  FOREACH v_src_id IN ARRAY p_source_product_ids LOOP
    PERFORM public.mp_events_link_product(v_event_id, v_src_id);
  END LOOP;
  FOREACH v_origin_lot_id IN ARRAY v_origin_lot_ids LOOP
    PERFORM public.mp_events_link_lot(v_event_id, v_origin_lot_id);
  END LOOP;

  -- Match the Airtable production workflow: every selected freezer tray is
  -- fully retired after the packaging operation. Any difference between the
  -- selected tray weight and packaged weight remains visible in event audit
  -- data as unpackaged_source_weight_g.
  UPDATE public.products p
  SET net_weight_g = 0,
      net_weight_oz = 0,
      tray_state = 'empty_tray',
      storage_location_id = v_consumed_location_id,
      nc_updated_at = now()
  WHERE p.nocopk = ANY(p_source_product_ids);

  FOREACH v_src_id IN ARRAY p_source_product_ids LOOP
    PERFORM public.mp_product_set_storage_location(v_src_id, v_consumed_location_id);
  END LOOP;

  RETURN v_requested_count;
END;
$$;

-- PRODUCT TRAY LIFECYCLE: move freezer tray products to a Freeze Dryer location and log the transition
CREATE OR REPLACE FUNCTION public.mp_products_move_to_freeze_dryer(
  p_product_ids bigint[],
  p_freeze_dryer_location_id bigint,
  p_operator text DEFAULT NULL,
  p_station text DEFAULT 'Products',
  p_notes text DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
  v_product_id bigint;
  v_event_id bigint;
  v_count integer := 0;
  v_bad_count integer;
  v_prev_tray_state text;
  v_prev_location_id bigint;
  v_prev_location_name text;
  v_new_location_name text;
BEGIN
  IF p_product_ids IS NULL OR array_length(p_product_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'At least one freezer tray product is required';
  END IF;

  IF p_freeze_dryer_location_id IS NULL THEN
    RAISE EXCEPTION 'Freeze Dryer location is required';
  END IF;

  SELECT count(*) INTO v_bad_count
  FROM public.products p
  WHERE p.nocopk = ANY(p_product_ids)
    AND COALESCE(p.item_category_mat, '') <> 'freezer_tray';

  IF COALESCE(v_bad_count, 0) > 0 THEN
    RAISE EXCEPTION 'Only freezer_tray products may be moved to the Freeze Dryer';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.locations l
    WHERE l.nocopk = p_freeze_dryer_location_id
      AND lower(COALESCE(l.name, '')) LIKE '%freeze dryer%'
  ) THEN
    RAISE EXCEPTION 'Selected location is not a Freeze Dryer location';
  END IF;

  SELECT l.name INTO v_new_location_name
  FROM public.locations l
  WHERE l.nocopk = p_freeze_dryer_location_id;

  FOREACH v_product_id IN ARRAY p_product_ids LOOP
    SELECT p.tray_state, p.storage_location_id, l.name
    INTO v_prev_tray_state, v_prev_location_id, v_prev_location_name
    FROM public.products p
    LEFT JOIN public.locations l ON l.nocopk = p.storage_location_id
    WHERE p.nocopk = v_product_id;

    UPDATE public.products
    SET storage_location_id = p_freeze_dryer_location_id,
        tray_state = 'freeze_drying',
        nc_updated_at = now(),
        notes = CASE
          WHEN COALESCE(p_notes, '') = '' THEN notes
          WHEN COALESCE(notes, '') = '' THEN p_notes
          ELSE notes || E'\n' || p_notes
        END
    WHERE nocopk = v_product_id
      AND COALESCE(item_category_mat, '') = 'freezer_tray';

    IF FOUND THEN
      BEGIN
        PERFORM public.mp_product_set_storage_location(v_product_id, p_freeze_dryer_location_id);
      EXCEPTION WHEN undefined_function THEN NULL;
      END;

      -- Product lifecycle events are required audit records. Use an explicit
      -- timestamp-without-time-zone value so function resolution cannot fail,
      -- and do not suppress event or relationship failures after the product
      -- mutation has succeeded.
      v_event_id := public.mp_events_insert(
        p_lot_id => NULL::bigint,
        p_product_id => v_product_id,
        p_type => 'MovedToFreezeDryer'::text,
        p_timestamp => clock_timestamp()::timestamp without time zone,
        p_operator => COALESCE(p_operator, '')::text,
        p_station => COALESCE(p_station, 'Products')::text,
        p_fields_json => jsonb_build_object(
          'action', 'Move to Freeze Dryer',
          'workflow', 'mp_products_move_to_freeze_dryer',
          'product_id', v_product_id,
          'previous_tray_state', v_prev_tray_state,
          'new_tray_state', 'freeze_drying',
          'previous_storage_location_id', v_prev_location_id,
          'previous_storage_location', v_prev_location_name,
          'new_storage_location_id', p_freeze_dryer_location_id,
          'new_storage_location', v_new_location_name,
          'operator', p_operator,
          'notes', p_notes
        )
      );

      PERFORM public.mp_events_link_product(v_event_id, v_product_id);

      v_count := v_count + 1;
    END IF;
  END LOOP;

  RETURN v_count;
END;
$$;


-- PRODUCT TRAY LIFECYCLE: retire/spoil/compost active tray products and log the transition
CREATE OR REPLACE FUNCTION public.mp_products_retire_trays(
  p_product_ids bigint[],
  p_reason text,
  p_operator text DEFAULT NULL,
  p_station text DEFAULT 'Products',
  p_notes text DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
  v_product_id bigint;
  v_event_id bigint;
  v_count integer := 0;
  v_state text;
  v_event_type text;
  v_target_location_name text;
  v_target_location_id bigint;
  v_prev_tray_state text;
  v_prev_location_id bigint;
  v_prev_location_name text;
  v_target_location_resolved_name text;
  v_bad_count integer;
BEGIN
  IF p_product_ids IS NULL OR array_length(p_product_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'At least one tray product is required';
  END IF;

  v_state := lower(btrim(COALESCE(p_reason, '')));
  IF v_state NOT IN ('retired', 'spoiled', 'compost') THEN
    RAISE EXCEPTION 'Reason must be retired, spoiled, or compost';
  END IF;

  SELECT count(*) INTO v_bad_count
  FROM public.products p
  WHERE p.nocopk = ANY(p_product_ids)
    AND COALESCE(p.item_category_mat, '') NOT IN ('fresh_tray', 'freezer_tray');

  IF COALESCE(v_bad_count, 0) > 0 THEN
    RAISE EXCEPTION 'Only fresh_tray and freezer_tray products may be retired by this action';
  END IF;

  v_target_location_name := CASE
    WHEN v_state = 'compost' THEN 'Compost'
    WHEN v_state = 'spoiled' THEN 'Expired'
    ELSE 'Retired'
  END;

  IF v_state = 'retired' THEN
    -- Airtable currently has no dedicated Retired product location. Prefer one
    -- if it is added later; otherwise use the existing Consumed terminal
    -- location while retaining tray_state = retired and ProductRetired audit
    -- semantics.
    SELECT l.nocopk, l.name
    INTO v_target_location_id, v_target_location_resolved_name
    FROM public.locations l
    WHERE lower(btrim(l.name)) IN ('retired', 'consumed')
    ORDER BY
      CASE WHEN COALESCE(l.active, false) THEN 0 ELSE 1 END,
      CASE lower(btrim(l.name)) WHEN 'retired' THEN 0 ELSE 1 END,
      l.nocopk
    LIMIT 1;
  ELSE
    SELECT l.nocopk, l.name
    INTO v_target_location_id, v_target_location_resolved_name
    FROM public.locations l
    WHERE lower(btrim(l.name)) = lower(btrim(v_target_location_name))
    ORDER BY CASE WHEN COALESCE(l.active, false) THEN 0 ELSE 1 END, l.nocopk
    LIMIT 1;
  END IF;

  IF v_target_location_id IS NULL THEN
    RAISE EXCEPTION 'Target location not found: %',
      CASE WHEN v_state = 'retired' THEN 'Retired or Consumed' ELSE v_target_location_name END;
  END IF;

  v_event_type := CASE
    WHEN v_state = 'compost' THEN 'ProductComposted'
    WHEN v_state = 'spoiled' THEN 'ProductSpoiled'
    ELSE 'ProductRetired'
  END;

  FOREACH v_product_id IN ARRAY p_product_ids LOOP
    SELECT p.tray_state, p.storage_location_id, l.name
    INTO v_prev_tray_state, v_prev_location_id, v_prev_location_name
    FROM public.products p
    LEFT JOIN public.locations l ON l.nocopk = p.storage_location_id
    WHERE p.nocopk = v_product_id;

    UPDATE public.products
    SET tray_state = v_state,
        storage_location_id = COALESCE(v_target_location_id, storage_location_id),
        nc_updated_at = now(),
        notes = CASE
          WHEN COALESCE(p_notes, '') = '' THEN notes
          WHEN COALESCE(notes, '') = '' THEN p_notes
          ELSE notes || E'\n' || p_notes
        END
    WHERE nocopk = v_product_id
      AND COALESCE(item_category_mat, '') IN ('fresh_tray', 'freezer_tray');

    IF FOUND THEN
      IF v_target_location_id IS NOT NULL THEN
        BEGIN
          PERFORM public.mp_product_set_storage_location(v_product_id, v_target_location_id);
        EXCEPTION WHEN undefined_function THEN NULL;
        END;
      END IF;

      -- Product lifecycle events are required audit records. Use an explicit
      -- timestamp-without-time-zone value so function resolution cannot fail,
      -- and do not suppress event or relationship failures after the product
      -- mutation has succeeded.
      v_event_id := public.mp_events_insert(
        p_lot_id => NULL::bigint,
        p_product_id => v_product_id,
        p_type => v_event_type,
        p_timestamp => clock_timestamp()::timestamp without time zone,
        p_operator => COALESCE(p_operator, '')::text,
        p_station => COALESCE(p_station, 'Products')::text,
        p_fields_json => jsonb_build_object(
          'action', 'Retire Tray Product',
          'workflow', 'mp_products_retire_trays',
          'product_id', v_product_id,
          'reason', v_state,
          'previous_tray_state', v_prev_tray_state,
          'new_tray_state', v_state,
          'previous_storage_location_id', v_prev_location_id,
          'previous_storage_location', v_prev_location_name,
          'new_storage_location_id', v_target_location_id,
          'new_storage_location', v_target_location_resolved_name,
          'operator', p_operator,
          'notes', p_notes
        )
      );

      PERFORM public.mp_events_link_product(v_event_id, v_product_id);

      v_count := v_count + 1;
    END IF;
  END LOOP;

  RETURN v_count;
END;
$$;
