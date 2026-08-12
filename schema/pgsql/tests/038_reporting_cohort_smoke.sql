-- 038_reporting_cohort_smoke.sql
-- Issue #87 Phase 5 read-only cohort data-layer validation.

BEGIN;
SET LOCAL search_path = public, pg_catalog;
SET LOCAL client_min_messages = NOTICE;

DO $$
DECLARE
  v_lot_count bigint;
  v_view_count bigint;
  v_default_cohort_count bigint;
  v_expected_grain_options bigint;
  v_expected_substrate_options bigint;
  v_fixture_nocopk bigint;
  v_invalid_basis_rejected boolean := false;
  v_invalid_range_rejected boolean := false;
BEGIN
  IF to_regclass('public.v_reporting_cohort_lifecycle') IS NULL THEN
    RAISE EXCEPTION 'v_reporting_cohort_lifecycle is not installed';
  END IF;

  IF to_regclass('public.v_reporting_cohort_dimension_options') IS NULL THEN
    RAISE EXCEPTION 'v_reporting_cohort_dimension_options is not installed';
  END IF;

  IF to_regprocedure('public.mp_reporting_cohort(text,timestamp without time zone,timestamp without time zone,text,text,text,text,text,text,boolean,text)') IS NULL THEN
    RAISE EXCEPTION 'mp_reporting_cohort(...) is not installed';
  END IF;

  SELECT count(*) INTO v_lot_count FROM public.lots;
  SELECT count(*) INTO v_view_count FROM public.v_reporting_cohort_lifecycle;

  IF v_view_count <> v_lot_count THEN
    RAISE EXCEPTION 'Cohort fact view must contain exactly one row per lot (% view rows, % lots)', v_view_count, v_lot_count;
  END IF;

  SELECT count(*) INTO v_default_cohort_count
  FROM public.mp_reporting_cohort();

  IF v_default_cohort_count <> v_view_count THEN
    RAISE EXCEPTION 'Unfiltered canonical cohort must equal the cohort fact view (% function rows, % view rows)', v_default_cohort_count, v_view_count;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.v_reporting_cohort_lifecycle c
    WHERE c.cohort_grain_age_at_spawn_valid_count > c.cohort_grain_input_count
       OR c.cohort_substrate_age_at_spawn_valid_count > c.cohort_substrate_input_count
  ) THEN
    RAISE EXCEPTION 'Valid input-age counts cannot exceed explicit input relationship counts';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.v_reporting_cohort_lifecycle c
    WHERE (c.cohort_grain_age_at_spawn_valid_count > 0 AND c.cohort_grain_age_at_spawn_days_avg IS NULL)
       OR (c.cohort_substrate_age_at_spawn_valid_count > 0 AND c.cohort_substrate_age_at_spawn_days_avg IS NULL)
  ) THEN
    RAISE EXCEPTION 'Input-age average must be populated when at least one valid age exists';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.v_reporting_cohort_lifecycle c
    WHERE c.cohort_grain_input_count <> (
      SELECT count(DISTINCT j.lots1_id)
      FROM public._m2m_lots_lots_grain_inputs j
      WHERE j.lots_id = c.lot_nocopk
        AND j.lots1_id <> j.lots_id
    )
       OR c.cohort_substrate_input_count <> (
      SELECT count(DISTINCT j.lots1_id)
      FROM public._m2m_lots_lots_substrate_inputs j
      WHERE j.lots_id = c.lot_nocopk
        AND j.lots1_id <> j.lots_id
    )
  ) THEN
    RAISE EXCEPTION 'Cohort input counts must match the exact non-self M2M relationships';
  END IF;

  SELECT count(*) INTO v_expected_grain_options
  FROM (
    SELECT lower(btrim(g.value)) AS value_key
    FROM public.v_reporting_cohort_lifecycle c
    CROSS JOIN LATERAL unnest(c.cohort_grain_input_item_names) AS g(value)
    WHERE NULLIF(btrim(g.value), '') IS NOT NULL
    GROUP BY lower(btrim(g.value))
  ) x;

  IF (
    SELECT count(*)
    FROM public.v_reporting_cohort_dimension_options
    WHERE dimension = 'grain_item'
  ) <> v_expected_grain_options THEN
    RAISE EXCEPTION 'Grain selector options must contain one row per exact individual grain item';
  END IF;

  SELECT count(*) INTO v_expected_substrate_options
  FROM (
    SELECT lower(btrim(s.value)) AS value_key
    FROM public.v_reporting_cohort_lifecycle c
    CROSS JOIN LATERAL unnest(c.cohort_substrate_input_item_names) AS s(value)
    WHERE NULLIF(btrim(s.value), '') IS NOT NULL
    GROUP BY lower(btrim(s.value))
  ) x;

  IF (
    SELECT count(*)
    FROM public.v_reporting_cohort_dimension_options
    WHERE dimension = 'substrate_item'
  ) <> v_expected_substrate_options THEN
    RAISE EXCEPTION 'Substrate selector options must contain one row per exact individual substrate item';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.v_reporting_cohort_dimension_options
    WHERE dimension IN ('grain_item', 'substrate_item')
      AND (value LIKE '{%' OR value LIKE '%}%')
  ) THEN
    RAISE EXCEPTION 'Grain/substrate selector values must not be serialized PostgreSQL arrays';
  END IF;

  -- Exact grain/substrate filters must not return rows lacking the selected relationship value.
  IF EXISTS (
    SELECT 1
    FROM public.v_reporting_cohort_dimension_options o
    CROSS JOIN LATERAL public.mp_reporting_cohort(p_grain_item => o.value) c
    WHERE o.dimension = 'grain_item'
      AND NOT EXISTS (
        SELECT 1
        FROM unnest(c.cohort_grain_input_item_names) AS g(value)
        WHERE lower(btrim(g.value)) = lower(btrim(o.value))
      )
  ) THEN
    RAISE EXCEPTION 'Canonical grain filter returned a lot without the selected exact grain relationship';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.v_reporting_cohort_dimension_options o
    CROSS JOIN LATERAL public.mp_reporting_cohort(p_substrate_item => o.value) c
    WHERE o.dimension = 'substrate_item'
      AND NOT EXISTS (
        SELECT 1
        FROM unnest(c.cohort_substrate_input_item_names) AS s(value)
        WHERE lower(btrim(s.value)) = lower(btrim(o.value))
      )
  ) THEN
    RAISE EXCEPTION 'Canonical substrate filter returned a lot without the selected exact substrate relationship';
  END IF;

  BEGIN
    PERFORM count(*) FROM public.mp_reporting_cohort(p_date_basis => 'not-a-real-basis');
  EXCEPTION
    WHEN SQLSTATE '22023' THEN
      v_invalid_basis_rejected := true;
  END;

  IF NOT v_invalid_basis_rejected THEN
    RAISE EXCEPTION 'Unsupported cohort date basis should be rejected with SQLSTATE 22023';
  END IF;

  BEGIN
    PERFORM count(*)
    FROM public.mp_reporting_cohort(
      p_start_at => timestamp '2026-01-02 00:00:00',
      p_end_at => timestamp '2026-01-01 00:00:00'
    );
  EXCEPTION
    WHEN SQLSTATE '22023' THEN
      v_invalid_range_rejected := true;
  END;

  IF NOT v_invalid_range_rejected THEN
    RAISE EXCEPTION 'Cohort end timestamp at/before start should be rejected';
  END IF;

  -- Historical fixture from the v1.1.0 migration dataset, when present.
  SELECT nocopk INTO v_fixture_nocopk
  FROM public.lots
  WHERE lot_id = 'LOT-260527-ivas';

  IF v_fixture_nocopk IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.v_reporting_cohort_lifecycle c
      WHERE c.lot_nocopk = v_fixture_nocopk
        AND c.item_category = 'fruiting_block'
        AND c.species_strain = 'Malabar'
        AND 'Wild Bird Seed' = ANY(c.cohort_grain_input_item_names)
        AND 'Coco Verm Gypsum' = ANY(c.cohort_substrate_input_item_names)
        AND c.cohort_grain_age_at_spawn_valid_count = 1
        AND abs(c.cohort_grain_age_at_spawn_days_avg - 58.179) < 0.001
        AND c.cohort_substrate_age_at_spawn_valid_count = 1
        AND abs(c.cohort_substrate_age_at_spawn_days_avg - 2.130) < 0.001
        AND c.cohort_is_contaminated
        AND c.flush_count = 1
        AND c.total_harvest_g = 277.14
    ) THEN
      RAISE EXCEPTION 'Historical fixture cohort dimensions/outcomes are incomplete';
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM public.mp_reporting_cohort(
        p_date_basis => 'spawned',
        p_start_at => timestamp '2026-05-27 00:00:00',
        p_end_at => timestamp '2026-05-28 00:00:00',
        p_item_category => 'fruiting_block',
        p_item_name => 'Small CVG',
        p_strain => 'Malabar',
        p_grain_item => 'Wild Bird Seed',
        p_substrate_item => 'Coco Verm Gypsum',
        p_data_origin => 'airtable_migrated'
      ) c
      WHERE c.lot_nocopk = v_fixture_nocopk
    ) THEN
      RAISE EXCEPTION 'Historical fixture should belong to the combined exact cohort filter';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.mp_reporting_cohort(
        p_date_basis => 'spawned',
        p_start_at => timestamp '2026-05-28 00:00:00',
        p_end_at => timestamp '2026-05-29 00:00:00'
      ) c
      WHERE c.lot_nocopk = v_fixture_nocopk
    ) THEN
      RAISE EXCEPTION 'Historical fixture should be excluded when its selected date basis falls outside the range';
    END IF;
  END IF;

  RAISE NOTICE 'Issue #87 Phase 5 cohort reporting layer smoke tests passed (% lots).', v_view_count;
END
$$;

ROLLBACK;
