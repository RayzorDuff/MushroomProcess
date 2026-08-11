\set ON_ERROR_STOP on

BEGIN;
SET LOCAL statement_timeout = '30s';
SET LOCAL lock_timeout = '5s';

DO $test$
DECLARE
  v_missing text[];
  v_base_count bigint;
  v_view_count bigint;
BEGIN
  SELECT array_agg(v.name ORDER BY v.name)
  INTO v_missing
  FROM (VALUES
    ('v_ingredients'),
    ('vc_ingredients'),
    ('v_recipe_ingredients'),
    ('vc_recipe_ingredients'),
    ('v_recipe_steps'),
    ('vc_recipe_steps'),
    ('v_qr_scan_log'),
    ('vc_qr_scan_log')
  ) AS v(name)
  WHERE to_regclass('public.' || v.name) IS NULL;

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'Missing PostgreSQL-native compatibility views: %', v_missing;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'v_recipes' AND column_name = 'description'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'v_recipes' AND column_name = 'batch_yield_text'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'vc_recipes' AND column_name = 'description'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'vc_recipes' AND column_name = 'batch_yield_text'
  ) THEN
    RAISE EXCEPTION 'v_recipes/vc_recipes do not expose migration 033 Recipe document fields';
  END IF;

  SELECT count(*) INTO v_base_count FROM public.ingredients;
  SELECT count(*) INTO v_view_count FROM public.vc_ingredients;
  IF v_base_count <> v_view_count THEN
    RAISE EXCEPTION 'vc_ingredients count % differs from ingredients count %', v_view_count, v_base_count;
  END IF;

  SELECT count(*) INTO v_base_count FROM public.recipe_ingredients;
  SELECT count(*) INTO v_view_count FROM public.vc_recipe_ingredients;
  IF v_base_count <> v_view_count THEN
    RAISE EXCEPTION 'vc_recipe_ingredients count % differs from recipe_ingredients count %', v_view_count, v_base_count;
  END IF;

  SELECT count(*) INTO v_base_count FROM public.recipe_steps;
  SELECT count(*) INTO v_view_count FROM public.vc_recipe_steps;
  IF v_base_count <> v_view_count THEN
    RAISE EXCEPTION 'vc_recipe_steps count % differs from recipe_steps count %', v_view_count, v_base_count;
  END IF;

  SELECT count(*) INTO v_base_count FROM public.qr_scan_log;
  SELECT count(*) INTO v_view_count FROM public.vc_qr_scan_log;
  IF v_base_count <> v_view_count THEN
    RAISE EXCEPTION 'vc_qr_scan_log count % differs from qr_scan_log count %', v_view_count, v_base_count;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.vc_recipe_ingredients
    WHERE recipe_code IS NULL OR ingredient_code IS NULL
  ) THEN
    RAISE EXCEPTION 'vc_recipe_ingredients failed to resolve Recipe/Ingredient display codes';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.vc_recipe_steps
    WHERE recipe_code IS NULL
  ) THEN
    RAISE EXCEPTION 'vc_recipe_steps failed to resolve Recipe display code';
  END IF;

  RAISE NOTICE 'PostgreSQL-native v_/vc_ view contract smoke tests passed for Issues #79 and #81.';
END
$test$;

ROLLBACK;
