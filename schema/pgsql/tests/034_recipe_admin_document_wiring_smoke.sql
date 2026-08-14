-- 034_recipe_admin_document_wiring_smoke.sql
-- Rollback-only coverage for Issue #79 expanded Recipe Ingredient writes.

BEGIN;
SET LOCAL client_min_messages TO NOTICE;
SET LOCAL search_path TO public;

DO $$
DECLARE
  v_recipe bigint;
  v_other_recipe bigint;
  v_ing bigint;
  v_parent bigint;
  v_child bigint;
  v_other_parent bigint;
  v_failed boolean;
BEGIN
  INSERT INTO recipes(recipe_id, active, name, category, nc_created_at, nc_updated_at)
  VALUES ('REC-TEST-ADMIN-DOC-79', true, 'Issue 79 admin document test', 'other', now(), now())
  RETURNING nocopk INTO v_recipe;

  INSERT INTO recipes(recipe_id, active, name, category, nc_created_at, nc_updated_at)
  VALUES ('REC-TEST-ADMIN-DOC-79-B', true, 'Issue 79 other recipe', 'other', now(), now())
  RETURNING nocopk INTO v_other_recipe;

  INSERT INTO ingredients(ingredient_id, active, name, category, default_unit)
  VALUES ('ING-TEST-ADMIN-DOC-79', true, 'Issue 79 test ingredient', 'other', 'mL')
  RETURNING nocopk INTO v_ing;

  SELECT x.nocopk INTO v_parent
  FROM mp_recipe_ingredient_document_admin_save(
    NULL, v_recipe, v_ing,
    390, 420,
    '390-420 mL total', 'mL', 'Example Vendor',
    'broth', NULL, false, 10, true, 'Parent mixture'
  ) x;

  IF NOT EXISTS (
    SELECT 1 FROM recipe_ingredients ri
    WHERE ri.nocopk = v_parent
      AND ri.amount = 390
      AND ri.amount_max = 420
      AND ri.quantity_text = '390-420 mL total'
      AND ri.alternative_group = 'broth'
      AND ri.optional = false
  ) THEN
    RAISE EXCEPTION 'Expanded Recipe Ingredient values did not persist.';
  END IF;

  SELECT x.nocopk INTO v_child
  FROM mp_recipe_ingredient_document_admin_save(
    NULL, v_recipe, v_ing,
    NULL, NULL,
    'Filtered water to final broth volume', 'mL', NULL,
    NULL, v_parent, true, 20, true, 'Nested qualitative quantity'
  ) x;

  IF NOT EXISTS (
    SELECT 1 FROM recipe_ingredients ri
    WHERE ri.nocopk = v_child
      AND ri.amount IS NULL
      AND ri.quantity_text = 'Filtered water to final broth volume'
      AND ri.parent_recipe_ingredient_id = v_parent
      AND ri.optional = true
  ) THEN
    RAISE EXCEPTION 'Nested/qualitative Recipe Ingredient values did not persist.';
  END IF;

  v_failed := false;
  BEGIN
    PERFORM * FROM mp_recipe_ingredient_document_admin_save(
      NULL, v_recipe, v_ing,
      10, 5, NULL, 'g', NULL,
      NULL, NULL, false, NULL, true, NULL
    );
  EXCEPTION WHEN OTHERS THEN
    v_failed := position('Maximum Amount cannot be less' in SQLERRM) > 0;
  END;
  IF NOT v_failed THEN
    RAISE EXCEPTION 'Expected lower Maximum Amount validation failure.';
  END IF;

  v_failed := false;
  BEGIN
    PERFORM * FROM mp_recipe_ingredient_document_admin_save(
      NULL, v_recipe, v_ing,
      NULL, NULL, NULL, 'mL', NULL,
      NULL, NULL, false, NULL, true, NULL
    );
  EXCEPTION WHEN OTHERS THEN
    v_failed := position('Amount or Quantity / Display Text' in SQLERRM) > 0;
  END;
  IF NOT v_failed THEN
    RAISE EXCEPTION 'Expected missing quantity validation failure.';
  END IF;

  SELECT x.nocopk INTO v_other_parent
  FROM mp_recipe_ingredient_document_admin_save(
    NULL, v_other_recipe, v_ing,
    1, NULL, NULL, 'g', NULL,
    NULL, NULL, false, 10, true, NULL
  ) x;

  v_failed := false;
  BEGIN
    PERFORM * FROM mp_recipe_ingredient_document_admin_save(
      v_child, v_recipe, v_ing,
      NULL, NULL, 'Still qualitative', 'mL', NULL,
      NULL, v_other_parent, false, 20, true, NULL
    );
  EXCEPTION WHEN OTHERS THEN
    v_failed := position('same Recipe' in SQLERRM) > 0;
  END;
  IF NOT v_failed THEN
    RAISE EXCEPTION 'Expected cross-Recipe parent validation failure.';
  END IF;

  RAISE NOTICE 'Issue #79 expanded recipe administration smoke tests passed.';
END
$$;

ROLLBACK;
