-- 038_reporting_cohort.sql
-- Issue #87 Phase 5: canonical cohort analytics data layer.

SET search_path = public, pg_catalog;

BEGIN;

/*
 * v_reporting_cohort_lifecycle is the one-row-per-lot cohort fact view used by
 * every later cohort chart/table.  It extends the canonical lifecycle contract
 * with exact input-dimension arrays, grain/substrate age-at-use measures, and
 * outcome booleans.  It deliberately does not infer a separate species value:
 * the current schema stores only strains.species_strain / lot materialization.
 */
CREATE OR REPLACE VIEW public.v_reporting_cohort_lifecycle AS
WITH grain_edges AS (
  SELECT DISTINCT
    j.lots_id AS lot_nocopk,
    j.lots1_id AS input_lot_nocopk,
    input_lot.item_name AS input_item_name,
    CASE
      WHEN root.spawned_at IS NOT NULL
       AND input_lot.inoculated_at IS NOT NULL
        THEN round((extract(epoch FROM (root.spawned_at - input_lot.inoculated_at)) / 86400.0)::numeric, 3)
      ELSE NULL
    END AS age_at_spawn_days
  FROM public._m2m_lots_lots_grain_inputs j
  JOIN public.v_reporting_lot_lifecycle root
    ON root.lot_nocopk = j.lots_id
  JOIN public.v_reporting_lot_lifecycle input_lot
    ON input_lot.lot_nocopk = j.lots1_id
  WHERE j.lots1_id <> j.lots_id
),
grain_rollup AS (
  SELECT
    g.lot_nocopk,
    count(*)::bigint AS input_count,
    COALESCE(
      array_agg(DISTINCT g.input_item_name ORDER BY g.input_item_name)
        FILTER (WHERE NULLIF(btrim(g.input_item_name), '') IS NOT NULL),
      ARRAY[]::text[]
    ) AS input_item_names,
    count(*) FILTER (WHERE g.age_at_spawn_days IS NOT NULL)::bigint AS valid_age_count,
    min(g.age_at_spawn_days) AS min_age_days,
    round(avg(g.age_at_spawn_days)::numeric, 3) AS avg_age_days,
    max(g.age_at_spawn_days) AS max_age_days,
    COALESCE(bool_or(g.age_at_spawn_days < 0), false) AS has_negative_age
  FROM grain_edges g
  GROUP BY g.lot_nocopk
),
substrate_edges AS (
  SELECT DISTINCT
    j.lots_id AS lot_nocopk,
    j.lots1_id AS input_lot_nocopk,
    input_lot.item_name AS input_item_name,
    CASE
      WHEN root.spawned_at IS NOT NULL
       AND input_lot.processed_at IS NOT NULL
        THEN round((extract(epoch FROM (root.spawned_at - input_lot.processed_at)) / 86400.0)::numeric, 3)
      ELSE NULL
    END AS age_at_spawn_days
  FROM public._m2m_lots_lots_substrate_inputs j
  JOIN public.v_reporting_lot_lifecycle root
    ON root.lot_nocopk = j.lots_id
  JOIN public.v_reporting_lot_lifecycle input_lot
    ON input_lot.lot_nocopk = j.lots1_id
  WHERE j.lots1_id <> j.lots_id
),
substrate_rollup AS (
  SELECT
    s.lot_nocopk,
    count(*)::bigint AS input_count,
    COALESCE(
      array_agg(DISTINCT s.input_item_name ORDER BY s.input_item_name)
        FILTER (WHERE NULLIF(btrim(s.input_item_name), '') IS NOT NULL),
      ARRAY[]::text[]
    ) AS input_item_names,
    count(*) FILTER (WHERE s.age_at_spawn_days IS NOT NULL)::bigint AS valid_age_count,
    min(s.age_at_spawn_days) AS min_age_days,
    round(avg(s.age_at_spawn_days)::numeric, 3) AS avg_age_days,
    max(s.age_at_spawn_days) AS max_age_days,
    COALESCE(bool_or(s.age_at_spawn_days < 0), false) AS has_negative_age
  FROM substrate_edges s
  GROUP BY s.lot_nocopk
),
cohort_base AS (
  SELECT
    l.*,
    COALESCE(g.input_count, 0)::bigint AS cohort_grain_input_count,
    COALESCE(g.input_item_names, ARRAY[]::text[]) AS cohort_grain_input_item_names,
    COALESCE(g.valid_age_count, 0)::bigint AS cohort_grain_age_at_spawn_valid_count,
    g.min_age_days AS cohort_grain_age_at_spawn_days_min,
    g.avg_age_days AS cohort_grain_age_at_spawn_days_avg,
    g.max_age_days AS cohort_grain_age_at_spawn_days_max,
    COALESCE(s.input_count, 0)::bigint AS cohort_substrate_input_count,
    COALESCE(s.input_item_names, ARRAY[]::text[]) AS cohort_substrate_input_item_names,
    COALESCE(s.valid_age_count, 0)::bigint AS cohort_substrate_age_at_spawn_valid_count,
    s.min_age_days AS cohort_substrate_age_at_spawn_days_min,
    s.avg_age_days AS cohort_substrate_age_at_spawn_days_avg,
    s.max_age_days AS cohort_substrate_age_at_spawn_days_max,
    (
      l.contaminated_at IS NOT NULL
      OR lower(COALESCE(l.terminal_reason, '')) = 'contaminated'
    ) AS cohort_is_contaminated,
    (l.harvest_event_count > 0) AS cohort_is_harvested,
    (l.terminal_at IS NOT NULL OR l.terminal_reason IS NOT NULL) AS cohort_is_terminal,
    CASE
      WHEN l.spawned_at IS NOT NULL AND l.contaminated_at IS NOT NULL
        THEN round((extract(epoch FROM (l.contaminated_at - l.spawned_at)) / 86400.0)::numeric, 3)
      ELSE NULL
    END AS days_spawn_to_contamination,
    CASE
      WHEN l.lifecycle_start_at IS NOT NULL AND l.contaminated_at IS NOT NULL
        THEN round((extract(epoch FROM (l.contaminated_at - l.lifecycle_start_at)) / 86400.0)::numeric, 3)
      ELSE NULL
    END AS days_lifecycle_start_to_contamination,
    COALESCE(g.has_negative_age, false) AS cohort_has_negative_grain_age,
    COALESCE(s.has_negative_age, false) AS cohort_has_negative_substrate_age
  FROM public.v_reporting_lot_lifecycle l
  LEFT JOIN grain_rollup g
    ON g.lot_nocopk = l.lot_nocopk
  LEFT JOIN substrate_rollup s
    ON s.lot_nocopk = l.lot_nocopk
)
SELECT
  c.*,
  ARRAY(
    SELECT DISTINCT q.flag
    FROM unnest(
      COALESCE(c.quality_flags, ARRAY[]::text[])
      || ARRAY_REMOVE(ARRAY[
        CASE WHEN c.cohort_has_negative_grain_age THEN 'negative_grain_age_at_spawn' END,
        CASE WHEN c.cohort_has_negative_substrate_age THEN 'negative_substrate_age_at_spawn' END,
        CASE
          WHEN c.days_spawn_to_contamination IS NOT NULL
           AND c.days_spawn_to_contamination < 0
            THEN 'negative_spawn_to_contamination_duration'
        END,
        CASE
          WHEN c.days_lifecycle_start_to_contamination IS NOT NULL
           AND c.days_lifecycle_start_to_contamination < 0
            THEN 'negative_lifecycle_start_to_contamination_duration'
        END
      ], NULL)::text[]
    ) AS q(flag)
    ORDER BY q.flag
  )::text[] AS cohort_quality_flags
