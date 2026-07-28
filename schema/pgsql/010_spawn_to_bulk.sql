/*
  010_spawn_to_bulk_actions.sql

  Adds a Postgres-native Spawn to Bulk operation for the Lots page.

  Design notes:
    - User selects one or more substrate lots in tblLots.
    - User selects one or more colonized grain source lots in the modal.
    - Multiple grain sources are allowed when they share the same species.
    - If multiple strains are used within the same species, output lots keep strain_id NULL
      and retain full parent links/event JSON for lineage.
    - Supports Issue #1 style unequal block sizing by accepting p_output_plan_json:
        [
          {"ratio": 5},
          {"ratio": 2.5},
          {"item_code": "FB-COCO-LG", "ratio": 5}
        ]
      If ratios are supplied, total input unit_size is allocated proportionally.
      If no ratios are supplied and substrate count equals output count, each substrate
      bag gets its own block plus an even grain share.
      Otherwise, total input unit_size is divided evenly.
*/

CREATE OR REPLACE FUNCTION public.mp_lots_spawn_species_key(p_species_strain text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT lower(
    btrim(
      CASE
        WHEN p_species_strain IS NULL THEN ''
        WHEN p_species_strain ~ '\s[-–—]\s' THEN regexp_replace(p_species_strain, '\s[-–—]\s.*$', '')
        ELSE array_to_string((regexp_split_to_array(btrim(p_species_strain), '\s+'))[1:2], ' ')
      END
    )
  );
$$;

CREATE OR REPLACE FUNCTION public.mp_lots_pick_fruiting_block_item_code(
  p_substrate_signature text,
  p_unit_size_lb numeric
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_sig text := upper(COALESCE(p_substrate_signature, ''));
BEGIN
  IF v_sig LIKE '%CVG%' THEN
    RETURN CASE WHEN COALESCE(p_unit_size_lb, 0) >= 5 THEN 'FB-COCO-LG' ELSE 'FB-COCO-SM' END;
  ELSIF v_sig LIKE '%MM75%' THEN
    RETURN CASE WHEN COALESCE(p_unit_size_lb, 0) >= 5 THEN 'FB-MM75-LG' ELSE 'FB-MM75-SM' END;
  ELSIF v_sig LIKE '%MM50%' THEN
    RETURN CASE WHEN COALESCE(p_unit_size_lb, 0) >= 5 THEN 'FB-MM50-LG' ELSE 'FB-MM50-SM' END;
  END IF;

  RETURN 'FB-GENERIC';
END;
$$;

DROP FUNCTION IF EXISTS public.mp_lots_spawn_to_bulk(
  bigint[],
  bigint[],
  integer,
  jsonb,
  bigint,
  timestamp without time zone,
  text,
  text,
  timestamp without time zone,
  text
);

CREATE OR REPLACE FUNCTION public.mp_lots_spawn_to_bulk(
  p_grain_lot_ids bigint[],
  p_substrate_lot_ids bigint[],
  p_output_count integer DEFAULT NULL,
  p_output_plan_json jsonb DEFAULT '[]'::jsonb,
  p_storage_location_id bigint DEFAULT NULL,
  p_override_spawn_time timestamp without time zone DEFAULT NULL,
  p_operator text DEFAULT 'system',
  p_station text DEFAULT 'Spawn to Bulk',
  p_timestamp timestamp without time zone DEFAULT NULL,
  p_note text DEFAULT NULL,
  p_fruiting_goal text DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
  v_ts timestamp without time zone := COALESCE(p_override_spawn_time, p_timestamp, now());
  v_storage_location_id bigint;
  v_consumed_location_id bigint;

  v_grain_count integer;
  v_sub_count integer;
  v_output_count integer;
  v_plan_count integer;

  v_grain_total numeric;
  v_sub_total numeric;
  v_total_size numeric;
  v_grain_share numeric;
  v_ratio_sum numeric;
  v_substrate_signature text;

  v_species_count integer;
  v_species_key text;
  v_distinct_strain_count integer;
  v_output_strain_id bigint;
  v_output_species_label text;
  v_output_species_strain_mat text;
  v_output_vendor_name_mat text;
  v_output_recipe_id bigint;
  v_process_type text;

  v_parent_ids bigint[];
  v_parent_ids_json text;

  v_i integer;
  v_unit_size numeric;
  v_ratio numeric;
  v_item_code text;
  v_item_id bigint;
  v_item_name text;
  v_item_category text;
  v_created_lot_id bigint;
  v_created_lot_ids bigint[] := ARRAY[]::bigint[];
  v_created_count integer := 0;
  v_event_id bigint;
  v_fruiting_goal text;

  v_source record;
  v_source_component record;
  v_source_component_found boolean;
  v_distribution_factor numeric;
  v_component_weight numeric;
  v_component_recipe_id bigint;
  v_component_role text;
  v_component_sort_order numeric;
  v_lot_recipe_component_id bigint;
  v_component_count integer;
  v_component_weight_sum numeric;
BEGIN
  IF p_grain_lot_ids IS NULL OR array_length(p_grain_lot_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'Select at least one colonized grain source lot.';
  END IF;

  IF p_substrate_lot_ids IS NULL OR array_length(p_substrate_lot_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'Select at least one substrate lot.';
  END IF;

  SELECT count(*)
  INTO v_grain_count
  FROM public.lots l
  WHERE l.nocopk = ANY(p_grain_lot_ids)
    AND lower(COALESCE(l.item_category_mat, '')) = 'grain'
    AND lower(COALESCE(l.status, '')) NOT IN ('consumed', 'retired', 'expired', 'compost', 'composted');

  IF v_grain_count <> array_length(p_grain_lot_ids, 1) THEN
    RAISE EXCEPTION 'All source lots must be active grain lots.';
  END IF;

  SELECT count(*)
  INTO v_sub_count
  FROM public.lots l
  WHERE l.nocopk = ANY(p_substrate_lot_ids)
    AND lower(COALESCE(l.item_category_mat, '')) = 'substrate'
    AND lower(COALESCE(l.status, '')) NOT IN ('consumed', 'retired', 'expired', 'compost', 'composted');

  IF v_sub_count <> array_length(p_substrate_lot_ids, 1) THEN
    RAISE EXCEPTION 'All selected target lots must be active substrate lots.';
  END IF;

  SELECT
    count(DISTINCT public.mp_lots_spawn_species_key(l.strain_species_strain_mat)),
    min(public.mp_lots_spawn_species_key(l.strain_species_strain_mat)),
    count(DISTINCT l.strain_id),
    CASE WHEN count(DISTINCT l.strain_id) = 1 THEN min(l.strain_id) ELSE NULL END,
    min(NULLIF(public.mp_lots_spawn_species_key(l.strain_species_strain_mat), ''))
  INTO
    v_species_count,
    v_species_key,
    v_distinct_strain_count,
    v_output_strain_id,
    v_output_species_label
  FROM public.lots l
  WHERE l.nocopk = ANY(p_grain_lot_ids);

  IF v_species_count IS NULL OR v_species_count = 0 OR v_species_key IS NULL OR v_species_key = '' THEN
    RAISE EXCEPTION 'Selected grain source lots must have a species/strain.';
  END IF;

  IF v_species_count <> 1 THEN
    RAISE EXCEPTION 'Selected grain source lots must all be the same species.';
  END IF;

  SELECT
    CASE
      WHEN count(DISTINCT NULLIF(btrim(l.strain_species_strain_mat), '')) = 1
        THEN min(NULLIF(btrim(l.strain_species_strain_mat), ''))
      ELSE initcap(v_output_species_label) || ' Mixed Strain'
    END,
    CASE
      WHEN count(DISTINCT NULLIF(btrim(l.vendor_name_mat), '')) = 1
        THEN min(NULLIF(btrim(l.vendor_name_mat), ''))
      ELSE NULL
    END
  INTO v_output_species_strain_mat, v_output_vendor_name_mat
  FROM public.lots l
  WHERE l.nocopk = ANY(p_grain_lot_ids);

  IF v_output_strain_id IS NULL AND NULLIF(v_output_species_strain_mat, '') IS NOT NULL THEN
    SELECT s.nocopk
    INTO v_output_strain_id
    FROM public.strains s
    WHERE lower(btrim(s.species_strain)) = lower(btrim(v_output_species_strain_mat))
    ORDER BY CASE WHEN COALESCE(s.active, false) THEN 0 ELSE 1 END, s.nocopk
    LIMIT 1;
  END IF;

  SELECT COALESCE(sum(NULLIF(unit_size, 0)), 0)
  INTO v_grain_total
  FROM public.lots
  WHERE nocopk = ANY(p_grain_lot_ids);

  SELECT COALESCE(sum(NULLIF(unit_size, 0)), 0)
  INTO v_sub_total
  FROM public.lots
  WHERE nocopk = ANY(p_substrate_lot_ids);

  v_total_size := COALESCE(v_grain_total, 0) + COALESCE(v_sub_total, 0);
  IF v_total_size <= 0 THEN
    RAISE EXCEPTION 'Total grain + substrate unit_size must be greater than zero.';
  END IF;

  p_output_plan_json := COALESCE(p_output_plan_json, '[]'::jsonb);
  IF jsonb_typeof(p_output_plan_json) <> 'array' THEN
    RAISE EXCEPTION 'p_output_plan_json must be a JSON array.';
  END IF;

  v_plan_count := jsonb_array_length(p_output_plan_json);
  v_output_count := COALESCE(NULLIF(p_output_count, 0), NULLIF(v_plan_count, 0), v_sub_count);

  IF v_output_count IS NULL OR v_output_count <= 0 THEN
    RAISE EXCEPTION 'Output count must be greater than zero.';
  END IF;

  IF v_plan_count > 0 AND v_plan_count <> v_output_count THEN
    RAISE EXCEPTION 'Output plan length (%) must match output count (%).', v_plan_count, v_output_count;
  END IF;

  SELECT COALESCE(sum((e.value->>'ratio')::numeric), 0)
  INTO v_ratio_sum
  FROM jsonb_array_elements(p_output_plan_json) e
  WHERE NULLIF(e.value->>'ratio', '') IS NOT NULL;

  IF v_plan_count > 0 AND v_ratio_sum <= 0 THEN
    RAISE EXCEPTION 'Output plan ratios must sum to more than zero.';
  END IF;

  SELECT string_agg(DISTINCT tag, ',')
  INTO v_substrate_signature
  FROM (
    SELECT CASE
      WHEN upper(COALESCE(l.item_name_mat, '') || ' ' || COALESCE(i.item_id, '') || ' ' || COALESCE(i.name, '')) LIKE '%CVG%' THEN 'CVG'
      WHEN upper(COALESCE(l.item_name_mat, '') || ' ' || COALESCE(i.item_id, '') || ' ' || COALESCE(i.name, '')) LIKE '%MM75%' THEN 'MM75'
      WHEN upper(COALESCE(l.item_name_mat, '') || ' ' || COALESCE(i.item_id, '') || ' ' || COALESCE(i.name, '')) LIKE '%MASTER%75%' THEN 'MM75'
      WHEN upper(COALESCE(l.item_name_mat, '') || ' ' || COALESCE(i.item_id, '') || ' ' || COALESCE(i.name, '')) LIKE '%MM50%' THEN 'MM50'
      WHEN upper(COALESCE(l.item_name_mat, '') || ' ' || COALESCE(i.item_id, '') || ' ' || COALESCE(i.name, '')) LIKE '%MASTER%50%' THEN 'MM50'
      ELSE NULL
    END AS tag
    FROM public.lots l
    LEFT JOIN public.items i ON i.nocopk = l.item_id
    WHERE l.nocopk = ANY(p_substrate_lot_ids)
  ) s
  WHERE tag IS NOT NULL;

  IF position(',' in COALESCE(v_substrate_signature, '')) > 0 THEN
    v_substrate_signature := '';
  END IF;

  SELECT min(recipe_id), min(process_type_mat)
  INTO v_output_recipe_id, v_process_type
  FROM public.lots
  WHERE nocopk = ANY(p_substrate_lot_ids);

  v_parent_ids := p_grain_lot_ids || p_substrate_lot_ids;
  v_parent_ids_json := to_jsonb(v_parent_ids)::text;

  v_storage_location_id := COALESCE(
    p_storage_location_id,
    (
      SELECT nocopk
      FROM public.locations
      WHERE lower(btrim(name)) = lower(btrim('Dark Room'))
      ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
      LIMIT 1
    )
  );

  IF v_storage_location_id IS NULL THEN
    RAISE EXCEPTION 'Storage location is required.';
  END IF;

  v_fruiting_goal := NULLIF(lower(btrim(COALESCE(p_fruiting_goal, ''))), '');
  IF v_fruiting_goal IS NOT NULL
     AND v_fruiting_goal NOT IN ('top', 'side', 'shoebox', 'monotub') THEN
    RAISE EXCEPTION 'Fruiting goal must be top, side, shoebox, or monotub.';
  END IF;

  SELECT nocopk
  INTO v_consumed_location_id
  FROM public.locations
  WHERE lower(btrim(name)) = lower(btrim('Consumed'))
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  v_grain_share := v_grain_total / v_output_count;

  FOR v_i IN 1..v_output_count LOOP
    IF v_plan_count > 0 THEN
      v_ratio := NULLIF(p_output_plan_json->(v_i - 1)->>'ratio', '')::numeric;
      v_unit_size := v_total_size * v_ratio / v_ratio_sum;
      v_item_code := NULLIF(btrim(p_output_plan_json->(v_i - 1)->>'item_code'), '');
    ELSIF v_sub_count = v_output_count THEN
      SELECT COALESCE(unit_size, 0) + v_grain_share
      INTO v_unit_size
      FROM (
        SELECT l.unit_size, row_number() OVER (ORDER BY l.nocopk) AS rn
        FROM public.lots l
        WHERE l.nocopk = ANY(p_substrate_lot_ids)
      ) s
      WHERE s.rn = v_i;
      v_item_code := NULL;
    ELSE
      v_unit_size := v_total_size / v_output_count;
      v_item_code := NULL;
    END IF;

    IF v_item_code IS NULL THEN
      v_item_code := public.mp_lots_pick_fruiting_block_item_code(v_substrate_signature, v_unit_size);
    END IF;

    SELECT i.nocopk, i.name, i.category
    INTO v_item_id, v_item_name, v_item_category
    FROM public.items i
    WHERE upper(i.item_id) = upper(v_item_code)
       OR upper(i.name) = upper(v_item_code)
    ORDER BY CASE WHEN upper(i.item_id) = upper(v_item_code) THEN 0 ELSE 1 END, i.nocopk
    LIMIT 1;

    IF v_item_id IS NULL THEN
      SELECT i.nocopk, i.name, i.category
      INTO v_item_id, v_item_name, v_item_category
      FROM public.items i
      WHERE upper(i.item_id) = 'FB-GENERIC'
      ORDER BY i.nocopk
      LIMIT 1;
    END IF;

    IF v_item_id IS NULL THEN
      RAISE EXCEPTION 'Could not resolve fruiting block item code "%", and FB-GENERIC was not found.', v_item_code;
    END IF;

    INSERT INTO public.lots (
      item_id,
      item_name_mat,
      item_category_mat,
      recipe_id,
      strain_id,
      qty,
      unit_size,
      status,
      parents_json,
      location_id,
      operator,
      created_at,
      use_by,
      process_type_mat,
      strain_species_strain_mat,
      vendor_name_mat,
      spawned_at,
      fruiting_goal,
      label_template,
      notes
    )
    VALUES (
      v_item_id,
      v_item_name,
      COALESCE(NULLIF(v_item_category, ''), 'fruiting_block'),
      v_output_recipe_id,
      v_output_strain_id,
      1,
      v_unit_size,
      'Colonizing',
      v_parent_ids_json,
      v_storage_location_id,
      p_operator,
      v_ts,
      (v_ts::date + interval '3 months')::date,
      v_process_type,
      v_output_species_strain_mat,
      v_output_vendor_name_mat,
      v_ts,
      v_fruiting_goal,
      'Bulk_Created',
      NULLIF(p_note, '')
    )
    RETURNING nocopk INTO v_created_lot_id;

    v_created_lot_ids := array_append(v_created_lot_ids, v_created_lot_id);

    BEGIN
      PERFORM public.mp_lot_set_location(v_created_lot_id, v_storage_location_id);
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    BEGIN
      INSERT INTO public._m2m_lots_items_item_id(lots_id, items_id)
      VALUES (v_created_lot_id, v_item_id)
      ON CONFLICT DO NOTHING;
    EXCEPTION WHEN undefined_table THEN NULL;
    END;

    IF v_output_strain_id IS NOT NULL THEN
      BEGIN
        INSERT INTO public._m2m_lots_strains_strain_id(lots_id, strains_id)
        VALUES (v_created_lot_id, v_output_strain_id)
        ON CONFLICT DO NOTHING;
      EXCEPTION WHEN undefined_table THEN NULL;
      END;
    END IF;

    FOREACH v_event_id IN ARRAY p_grain_lot_ids LOOP
      BEGIN
        INSERT INTO public._m2m_lots_lots_grain_inputs(lots_id, lots1_id)
        VALUES (v_created_lot_id, v_event_id)
        ON CONFLICT DO NOTHING;
      EXCEPTION WHEN undefined_table THEN NULL;
      END;
    END LOOP;

    FOREACH v_event_id IN ARRAY p_substrate_lot_ids LOOP
      BEGIN
        INSERT INTO public._m2m_lots_lots_substrate_inputs(lots_id, lots1_id)
        VALUES (v_created_lot_id, v_event_id)
        ON CONFLICT DO NOTHING;
      EXCEPTION WHEN undefined_table THEN NULL;
      END;
    END LOOP;

    -- Persist the actual grain/substrate recipe contribution history for the
    -- output lot. Source component weights are allocated using the same rule
    -- that calculated this output lot's unit_size.
    v_component_sort_order := 0;

    FOR v_source IN
      SELECT
        source_rows.nocopk,
        source_rows.lot_id,
        source_rows.item_id,
        source_rows.recipe_id,
        source_rows.unit_size,
        source_rows.source_role,
        source_rows.source_ordinal
      FROM (
        SELECT
          l.nocopk,
          l.lot_id,
          l.item_id,
          l.recipe_id,
          l.unit_size,
          'grain'::text AS source_role,
          grain_ids.ordinality::integer AS source_ordinal
        FROM unnest(p_grain_lot_ids) WITH ORDINALITY AS grain_ids(lot_id, ordinality)
        JOIN public.lots l ON l.nocopk = grain_ids.lot_id

        UNION ALL

        SELECT
          l.nocopk,
          l.lot_id,
          l.item_id,
          l.recipe_id,
          l.unit_size,
          'substrate'::text AS source_role,
          substrate_ids.ordinality::integer AS source_ordinal
        FROM unnest(p_substrate_lot_ids) WITH ORDINALITY AS substrate_ids(lot_id, ordinality)
        JOIN public.lots l ON l.nocopk = substrate_ids.lot_id
      ) source_rows
      ORDER BY
        CASE source_rows.source_role WHEN 'grain' THEN 0 ELSE 1 END,
        source_rows.source_ordinal,
        source_rows.nocopk
    LOOP
      IF v_plan_count > 0 THEN
        v_distribution_factor := v_ratio / v_ratio_sum;
      ELSIF v_sub_count = v_output_count THEN
        IF v_source.source_role = 'grain' THEN
          v_distribution_factor := 1.0 / v_output_count;
        ELSIF v_source.source_ordinal = v_i THEN
          v_distribution_factor := 1.0;
        ELSE
          CONTINUE;
        END IF;
      ELSE
        v_distribution_factor := 1.0 / v_output_count;
      END IF;

      v_source_component_found := false;

      FOR v_source_component IN
        SELECT
          lrc.recipe_id,
          lrc.source_item_recipe_component_id,
          NULLIF(btrim(lrc.component_role), '') AS component_role,
          COALESCE(
            NULLIF(lrc.component_weight_lb, 0),
            v_source.unit_size * NULLIF(lrc.component_percent, 0) / 100.0,
            CASE WHEN count(*) OVER () = 1 THEN v_source.unit_size END
          ) AS component_weight_lb,
          count(*) OVER () AS source_component_count,
          lrc.sort_order,
          lrc.nocopk
        FROM public.lot_recipe_components lrc
        WHERE lrc.lot_id = v_source.nocopk
        ORDER BY COALESCE(lrc.sort_order, 0), lrc.nocopk
      LOOP
        v_source_component_found := true;

        IF v_source_component.component_weight_lb IS NULL
           OR v_source_component.component_weight_lb <= 0 THEN
          RAISE EXCEPTION
            'Spawn to Bulk source lot % component % of % has no usable weight or percent.',
            COALESCE(v_source.lot_id, v_source.nocopk::text),
            v_source_component.nocopk,
            v_source_component.source_component_count;
        END IF;

        v_component_sort_order := v_component_sort_order + 1;
        v_component_weight := v_source_component.component_weight_lb * v_distribution_factor;
        v_component_recipe_id := COALESCE(v_source_component.recipe_id, v_source.recipe_id);
        v_component_role := COALESCE(v_source_component.component_role, v_source.source_role);

        IF v_component_recipe_id IS NULL THEN
          RAISE EXCEPTION
            'Spawn to Bulk source lot % has no recipe for component role %.',
            COALESCE(v_source.lot_id, v_source.nocopk::text), v_component_role;
        END IF;

        INSERT INTO public.lot_recipe_components (
          lot_id,
          item_id,
          recipe_id,
          source_item_recipe_component_id,
          component_role,
          component_weight_lb,
          component_percent,
          sort_order,
          notes
        )
        VALUES (
          v_created_lot_id,
          v_item_id,
          v_component_recipe_id,
          v_source_component.source_item_recipe_component_id,
          v_component_role,
          v_component_weight,
          CASE
            WHEN COALESCE(v_unit_size, 0) > 0
              THEN v_component_weight / v_unit_size * 100.0
            ELSE NULL
          END,
          v_component_sort_order,
          'Derived from Spawn to Bulk ' || v_source.source_role ||
            ' input ' || COALESCE(v_source.lot_id, v_source.nocopk::text)
        )
        RETURNING nocopk INTO v_lot_recipe_component_id;

        PERFORM public.mp_link_lot_recipe_component(
          v_lot_recipe_component_id,
          v_created_lot_id,
          v_item_id,
          v_component_recipe_id,
          v_source_component.source_item_recipe_component_id
        );
      END LOOP;

      -- Legacy/imported source lots may not yet have actual component rows.
      -- Fall back to the source lot recipe while still recording a distinct
      -- contribution for each grain/substrate input.
      IF NOT v_source_component_found THEN
        IF v_source.recipe_id IS NULL THEN
          RAISE EXCEPTION
            'Spawn to Bulk source lot % has neither lot_recipe_components nor recipe_id.',
            COALESCE(v_source.lot_id, v_source.nocopk::text);
        END IF;

        v_component_sort_order := v_component_sort_order + 1;
        v_component_weight := v_source.unit_size * v_distribution_factor;

        INSERT INTO public.lot_recipe_components (
          lot_id,
          item_id,
          recipe_id,
          source_item_recipe_component_id,
          component_role,
          component_weight_lb,
          component_percent,
          sort_order,
          notes
        )
        VALUES (
          v_created_lot_id,
          v_item_id,
          v_source.recipe_id,
          NULL,
          v_source.source_role,
          v_component_weight,
          CASE
            WHEN COALESCE(v_unit_size, 0) > 0
              THEN v_component_weight / v_unit_size * 100.0
            ELSE NULL
          END,
          v_component_sort_order,
          'Derived from Spawn to Bulk ' || v_source.source_role ||
            ' input ' || COALESCE(v_source.lot_id, v_source.nocopk::text) ||
            ' using source lot recipe fallback'
        )
        RETURNING nocopk INTO v_lot_recipe_component_id;

        PERFORM public.mp_link_lot_recipe_component(
          v_lot_recipe_component_id,
          v_created_lot_id,
          v_item_id,
          v_source.recipe_id,
          NULL
        );
      END IF;
    END LOOP;

    SELECT count(*)::integer, COALESCE(sum(lrc.component_weight_lb), 0)
    INTO v_component_count, v_component_weight_sum
    FROM public.lot_recipe_components lrc
    WHERE lrc.lot_id = v_created_lot_id;

    IF v_component_count = 0 THEN
      RAISE EXCEPTION 'Spawn to Bulk created output lot % without component history.',
        v_created_lot_id;
    END IF;

    IF abs(v_component_weight_sum - v_unit_size) >= 0.000001 THEN
      RAISE EXCEPTION
        'Spawn to Bulk component weights for output lot % total % lb but output unit_size is % lb.',
        v_created_lot_id, v_component_weight_sum, v_unit_size;
    END IF;

    BEGIN
      v_event_id := public.mp_events_insert_and_link_lot(
        v_created_lot_id,
        'SpawnedToBulk',
        v_ts,
        p_operator,
        p_station,
        jsonb_build_object(
          'grain_input_ids', p_grain_lot_ids,
          'substrate_input_ids', p_substrate_lot_ids,
          'output_index', v_i - 1,
          'output_count', v_output_count,
          'per_output_unit_size_lb', v_unit_size,
          'output_item_code', v_item_code,
          'fruiting_goal', v_fruiting_goal,
          'output_plan_json', p_output_plan_json,
          'note', p_note
        )
      );
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    BEGIN
      PERFORM public.mp_print_queue_enqueue(
        'lot'::text,
        'Bulk_Created'::text,
        v_created_lot_id,
        NULL::bigint,
        NULL::bigint,
        'Queued'::text
      );
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    v_created_count := v_created_count + 1;
  END LOOP;

  UPDATE public.lots
  SET status = 'Consumed',
      retired_at = COALESCE(retired_at, v_ts),
      nc_updated_at = now()
  WHERE nocopk = ANY(v_parent_ids);

  IF v_consumed_location_id IS NOT NULL THEN
    FOREACH v_event_id IN ARRAY v_parent_ids LOOP
      BEGIN
        PERFORM public.mp_lot_set_location(v_event_id, v_consumed_location_id);
      EXCEPTION WHEN undefined_function THEN NULL;
      END;
    END LOOP;
  END IF;

  FOREACH v_event_id IN ARRAY v_parent_ids LOOP
    BEGIN
      PERFORM public.mp_events_insert_and_link_lot(
        v_event_id,
        'Consumed',
        v_ts,
        p_operator,
        p_station,
        jsonb_build_object(
          'consumed_by_lot_ids', v_created_lot_ids,
          'consumed_by_spawn_to_bulk', true,
          'created_lot_count', v_created_count,
          'grain_input_ids', p_grain_lot_ids,
          'substrate_input_ids', p_substrate_lot_ids
        )
      );
    EXCEPTION WHEN undefined_function THEN NULL;
    END;
  END LOOP;

  RETURN v_created_count;
END;
$$;
