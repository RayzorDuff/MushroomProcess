\set ON_ERROR_STOP on

BEGIN;
SET LOCAL statement_timeout = '30s';
SET LOCAL lock_timeout = '5s';

DO $test$
DECLARE
  v_base_count bigint;
  v_view_count bigint;
  v_duplicate_count bigint;
  v_sample record;
BEGIN
  IF to_regclass('public.v_reporting_lot_lifecycle') IS NULL THEN
    RAISE EXCEPTION 'Missing public.v_reporting_lot_lifecycle';
  END IF;

  IF to_regprocedure('public.mp_reporting_try_jsonb(text)') IS NULL THEN
    RAISE EXCEPTION 'Missing public.mp_reporting_try_jsonb(text)';
  END IF;

  IF to_regprocedure('public.mp_reporting_try_numeric(text)') IS NULL THEN
    RAISE EXCEPTION 'Missing public.mp_reporting_try_numeric(text)';
  END IF;

  SELECT count(*) INTO v_base_count FROM public.lots;
  SELECT count(*) INTO v_view_count FROM public.v_reporting_lot_lifecycle;
  IF v_base_count <> v_view_count THEN
    RAISE EXCEPTION 'Lifecycle view count % differs from lots count %', v_view_count, v_base_count;
  END IF;

  SELECT count(*)
  INTO v_duplicate_count
  FROM (
    SELECT lot_nocopk
    FROM public.v_reporting_lot_lifecycle
    GROUP BY lot_nocopk
    HAVING count(*) <> 1
  ) d;
  IF v_duplicate_count <> 0 THEN
    RAISE EXCEPTION 'Lifecycle view contains % duplicate lot rows', v_duplicate_count;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.v_reporting_lot_lifecycle
    WHERE processed_direct_at IS NOT NULL
      AND processed_at IS DISTINCT FROM processed_direct_at
  ) THEN
    RAISE EXCEPTION 'processed_at does not honor lots.sterilized_at precedence';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.v_reporting_lot_lifecycle
    WHERE inoculated_direct_at IS NOT NULL
      AND inoculated_at IS DISTINCT FROM inoculated_direct_at
  ) THEN
    RAISE EXCEPTION 'inoculated_at does not honor lots.inoculated_at precedence';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.v_reporting_lot_lifecycle
    WHERE spawned_direct_at IS NOT NULL
      AND spawned_at IS DISTINCT FROM spawned_direct_at
  ) THEN
    RAISE EXCEPTION 'spawned_at does not honor lots.spawned_at precedence';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.v_reporting_lot_lifecycle
    WHERE fruiting_start_direct_at IS NOT NULL
      AND fruiting_start_at IS DISTINCT FROM fruiting_start_direct_at
  ) THEN
    RAISE EXCEPTION 'fruiting_start_at does not honor lots.beganfruiting_at precedence';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.v_reporting_lot_lifecycle
    WHERE first_harvest_direct_at IS NOT NULL
      AND first_harvest_at IS DISTINCT FROM first_harvest_direct_at
  ) THEN
    RAISE EXCEPTION 'first_harvest_at does not honor lots.firstharvested_at precedence';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.v_reporting_lot_lifecycle
    WHERE last_harvest_direct_at IS NOT NULL
      AND last_harvest_at IS DISTINCT FROM last_harvest_direct_at
  ) THEN
    RAISE EXCEPTION 'last_harvest_at does not honor lots.lastharvested_at precedence';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.v_reporting_lot_lifecycle
    WHERE terminal_direct_at IS NOT NULL
      AND terminal_at IS DISTINCT FROM terminal_direct_at
  ) THEN
    RAISE EXCEPTION 'terminal_at does not honor lots.retired_at precedence';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.v_reporting_lot_lifecycle
    WHERE lifecycle_start_at IS NULL
      AND record_created_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'lifecycle_start_at failed to fall back to a non-null record_created_at';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.v_reporting_lot_lifecycle
    WHERE lifecycle_start_is_record_created_fallback
      AND lifecycle_start_source <> 'lots.created_at:fallback'
  ) THEN
    RAISE EXCEPTION 'Lifecycle-start fallback flag/source are inconsistent';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.v_reporting_lot_lifecycle
    WHERE data_origin NOT IN ('airtable_migrated', 'postgres_native')
  ) THEN
    RAISE EXCEPTION 'Unexpected lifecycle data_origin value';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.v_reporting_lot_lifecycle
    WHERE contaminated_at IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM public.events e
        WHERE e.lot_id = lot_nocopk
          AND lower(COALESCE(e.type, '')) = 'contaminated'
          AND e."timestamp" IS NOT NULL
      )
  ) THEN
    RAISE EXCEPTION 'contaminated_at was derived without a dated Contaminated event';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.v_reporting_lot_lifecycle v
    WHERE v.harvest_event_count <> (
      SELECT count(*)
      FROM public.events e
      WHERE e.lot_id = v.lot_nocopk
        AND lower(COALESCE(e.type, '')) = 'harvest'
    )
  ) THEN
    RAISE EXCEPTION 'harvest_event_count does not match source Harvest events';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.v_reporting_lot_lifecycle v
    WHERE v.grain_input_count <> (
      SELECT count(*)
      FROM public._m2m_lots_lots_grain_inputs j
      WHERE j.lots_id = v.lot_nocopk
    )
       OR v.substrate_input_count <> (
      SELECT count(*)
      FROM public._m2m_lots_lots_substrate_inputs j
      WHERE j.lots_id = v.lot_nocopk
    )
  ) THEN
    RAISE EXCEPTION 'Input relationship counts differ from canonical M2M lineage tables';
  END IF;

  /*
   * Historical v1.1.0 migration fixture.  This row is intentionally useful:
   * its SpawnedToBulk event is undated, while lots.spawned_at is populated;
   * fruiting, Harvest, and Contaminated dates survive as dated Events.
   * Skip the assertion when this exact migrated lot is absent from a database.
   */
  SELECT *
  INTO v_sample
  FROM public.v_reporting_lot_lifecycle
  WHERE lot_id = 'LOT-260527-ivas';

  IF FOUND THEN
    IF v_sample.data_origin <> 'airtable_migrated'
       OR v_sample.spawned_at IS DISTINCT FROM timestamp '2026-05-27 22:05:05.818'
       OR v_sample.spawned_at_source <> 'lots.spawned_at'
       OR v_sample.fruiting_start_at IS DISTINCT FROM timestamp '2026-06-10 21:48:51.511'
       OR v_sample.fruiting_start_at_source <> 'event:FruitingStart'
       OR v_sample.first_harvest_at IS DISTINCT FROM timestamp '2026-06-25 20:30:56.840'
       OR v_sample.first_harvest_at_source <> 'event:Harvest'
       OR v_sample.contaminated_at IS DISTINCT FROM timestamp '2026-07-14 20:14:51.880'
       OR v_sample.terminal_at IS DISTINCT FROM timestamp '2026-07-14 20:14:51.880'
       OR v_sample.harvest_event_count <> 1
       OR v_sample.flush_count <> 1
       OR v_sample.first_flush_g IS DISTINCT FROM 277.14::numeric
       OR v_sample.total_harvest_g IS DISTINCT FROM 277.14::numeric
       OR v_sample.grain_input_count < 1
       OR v_sample.substrate_input_count < 1 THEN
      RAISE EXCEPTION 'Historical lifecycle fallback fixture LOT-260527-ivas does not match the v1.1.0 migration contract';
    END IF;
  END IF;

  RAISE NOTICE 'Issue #87 Phase 2 lifecycle reporting view smoke tests passed (% lots).', v_view_count;
END
$test$;

ROLLBACK;