FROM cohort_base c;

COMMENT ON VIEW public.v_reporting_cohort_lifecycle IS
  'Issue #87 Phase 5 canonical one-row-per-lot cohort fact view. Extends lifecycle reporting with exact grain/substrate cohort dimensions, age-at-spawn measures, outcome flags, and cohort quality flags.';

/*
 * Selector source for Phase 6.  Grain/substrate values are emitted one item at
 * a time from explicit relationship data; array rendering is never used as a
 * selector value.
 */
CREATE OR REPLACE VIEW public.v_reporting_cohort_dimension_options AS
WITH raw_options AS (
  SELECT c.lot_nocopk, 'item_category'::text AS dimension, c.item_category AS value
  FROM public.v_reporting_cohort_lifecycle c

  UNION ALL

  SELECT c.lot_nocopk, 'item'::text, c.item_name
  FROM public.v_reporting_cohort_lifecycle c

  UNION ALL

  SELECT c.lot_nocopk, 'strain'::text, c.species_strain
  FROM public.v_reporting_cohort_lifecycle c

  UNION ALL

  SELECT c.lot_nocopk, 'recipe'::text, c.recipe_name
  FROM public.v_reporting_cohort_lifecycle c

  UNION ALL

  SELECT c.lot_nocopk, 'grain_item'::text, grain_item.value
  FROM public.v_reporting_cohort_lifecycle c
  CROSS JOIN LATERAL unnest(c.cohort_grain_input_item_names) AS grain_item(value)

  UNION ALL

  SELECT c.lot_nocopk, 'substrate_item'::text, substrate_item.value
  FROM public.v_reporting_cohort_lifecycle c
  CROSS JOIN LATERAL unnest(c.cohort_substrate_input_item_names) AS substrate_item(value)

  UNION ALL

  SELECT c.lot_nocopk, 'data_origin'::text, c.data_origin
  FROM public.v_reporting_cohort_lifecycle c
),
normalized AS (
  SELECT
    r.lot_nocopk,
    r.dimension,
    btrim(r.value) AS value,
    lower(btrim(r.value)) AS value_key
  FROM raw_options r
  WHERE NULLIF(btrim(r.value), '') IS NOT NULL
)
SELECT
  n.dimension,
  min(n.value) AS value,
  count(DISTINCT n.lot_nocopk)::bigint AS lot_count
