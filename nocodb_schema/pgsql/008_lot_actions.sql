/*
  008_lot_actions.sql

  Restores mp_lots_shake, and updates shake/retire to:
    - use the canonical events insert function (mp_events_insert or mp_events_insert_and_link_lot)
    - link created events to lots via mp_events_link_lot (defined elsewhere; if missing, it won't fail)

  Schema assumptions:
    - public.lots has: nocopk (PK), lot_id, status, location_id (FK 1:1), notes, inoculated_at, item_name_mat, strain_species_strain_mat
    - public.locations has: nocopk (PK), name
    - public.events table exists
*/

-- 1) SHAKE: logs a Shake event for each lot, clears ui_error fields (if present), optional note append
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

  SELECT l.name INTO v_location_name
  FROM public.locations l
  WHERE l.nocopk = p_location_id;

  IF p_location_id IS NULL OR v_location_name IS NULL THEN
    RAISE EXCEPTION 'Location not found for nocopk: %', p_location_id;
  END IF;

  FOREACH v_lot_id IN ARRAY p_lot_ids LOOP
    v_fields := jsonb_build_object(
      'action', 'Shake',
      'note', p_note
    );

    -- Insert + link
    BEGIN
      v_event_id := public.mp_events_insert_and_link_lot(
	v_lot_id::bigint,
	'Shake'::text, 
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

-- 2) RETIRE: supports multiple reasons; logs one event per reason per lot.
--    Terminal status/location rules:
--      - if reasons include Compost/Composted OR Contaminated -> status Composted, location Compost
--      - if reasons include Expired -> status Expired, location Expired
--      - else -> status Retired, location unchanged
--    Also sets retired_at and appends note.
CREATE OR REPLACE FUNCTION public.mp_lots_retire(
  p_lot_ids   bigint[],
  p_reasons   text[],
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
  v_reason text;
  v_event_id bigint;
  v_fields jsonb;
  v_reasons_lower text[];
  v_terminal_status text;
  v_terminal_location text;
  v_counter integer := 0;
BEGIN
  IF p_lot_ids IS NULL OR array_length(p_lot_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;

  v_reasons_lower := ARRAY(
    SELECT lower(btrim(x))
    FROM unnest(COALESCE(p_reasons, ARRAY[]::text[])) AS x
    WHERE x IS NOT NULL AND btrim(x) <> ''
  );

  -- Decide terminal status + optional terminal location
  IF 'expired' = ANY(v_reasons_lower) THEN
    v_terminal_status := 'Expired';
    v_terminal_location := 'Expired';
  ELSIF ('compost' = ANY(v_reasons_lower)) OR ('composted' = ANY(v_reasons_lower)) OR ('contaminated' = ANY(v_reasons_lower)) OR ('inviable' = ANY(v_reasons_lower)) THEN
    v_terminal_status := 'Composted';
    v_terminal_location := 'Compost';
  ELSE
    v_terminal_status := 'Retired';
    v_terminal_location := NULL;
  END IF;

  FOREACH v_lot_id IN ARRAY p_lot_ids LOOP

    -- log one event per reason
    FOREACH v_reason IN ARRAY COALESCE(p_reasons, ARRAY[]::text[]) LOOP
      IF v_reason IS NULL OR btrim(v_reason) = '' THEN
        CONTINUE;
      END IF;

      v_fields := jsonb_build_object(
        'reason', v_reason,
        'reasons', COALESCE(p_reasons, ARRAY[]::text[]),
        'terminal_status', v_terminal_status,
        'terminal_location', v_terminal_location,
        'note', p_note
      );

      BEGIN
        v_event_id := public.mp_events_insert_and_link_lot(
		v_lot_id::bigint,
		v_reason::text, 
		COALESCE(p_timestamp, now())::timestamp, 
		p_operator::text, 
		p_station::text, 
		v_fields::jsonb
	);
      EXCEPTION WHEN undefined_function THEN
	NULL;
      END;

    END LOOP;

    -- terminal updates
    UPDATE public.lots
    SET status = v_terminal_status,
        retired_at = COALESCE(p_timestamp, now())
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

-- 3) MOVE: updates location_id by name and performs special transitions for Fridge and Fruiting.
--    Special rules (minimal implementation matching Airtable Dark Room Actions intent):
--      - If moving to Fridge:
--          * ensure status is FullyColonized (insert event FullyColonized if it wasn't already)
--          * then set status to Fridge or ColdShock (based on p_fridge_mode)
--          * insert an event for the move/transition
--      - If moving to Fruiting:
--          * set status to Fruiting
--          * insert an event for the move/transition
CREATE OR REPLACE FUNCTION public.mp_lots_move(
  p_lot_ids   bigint[],
  p_location_id bigint,
  p_fridge_mode text DEFAULT 'Fridge',
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
  v_event_id bigint;
  v_fields jsonb;
  v_counter integer := 0;
  v_old_status text;
  v_new_status text;
  v_location_name text;
BEGIN
  IF p_lot_ids IS NULL OR array_length(p_lot_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;

  SELECT l.name INTO v_location_name
  FROM public.locations l
  WHERE l.nocopk = p_location_id;

  IF p_location_id IS NULL OR v_location_name IS NULL THEN
    RAISE EXCEPTION 'Location not found for nocopk: %', p_location_id;
  END IF;

  FOREACH v_lot_id IN ARRAY p_lot_ids LOOP
    SELECT status INTO v_old_status FROM public.lots WHERE nocopk = v_lot_id;

    -- Update location
    PERFORM public.mp_lot_set_location(v_lot_id, p_location_id);

    v_new_status := NULL;

    IF v_location_name ILIKE '%Fridge%' OR v_location_name ILIKE '%Refrigerator%' THEN
      -- Ensure FullyColonized first
      IF COALESCE(v_old_status,'') NOT IN ('FullyColonized','Fridge','ColdShock') THEN
        UPDATE public.lots SET status = 'FullyColonized' WHERE nocopk = v_lot_id;
        v_fields := jsonb_build_object('action','FullyColonized','from_status',v_old_status,'to_status','FullyColonized','note',p_note);
        BEGIN
          v_event_id := public.mp_events_insert_and_link_lot(
            v_lot_id::bigint, 
            'FullyColonized'::text, 
            COALESCE(p_timestamp, now())::timestamp, 
            p_operator::text, 
            p_station::text, 
            v_fields::jsonb
          );
        EXCEPTION WHEN undefined_function THEN NULL;
        END;
      END IF;

      v_new_status := CASE WHEN COALESCE(p_fridge_mode,'') = 'ColdShock' THEN 'ColdShock' ELSE 'Fridge' END;
      UPDATE public.lots SET status = v_new_status WHERE nocopk = v_lot_id;

      v_fields := jsonb_build_object('action','Move','to_location',v_location_name,'to_location_id',p_location_id,'to_status',v_new_status,'note',p_note);
      BEGIN
        v_event_id := public.mp_events_insert_and_link_lot(
          v_lot_id::bigint, 
          v_new_status::text, 
          COALESCE(p_timestamp, now())::timestamp, 
          p_operator::text, 
          p_station::text, 
          v_fields::jsonb
        );
      EXCEPTION WHEN undefined_function THEN NULL;
      END;

    ELSIF v_location_name ILIKE '%Fruiting%' THEN
      v_new_status := 'Fruiting';
      UPDATE public.lots SET status = v_new_status WHERE nocopk = v_lot_id;

      v_fields := jsonb_build_object('action','Move','to_location',v_location_name,'to_location_id',p_location_id,'to_status',v_new_status,'note',p_note);
      BEGIN
        v_event_id := public.mp_events_insert_and_link_lot(
          v_lot_id::bigint, 
          'Fruiting'::text, 
          COALESCE(p_timestamp, now())::timestamp, 
          p_operator::text, 
          p_station::text, 
          v_fields::jsonb
        );
      EXCEPTION WHEN undefined_function THEN NULL;
      END;
    ELSE
      v_fields := jsonb_build_object('action','Move','to_location',v_location_name,'to_location_id',p_location_id,'note',p_note);
      BEGIN
        v_event_id := public.mp_events_insert_and_link_lot(
          v_lot_id::bigint, 
          'Move'::text, 
          COALESCE(p_timestamp, now())::timestamp, 
          p_operator::text, 
          p_station::text, 
          v_fields::jsonb
        );
      EXCEPTION WHEN undefined_function THEN NULL;
      END;
    END IF;

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

-- 4) MODIFY: creates a modification event for each lot (does not change status by default)
CREATE OR REPLACE FUNCTION public.mp_lots_modify(
  p_lot_ids   bigint[],
  p_actions   text[],
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
  v_action text;
  v_fields jsonb;
  v_counter integer := 0;
BEGIN
  IF p_lot_ids IS NULL OR array_length(p_lot_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;

  SELECT l.name INTO v_location_name
  FROM public.locations l
  WHERE l.nocopk = p_location_id;

  IF p_location_id IS NULL OR v_location_name IS NULL THEN
    RAISE EXCEPTION 'Location not found for nocopk: %', p_location_id;
  END IF;

  FOREACH v_lot_id IN ARRAY p_lot_ids LOOP
    
    -- log one event per reason
    FOREACH v_action IN ARRAY COALESCE(p_actions, ARRAY[]::text[]) LOOP
      IF v_action IS NULL OR btrim(v_action) = '' THEN
        CONTINUE;
      END IF;

      v_fields := jsonb_build_object('action', v_action, 'note', p_note);

      BEGIN
        v_event_id := public.mp_events_insert_and_link_lot(
          v_lot_id::bigint, 
          COALESCE(NULLIF(btrim(v_action),''), 'Modify')::text, 
          COALESCE(p_timestamp, now())::timestamp, 
          p_operator::text, 
          p_station::text, 
          v_fields::jsonb
        );
      EXCEPTION WHEN undefined_function THEN NULL;
      END;

      IF v_action = 'ApplyCasing' THEN
        UPDATE public.lots
        SET 
          casing_applied_at = now()::date,
	  casing_notes = CASE
	    WHEN casing_notes IS NULL OR notes = '' THEN p_note
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
    v_source_item_category,
    v_source_item_name
  FROM public.lots l
  LEFT JOIN public.items i ON i.nocopk = l.item_id
  WHERE l.nocopk = p_source_lot_id;

  IF v_source_item_id IS NULL THEN
    UPDATE public.lots
      SET ui_error = 'Inoculate validation: Source lot must be linked to an item.',
          ui_error_at = now()
    WHERE nocopk = p_source_lot_id;
    RETURN 0;
  END IF;

  v_source_item_category := lower(COALESCE(v_source_item_category, ''));
  v_is_liquid_source := v_source_item_category IN ('lc_syringe','lc_flask');
  v_is_solid_source := v_source_item_category IN ('plate','grain');
  v_is_untracked_source := v_source_item_category = 'untracked_source';

  IF NOT (v_is_liquid_source OR v_is_solid_source OR v_is_untracked_source) THEN
    UPDATE public.lots
      SET ui_error = format('Inoculate validation: Source must be lc_syringe, lc_flask, plate, grain, or untracked_source (got "%s").', v_source_item_category),
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

  -- Clear any prior errors
  UPDATE public.lots SET ui_error = NULL, ui_error_at = NULL WHERE nocopk = p_source_lot_id;

  -- Apply inoculation to each target
  FOREACH v_target_id IN ARRAY p_target_lot_ids LOOP
    -- load target + item
    SELECT
      l.item_id,
      l.unit_size,
      l.total_volume_ml,
      l.remaining_volume_ml,
      i.category,
      i.name
    INTO
      v_target_item_id,
      v_target_unit_size,
      v_target_total_ml,
      v_target_remaining_ml,
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

    IF v_target_item_category NOT IN ('grain','lc_flask','plate') THEN
      UPDATE public.lots
        SET ui_error = format('Inoculate validation: Target lot %s must be grain, lc_flask, or plate (got "%s").', v_target_id, v_target_item_category),
            ui_error_at = now()
      WHERE nocopk = p_source_lot_id;
      CONTINUE;
    END IF;
    
    v_label_type := CASE 
        WHEN v_target_item_category IS NOT NULL AND btrim(v_target_item_category) = 'grain' THEN 'Grain_Inoculated'
        WHEN v_target_item_category IS NOT NULL AND btrim(v_target_item_category) = 'plate' THEN 'Plate_Inoculated'
        ELSE 'LC_Flask_Inoculated'
    END;
    
    -- 1. Determine base volume based on target type
    IF v_target_item_category = 'lc_flask' THEN
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
      notes = CASE WHEN v_is_untracked_source THEN v_source_notes ELSE notes END,
      use_by = CASE
        WHEN v_target_item_category = 'lc_flask' THEN (v_inoc_time + interval '6 months')::date
        WHEN v_target_item_category = 'grain' THEN (v_inoc_time + interval '3 months')::date
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
      'source_lot_id', p_source_lot_id,
      'source_category', v_source_item_category,
      'volume_ml', CASE WHEN (NOT v_is_untracked_source) AND v_is_liquid_source THEN p_lc_volume_ml ELSE NULL END,
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

-- 5) PACKAGE (basic): for each selected lot, create a product and link it as an origin lot, then enqueue a print job.
--    Focused on Packaging Grain/Substrate/Block (other packaging types can be added later).
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

  v_item_id bigint;
  v_name_mat text;
  v_item_category_mat text;
  v_item_category text;
  v_item_name text;

  v_lot_id_text text;
  v_lot_unit_size numeric;
  v_item_default_lb numeric;
  v_item_default_g numeric;
  v_item_default_oz numeric;
  v_net_g numeric;
  v_net_oz numeric;

  v_pack_date date;
  v_use_by date;
  v_storage_location_id bigint;
  v_storage_location_name text;
  v_is_freeze_dried boolean;
  v_spawned_at timestamp without time zone;
  v_inoculated_at timestamp without time zone;

  -- constants
  c_lb_to_g constant numeric := 453.59237;
  c_oz_to_g constant numeric := 28.349523125;
BEGIN
  IF p_lot_ids IS NULL OR array_length(p_lot_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;

  v_pack_date := now()::date;
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
  WHERE l.nocopk = v_storage_location_id;

  FOREACH v_lot_id IN ARRAY p_lot_ids LOOP
    -- Load lot + item context
    SELECT
      l.item_id,
      l.item_name_mat,
      l.item_category_mat,
      l.lot_id,
      l.unit_size,
      l.spawned_at,
      l.inoculated_at,
      i.name,
      i.category,
      i.default_unit_size_lb,
      i.default_unit_size_g,
      i.default_unit_size_oz
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
      v_item_default_lb,
      v_item_default_g,
      v_item_default_oz
    FROM public.lots l
    LEFT JOIN public.items i ON i.nocopk = l.item_id
    WHERE l.nocopk = v_lot_id;

    IF v_item_id IS NULL THEN
      UPDATE public.lots
      SET ui_error = 'Validation: item_id is required on lot before productizing.', ui_error_at = now()
      WHERE nocopk = v_lot_id;
      CONTINUE;
    END IF;

    -- Derive category (package_kind equivalent) from Lot/Item category
    v_item_category_mat := COALESCE(NULLIF(btrim(v_item_category_mat), ''), NULLIF(btrim(v_item_category), ''), NULL);
    v_item_name := COALESCE(v_item_name, v_name_mat, '');

    v_is_freeze_dried := (lower(COALESCE(v_item_category_mat,'')) = 'freezedriedmushrooms')
                         OR (position('freeze dried' in lower(COALESCE(v_item_name,''))) > 0);

    -- Compute use_by: freeze-dried = +2y from pack_date; else +3mo from spawned_at/inoculated_at/today
    IF v_is_freeze_dried THEN
      v_use_by := (v_pack_date + interval '2 years')::date;
    ELSE
      v_use_by := (
        COALESCE(
          (v_spawned_at + interval '3 months')::date,
          (v_inoculated_at + interval '3 months')::date,
          (v_pack_date + interval '3 months')::date
        )
      );
    END IF;

    -- Compute net weight from Lot size + Item defaults (mirrors Airtable automation priority)
    v_net_g := NULL;
    v_net_oz := NULL;

    -- A) lots.unit_size (assumed pounds)
    IF v_lot_unit_size IS NOT NULL AND v_lot_unit_size > 0 THEN
      v_net_g  := round(v_lot_unit_size * c_lb_to_g, 2);
      v_net_oz := round(v_lot_unit_size * 16, 2);
    ELSE
      -- B) items defaults priority: g, oz, lb
      IF v_item_default_g IS NOT NULL AND v_item_default_g > 0 THEN
        v_net_g  := round(v_item_default_g, 2);
        v_net_oz := round(v_item_default_g / c_oz_to_g, 2);
      ELSIF v_item_default_oz IS NOT NULL AND v_item_default_oz > 0 THEN
        v_net_g  := round(v_item_default_oz * c_oz_to_g, 2);
        v_net_oz := round(v_item_default_oz, 2);
      ELSIF v_item_default_lb IS NOT NULL AND v_item_default_lb > 0 THEN
        v_net_g  := round(v_item_default_lb * c_lb_to_g, 2);
        v_net_oz := round(v_item_default_lb * 16, 2);
      END IF;
    END IF;

    IF v_net_g IS NULL OR v_net_oz IS NULL THEN
      UPDATE public.lots
      SET ui_error = 'Validation: Unable to determine net weight. Provide lots.unit_size (lbs) or item default size (lb/g/oz).', ui_error_at = now()
      WHERE nocopk = v_lot_id;
      -- Silent error - create the product with zero net weight.
      -- CONTINUE;
    END IF;

    -- Create Product
    INSERT INTO public.products (
      item_id,
      name_mat,
      item_category_mat,
      net_weight_g,
      net_weight_oz,
      pack_date,
      use_by,
      package_size_g,
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
      v_pack_date,
      v_use_by,
      p_package_size_g,
      p_package_count,
      to_jsonb(ARRAY[COALESCE(NULLIF(btrim(l.lot_id),''), l.nocopk::text)])::text,
      l.strain_id,
      p_note
    FROM public.lots l
    WHERE l.nocopk = v_lot_id
    RETURNING nocopk INTO v_product_id;

    -- Materialize products.process_type_mat if the column exists
    IF EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name   = 'products'
        AND column_name  = 'process_type_mat'
    ) THEN
      IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name   = 'lots'
          AND column_name  = 'process_type_mat'
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
          AND table_name   = 'lots'
          AND column_name  = 'process_type'
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


    -- Set product storage location (user-selected)
    BEGIN
      PERFORM public.mp_product_set_storage_location(v_product_id, v_storage_location_id);
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    -- Link product <-> origin lot
    BEGIN
      INSERT INTO public._m2m_products_lots_origin_lots (products_id, lots_id)
      VALUES (v_product_id, v_lot_id)
      ON CONFLICT DO NOTHING;
    EXCEPTION WHEN undefined_table THEN NULL;
    END;

    -- Mark source lot as Consumed (status + location)
    UPDATE public.lots
    SET
      status = 'Consumed',
      ui_error = NULL,
      ui_error_at = NULL
    WHERE nocopk = v_lot_id;

    BEGIN
      PERFORM public.mp_lot_set_location_by_name(v_lot_id, 'Consumed');
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    -- Event for packaging (includes derived weights/use_by and consumption)
    v_fields := jsonb_build_object(
      'action','Package',
      'derived_item_category', v_item_category_mat,
      'net_weight_g', v_net_g,
      'net_weight_oz', v_net_oz,
      'pack_date', v_pack_date,
      'use_by', v_use_by,
      'package_count', p_package_count,
      'package_size_g', p_package_size_g,
      'product_storage_location_id', v_storage_location_id,
      'product_storage_location', v_storage_location_name,
      'source_lot_status', 'Consumed',
      'source_lot_location', 'Consumed',
      'note', p_note
    );
    BEGIN
      v_event_id := public.mp_events_insert(
        v_lot_id::bigint,
        v_product_id::bigint,
        'Package'::text,
        COALESCE(p_timestamp, now())::timestamp,
        p_operator::text,
        p_station::text,
        v_fields::jsonb
      );
      BEGIN
        PERFORM public.mp_events_link_lot(v_event_id, v_lot_id);
      EXCEPTION WHEN undefined_function THEN NULL;
      END;
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    -- Print job
    BEGIN
      PERFORM public.mp_print_queue_enqueue(
        'product'::text,
        'Product_Package'::text,
        v_lot_id,
        v_product_id,
        NULL::bigint,
        'Queued'::text
      );
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

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
  p_station text DEFAULT 'Lots',
  p_timestamp timestamp without time zone DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
  v_ts timestamp without time zone := COALESCE(p_timestamp, now());
  v_src record;
  v_new_lot_id bigint;
  v_event_id bigint;
  v_count integer := 0;
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
  v_total_ml numeric := COALESCE(p_ml_each,0) * COALESCE(p_syringe_count,0);
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

  FOR i IN 1..p_syringe_count LOOP
    INSERT INTO public.lots(
      item_id, recipe_id, strain_id,
      item_name_mat, item_category_mat,
      strain_species_strain_mat, vendor_name_mat, source_type,
      status, operator, created_at,
      source_lot_id, parent_lot_id,
      total_volume_ml, remaining_volume_ml, received_date,
      notes
    )
    VALUES (
      p_syringe_item_id,
      NULL,
      v_src.strain_id,
      NULL,
      'lc_syringe',
      v_src.strain_species_strain_mat,
      v_src.vendor_name_mat,
      'Produced'
      'Fridge',
      p_operator,
      v_ts,
      p_source_lc_flask_lot_id,
      p_source_lc_flask_lot_id,
      p_ml_each,
      p_ml_each,
      v_ts::date,
      p_notes
    )
    RETURNING nocopk INTO v_new_lot_id;

    -- Set location
    BEGIN
      PERFORM public.mp_lot_set_location(v_new_lot_id, v_loc_id);
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    -- Event
    BEGIN
      v_event_id := public.mp_events_insert(
        'Draw Syringes'::text,
        COALESCE(p_operator,'')::text,
        COALESCE(p_station,'Lots')::text,
        v_ts,
        jsonb_build_object(
          'source_lot_id', p_source_lc_flask_lot_id,
          'ml_each', p_ml_each,
          'notes', p_notes
        )
      );
      BEGIN
        PERFORM public.mp_events_link_lot(v_event_id, v_new_lot_id);
      EXCEPTION WHEN undefined_function THEN NULL;
      END;
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    -- Print job (lot label)
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

    v_count := v_count + 1;
  END LOOP;

  -- Decrement source volume
  IF v_src.remaining_volume_ml IS NOT NULL THEN
    UPDATE public.lots
      SET remaining_volume_ml = GREATEST(0, COALESCE(remaining_volume_ml,0) - v_total_ml),
          nc_updated_at = now()
      WHERE nocopk = p_source_lc_flask_lot_id;

    -- Auto-consume if depleted
    IF (SELECT COALESCE(remaining_volume_ml,0) FROM public.lots WHERE nocopk = p_source_lc_flask_lot_id) <= 0 THEN
      UPDATE public.lots
        SET status = 'Consumed',
            nc_updated_at = now()
        WHERE nocopk = p_source_lc_flask_lot_id;
      BEGIN
        PERFORM public.mp_lot_set_location_by_name(p_source_lc_flask_lot_id, 'Consumed');
      EXCEPTION WHEN undefined_function THEN NULL;
      END;
    END IF;
  END IF;

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
  p_station text DEFAULT 'Lab - Receive',
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
      unit_size, total_volume_ml, remaining_volume_ml,
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
      p_ml_each,
      p_ml_each,
      p_ml_each,
      p_operator,
      v_ts,
      p_notes
    )
    RETURNING nocopk INTO v_new_lot_id;

    BEGIN
      PERFORM public.mp_lot_set_location(v_new_lot_id, v_loc_id);
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    BEGIN
      v_event_id := public.mp_events_insert(
        'Receive Purchased Syringe'::text,
        COALESCE(p_operator,'')::text,
        COALESCE(p_station,'Lab - Receive')::text,
        v_ts,
        jsonb_build_object(
          'vendor_name', p_vendor_name,
          'vendor_batch', p_vendor_batch,
          'source_type', 'Purchased',
          'received_date', v_rcv,
          'ml_each', p_ml_each,
          'notes', p_notes
        )
      );
      BEGIN
        PERFORM public.mp_events_link_lot(v_event_id, v_new_lot_id);
      EXCEPTION WHEN undefined_function THEN NULL;
      END;
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
  p_station text DEFAULT 'Lab - Agar',
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
BEGIN
  IF p_source_agar_flask_lot_id IS NULL THEN RAISE EXCEPTION 'Source agar_flask lot required'; END IF;
  IF p_plate_item_id IS NULL THEN RAISE EXCEPTION 'Plate item required'; END IF;
  IF p_plate_count IS NULL OR p_plate_count <= 0 THEN RAISE EXCEPTION 'Plate count must be > 0'; END IF;

  SELECT * INTO v_src FROM public.lots WHERE nocopk = p_source_agar_flask_lot_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Source lot not found: %', p_source_agar_flask_lot_id; END IF;
  IF COALESCE(v_src.item_category_mat,'') <> 'agar_flask' THEN
    RAISE EXCEPTION 'Source lot must be agar_flask (got %)', v_src.item_category_mat;
  END IF;

  SELECT nocopk, name, category INTO v_plate_item
  FROM public.items
  WHERE nocopk = p_plate_item_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Plate item not found: %', p_plate_item_id;
  END IF;

  FOR v_i IN 1..p_plate_count LOOP
    INSERT INTO public.lots(
      item_id, recipe_id, strain_id,
      item_name_mat, item_category_mat,
      strain_species_strain_mat, vendor_name_mat,
      status, operator, created_at,
      source_lot_id, parent_lot_id,
      plate_group_id, received_date,
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
      v_src.status,
      p_operator,
      v_ts,
      p_source_agar_flask_lot_id,
      p_source_agar_flask_lot_id,
      v_group_id,
      v_ts::date,
      p_notes
    )
    RETURNING nocopk INTO v_new_lot_id;

    BEGIN
      PERFORM public.mp_link_lot_item(v_new_lot_id, p_plate_item_id);
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    BEGIN
      PERFORM public.mp_link_lot_recipe(v_new_lot_id, v_src.recipe_id);
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    BEGIN
      PERFORM public.mp_lot_set_location(v_new_lot_id, v_loc_id);
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    BEGIN
      v_event_id := public.mp_events_insert(
        'Pour Plates'::text,
        COALESCE(p_operator,'')::text,
        COALESCE(p_station,'Lab - Agar')::text,
        v_ts,
        jsonb_build_object(
          'source_lot_id', p_source_agar_flask_lot_id,
          'plate_group_id', v_group_id,
          'notes', p_notes
        )
      );
      BEGIN
        PERFORM public.mp_events_link_lot(v_event_id, v_new_lot_id);
      EXCEPTION WHEN undefined_function THEN NULL;
      END;
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    -- We don't create labels until plates are inoculated
    -- BEGIN
    --   PERFORM public.mp_print_queue_enqueue(
    --     'lot'::text,
    --     'Plate_Poured'::text,
    --     v_new_lot_id,
    --     NULL::bigint,
    --     NULL::bigint,
    --     'Queued'::text
    --   );
    -- EXCEPTION WHEN undefined_function THEN NULL;
    -- END;
  END LOOP;

  -- Optionally mark source as consumed if remaining_volume_ml is tracked and now <= 0 (do not decrement without a known rate)
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


-- PACKAGE FREEZE DRIED (basic): create packaged product(s) from selected freeze tray products, link via merge_tray_products, events + print jobs
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
  p_notes text DEFAULT NULL
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
      WHERE lower(btrim(l.name)) = lower(btrim('Freezer'))
      ORDER BY CASE WHEN COALESCE(l.active, false) THEN 0 ELSE 1 END, l.nocopk
      LIMIT 1
    )
  );
  v_src_id bigint;
  v_new_product_id bigint;
  v_event_id bigint;
  v_counter integer := 0;
