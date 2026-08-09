-- 032_recipe_management.sql
-- PostgreSQL-first recipe/ingredient administration for GitHub issue #79.
--
-- Airtable is no longer the production source of truth. This migration adds
-- structured recipe ingredients and canonical administrative save functions
-- while preserving the existing recipes.ingredients field as read-only legacy
-- reference data. Existing item_recipe_components remain the source of allowed
-- item/component plans and lot_recipe_components remain immutable production
-- history managed by operational workflows.

SET client_min_messages TO WARNING;
BEGIN;

CREATE TABLE IF NOT EXISTS public.ingredients (
  nocopk bigserial PRIMARY KEY,
  ingredient_id text NOT NULL,
  active boolean NOT NULL DEFAULT true,
  name text NOT NULL,
  category text,
  default_unit text,
  preferred_vendor text,
  notes text,
  nocouuid uuid NOT NULL DEFAULT gen_random_uuid(),
  nc_created_at timestamp without time zone NOT NULL DEFAULT now(),
  nc_updated_at timestamp without time zone NOT NULL DEFAULT now(),
  CONSTRAINT uq_ingredients_ingredient_id UNIQUE (ingredient_id),
  CONSTRAINT ck_ingredients_ingredient_id_nonblank CHECK (btrim(ingredient_id) <> ''),
  CONSTRAINT ck_ingredients_name_nonblank CHECK (btrim(name) <> '')
);

CREATE INDEX IF NOT EXISTS ix_ingredients_name
  ON public.ingredients (lower(name), nocopk);
CREATE INDEX IF NOT EXISTS ix_ingredients_active
  ON public.ingredients (active, lower(name), nocopk);

CREATE TABLE IF NOT EXISTS public.recipe_ingredients (
  nocopk bigserial PRIMARY KEY,
  recipe_ingredient_id text NOT NULL,
  recipe_id bigint NOT NULL,
  ingredient_id bigint NOT NULL,
  amount numeric NOT NULL,
  unit text NOT NULL,
  vendor_name text,
  sort_order numeric,
  active boolean NOT NULL DEFAULT true,
  notes text,
  nocouuid uuid NOT NULL DEFAULT gen_random_uuid(),
  nc_created_at timestamp without time zone NOT NULL DEFAULT now(),
  nc_updated_at timestamp without time zone NOT NULL DEFAULT now(),
  CONSTRAINT uq_recipe_ingredients_recipe_ingredient_id UNIQUE (recipe_ingredient_id),
  CONSTRAINT fk_recipe_ingredients_recipe
    FOREIGN KEY (recipe_id) REFERENCES public.recipes(nocopk) DEFERRABLE INITIALLY DEFERRED,
  CONSTRAINT fk_recipe_ingredients_ingredient
    FOREIGN KEY (ingredient_id) REFERENCES public.ingredients(nocopk) DEFERRABLE INITIALLY DEFERRED,
  CONSTRAINT ck_recipe_ingredients_amount_positive CHECK (amount > 0),
  CONSTRAINT ck_recipe_ingredients_unit_nonblank CHECK (btrim(unit) <> '')
);

CREATE INDEX IF NOT EXISTS ix_recipe_ingredients_recipe
  ON public.recipe_ingredients (recipe_id, active, sort_order, nocopk);
CREATE INDEX IF NOT EXISTS ix_recipe_ingredients_ingredient
  ON public.recipe_ingredients (ingredient_id, active, recipe_id, nocopk);

