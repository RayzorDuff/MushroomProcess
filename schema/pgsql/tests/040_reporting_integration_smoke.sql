-- 040_reporting_integration_smoke.sql
-- Issue #87 Phase 8: final read-only integration validation across all
-- Reporting data layers.  This test creates only transaction-local temporary
-- snapshots and always rolls them back.

BEGIN;
SET LOCAL search_path = public, pg_catalog;
SET LOCAL statement_timeout = '120s';
SET LOCAL lock_timeout = '5s';

DO $$
DECLARE
  missing text[] := ARRAY[]::text[];
  rel text;
BEGIN
  FOREACH rel IN ARRAY ARRAY[
    'public.v_reporting_lot_lifecycle',
    'public.v_reporting_lot_lineage',
    'public.v_reporting_cohort_lifecycle',
    'public.v_reporting_cohort_dimension_options',
    'public.v_reporting_product_inventory',
    'public.v_reporting_lot_inventory'
  ] LOOP
    IF to_regclass(rel) IS NULL THEN
      missing := array_append(missing, rel);
    END IF;
  END LOOP;

  IF to_regprocedure('public.mp_reporting_cohort(text,timestamp without time zone,timestamp without time zone,text,text,text,text,text,text,boolean,text)') IS NULL THEN
    missing := array_append(missing, 'public.mp_reporting_cohort(...)');
  END IF;

  IF to_regprocedure('public.mp_reporting_product_inventory(date,integer,text,text,text,text,text,text)') IS NULL THEN
    missing := array_append(missing, 'public.mp_reporting_product_inventory(...)');
  END IF;

  IF cardinality(missing) > 0 THEN
    RAISE EXCEPTION 'Issue #87 Reporting prerequisites missing: %', array_to_string(missing, ', ');
  END IF;

  RAISE NOTICE 'Phase 8 Reporting integration: prerequisites present; materializing reporting snapshots...';
END;
$$;

CREATE TEMP TABLE _reporting_lifecycle ON COMMIT DROP AS
SELECT * FROM public.v_reporting_lot_lifecycle;
CREATE UNIQUE INDEX _reporting_lifecycle_nocopk_idx ON _reporting_lifecycle(lot_nocopk);
CREATE INDEX _reporting_lifecycle_lot_id_idx ON _reporting_lifecycle(lot_id);
ANALYZE _reporting_lifecycle;

CREATE TEMP TABLE _reporting_cohort ON COMMIT DROP AS
SELECT * FROM public.v_reporting_cohort_lifecycle;
CREATE UNIQUE INDEX _reporting_cohort_nocopk_idx ON _reporting_cohort(lot_nocopk);
ANALYZE _reporting_cohort;

CREATE TEMP TABLE _reporting_product_inventory ON COMMIT DROP AS
SELECT * FROM public.v_reporting_product_inventory;
CREATE UNIQUE INDEX _reporting_product_nocopk_idx ON _reporting_product_inventory(product_nocopk);
ANALYZE _reporting_product_inventory;

CREATE TEMP TABLE _reporting_lot_inventory ON COMMIT DROP AS
SELECT * FROM public.v_reporting_lot_inventory;
CREATE UNIQUE INDEX _reporting_lot_inventory_nocopk_idx ON _reporting_lot_inventory(lot_nocopk);
ANALYZE _reporting_lot_inventory;

DO $$
DECLARE
  source_lots bigint;
  lifecycle_lots bigint;
  cohort_lots bigint;
  cohort_function_lots bigint;
  lot_inventory_lots bigint;
  source_products bigint;
  product_rows bigint;
  product_function_rows bigint;
  active_products bigint;
  terminal_products bigint;
  fixture_nocopk bigint;
  fixture_flushes bigint;
  fixture_yield numeric;
  fixture_grain bigint;
  fixture_substrate bigint;
  fixture_products bigint;
