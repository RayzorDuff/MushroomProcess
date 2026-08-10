-- 034_recipe_admin_document_wiring.sql
-- Complete Issue #79 administrative write support for the document-oriented
-- recipe fields introduced by migration 033.
--
-- This migration does not alter production lot component history. It adds a
-- canonical save function for the expanded structured recipe-ingredient model.

SET client_min_messages TO WARNING;
BEGIN;

CREATE OR REPLACE FUNCTION public.mp_recipe_ingredient_document_admin_save(
  p_nocopk bigint,
  p_recipe_id bigint,
  p_ingredient_id bigint,
  p_amount numeric,
  p_amount_max numeric,
  p_quantity_text text,
  p_unit text,
  p_vendor_name text,
  p_alternative_group text,
  p_parent_recipe_ingredient_id bigint,
  p_optional boolean,
  p_sort_order numeric,
  p_active boolean,
  p_notes text
)
RETURNS TABLE(
  nocopk bigint,
  recipe_ingredient_id text,
  recipe_id bigint,
  ingredient_id bigint,
  amount numeric,
  amount_max numeric,
  quantity_text text,
  unit text,
  vendor_name text,
  alternative_group text,
  parent_recipe_ingredient_id bigint,
  optional boolean,
  sort_order numeric,
  active boolean,
  notes text
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_quantity_text text := NULLIF(btrim(COALESCE(p_quantity_text, '')), '');
  v_unit text := NULLIF(btrim(COALESCE(p_unit, '')), '');
  v_vendor text := NULLIF(btrim(COALESCE(p_vendor_name, '')), '');
  v_alternative_group text := NULLIF(btrim(COALESCE(p_alternative_group, '')), '');
  v_notes text := NULLIF(btrim(COALESCE(p_notes, '')), '');
  v_parent_recipe_id bigint;
  v_id bigint;
  v_generated_id text;
BEGIN
  IF p_recipe_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.recipes r WHERE r.nocopk = p_recipe_id
  ) THEN
    RAISE EXCEPTION 'Select a valid Recipe before saving a structured ingredient.';
  END IF;

  IF p_ingredient_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.ingredients i WHERE i.nocopk = p_ingredient_id
  ) THEN
    RAISE EXCEPTION 'Select a valid Ingredient.';
  END IF;

  IF p_amount IS NOT NULL AND p_amount <= 0 THEN
    RAISE EXCEPTION 'Ingredient Amount must be greater than zero when supplied.';
  END IF;

  IF p_amount_max IS NOT NULL AND p_amount_max <= 0 THEN
    RAISE EXCEPTION 'Ingredient Maximum Amount must be greater than zero when supplied.';
  END IF;

  IF p_amount IS NOT NULL AND p_amount_max IS NOT NULL AND p_amount_max < p_amount THEN
    RAISE EXCEPTION 'Ingredient Maximum Amount cannot be less than Amount.';
  END IF;

  IF p_amount IS NULL AND v_quantity_text IS NULL THEN
    RAISE EXCEPTION 'Provide an Ingredient Amount or Quantity / Display Text.';
  END IF;

  -- unit remains a required canonical field in recipe_ingredients. Even a
  -- qualitative/display quantity should retain its most useful unit context.
  IF v_unit IS NULL THEN
    RAISE EXCEPTION 'Ingredient Unit is required.';
  END IF;

  IF p_parent_recipe_ingredient_id IS NOT NULL THEN
    SELECT ri.recipe_id
      INTO v_parent_recipe_id
      FROM public.recipe_ingredients ri
     WHERE ri.nocopk = p_parent_recipe_ingredient_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Parent Recipe Ingredient not found for nocopk: %', p_parent_recipe_ingredient_id;
    END IF;

    IF v_parent_recipe_id <> p_recipe_id THEN
      RAISE EXCEPTION 'Parent Recipe Ingredient must belong to the same Recipe.';
    END IF;

    IF p_nocopk IS NOT NULL AND p_nocopk > 0
       AND p_parent_recipe_ingredient_id = p_nocopk THEN
      RAISE EXCEPTION 'A Recipe Ingredient cannot be its own parent.';
    END IF;
  END IF;

  IF p_nocopk IS NULL OR p_nocopk <= 0 THEN
    v_generated_id := 'RING-' || to_char(clock_timestamp(), 'YYMMDD') || '-' ||
      left(replace(gen_random_uuid()::text, '-', ''), 6);

    INSERT INTO public.recipe_ingredients(
      recipe_ingredient_id,
      recipe_id,
      ingredient_id,
      amount,
      amount_max,
      quantity_text,
      unit,
      vendor_name,
      alternative_group,
      parent_recipe_ingredient_id,
      optional,
      sort_order,
      active,
      notes,
      nc_created_at,
      nc_updated_at
    )
    VALUES (
      v_generated_id,
      p_recipe_id,
      p_ingredient_id,
      p_amount,
      p_amount_max,
      v_quantity_text,
      v_unit,
      v_vendor,
      v_alternative_group,
      p_parent_recipe_ingredient_id,
      COALESCE(p_optional, false),
      p_sort_order,
      COALESCE(p_active, true),
      v_notes,
      now(),
      now()
    )
    RETURNING recipe_ingredients.nocopk INTO v_id;
  ELSE
    IF NOT EXISTS (
      SELECT 1 FROM public.recipe_ingredients ri WHERE ri.nocopk = p_nocopk
    ) THEN
      RAISE EXCEPTION 'Structured recipe ingredient not found for nocopk: %', p_nocopk;
    END IF;

    UPDATE public.recipe_ingredients ri
       SET recipe_id = p_recipe_id,
           ingredient_id = p_ingredient_id,
           amount = p_amount,
           amount_max = p_amount_max,
           quantity_text = v_quantity_text,
           unit = v_unit,
           vendor_name = v_vendor,
           alternative_group = v_alternative_group,
           parent_recipe_ingredient_id = p_parent_recipe_ingredient_id,
           optional = COALESCE(p_optional, false),
           sort_order = p_sort_order,
           active = COALESCE(p_active, true),
           notes = v_notes,
           nc_updated_at = now()
     WHERE ri.nocopk = p_nocopk
    RETURNING ri.nocopk INTO v_id;
  END IF;

  RETURN QUERY
  SELECT ri.nocopk,
         ri.recipe_ingredient_id,
         ri.recipe_id,
         ri.ingredient_id,
         ri.amount,
         ri.amount_max,
         ri.quantity_text,
         ri.unit,
         ri.vendor_name,
         ri.alternative_group,
         ri.parent_recipe_ingredient_id,
         ri.optional,
         ri.sort_order,
         ri.active,
         ri.notes
    FROM public.recipe_ingredients ri
   WHERE ri.nocopk = v_id;
END;
$$;

COMMENT ON FUNCTION public.mp_recipe_ingredient_document_admin_save(
  bigint,bigint,bigint,numeric,numeric,text,text,text,text,bigint,boolean,numeric,boolean,text
) IS
  'Create/update the complete Issue #79 structured recipe ingredient definition, including ranges, display quantities, alternatives, nesting, and optional state.';

COMMIT;
