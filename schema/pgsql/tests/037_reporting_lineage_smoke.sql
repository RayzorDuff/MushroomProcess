-- 037_reporting_lineage_smoke.sql
-- Issue #87 Phase 4 read-only lineage validation.

BEGIN;
SET LOCAL search_path = public, pg_catalog;
SET LOCAL client_min_messages = NOTICE;

DO $$
DECLARE
  v_grain_links bigint;
  v_substrate_links bigint;
  v_product_links bigint;
  v_fixture_nocopk bigint;
  v_fixture_grain bigint;
  v_fixture_substrate bigint;
BEGIN
  IF to_regclass('public.v_reporting_lot_lineage') IS NULL THEN
    RAISE EXCEPTION 'v_reporting_lot_lineage is not installed';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.v_reporting_lot_lineage
    WHERE direction NOT IN ('upstream', 'downstream')
       OR related_entity_type NOT IN ('lot', 'product')
  ) THEN
    RAISE EXCEPTION 'Lineage view contains an invalid direction/entity type';
  END IF;

  SELECT count(DISTINCT (j.lots_id, j.lots1_id)) INTO v_grain_links
  FROM public._m2m_lots_lots_grain_inputs j
  WHERE j.lots1_id <> j.lots_id;

  IF (
    SELECT count(*)
    FROM public.v_reporting_lot_lineage
    WHERE relationship_type = 'grain_input'
      AND related_entity_type = 'lot'
  ) <> v_grain_links * 2 THEN
    RAISE EXCEPTION 'Every non-self grain-input edge must be visible in both directions';
  END IF;

  SELECT count(DISTINCT (j.lots_id, j.lots1_id)) INTO v_substrate_links
  FROM public._m2m_lots_lots_substrate_inputs j
  WHERE j.lots1_id <> j.lots_id;

  IF (
    SELECT count(*)
    FROM public.v_reporting_lot_lineage
    WHERE relationship_type = 'substrate_input'
      AND related_entity_type = 'lot'
  ) <> v_substrate_links * 2 THEN
    RAISE EXCEPTION 'Every non-self substrate-input edge must be visible in both directions';
  END IF;

  SELECT count(DISTINCT (j.products_id, j.lots_id)) INTO v_product_links
  FROM public._m2m_products_lots_origin_lots j;

  IF (
    SELECT count(*)
    FROM public.v_reporting_lot_lineage
    WHERE relationship_type = 'origin_product'
      AND related_entity_type = 'product'
  ) <> v_product_links THEN
    RAISE EXCEPTION 'Every product origin-lot link must be visible downstream';
  END IF;

  -- Historical fixture from the v1.1.0 migration dataset, when present.
  SELECT nocopk INTO v_fixture_nocopk
  FROM public.lots
  WHERE lot_id = 'LOT-260527-ivas';

  IF v_fixture_nocopk IS NOT NULL THEN
    SELECT nocopk INTO v_fixture_grain
    FROM public.lots
    WHERE lot_id = 'LOT-260324-K0Bj';

    SELECT nocopk INTO v_fixture_substrate
    FROM public.lots
    WHERE lot_id = 'LOT-260525-pxJB';

    IF NOT EXISTS (
      SELECT 1
      FROM public.v_reporting_lot_lineage
      WHERE lot_nocopk = v_fixture_nocopk
        AND direction = 'upstream'
        AND relationship_type = 'grain_input'
        AND related_nocopk = v_fixture_grain
        AND related_id = 'LOT-260324-K0Bj'
        AND related_item_name = 'Wild Bird Seed'
        AND related_inoculated_at IS NOT NULL
        AND input_age_at_use_days > 0
    ) THEN
      RAISE EXCEPTION 'Historical fixture source-grain lineage is missing or incomplete';
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM public.v_reporting_lot_lineage
      WHERE lot_nocopk = v_fixture_nocopk
        AND direction = 'upstream'
        AND relationship_type = 'substrate_input'
        AND related_nocopk = v_fixture_substrate
        AND related_id = 'LOT-260525-pxJB'
        AND related_item_name = 'Coco Verm Gypsum'
    ) THEN
      RAISE EXCEPTION 'Historical fixture source-substrate lineage is missing';
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM public.v_reporting_lot_lineage
      WHERE lot_nocopk = v_fixture_grain
        AND direction = 'downstream'
        AND relationship_type = 'grain_input'
        AND related_nocopk = v_fixture_nocopk
        AND related_id = 'LOT-260527-ivas'
        AND related_days_spawn_to_fruiting IS NOT NULL
        AND related_days_in_fruiting IS NOT NULL
        AND related_flush_count = 1
        AND related_total_harvest_g = 277.14
        AND related_terminal_reason = 'Contaminated'
    ) THEN
      RAISE EXCEPTION 'Historical fixture downstream fruiting-block outcome is missing';
    END IF;

    IF (
      SELECT count(*)
      FROM public.v_reporting_lot_lineage
      WHERE lot_nocopk = v_fixture_nocopk
        AND relationship_type = 'origin_product'
        AND related_entity_type = 'product'
    ) < 1 THEN
      RAISE EXCEPTION 'Historical fixture should expose at least one resulting product';
    END IF;
  END IF;

  RAISE NOTICE 'Issue #87 Phase 4 lineage reporting view smoke tests passed.';
END
$$;

ROLLBACK;
