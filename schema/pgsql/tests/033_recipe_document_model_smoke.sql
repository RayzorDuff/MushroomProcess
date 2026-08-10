-- 033_recipe_document_model_smoke.sql
-- Rollback-only coverage for Issue #79 recipe document representation.

BEGIN;
SET LOCAL client_min_messages TO NOTICE;
SET LOCAL search_path TO public;

DO $$
DECLARE
  v_recipe bigint;
  v_ing bigint;
  v_parent bigint;
  v_child bigint;
  v_step bigint;
  v_failed boolean := false;
BEGIN
  INSERT INTO recipes(recipe_id, active, name, category, nc_created_at, nc_updated_at)
  VALUES ('REC-TEST-DOC-79', true, 'Issue 79 document test', 'other', now(), now())
  RETURNING nocopk INTO v_recipe;

  PERFORM * FROM mp_recipe_document_metadata_save(
    v_recipe,
    'Narrative description for generated documentation.',
    '6 x 8 oz jars'
  );

  IF NOT EXISTS (
    SELECT 1 FROM recipes
    WHERE nocopk = v_recipe
      AND description = 'Narrative description for generated documentation.'
      AND batch_yield_text = '6 x 8 oz jars'
  ) THEN
    RAISE EXCEPTION 'Recipe document metadata did not persist.';
  END IF;

  INSERT INTO ingredients(ingredient_id, active, name, category, default_unit)
  VALUES ('ING-TEST-DOC-79', true, 'Prepared Broth', 'other', 'mL')
  RETURNING nocopk INTO v_ing;

  INSERT INTO recipe_ingredients(
    recipe_ingredient_id, recipe_id, ingredient_id, amount, amount_max,
    unit, quantity_text, sort_order, active
  )
  VALUES (
    'RING-TEST-DOC-PARENT', v_recipe, v_ing, 390, 420,
    'mL', '390-420 mL total (65-70 mL per jar)', 1, true
  )
  RETURNING nocopk INTO v_parent;

  INSERT INTO recipe_ingredients(
    recipe_ingredient_id, recipe_id, ingredient_id, amount, unit,
    quantity_text, parent_recipe_ingredient_id, sort_order, active
  )
  VALUES (
    'RING-TEST-DOC-CHILD', v_recipe, v_ing, NULL, 'mL',
    'Filtered water to final broth volume', v_parent, 2, true
  )
  RETURNING nocopk INTO v_child;

  IF NOT EXISTS (
    SELECT 1 FROM recipe_ingredients
    WHERE nocopk = v_child
      AND amount IS NULL
      AND quantity_text = 'Filtered water to final broth volume'
      AND parent_recipe_ingredient_id = v_parent
  ) THEN
    RAISE EXCEPTION 'Qualitative/nested recipe ingredient representation failed.';
  END IF;

  BEGIN
    UPDATE recipe_ingredients SET amount_max = 100 WHERE nocopk = v_parent;
  EXCEPTION WHEN check_violation THEN
    v_failed := true;
  END;
  IF NOT v_failed THEN
    RAISE EXCEPTION 'Expected amount_max lower-than-amount validation failure.';
  END IF;

  SELECT s.nocopk INTO v_step
  FROM mp_recipe_step_admin_save(
    NULL, v_recipe, 'Preparation', 1, 1,
    'Mix ingredients thoroughly before processing.', true, NULL
  ) s;

  IF NOT EXISTS (
    SELECT 1 FROM recipe_steps
    WHERE nocopk = v_step
      AND recipe_id = v_recipe
      AND section = 'Preparation'
      AND step_order = 1
  ) THEN
    RAISE EXCEPTION 'Recipe step did not persist.';
  END IF;

  RAISE NOTICE 'Issue #79 recipe document model smoke tests passed.';
END
$$;

ROLLBACK;