BEGIN
  SELECT count(*) INTO source_lots FROM public.lots;
  SELECT count(*) INTO lifecycle_lots FROM _reporting_lifecycle;
  SELECT count(*) INTO cohort_lots FROM _reporting_cohort;
  SELECT count(*) INTO lot_inventory_lots FROM _reporting_lot_inventory;

  IF lifecycle_lots <> source_lots THEN
    RAISE EXCEPTION 'Lifecycle cardinality mismatch: lots %, lifecycle %', source_lots, lifecycle_lots;
  END IF;

  IF cohort_lots <> source_lots THEN
    RAISE EXCEPTION 'Cohort cardinality mismatch: lots %, cohort %', source_lots, cohort_lots;
  END IF;

  IF lot_inventory_lots <> source_lots THEN
    RAISE EXCEPTION 'Lot inventory cardinality mismatch: lots %, inventory %', source_lots, lot_inventory_lots;
  END IF;

  IF EXISTS (
    SELECT 1 FROM _reporting_lifecycle GROUP BY lot_nocopk HAVING count(*) <> 1
  ) THEN
    RAISE EXCEPTION 'Lifecycle view is not one row per lot';
  END IF;

  IF EXISTS (
    SELECT 1 FROM _reporting_cohort GROUP BY lot_nocopk HAVING count(*) <> 1
  ) THEN
    RAISE EXCEPTION 'Cohort fact view is not one row per lot';
  END IF;

  SELECT count(*) INTO cohort_function_lots
  FROM public.mp_reporting_cohort();

  IF cohort_function_lots <> cohort_lots THEN
    RAISE EXCEPTION 'Unfiltered cohort function mismatch: function %, fact view %', cohort_function_lots, cohort_lots;
  END IF;

  RAISE NOTICE 'Phase 8 Reporting integration: lot lifecycle/cohort/in-process cardinality passed (% lots).', source_lots;

  SELECT count(*) INTO source_products FROM public.products;
  SELECT count(*) INTO product_rows FROM _reporting_product_inventory;
  SELECT count(*) FILTER (WHERE active_inventory), count(*) FILTER (WHERE NOT active_inventory)
    INTO active_products, terminal_products
  FROM _reporting_product_inventory;

  IF product_rows <> source_products THEN
    RAISE EXCEPTION 'Product inventory cardinality mismatch: products %, reporting %', source_products, product_rows;
  END IF;

  IF active_products + terminal_products <> source_products THEN
    RAISE EXCEPTION 'Product active/terminal partition mismatch: active %, terminal %, total %', active_products, terminal_products, source_products;
  END IF;

  SELECT count(*) INTO product_function_rows
  FROM public.mp_reporting_product_inventory(p_scope => 'all');

  IF product_function_rows <> source_products THEN
    RAISE EXCEPTION 'Unfiltered Product inventory function mismatch: function %, products %', product_function_rows, source_products;
  END IF;

  RAISE NOTICE 'Phase 8 Reporting integration: Product inventory cardinality passed (% products; % active; % terminal).',
    source_products, active_products, terminal_products;

  /*
   * Cross-layer historical fixture.  It is optional so a clean database can
   * still run the integration test, but when the migrated production fixture
   * is present all established Phase 2/4/5 relationships must remain coherent.
   */
  SELECT lot_nocopk, flush_count, total_harvest_g
    INTO fixture_nocopk, fixture_flushes, fixture_yield
  FROM _reporting_lifecycle
  WHERE lot_id = 'LOT-260527-ivas';

  IF fixture_nocopk IS NOT NULL THEN
    IF fixture_flushes <> 1 OR fixture_yield IS DISTINCT FROM 277.14::numeric THEN
      RAISE EXCEPTION 'Historical fixture Harvest contract drifted: flushes %, yield %', fixture_flushes, fixture_yield;
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM _reporting_cohort
      WHERE lot_nocopk = fixture_nocopk
        AND cohort_is_contaminated
        AND cohort_grain_age_at_spawn_days_avg IS NOT NULL
        AND days_spawn_to_fruiting IS NOT NULL
    ) THEN
      RAISE EXCEPTION 'Historical fixture is missing expected cohort facts';
    END IF;

    SELECT count(*) FILTER (WHERE relationship_type = 'grain_input' AND direction = 'upstream'),
           count(*) FILTER (WHERE relationship_type = 'substrate_input' AND direction = 'upstream'),
           count(*) FILTER (WHERE relationship_type = 'origin_product' AND direction = 'downstream')
      INTO fixture_grain, fixture_substrate, fixture_products
    FROM public.v_reporting_lot_lineage
    WHERE lot_nocopk = fixture_nocopk;

    IF fixture_grain < 1 THEN
      RAISE EXCEPTION 'Historical fixture lost its source-grain lineage';
    END IF;
    IF fixture_substrate < 1 THEN
      RAISE EXCEPTION 'Historical fixture lost its source-substrate lineage';
    END IF;
    IF fixture_products < 1 THEN
      RAISE EXCEPTION 'Historical fixture lost resulting-product lineage';
    END IF;

    RAISE NOTICE 'Phase 8 Reporting integration: historical lifecycle/lineage/cohort fixture passed.';
  ELSE
    RAISE NOTICE 'Phase 8 Reporting integration: historical fixture LOT-260527-ivas is absent; fixture-specific checks skipped.';
  END IF;

  RAISE NOTICE 'Issue #87 Phase 8 Reporting integration smoke tests passed (% lots; % products).', source_lots, source_products;
END;
$$;

ROLLBACK;
