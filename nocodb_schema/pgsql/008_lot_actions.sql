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
  p_location_name text,
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
          v_fields::jsonb
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
  p_package_count numeric DEFAULT 1,
  p_package_size_g numeric DEFAULT NULL,
  p_storage_location_name text DEFAULT 'Products Storage',
  p_label_type text DEFAULT 'Product',
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

    -- Set product storage location (user-selected)
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
      'product_storage_location', p_storage_location_name,
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
