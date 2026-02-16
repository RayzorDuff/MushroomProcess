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

-- Helper: get location name for a lot
CREATE OR REPLACE FUNCTION public.mp_lot_get_location_name(p_lot_id bigint)
RETURNS text
LANGUAGE sql
AS $$
  SELECT l2.name
  FROM public.lots l
  LEFT JOIN public.locations l2 ON l2.nocopk = l.location_id
  WHERE l.nocopk = p_lot_id
$$;

-- Helper: set location for a lot by location name (uses lots.location_id FK)
CREATE OR REPLACE FUNCTION public.mp_lot_set_location_by_name(p_lot_id bigint, p_location_name text)
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
  WHERE name = p_location_name
  LIMIT 1;

  IF v_loc_id IS NULL THEN
    RAISE EXCEPTION 'Location not found: %', p_location_name;
  END IF;

  UPDATE public.lots
  SET location_id = v_loc_id
  WHERE nocopk = p_lot_id;
END;
$$;

-- 1) SHAKE: logs a Shake event for each lot, clears ui_error fields (if present), optional note append
CREATE OR REPLACE FUNCTION public.mp_lots_shake(
  p_lot_ids   bigint[],
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
  v_fields jsonb;
  v_counter integer := 0;
BEGIN
  IF p_lot_ids IS NULL OR array_length(p_lot_ids, 1) IS NULL THEN
    RETURN 0;
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
  p_station   text DEFAULT 'Dark Room',
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
  ELSIF ('compost' = ANY(v_reasons_lower)) OR ('composted' = ANY(v_reasons_lower)) OR ('contaminated' = ANY(v_reasons_lower)) THEN
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
