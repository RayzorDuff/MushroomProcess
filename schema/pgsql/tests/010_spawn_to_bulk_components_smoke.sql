\set ON_ERROR_STOP on

-- Transactional smoke test for #75 and #68 Spawn to Bulk component history.
-- Run after 005_helpers.sql, 006_print.sql, and 010_spawn_to_bulk.sql.
-- All fixtures and outputs are rolled back.
BEGIN;

DO $$
DECLARE
  v_grain_item_id bigint;
  v_substrate_item_id bigint;
  v_output_item_id bigint;
  v_grain_recipe_id bigint;
  v_substrate_recipe_id bigint;
  v_grain_item_component_id bigint;
  v_substrate_item_component_id bigint;
  v_location_id bigint;
  v_strain_id bigint;

  v_grain_lot_id bigint;
  v_substrate_lot_1_id bigint;
  v_substrate_lot_2_id bigint;
  v_source_component_id bigint;
  v_created_count integer;
  v_output_lot_ids bigint[];
  v_output_lot record;
  v_component_count integer;
  v_component_weight_sum numeric;
  v_component_percent_sum numeric;
BEGIN
  SELECT nocopk INTO v_grain_item_id
  FROM public.items
  WHERE item_id = 'GRAIN-BAG'
  LIMIT 1;

  SELECT nocopk INTO v_substrate_item_id
  FROM public.items
  WHERE item_id = 'SUB-CVG-BAG'
  LIMIT 1;

  SELECT nocopk INTO v_output_item_id
  FROM public.items
  WHERE item_id = 'FB-COCO-SM'
  LIMIT 1;

  SELECT nocopk INTO v_grain_recipe_id
  FROM public.recipes
  WHERE recipe_id = 'REC-GRAIN-WBS'
  LIMIT 1;

  SELECT nocopk INTO v_substrate_recipe_id
  FROM public.recipes
  WHERE recipe_id IN ('REC-SUB-CVG-V2', 'REC-SUB-CVG-RIZ-V1')
  ORDER BY CASE recipe_id WHEN 'REC-SUB-CVG-V2' THEN 0 ELSE 1 END
  LIMIT 1;

  SELECT nocopk INTO v_grain_item_component_id
  FROM public.item_recipe_components
  WHERE item_id = v_grain_item_id
    AND recipe_id = v_grain_recipe_id
    AND COALESCE(active, false)
  ORDER BY nocopk
  LIMIT 1;

  SELECT nocopk INTO v_substrate_item_component_id
  FROM public.item_recipe_components
  WHERE item_id = v_substrate_item_id
    AND recipe_id = v_substrate_recipe_id
    AND COALESCE(active, false)
  ORDER BY nocopk
  LIMIT 1;

  SELECT nocopk INTO v_location_id
  FROM public.locations
  WHERE lower(btrim(name)) = 'dark room'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;

  SELECT nocopk INTO v_strain_id
  FROM public.strains
  WHERE COALESCE(active, false)
    AND NULLIF(btrim(species_strain), '') IS NOT NULL
  ORDER BY nocopk
  LIMIT 1;

  IF v_grain_item_id IS NULL
     OR v_substrate_item_id IS NULL
     OR v_output_item_id IS NULL
     OR v_grain_recipe_id IS NULL
     OR v_substrate_recipe_id IS NULL
     OR v_grain_item_component_id IS NULL
     OR v_substrate_item_component_id IS NULL
     OR v_location_id IS NULL
     OR v_strain_id IS NULL THEN
    RAISE EXCEPTION 'Spawn to Bulk component smoke-test fixtures are missing from imported Airtable data.';
  END IF;

  INSERT INTO public.lots (
    lot_id,
    item_id,
    item_name_mat,
    item_category_mat,
    recipe_id,
    strain_id,
    strain_species_strain_mat,
    qty,
    unit_size,
    status,
    location_id,
    created_at,
    sterilized_at,
    inoculated_at,
    notes
  )
  SELECT
    'LOT-RC5-SPAWN-COMP-GRAIN',
    v_grain_item_id,
    i.name,
    'grain',
    v_grain_recipe_id,
    v_strain_id,
    s.species_strain,
    1,
    1.5,
    'FullyColonized',
    v_location_id,
    clock_timestamp()::timestamp without time zone - interval '10 days',
    clock_timestamp()::timestamp without time zone - interval '10 days',
    clock_timestamp()::timestamp without time zone - interval '8 days',
    'Rollback-only #75 grain source'
  FROM public.items i
  JOIN public.strains s ON s.nocopk = v_strain_id
  WHERE i.nocopk = v_grain_item_id
  RETURNING nocopk INTO v_grain_lot_id;

  INSERT INTO public.lots (
    lot_id,
    item_id,
    item_name_mat,
    item_category_mat,
    recipe_id,
    qty,
    unit_size,
    status,
    location_id,
    created_at,
    sterilized_at,
    notes
  )
  SELECT
    'LOT-RC5-SPAWN-COMP-SUB1',
    v_substrate_item_id,
    i.name,
    'substrate',
    v_substrate_recipe_id,
    1,
    5,
    'Sterilized',
    v_location_id,
    clock_timestamp()::timestamp without time zone - interval '5 days',
    clock_timestamp()::timestamp without time zone - interval '5 days',
    'Rollback-only #75 substrate source 1'
  FROM public.items i
  WHERE i.nocopk = v_substrate_item_id
  RETURNING nocopk INTO v_substrate_lot_1_id;

  INSERT INTO public.lots (
    lot_id,
    item_id,
    item_name_mat,
    item_category_mat,
    recipe_id,
    qty,
    unit_size,
    status,
    location_id,
    created_at,
    sterilized_at,
    notes
  )
  SELECT
    'LOT-RC5-SPAWN-COMP-SUB2',
    v_substrate_item_id,
    i.name,
    'substrate',
    v_substrate_recipe_id,
    1,
    5,
    'Sterilized',
    v_location_id,
    clock_timestamp()::timestamp without time zone - interval '5 days',
    clock_timestamp()::timestamp without time zone - interval '5 days',
    'Rollback-only #75 substrate source 2'
  FROM public.items i
  WHERE i.nocopk = v_substrate_item_id
  RETURNING nocopk INTO v_substrate_lot_2_id;

  -- Grain and the first substrate have actual source component rows. The
  -- second substrate deliberately exercises the source-lot recipe fallback.
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
    v_grain_lot_id,
    v_grain_item_id,
    v_grain_recipe_id,
    v_grain_item_component_id,
    'grain',
    1.5,
    100,
    1,
    'Rollback-only #75 source grain component'
  )
  RETURNING nocopk INTO v_source_component_id;

  PERFORM public.mp_link_lot_recipe_component(
    v_source_component_id,
    v_grain_lot_id,
    v_grain_item_id,
    v_grain_recipe_id,
    v_grain_item_component_id
  );

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
    v_substrate_lot_1_id,
    v_substrate_item_id,
    v_substrate_recipe_id,
    v_substrate_item_component_id,
    'substrate',
    5,
    100,
    1,
    'Rollback-only #75 source substrate component'
  )
  RETURNING nocopk INTO v_source_component_id;

  PERFORM public.mp_link_lot_recipe_component(
    v_source_component_id,
    v_substrate_lot_1_id,
    v_substrate_item_id,
    v_substrate_recipe_id,
    v_substrate_item_component_id
  );

  v_created_count := public.mp_lots_spawn_to_bulk(
    p_grain_lot_ids => ARRAY[v_grain_lot_id],
    p_substrate_lot_ids => ARRAY[v_substrate_lot_1_id, v_substrate_lot_2_id],
    p_output_count => 3,
    p_output_plan_json => '[]'::jsonb,
    p_storage_location_id => v_location_id,
    p_override_spawn_time => NULL,
    p_operator => 'RC5 #75 smoke test',
    p_station => 'Spawn to Bulk',
    p_timestamp => clock_timestamp()::timestamp without time zone,
    p_note => 'Rollback-only #75 Spawn to Bulk component test',
    p_fruiting_goal => 'shoebox'
  );

  IF v_created_count <> 3 THEN
    RAISE EXCEPTION 'Expected three Spawn to Bulk outputs, got %.', v_created_count;
  END IF;

  SELECT COALESCE(array_agg(l.nocopk ORDER BY l.nocopk), ARRAY[]::bigint[])
  INTO v_output_lot_ids
  FROM public.lots l
  WHERE l.notes = 'Rollback-only #75 Spawn to Bulk component test';

  IF cardinality(v_output_lot_ids) <> 3 THEN
    RAISE EXCEPTION 'Expected three created output lot IDs, got %.', cardinality(v_output_lot_ids);
  END IF;

  FOR v_output_lot IN
    SELECT l.nocopk, l.item_id, l.unit_size
    FROM public.lots l
    WHERE l.nocopk = ANY(v_output_lot_ids)
    ORDER BY l.nocopk
  LOOP
    SELECT
      count(*)::integer,
      COALESCE(sum(lrc.component_weight_lb), 0),
      COALESCE(sum(lrc.component_percent), 0)
    INTO
      v_component_count,
      v_component_weight_sum,
      v_component_percent_sum
    FROM public.lot_recipe_components lrc
    WHERE lrc.lot_id = v_output_lot.nocopk;

    IF v_output_lot.item_id <> v_output_item_id
       OR abs(v_output_lot.unit_size - 3.8333333333333333) >= 0.000001 THEN
      RAISE EXCEPTION 'Unexpected Spawn to Bulk output lot: %', row_to_json(v_output_lot);
    END IF;

    IF v_component_count <> 3
       OR abs(v_component_weight_sum - v_output_lot.unit_size) >= 0.000001
       OR abs(v_component_percent_sum - 100) >= 0.000001 THEN
      RAISE EXCEPTION
        'Output lot % component totals are incorrect: count %, weight %, percent %.',
        v_output_lot.nocopk,
        v_component_count,
        v_component_weight_sum,
        v_component_percent_sum;
    END IF;

    IF (
      SELECT count(*)
      FROM public.lot_recipe_components lrc
      WHERE lrc.lot_id = v_output_lot.nocopk
        AND lrc.component_role = 'grain'
        AND lrc.recipe_id = v_grain_recipe_id
        AND abs(lrc.component_weight_lb - 0.5) < 0.000001
    ) <> 1 THEN
      RAISE EXCEPTION 'Output lot % is missing its 0.5 lb grain component.', v_output_lot.nocopk;
    END IF;

    IF (
      SELECT count(*)
      FROM public.lot_recipe_components lrc
      WHERE lrc.lot_id = v_output_lot.nocopk
        AND lrc.component_role = 'substrate'
        AND lrc.recipe_id = v_substrate_recipe_id
        AND abs(lrc.component_weight_lb - 1.6666666666666667) < 0.000001
    ) <> 2 THEN
      RAISE EXCEPTION 'Output lot % is missing its two separate substrate components.', v_output_lot.nocopk;
    END IF;

    IF (
      SELECT count(*)
      FROM public._m2m_lots_lot_recipe_components_lot_recipe_components j
      JOIN public.lot_recipe_components lrc
        ON lrc.nocopk = j.lot_recipe_components_id
      WHERE j.lots_id = v_output_lot.nocopk
        AND lrc.lot_id = v_output_lot.nocopk
    ) <> 3 THEN
      RAISE EXCEPTION 'Output lot % inverse component links are incomplete.', v_output_lot.nocopk;
    END IF;

    IF (
      SELECT count(*)
      FROM public.lot_recipe_components lrc
      WHERE lrc.lot_id = v_output_lot.nocopk
        AND lrc.source_item_recipe_component_id IS NOT NULL
    ) <> 2 THEN
      RAISE EXCEPTION 'Output lot % did not preserve source item-component lineage.', v_output_lot.nocopk;
    END IF;

    IF (
      SELECT count(DISTINCT substring(lrc.notes FROM 'input (LOT-[^ ]+)'))
      FROM public.lot_recipe_components lrc
      WHERE lrc.lot_id = v_output_lot.nocopk
    ) <> 3 THEN
      RAISE EXCEPTION 'Output lot % component notes do not retain all source lot identities.', v_output_lot.nocopk;
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM public.lot_recipe_components lrc
      WHERE lrc.lot_id = v_output_lot.nocopk
        AND lrc.notes LIKE '%source lot recipe fallback%'
    ) THEN
      RAISE EXCEPTION 'Output lot % did not exercise the source recipe fallback.', v_output_lot.nocopk;
    END IF;
  END LOOP;

  IF (
    SELECT count(*)
    FROM public.lots l
    WHERE l.nocopk = ANY(ARRAY[v_grain_lot_id, v_substrate_lot_1_id, v_substrate_lot_2_id])
      AND l.status = 'Consumed'
  ) <> 3 THEN
    RAISE EXCEPTION 'Spawn to Bulk source lots were not all consumed.';
  END IF;

  -- A repeated submission with the same consumed sources must fail before
  -- creating additional outputs or duplicate component rows.
  BEGIN
    PERFORM public.mp_lots_spawn_to_bulk(
      p_grain_lot_ids => ARRAY[v_grain_lot_id],
      p_substrate_lot_ids => ARRAY[v_substrate_lot_1_id, v_substrate_lot_2_id],
      p_output_count => 3,
      p_output_plan_json => '[]'::jsonb,
      p_storage_location_id => v_location_id,
      p_override_spawn_time => NULL,
      p_operator => 'RC5 #75 smoke test',
      p_station => 'Spawn to Bulk',
      p_timestamp => clock_timestamp()::timestamp without time zone,
      p_note => 'Rollback-only #75 duplicate attempt',
      p_fruiting_goal => 'shoebox'
    );
    RAISE EXCEPTION 'Expected consumed-source retry validation did not occur.';
  EXCEPTION WHEN OTHERS THEN
    IF position('active grain lots' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
  END;

  IF (
    SELECT count(*)
    FROM public.lots l
    WHERE l.notes IN (
      'Rollback-only #75 Spawn to Bulk component test',
      'Rollback-only #75 duplicate attempt'
    )
  ) <> 3 THEN
    RAISE EXCEPTION 'Duplicate Spawn to Bulk attempt created unexpected output lots.';
  END IF;

  IF (
    SELECT count(*)
    FROM public.lot_recipe_components lrc
    WHERE lrc.lot_id = ANY(v_output_lot_ids)
  ) <> 9 THEN
    RAISE EXCEPTION 'Duplicate Spawn to Bulk attempt changed component-row cardinality.';
  END IF;

  RAISE NOTICE 'Spawn to Bulk component-history smoke tests passed.';
END;
$$;

ROLLBACK;