CREATE OR REPLACE FUNCTION public.mp_recipe_admin_save(
  p_nocopk bigint,
  p_recipe_id text,
  p_name text,
  p_category text DEFAULT NULL,
  p_active boolean DEFAULT true,
  p_notes text DEFAULT NULL
)
RETURNS TABLE(
  nocopk bigint,
  recipe_id text,
  active boolean,
  name text,
  category text,
  ingredients text,
  notes text
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_recipe_id text := NULLIF(btrim(COALESCE(p_recipe_id, '')), '');
  v_name text := NULLIF(btrim(COALESCE(p_name, '')), '');
  v_category text := NULLIF(btrim(COALESCE(p_category, '')), '');
  v_notes text := NULLIF(btrim(COALESCE(p_notes, '')), '');
  v_id bigint;
BEGIN
  IF v_recipe_id IS NULL THEN
    RAISE EXCEPTION 'Recipe ID is required.';
  END IF;
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'Recipe Name is required.';
  END IF;

  IF p_nocopk IS NULL OR p_nocopk <= 0 THEN
    INSERT INTO public.recipes(recipe_id, active, name, category, notes, nc_created_at, nc_updated_at)
    VALUES (v_recipe_id, COALESCE(p_active, true), v_name, v_category, v_notes, now(), now())
    RETURNING recipes.nocopk INTO v_id;
  ELSE
    IF NOT EXISTS (SELECT 1 FROM public.recipes r WHERE r.nocopk = p_nocopk) THEN
      RAISE EXCEPTION 'Recipe not found for nocopk: %', p_nocopk;
    END IF;

    UPDATE public.recipes r
       SET recipe_id = v_recipe_id,
           active = COALESCE(p_active, true),
           name = v_name,
           category = v_category,
           notes = v_notes,
           nc_updated_at = now()
     WHERE r.nocopk = p_nocopk
    RETURNING r.nocopk INTO v_id;
  END IF;

  RETURN QUERY
  SELECT r.nocopk, r.recipe_id, COALESCE(r.active, false), r.name, r.category, r.ingredients, r.notes
  FROM public.recipes r
  WHERE r.nocopk = v_id;
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'Recipe ID "%" already exists.', v_recipe_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.mp_ingredient_admin_save(
  p_nocopk bigint,
  p_ingredient_id text,
  p_name text,
  p_category text DEFAULT NULL,
  p_default_unit text DEFAULT NULL,
  p_preferred_vendor text DEFAULT NULL,
  p_active boolean DEFAULT true,
  p_notes text DEFAULT NULL
)
RETURNS TABLE(
  nocopk bigint,
  ingredient_id text,
  active boolean,
  name text,
  category text,
  default_unit text,
  preferred_vendor text,
  notes text
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_ingredient_id text := NULLIF(btrim(COALESCE(p_ingredient_id, '')), '');
  v_name text := NULLIF(btrim(COALESCE(p_name, '')), '');
  v_category text := NULLIF(btrim(COALESCE(p_category, '')), '');
  v_default_unit text := NULLIF(btrim(COALESCE(p_default_unit, '')), '');
  v_vendor text := NULLIF(btrim(COALESCE(p_preferred_vendor, '')), '');
  v_notes text := NULLIF(btrim(COALESCE(p_notes, '')), '');
  v_id bigint;
BEGIN
  IF v_ingredient_id IS NULL THEN
    RAISE EXCEPTION 'Ingredient ID is required.';
  END IF;
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'Ingredient Name is required.';
  END IF;

  IF p_nocopk IS NULL OR p_nocopk <= 0 THEN
    INSERT INTO public.ingredients(
      ingredient_id, active, name, category, default_unit,
      preferred_vendor, notes, nc_created_at, nc_updated_at
    )
    VALUES (
      v_ingredient_id, COALESCE(p_active, true), v_name, v_category,
      v_default_unit, v_vendor, v_notes, now(), now()
    )
    RETURNING ingredients.nocopk INTO v_id;
  ELSE
    IF NOT EXISTS (SELECT 1 FROM public.ingredients i WHERE i.nocopk = p_nocopk) THEN
      RAISE EXCEPTION 'Ingredient not found for nocopk: %', p_nocopk;
    END IF;

    UPDATE public.ingredients i
       SET ingredient_id = v_ingredient_id,
           active = COALESCE(p_active, true),
           name = v_name,
           category = v_category,
           default_unit = v_default_unit,
           preferred_vendor = v_vendor,
           notes = v_notes,
           nc_updated_at = now()
     WHERE i.nocopk = p_nocopk
    RETURNING i.nocopk INTO v_id;
  END IF;

  RETURN QUERY
  SELECT i.nocopk, i.ingredient_id, i.active, i.name, i.category,
         i.default_unit, i.preferred_vendor, i.notes
  FROM public.ingredients i
  WHERE i.nocopk = v_id;
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'Ingredient ID "%" already exists.', v_ingredient_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.mp_recipe_ingredient_admin_save(
  p_nocopk bigint,
  p_recipe_id bigint,
  p_ingredient_id bigint,
  p_amount numeric,
  p_unit text,
  p_vendor_name text DEFAULT NULL,
  p_sort_order numeric DEFAULT NULL,
  p_active boolean DEFAULT true,
  p_notes text DEFAULT NULL
)
RETURNS TABLE(
  nocopk bigint,
  recipe_ingredient_id text,
  recipe_id bigint,
  ingredient_id bigint,
  amount numeric,
  unit text,
  vendor_name text,
  sort_order numeric,
  active boolean,
  notes text
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_unit text := NULLIF(btrim(COALESCE(p_unit, '')), '');
  v_vendor text := NULLIF(btrim(COALESCE(p_vendor_name, '')), '');
  v_notes text := NULLIF(btrim(COALESCE(p_notes, '')), '');
  v_id bigint;
  v_generated_id text;
BEGIN
  IF p_recipe_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.recipes r WHERE r.nocopk = p_recipe_id) THEN
    RAISE EXCEPTION 'Select a valid Recipe before saving a structured ingredient.';
  END IF;
  IF p_ingredient_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.ingredients i WHERE i.nocopk = p_ingredient_id) THEN
    RAISE EXCEPTION 'Select a valid Ingredient.';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Ingredient Amount must be greater than zero.';
  END IF;
  IF v_unit IS NULL THEN
    RAISE EXCEPTION 'Ingredient Unit is required.';
  END IF;

  IF p_nocopk IS NULL OR p_nocopk <= 0 THEN
    v_generated_id := 'RING-' || to_char(clock_timestamp(), 'YYMMDD') || '-' ||
      left(replace(gen_random_uuid()::text, '-', ''), 6);

    INSERT INTO public.recipe_ingredients(
      recipe_ingredient_id, recipe_id, ingredient_id, amount, unit,
      vendor_name, sort_order, active, notes, nc_created_at, nc_updated_at
    )
    VALUES (
      v_generated_id, p_recipe_id, p_ingredient_id, p_amount, v_unit,
      v_vendor, p_sort_order, COALESCE(p_active, true), v_notes, now(), now()
    )
    RETURNING recipe_ingredients.nocopk INTO v_id;
  ELSE
    IF NOT EXISTS (SELECT 1 FROM public.recipe_ingredients ri WHERE ri.nocopk = p_nocopk) THEN
      RAISE EXCEPTION 'Structured recipe ingredient not found for nocopk: %', p_nocopk;
    END IF;

    UPDATE public.recipe_ingredients ri
       SET recipe_id = p_recipe_id,
           ingredient_id = p_ingredient_id,
           amount = p_amount,
           unit = v_unit,
           vendor_name = v_vendor,
           sort_order = p_sort_order,
           active = COALESCE(p_active, true),
           notes = v_notes,
           nc_updated_at = now()
     WHERE ri.nocopk = p_nocopk
    RETURNING ri.nocopk INTO v_id;
  END IF;

  RETURN QUERY
  SELECT ri.nocopk, ri.recipe_ingredient_id, ri.recipe_id, ri.ingredient_id,
         ri.amount, ri.unit, ri.vendor_name, ri.sort_order, ri.active, ri.notes
  FROM public.recipe_ingredients ri
  WHERE ri.nocopk = v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.mp_item_recipe_component_admin_save(
  p_nocopk bigint,
  p_item_id bigint,
  p_component_set text,
  p_recipe_id bigint,
  p_component_role text,
  p_unit_size_lb numeric DEFAULT NULL,
  p_default_weight_lb numeric DEFAULT NULL,
  p_default_percent numeric DEFAULT NULL,
  p_sort_order numeric DEFAULT NULL,
  p_active boolean DEFAULT true,
  p_notes text DEFAULT NULL
)
RETURNS TABLE(
  nocopk bigint,
  component_id text,
  active boolean,
  item_id bigint,
  component_set text,
  recipe_id bigint,
  component_role text,
  unit_size_lb numeric,
  default_weight_lb numeric,
  default_percent numeric,
  sort_order numeric,
  notes text
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_component_mode text;
  v_component_set text := NULLIF(btrim(COALESCE(p_component_set, '')), '');
  v_role text := lower(NULLIF(btrim(COALESCE(p_component_role, '')), ''));
  v_notes text := NULLIF(btrim(COALESCE(p_notes, '')), '');
  v_id bigint;
  v_component_id text;
BEGIN
  SELECT lower(COALESCE(NULLIF(btrim(i.component_mode), ''), 'none'))
    INTO v_component_mode
  FROM public.items i
  WHERE i.nocopk = p_item_id;

  IF v_component_mode IS NULL THEN
    RAISE EXCEPTION 'Select a valid Item.';
  END IF;
  IF v_component_mode NOT IN ('single_recipe', 'multi_recipe') THEN
    RAISE EXCEPTION 'Item % does not use recipe components (component_mode=%).',
      p_item_id, v_component_mode;
  END IF;
  IF p_recipe_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.recipes r WHERE r.nocopk = p_recipe_id) THEN
    RAISE EXCEPTION 'Select a valid Recipe.';
  END IF;
  IF v_role IS NULL OR v_role NOT IN ('primary','grain','substrate','agar','lc','casing','supplement','other') THEN
    RAISE EXCEPTION 'Component Role must be one of primary, grain, substrate, agar, lc, casing, supplement, or other.';
  END IF;
  IF p_unit_size_lb IS NOT NULL AND p_unit_size_lb <= 0 THEN
    RAISE EXCEPTION 'Unit Size (lb) must be greater than zero when provided.';
  END IF;
  IF p_default_weight_lb IS NOT NULL AND p_default_weight_lb <= 0 THEN
    RAISE EXCEPTION 'Default Weight (lb) must be greater than zero when provided.';
  END IF;
  IF p_default_percent IS NOT NULL AND (p_default_percent < 0 OR p_default_percent > 100) THEN
    RAISE EXCEPTION 'Default Percent must be between 0 and 100 when provided.';
  END IF;

  IF v_component_mode = 'multi_recipe' AND v_component_set IS NULL THEN
    RAISE EXCEPTION 'Component Set is required for multi-recipe items.';
  END IF;
  IF v_component_mode = 'single_recipe' THEN
    v_component_set := NULL;
  END IF;

  IF COALESCE(p_active, true) AND EXISTS (
    SELECT 1
    FROM public.item_recipe_components c
    WHERE c.nocopk <> COALESCE(p_nocopk, -1)
      AND c.item_id = p_item_id
      AND c.recipe_id = p_recipe_id
      AND lower(COALESCE(c.component_role, '')) = v_role
      AND COALESCE(btrim(c.component_set), '') = COALESCE(v_component_set, '')
      AND c.unit_size_lb IS NOT DISTINCT FROM p_unit_size_lb
      AND COALESCE(c.active, false)
  ) THEN
    RAISE EXCEPTION 'An active component already exists for this Item, Component Set, Unit Size, Role, and Recipe.';
  END IF;

  IF p_nocopk IS NULL OR p_nocopk <= 0 THEN
    v_component_id := 'IRC-' || to_char(clock_timestamp(), 'YYMMDD') || '-' ||
      right(replace(gen_random_uuid()::text, '-', ''), 4);

    INSERT INTO public.item_recipe_components(
      component_id, active, item_id, component_set, recipe_id, component_role,
      unit_size_lb, default_weight_lb, default_percent, sort_order, notes,
      nc_created_at, nc_updated_at
    )
    VALUES (
      v_component_id, COALESCE(p_active, true), p_item_id, v_component_set,
      p_recipe_id, v_role, p_unit_size_lb, p_default_weight_lb,
      p_default_percent, p_sort_order, v_notes, now(), now()
    )
    RETURNING item_recipe_components.nocopk INTO v_id;
  ELSE
    IF NOT EXISTS (SELECT 1 FROM public.item_recipe_components c WHERE c.nocopk = p_nocopk) THEN
      RAISE EXCEPTION 'Item recipe component not found for nocopk: %', p_nocopk;
    END IF;

    UPDATE public.item_recipe_components c
       SET active = COALESCE(p_active, true),
           item_id = p_item_id,
           component_set = v_component_set,
           recipe_id = p_recipe_id,
           component_role = v_role,
           unit_size_lb = p_unit_size_lb,
           default_weight_lb = p_default_weight_lb,
           default_percent = p_default_percent,
           sort_order = p_sort_order,
           notes = v_notes,
           nc_updated_at = now()
     WHERE c.nocopk = p_nocopk
    RETURNING c.nocopk INTO v_id;
  END IF;

  RETURN QUERY
  SELECT c.nocopk, c.component_id, COALESCE(c.active, false), c.item_id,
         c.component_set, c.recipe_id, c.component_role, c.unit_size_lb,
         c.default_weight_lb, c.default_percent, c.sort_order, c.notes
  FROM public.item_recipe_components c
  WHERE c.nocopk = v_id;
END;
$$;

COMMENT ON TABLE public.ingredients IS
  'PostgreSQL-first ingredient master used by Recipes - Manage (#79). Future received ingredient inventory can reference these stable ingredient rows.';
COMMENT ON TABLE public.recipe_ingredients IS
  'Structured recipe definition rows: ingredient, amount, unit, source/vendor, order, and notes. recipes.ingredients remains legacy read-only reference text.';
COMMENT ON FUNCTION public.mp_recipe_admin_save(bigint,text,text,text,boolean,text) IS
  'Create/update recipe definition metadata without overwriting legacy recipes.ingredients text.';
COMMENT ON FUNCTION public.mp_ingredient_admin_save(bigint,text,text,text,text,text,boolean,text) IS
  'Create/update an ingredient master row.';
COMMENT ON FUNCTION public.mp_recipe_ingredient_admin_save(bigint,bigint,bigint,numeric,text,text,numeric,boolean,text) IS
  'Create/update a structured ingredient row for a recipe.';
COMMENT ON FUNCTION public.mp_item_recipe_component_admin_save(bigint,bigint,text,bigint,text,numeric,numeric,numeric,numeric,boolean,text) IS
  'Create/update allowed/default item recipe component plans; does not modify actual lot_recipe_components history.';

COMMIT;