BEGIN
  IF p_source_product_ids IS NULL OR array_length(p_source_product_ids,1) IS NULL THEN
    RAISE EXCEPTION 'At least one source product required';
  END IF;
  IF p_package_item_id IS NULL THEN RAISE EXCEPTION 'Package item required'; END IF;
  IF p_package_size_g IS NULL OR p_package_size_g <= 0 THEN RAISE EXCEPTION 'package_size_g must be > 0'; END IF;
  IF p_package_count IS NULL OR p_package_count <= 0 THEN RAISE EXCEPTION 'package_count must be > 0'; END IF;

  -- Create one packaged product per selected tray product (simple 1:1 mapping)
  FOREACH v_src_id IN ARRAY p_source_product_ids LOOP
    INSERT INTO public.products(
      item_id,
      item_category_mat,
      net_weight_g,
      net_weight_oz,
      pack_date,
      use_by,
      package_item_id,
      package_size_g,
      package_count,
      notes
    )
    VALUES(
      p_package_item_id,
      'freeze_dried_packaged',
      (p_package_size_g * p_package_count),
      (p_package_size_g * p_package_count) / 28.349523125,
      v_pack_date,
      p_use_by,
      p_package_item_id,
      p_package_size_g,
      p_package_count,
      p_notes
    )
    RETURNING nocopk INTO v_new_product_id;


    -- Materialize products.process_type_mat if the column exists (inherit from source tray product when possible)
    IF EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name   = 'products'
        AND column_name  = 'process_type_mat'
    ) THEN
      BEGIN
        UPDATE public.products p
        SET process_type_mat = COALESCE(
          (SELECT psrc.process_type_mat FROM public.products psrc WHERE psrc.nocopk = v_src_id),
          (SELECT psrc.process_type     FROM public.products psrc WHERE psrc.nocopk = v_src_id),
          (SELECT p.process_type        FROM public.products p    WHERE p.nocopk = v_new_product_id)
        )
        WHERE p.nocopk = v_new_product_id;
      EXCEPTION WHEN undefined_column THEN
        -- If process_type doesn't exist in this schema, just inherit process_type_mat from the source product
        UPDATE public.products p
        SET process_type_mat = (SELECT psrc.process_type_mat FROM public.products psrc WHERE psrc.nocopk = v_src_id)
        WHERE p.nocopk = v_new_product_id;
      END;
    END IF;

    -- Link source tray -> new packaged product
    INSERT INTO public._m2m_products_products_merge_tray_products(products_id, products1_id)
    VALUES (v_new_product_id, v_src_id)
    ON CONFLICT DO NOTHING;

    -- Set product location
    BEGIN
      PERFORM public.mp_product_set_storage_location(v_new_product_id, v_loc_id);
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    -- Event
    BEGIN
      v_event_id := public.mp_events_insert(
        'Package Freeze Dried'::text,
        COALESCE(p_operator,'')::text,
        COALESCE(p_station,'Products')::text,
        now(),
        jsonb_build_object(
          'source_product_id', v_src_id,
          'package_size_g', p_package_size_g,
          'package_count', p_package_count,
          'notes', p_notes
        )
      );
      BEGIN
        PERFORM public.mp_events_link_product(v_event_id, v_new_product_id);
      EXCEPTION WHEN undefined_function THEN NULL;
      END;
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    -- Print job
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

    v_counter := v_counter + 1;
  END LOOP;

  RETURN v_counter;
END;
$$;