FROM normalized n
GROUP BY n.dimension, n.value_key
ORDER BY n.dimension, min(n.value);

COMMENT ON VIEW public.v_reporting_cohort_dimension_options IS
  'Issue #87 Phase 5 normalized selector options for cohort Reporting. Grain/substrate options are individual exact relationship values, not text[] renderings.';

/*
 * Resolve the timestamp used for cohort membership.  Date ranges use an
 * inclusive lower bound and exclusive upper bound in mp_reporting_cohort().
 */
CREATE OR REPLACE FUNCTION public.mp_reporting_cohort_basis_at(
  p_date_basis text,
  p_record_created_at timestamp without time zone,
  p_lifecycle_start_at timestamp without time zone,
  p_received_at timestamp without time zone,
  p_processed_at timestamp without time zone,
  p_inoculated_at timestamp without time zone,
  p_fully_colonized_at timestamp without time zone,
  p_spawned_at timestamp without time zone,
  p_fruiting_start_at timestamp without time zone,
  p_first_harvest_at timestamp without time zone,
  p_last_harvest_at timestamp without time zone,
  p_contaminated_at timestamp without time zone,
  p_terminal_at timestamp without time zone
)
RETURNS timestamp without time zone
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_basis text := lower(COALESCE(NULLIF(btrim(p_date_basis), ''), 'lifecycle_start'));
BEGIN
  CASE v_basis
    WHEN 'record_created' THEN RETURN p_record_created_at;
    WHEN 'lifecycle_start' THEN RETURN p_lifecycle_start_at;
    WHEN 'received' THEN RETURN p_received_at;
    WHEN 'processed' THEN RETURN p_processed_at;
    WHEN 'inoculated' THEN RETURN p_inoculated_at;
    WHEN 'fully_colonized' THEN RETURN p_fully_colonized_at;
    WHEN 'spawned' THEN RETURN p_spawned_at;
    WHEN 'fruiting_start' THEN RETURN p_fruiting_start_at;
    WHEN 'first_harvest' THEN RETURN p_first_harvest_at;
    WHEN 'last_harvest' THEN RETURN p_last_harvest_at;
    WHEN 'contaminated' THEN RETURN p_contaminated_at;
    WHEN 'terminal' THEN RETURN p_terminal_at;
    ELSE
      RAISE EXCEPTION 'Unsupported Reporting cohort date basis: %', p_date_basis
        USING ERRCODE = '22023';
  END CASE;
END;
$$;

COMMENT ON FUNCTION public.mp_reporting_cohort_basis_at(
  text,
  timestamp without time zone,
  timestamp without time zone,
  timestamp without time zone,
  timestamp without time zone,
  timestamp without time zone,
  timestamp without time zone,
  timestamp without time zone,
  timestamp without time zone,
  timestamp without time zone,
  timestamp without time zone,
  timestamp without time zone,
  timestamp without time zone
) IS
  'Issue #87 Phase 5 cohort date-basis resolver. Rejects unsupported basis names instead of silently changing cohort membership.';

/*
 * Canonical cohort membership function.  Every Phase 6 metric/chart/table is
 * expected to derive its population from this function using the same parameter
 * set.  Blank text parameters are treated as unfiltered.  String dimensions use
 * exact case-insensitive equality; grain/substrate filters test exact individual
 * relationship values rather than substring matches against arrays.
 */
