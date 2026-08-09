-- 032_recipe_management_smoke.sql
-- Rollback-only smoke coverage for GitHub issue #79.

BEGIN;
SET LOCAL client_min_messages TO NOTICE;
SET LOCAL statement_timeout = '30s';

DO $$
DECLARE
  v_suffix text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  v_recipe_pk bigint;
  v_ingredient_pk bigint;
  v_recipe_ingredient_pk bigint;
  v_single_item_pk bigint;
  v_multi_item_pk bigint;
  v_none_item_pk bigint;
  v_single_component_pk bigint;
  v_multi_component_pk bigint;
  v_row record;
  v_failed boolean := false;
BEGIN
  IF to_regclass('public.ingredients') IS NULL THEN
    RAISE EXCEPTION 'ingredients table is missing';
  END IF;
  IF to_regclass('public.recipe_ingredients') IS NULL THEN
    RAISE EXCEPTION 'recipe_ingredients table is missing';
  END IF;

  SELECT r.nocopk
    INTO v_recipe_pk
  FROM public.mp_recipe_admin_save(
    NULL,
    'REC-ISSUE79-' || v_suffix,
    'Issue 79 smoke recipe',
    'substrate',
    true,
    'Issue 79 recipe smoke fixture'
  ) r;

  IF v_recipe_pk IS NULL THEN
    RAISE EXCEPTION 'mp_recipe_admin_save did not create a recipe';
  END IF;

  SELECT i.nocopk
    INTO v_ingredient_pk
  FROM public.mp_ingredient_admin_save(
    NULL,
    'ING-ISSUE79-' || v_suffix,
    'Issue 79 smoke ingredient',
    'bulk',
    'lb',
    'Smoke Vendor',
    true,
    'Issue 79 ingredient smoke fixture'
  ) i;

  IF v_ingredient_pk IS NULL THEN
    RAISE EXCEPTION 'mp_ingredient_admin_save did not create an ingredient';
  END IF;

  SELECT ri.nocopk
    INTO v_recipe_ingredient_pk
  FROM public.mp_recipe_ingredient_admin_save(
    NULL,
    v_recipe_pk,
    v_ingredient_pk,
    2.5,
    'lb',
    'Recipe Vendor',
    10,
    true,
    'Structured ingredient smoke fixture'
  ) ri;

  SELECT ri.amount, ri.unit, ri.vendor_name, ri.active
    INTO v_row
  FROM public.recipe_ingredients ri
  WHERE ri.nocopk = v_recipe_ingredient_pk;

  IF v_row.amount IS DISTINCT FROM 2.5::numeric
     OR v_row.unit IS DISTINCT FROM 'lb'
     OR v_row.vendor_name IS DISTINCT FROM 'Recipe Vendor'
     OR v_row.active IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Structured ingredient values were not stored correctly: %', row_to_json(v_row);
  END IF;

  PERFORM 1
  FROM public.mp_recipe_ingredient_admin_save(
    v_recipe_ingredient_pk,
    v_recipe_pk,
    v_ingredient_pk,
    3.0,
    'lb',
    'Updated Vendor',
    20,
    false,
    'Updated structured ingredient'
  );

  IF NOT EXISTS (
    SELECT 1
    FROM public.recipe_ingredients ri
    WHERE ri.nocopk = v_recipe_ingredient_pk
      AND ri.amount = 3.0
      AND ri.vendor_name = 'Updated Vendor'
      AND ri.sort_order = 20
      AND ri.active = false
  ) THEN
    RAISE EXCEPTION 'Structured ingredient update did not persist';
  END IF;

  INSERT INTO public.items(item_id, active, name, category, component_mode, size_source)
  VALUES ('ITEM-ISSUE79-N-' || v_suffix, true, 'Issue 79 none item', 'other', 'none', 'item_default')
  RETURNING nocopk INTO v_none_item_pk;

  v_failed := false;
  BEGIN
    PERFORM 1
    FROM public.mp_item_recipe_component_admin_save(
      NULL,
      v_none_item_pk,
      NULL,
      v_recipe_pk,
      'other',
      NULL,
      NULL,
      NULL,
      1,
      true,
      'component_mode none should fail'
    );
  EXCEPTION WHEN OTHERS THEN
    IF position('does not use recipe components' IN SQLERRM) > 0 THEN
      v_failed := true;
    ELSE
      RAISE;
    END IF;
  END;

  IF NOT v_failed THEN
    RAISE EXCEPTION 'component_mode=none item should reject Recipe Component saves';
  END IF;

  INSERT INTO public.items(item_id, active, name, category, component_mode, size_source)
  VALUES ('ITEM-ISSUE79-S-' || v_suffix, true, 'Issue 79 single item', 'grain', 'single_recipe', 'lot_unit_size')
  RETURNING nocopk INTO v_single_item_pk;

  SELECT c.nocopk
    INTO v_single_component_pk
  FROM public.mp_item_recipe_component_admin_save(
    NULL,
    v_single_item_pk,
    'SHOULD-BE-CLEARED',
    v_recipe_pk,
    'grain',
    NULL,
    NULL,
    NULL,
    1,
    true,
    'single recipe smoke component'
  ) c;

  IF EXISTS (
    SELECT 1
    FROM public.item_recipe_components c
    WHERE c.nocopk = v_single_component_pk
      AND NULLIF(btrim(COALESCE(c.component_set, '')), '') IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'single_recipe component_set should be normalized to NULL';
  END IF;

  INSERT INTO public.items(item_id, active, name, category, component_mode, size_source)
  VALUES ('ITEM-ISSUE79-M-' || v_suffix, true, 'Issue 79 multi item', 'all_in_one_bag', 'multi_recipe', 'component_sum')
  RETURNING nocopk INTO v_multi_item_pk;

  v_failed := false;
  BEGIN
    PERFORM 1
    FROM public.mp_item_recipe_component_admin_save(
      NULL,
      v_multi_item_pk,
      NULL,
      v_recipe_pk,
      'substrate',
      5,
      3,
      60,
      2,
      true,
      'missing component set should fail'
    );
  EXCEPTION WHEN OTHERS THEN
    IF position('Component Set is required' IN SQLERRM) > 0 THEN
      v_failed := true;
    ELSE
      RAISE;
    END IF;
  END;

  IF NOT v_failed THEN
    RAISE EXCEPTION 'multi_recipe save without component_set should have failed';
  END IF;

  SELECT c.nocopk
    INTO v_multi_component_pk
  FROM public.mp_item_recipe_component_admin_save(
    NULL,
    v_multi_item_pk,
    'WBS_CVG_TEST',
    v_recipe_pk,
    'substrate',
    5,
    3,
    60,
    2,
    true,
    'multi recipe smoke component'
  ) c;

  IF NOT EXISTS (
    SELECT 1
    FROM public.item_recipe_components c
    WHERE c.nocopk = v_multi_component_pk
      AND c.component_set = 'WBS_CVG_TEST'
      AND c.component_role = 'substrate'
      AND c.unit_size_lb = 5
      AND c.default_weight_lb = 3
      AND c.default_percent = 60
  ) THEN
    RAISE EXCEPTION 'multi_recipe component values were not stored correctly';
  END IF;

  v_failed := false;
  BEGIN
    PERFORM 1
    FROM public.mp_item_recipe_component_admin_save(
      NULL,
      v_multi_item_pk,
      'WBS_CVG_TEST',
      v_recipe_pk,
      'substrate',
      5,
      3,
      60,
      3,
      true,
      'duplicate active component should fail'
    );
  EXCEPTION WHEN OTHERS THEN
    IF position('An active component already exists' IN SQLERRM) > 0 THEN
      v_failed := true;
    ELSE
      RAISE;
    END IF;
  END;

  IF NOT v_failed THEN
    RAISE EXCEPTION 'duplicate active item component should have failed';
  END IF;

  -- The admin functions intentionally do not write production lot component
  -- history. That table remains available to the page only through read-only
  -- SELECT queries; operational lifecycle functions remain its writers.
  PERFORM 1 FROM public.lot_recipe_components LIMIT 1;

  RAISE NOTICE 'Issue #79 recipe management schema/function smoke tests passed.';
END $$;

ROLLBACK;
