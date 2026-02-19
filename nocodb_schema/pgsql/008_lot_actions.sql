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
  p_location_name text,
  p_fridge_mode text DEFAULT 'Fridge',
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
  v_old_status text;
  v_new_status text;
BEGIN
  IF p_lot_ids IS NULL OR array_length(p_lot_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;

  FOREACH v_lot_id IN ARRAY p_lot_ids LOOP
    SELECT status INTO v_old_status FROM public.lots WHERE nocopk = v_lot_id;

    -- Update location
    PERFORM public.mp_lot_set_location_by_name(v_lot_id, p_location_name);

    v_new_status := NULL;

    IF p.location_name ILIKE '%Fridge%' OR p.location_name ILIKE '%Refrigerator%' THEN
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

      v_fields := jsonb_build_object('action','Move','to_location',p_location_name,'to_status',v_new_status,'note',p_note);
      BEGIN
        v_event_id := public.mp_events_insert_and_link_lot(
          v_lot_id::bigint, 
          v_new_status::text, 
          COALESCE(p_timestamp, now())::timestamp, 
          p_operator::text, 
          p_station::text, 
          v_fields:jsonb
        );
      EXCEPTION WHEN undefined_function THEN NULL;
      END;

    ELSIF p_location_name ILIKE '%Fruiting%' THEN
      v_new_status := 'Fruiting';
      UPDATE public.lots SET status = v_new_status WHERE nocopk = v_lot_id;

      v_fields := jsonb_build_object('action','Move','to_location',p_location_name,'to_status',v_new_status,'note',p_note);
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
      v_fields := jsonb_build_object('action','Move','to_location',p_location_name,'note',p_note);
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
  p_action    text,
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
    v_fields := jsonb_build_object('action', p_action, 'note', p_note);

    BEGIN
      v_event_id := public.mp_events_insert_and_link_lot(
        v_lot_id::bigint, 
        COALESCE(NULLIF(btrim(p_action),''), 'Modify')::text, 
        COALESCE(p_timestamp, now())::timestamp, 
        p_operator::text, 
        p_station::text, 
        v_fields::jsonb
      );
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

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
  WHERE name = p_location_name
  LIMIT 1;

  IF v_loc_id IS NULL THEN
    RAISE EXCEPTION 'Location not found: %', p_location_name;
  END IF;

  UPDATE public.products
  SET storage_location_id = v_loc_id
  WHERE nocopk = p_product_id;
END;
$$;

-- 5) PACKAGE (basic): for each selected lot, create a product and link it as an origin lot, then enqueue a print job.
--    Focused on Packaging Grain/Substrate/Block (other packaging types can be added later).
CREATE OR REPLACE FUNCTION public.mp_lots_package_basic(
  p_lot_ids   bigint[],
  p_package_kind text,
  p_package_count numeric DEFAULT 1,
  p_package_size_g numeric DEFAULT NULL,
  p_storage_location_name text DEFAULT NULL,
  p_label_type text DEFAULT 'Product',
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
  v_product_id bigint;
  v_event_id bigint;
  v_fields jsonb;
  v_counter integer := 0;
  v_item_id bigint;
  v_name_mat text;
  v_item_category text;
  v_product_code text;
BEGIN
  IF p_lot_ids IS NULL OR array_length(p_lot_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;

  FOREACH v_lot_id IN ARRAY p_lot_ids LOOP
    SELECT item_id, item_name_mat, item_category_mat INTO v_item_id, v_name_mat, v_item_category
    FROM public.lots
    WHERE nocopk = v_lot_id;

    v_product_code := 'PRD-' || extract(epoch from clock_timestamp())::bigint::text || '-' || v_lot_id::text;

    INSERT INTO public.products (
      product_id, item_id, name_mat, item_category_mat,
      package_size_g, package_count, pack_date, notes
    ) VALUES (
      v_product_code,
      v_item_id,
      v_name_mat,
      COALESCE(v_item_category, p_package_kind),
      p_package_size_g,
      p_package_count,
      now()::date,
      p_note
    )
    RETURNING nocopk INTO v_product_id;

    -- Set product storage location (if provided)
    BEGIN
      PERFORM public.mp_product_set_storage_location_by_name(v_product_id, p_storage_location_name);
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    -- Link product <-> origin lot
    BEGIN
      INSERT INTO public._m2m_products_lots_origin_lots (products_id, lots_id)
      VALUES (v_product_id, v_lot_id)
      ON CONFLICT DO NOTHING;
    EXCEPTION WHEN undefined_table THEN NULL;
    END;

    -- Event for packaging
    v_fields := jsonb_build_object(
      'action','Package',
      'package_kind', p_package_kind,
      'package_count', p_package_count,
      'package_size_g', p_package_size_g,
      'storage_location', p_storage_location_name,
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
      -- link to lot if helper exists
      BEGIN
        PERFORM public.mp_events_link_lot(v_event_id, v_lot_id);
      EXCEPTION WHEN undefined_function THEN NULL;
      END;
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    -- Print job
    BEGIN
      PERFORM public.mp_print_queue_enqueue(
        'Product'::text,
        COALESCE(NULLIF(btrim(p_label_type),''), 'Product')::text,
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