CREATE OR REPLACE FUNCTION public.mp_reporting_cohort(
  p_date_basis text DEFAULT 'lifecycle_start',
  p_start_at timestamp without time zone DEFAULT NULL,
  p_end_at timestamp without time zone DEFAULT NULL,
  p_item_category text DEFAULT NULL,
  p_item_name text DEFAULT NULL,
  p_strain text DEFAULT NULL,
  p_grain_item text DEFAULT NULL,
  p_substrate_item text DEFAULT NULL,
  p_recipe text DEFAULT NULL,
  p_regulated boolean DEFAULT NULL,
  p_data_origin text DEFAULT NULL
)
RETURNS SETOF public.v_reporting_cohort_lifecycle
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_basis text := lower(COALESCE(NULLIF(btrim(p_date_basis), ''), 'lifecycle_start'));
  v_item_category text := NULLIF(btrim(p_item_category), '');
  v_item_name text := NULLIF(btrim(p_item_name), '');
  v_strain text := NULLIF(btrim(p_strain), '');
  v_grain_item text := NULLIF(btrim(p_grain_item), '');
  v_substrate_item text := NULLIF(btrim(p_substrate_item), '');
  v_recipe text := NULLIF(btrim(p_recipe), '');
  v_data_origin text := NULLIF(btrim(p_data_origin), '');
BEGIN
  IF p_start_at IS NOT NULL AND p_end_at IS NOT NULL AND p_end_at <= p_start_at THEN
    RAISE EXCEPTION 'Reporting cohort end timestamp (%) must be after start timestamp (%)', p_end_at, p_start_at
      USING ERRCODE = '22023';
  END IF;

  -- Validate once even when the underlying view is empty.
  PERFORM public.mp_reporting_cohort_basis_at(
    v_basis,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
  );

  RETURN QUERY
  SELECT c.*
  FROM public.v_reporting_cohort_lifecycle c
  WHERE
    (
      p_start_at IS NULL
      OR public.mp_reporting_cohort_basis_at(
        v_basis,
        c.record_created_at,
        c.lifecycle_start_at,
        c.received_at,
        c.processed_at,
        c.inoculated_at,
        c.fully_colonized_at,
        c.spawned_at,
        c.fruiting_start_at,
        c.first_harvest_at,
        c.last_harvest_at,
        c.contaminated_at,
        c.terminal_at
      ) >= p_start_at
    )
    AND (
      p_end_at IS NULL
      OR public.mp_reporting_cohort_basis_at(
        v_basis,
        c.record_created_at,
        c.lifecycle_start_at,
        c.received_at,
        c.processed_at,
        c.inoculated_at,
        c.fully_colonized_at,
        c.spawned_at,
        c.fruiting_start_at,
        c.first_harvest_at,
        c.last_harvest_at,
        c.contaminated_at,
        c.terminal_at
      ) < p_end_at
    )
    AND (
      v_item_category IS NULL
      OR lower(btrim(COALESCE(c.item_category, ''))) = lower(v_item_category)
    )
    AND (
      v_item_name IS NULL
      OR lower(btrim(COALESCE(c.item_name, ''))) = lower(v_item_name)
    )
    AND (
      v_strain IS NULL
      OR lower(btrim(COALESCE(c.species_strain, ''))) = lower(v_strain)
    )
    AND (
      v_grain_item IS NULL
      OR EXISTS (
        SELECT 1
        FROM unnest(c.cohort_grain_input_item_names) AS grain_item(value)
        WHERE lower(btrim(grain_item.value)) = lower(v_grain_item)
      )
    )
    AND (
      v_substrate_item IS NULL
      OR EXISTS (
        SELECT 1
        FROM unnest(c.cohort_substrate_input_item_names) AS substrate_item(value)
        WHERE lower(btrim(substrate_item.value)) = lower(v_substrate_item)
      )
    )
    AND (
      v_recipe IS NULL
      OR lower(btrim(COALESCE(c.recipe_name, ''))) = lower(v_recipe)
    )
    AND (p_regulated IS NULL OR COALESCE(c.strain_regulated, false) = p_regulated)
    AND (
      v_data_origin IS NULL
      OR lower(btrim(COALESCE(c.data_origin, ''))) = lower(v_data_origin)
    );
END;
$$;

COMMENT ON FUNCTION public.mp_reporting_cohort(
  text,
  timestamp without time zone,
  timestamp without time zone,
  text,
  text,
  text,
  text,
  text,
  text,
  boolean,
  text
) IS
  'Issue #87 Phase 5 canonical cohort-membership function. Applies one shared date-basis/category/item/strain/grain/substrate/recipe/regulation/origin filter contract for all cohort reports.';

COMMIT;
