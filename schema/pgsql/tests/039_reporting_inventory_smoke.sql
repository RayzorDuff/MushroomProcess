-- 039_reporting_inventory_smoke.sql
-- Issue #87 Phase 7: rollback/read-only validation for inventory reporting.

BEGIN;
SET LOCAL client_min_messages = NOTICE;
SET LOCAL statement_timeout = '120s';
SET LOCAL lock_timeout = '5s';

DO $$
DECLARE
  v_products bigint;
  v_view_products bigint;
  v_active bigint;
  v_terminal bigint;
  v_migrated_products bigint;
  v_active_asof bigint;
  v_expired_asof bigint;
  v_expiring_asof bigint;
  v_current_asof bigint;
  v_unknown_expiry_asof bigint;
  v_unknown_location bigint;
  v_bad_dates bigint;
  v_active_lots bigint;
  v_stage_lots bigint;
  v_rejected boolean := false;
BEGIN
  IF to_regclass('public.v_reporting_product_inventory') IS NULL THEN
    RAISE EXCEPTION 'v_reporting_product_inventory is missing';
  END IF;
  IF to_regclass('public.v_reporting_lot_inventory') IS NULL THEN
    RAISE EXCEPTION 'v_reporting_lot_inventory is missing';
  END IF;

  SELECT count(*) INTO v_products FROM public.products;
  SELECT count(*) INTO v_view_products FROM public.v_reporting_product_inventory;
  IF v_view_products <> v_products THEN
    RAISE EXCEPTION 'Product inventory cardinality mismatch: view %, products %', v_view_products, v_products;
  END IF;

  SELECT
    count(*) FILTER (WHERE active_inventory),
    count(*) FILTER (WHERE NOT active_inventory)
  INTO v_active, v_terminal
  FROM public.v_reporting_product_inventory;
  IF v_active + v_terminal <> v_products THEN
    RAISE EXCEPTION 'Active/terminal inventory classification does not cover every product';
  END IF;

  -- Exact historical migration snapshot from the Phase 1 audit.  This remains
  -- valid even after PostgreSQL-native Products are added because the view
  -- preserves data_origin.
  SELECT count(*)
  INTO v_migrated_products
  FROM public.v_reporting_product_inventory
  WHERE data_origin = 'airtable_migrated';

  IF v_migrated_products = 1235 THEN
    SELECT
      count(*) FILTER (WHERE active_inventory),
      count(*) FILTER (WHERE active_inventory AND public.mp_reporting_inventory_expiration_status(use_by, date '2026-08-06', 30) = 'expired'),
      count(*) FILTER (WHERE active_inventory AND public.mp_reporting_inventory_expiration_status(use_by, date '2026-08-06', 30) = 'expiring'),
      count(*) FILTER (WHERE active_inventory AND public.mp_reporting_inventory_expiration_status(use_by, date '2026-08-06', 30) = 'current'),
      count(*) FILTER (WHERE active_inventory AND public.mp_reporting_inventory_expiration_status(use_by, date '2026-08-06', 30) = 'unknown'),
      count(*) FILTER (WHERE active_inventory AND location_unknown),
      count(*) FILTER (WHERE use_by_before_pack)
    INTO
      v_active_asof, v_expired_asof, v_expiring_asof, v_current_asof,
      v_unknown_expiry_asof, v_unknown_location, v_bad_dates
    FROM public.v_reporting_product_inventory
    WHERE data_origin = 'airtable_migrated';

    IF v_active_asof <> 687 THEN
      RAISE EXCEPTION 'Historical active Product count mismatch: expected 687, got %', v_active_asof;
    END IF;
    IF v_expired_asof <> 78 THEN
      RAISE EXCEPTION 'Historical active-expired Product count mismatch: expected 78, got %', v_expired_asof;
    END IF;
    IF v_expiring_asof <> 15 THEN
      RAISE EXCEPTION 'Historical active-expiring Product count mismatch: expected 15, got %', v_expiring_asof;
    END IF;
    IF v_current_asof <> 416 THEN
      RAISE EXCEPTION 'Historical active-current Product count mismatch: expected 416, got %', v_current_asof;
    END IF;
    IF v_unknown_expiry_asof <> 178 THEN
      RAISE EXCEPTION 'Historical active unknown-use-by Product count mismatch: expected 178, got %', v_unknown_expiry_asof;
    END IF;
    IF v_unknown_location <> 261 THEN
      RAISE EXCEPTION 'Historical active Unknown-location count mismatch: expected 261, got %', v_unknown_location;
    END IF;
    IF v_bad_dates <> 32 THEN
      RAISE EXCEPTION 'Historical use_by-before-pack count mismatch: expected 32, got %', v_bad_dates;
    END IF;
  END IF;

  -- Exact filters must agree with direct predicates for a representative value.
  IF EXISTS (
    SELECT 1
    FROM (
      SELECT item_name
      FROM public.v_reporting_product_inventory
      WHERE active_inventory AND NULLIF(btrim(item_name), '') IS NOT NULL
      ORDER BY item_name
      LIMIT 1
    ) sample
    WHERE (
      SELECT count(*)
      FROM public.mp_reporting_product_inventory(
        p_as_of => CURRENT_DATE,
        p_scope => 'active',
        p_item_name => sample.item_name
      )
    ) <> (
      SELECT count(*)
      FROM public.v_reporting_product_inventory v
      WHERE v.active_inventory
        AND lower(btrim(COALESCE(v.item_name, ''))) = lower(btrim(sample.item_name))
    )
  ) THEN
    RAISE EXCEPTION 'Exact item filtering differs from canonical active Product view';
  END IF;

  -- Invalid filter parameters fail explicitly rather than returning misleading
  -- empty inventory.
  BEGIN
    PERFORM * FROM public.mp_reporting_product_inventory(p_scope => 'nonsense') LIMIT 1;
  EXCEPTION WHEN SQLSTATE '22023' THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Invalid inventory scope was not rejected';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.mp_reporting_inventory_expiration_status(CURRENT_DATE, CURRENT_DATE, -1);
  EXCEPTION WHEN SQLSTATE '22023' THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Negative expiration horizon was not rejected';
  END IF;

  SELECT count(*) INTO v_active_lots
  FROM public.v_reporting_lot_inventory
  WHERE active_inventory;

  SELECT COALESCE(sum(lot_count), 0)
  INTO v_stage_lots
  FROM (
    SELECT inventory_stage, count(*)::bigint AS lot_count
    FROM public.v_reporting_lot_inventory
    WHERE active_inventory
    GROUP BY inventory_stage
  ) q;

  IF v_active_lots <> v_stage_lots THEN
    RAISE EXCEPTION 'Active lot stage rollup mismatch: active %, grouped %', v_active_lots, v_stage_lots;
  END IF;

  RAISE NOTICE 'Issue #87 Phase 7 inventory reporting smoke tests passed (% products; % active products; % active lots).',
    v_products, v_active, v_active_lots;
END;
$$;

ROLLBACK;
