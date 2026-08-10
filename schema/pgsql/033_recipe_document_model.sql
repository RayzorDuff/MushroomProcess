-- 033_recipe_document_model.sql
-- Extend PostgreSQL-first recipe management so complete human-readable
-- production instructions can be represented in the database and later
-- rendered into documents such as Mushroom Grow Recipes.
--
-- Issue #79 deliberately keeps actual lot_recipe_components as immutable
-- production history. This migration only expands recipe definitions.

SET client_min_messages TO WARNING;
BEGIN;

ALTER TABLE public.recipes
  ADD COLUMN IF NOT EXISTS description text,
  ADD COLUMN IF NOT EXISTS batch_yield_text text;

ALTER TABLE public.recipe_ingredients
  ADD COLUMN IF NOT EXISTS amount_max numeric,
  ADD COLUMN IF NOT EXISTS quantity_text text,
  ADD COLUMN IF NOT EXISTS alternative_group text,
  ADD COLUMN IF NOT EXISTS parent_recipe_ingredient_id bigint,
  ADD COLUMN IF NOT EXISTS optional boolean NOT NULL DEFAULT false;

-- Some recipe instructions are qualitative rather than numeric, e.g.
-- "Filtered water to final broth volume". Preserve the existing numeric
-- amount when one exists, but permit a display quantity in its place.
ALTER TABLE public.recipe_ingredients
  ALTER COLUMN amount DROP NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint c
    WHERE c.conname = 'fk_recipe_ingredients_parent'
      AND c.conrelid = 'public.recipe_ingredients'::regclass
  ) THEN
    ALTER TABLE public.recipe_ingredients
      ADD CONSTRAINT fk_recipe_ingredients_parent
      FOREIGN KEY (parent_recipe_ingredient_id)
      REFERENCES public.recipe_ingredients(nocopk)
      DEFERRABLE INITIALLY DEFERRED;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint c
    WHERE c.conname = 'ck_recipe_ingredients_amount_max'
      AND c.conrelid = 'public.recipe_ingredients'::regclass
  ) THEN
    ALTER TABLE public.recipe_ingredients
      ADD CONSTRAINT ck_recipe_ingredients_amount_max
      CHECK (
        amount_max IS NULL
        OR (amount_max > 0 AND (amount IS NULL OR amount_max >= amount))
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint c
    WHERE c.conname = 'ck_recipe_ingredients_quantity_present'
      AND c.conrelid = 'public.recipe_ingredients'::regclass
  ) THEN
    ALTER TABLE public.recipe_ingredients
      ADD CONSTRAINT ck_recipe_ingredients_quantity_present
      CHECK (
        amount IS NOT NULL
        OR NULLIF(btrim(COALESCE(quantity_text, '')), '') IS NOT NULL
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint c
    WHERE c.conname = 'ck_recipe_ingredients_parent_not_self'
      AND c.conrelid = 'public.recipe_ingredients'::regclass
  ) THEN
    ALTER TABLE public.recipe_ingredients
      ADD CONSTRAINT ck_recipe_ingredients_parent_not_self
      CHECK (parent_recipe_ingredient_id IS NULL OR parent_recipe_ingredient_id <> nocopk);
  END IF;
END
$$;

CREATE INDEX IF NOT EXISTS ix_recipe_ingredients_parent
  ON public.recipe_ingredients(parent_recipe_ingredient_id, sort_order, nocopk);
CREATE INDEX IF NOT EXISTS ix_recipe_ingredients_alternative_group
  ON public.recipe_ingredients(recipe_id, alternative_group, sort_order, nocopk)
  WHERE alternative_group IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.recipe_steps (
  nocopk bigserial PRIMARY KEY,
  recipe_step_id text NOT NULL,
  recipe_id bigint NOT NULL,
  active boolean NOT NULL DEFAULT true,
  section text NOT NULL DEFAULT 'Preparation',
  section_order numeric,
  step_order numeric,
  instruction text NOT NULL,
  notes text,
  nocouuid uuid NOT NULL DEFAULT gen_random_uuid(),
  nc_created_at timestamp without time zone NOT NULL DEFAULT now(),
  nc_updated_at timestamp without time zone NOT NULL DEFAULT now(),
  CONSTRAINT uq_recipe_steps_recipe_step_id UNIQUE (recipe_step_id),
  CONSTRAINT fk_recipe_steps_recipe
    FOREIGN KEY (recipe_id) REFERENCES public.recipes(nocopk)
    DEFERRABLE INITIALLY DEFERRED,
  CONSTRAINT ck_recipe_steps_id_nonblank CHECK (btrim(recipe_step_id) <> ''),
  CONSTRAINT ck_recipe_steps_section_nonblank CHECK (btrim(section) <> ''),
  CONSTRAINT ck_recipe_steps_instruction_nonblank CHECK (btrim(instruction) <> '')
);

CREATE INDEX IF NOT EXISTS ix_recipe_steps_recipe_order
  ON public.recipe_steps(recipe_id, active, section_order, step_order, nocopk);

CREATE OR REPLACE FUNCTION public.mp_recipe_document_metadata_save(
  p_recipe_id bigint,
  p_description text DEFAULT NULL,
  p_batch_yield_text text DEFAULT NULL
)
RETURNS TABLE(
  nocopk bigint,
  recipe_id text,
  description text,
  batch_yield_text text
)
LANGUAGE plpgsql
AS $$
BEGIN
  IF p_recipe_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.recipes r WHERE r.nocopk = p_recipe_id
  ) THEN
    RAISE EXCEPTION 'Select a valid Recipe.';
  END IF;

  UPDATE public.recipes r
     SET description = NULLIF(btrim(COALESCE(p_description, '')), ''),
         batch_yield_text = NULLIF(btrim(COALESCE(p_batch_yield_text, '')), ''),
         nc_updated_at = now()
   WHERE r.nocopk = p_recipe_id;

  RETURN QUERY
  SELECT r.nocopk, r.recipe_id, r.description, r.batch_yield_text
  FROM public.recipes r
  WHERE r.nocopk = p_recipe_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.mp_recipe_step_admin_save(
  p_nocopk bigint,
  p_recipe_id bigint,
  p_section text,
  p_section_order numeric,
  p_step_order numeric,
  p_instruction text,
  p_active boolean DEFAULT true,
  p_notes text DEFAULT NULL
)
RETURNS TABLE(
  nocopk bigint,
  recipe_step_id text,
  recipe_id bigint,
  active boolean,
  section text,
  section_order numeric,
  step_order numeric,
  instruction text,
  notes text
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_section text := NULLIF(btrim(COALESCE(p_section, '')), '');
  v_instruction text := NULLIF(btrim(COALESCE(p_instruction, '')), '');
  v_notes text := NULLIF(btrim(COALESCE(p_notes, '')), '');
  v_id bigint;
  v_step_id text;
BEGIN
  IF p_recipe_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.recipes r WHERE r.nocopk = p_recipe_id
  ) THEN
    RAISE EXCEPTION 'Select a valid Recipe.';
  END IF;
  IF v_section IS NULL THEN
    RAISE EXCEPTION 'Recipe step Section is required.';
  END IF;
  IF v_instruction IS NULL THEN
    RAISE EXCEPTION 'Recipe step Instruction is required.';
  END IF;

  IF p_nocopk IS NULL OR p_nocopk <= 0 THEN
    v_step_id := 'RSTEP-' || to_char(clock_timestamp(), 'YYMMDD') || '-' ||
      left(replace(gen_random_uuid()::text, '-', ''), 6);

    INSERT INTO public.recipe_steps(
      recipe_step_id, recipe_id, active, section, section_order,
      step_order, instruction, notes, nc_created_at, nc_updated_at
    )
    VALUES (
      v_step_id, p_recipe_id, COALESCE(p_active, true), v_section,
      p_section_order, p_step_order, v_instruction, v_notes, now(), now()
    )
    RETURNING recipe_steps.nocopk INTO v_id;
  ELSE
    IF NOT EXISTS (SELECT 1 FROM public.recipe_steps s WHERE s.nocopk = p_nocopk) THEN
      RAISE EXCEPTION 'Recipe step not found for nocopk: %', p_nocopk;
    END IF;

    UPDATE public.recipe_steps s
       SET recipe_id = p_recipe_id,
           active = COALESCE(p_active, true),
           section = v_section,
           section_order = p_section_order,
           step_order = p_step_order,
           instruction = v_instruction,
           notes = v_notes,
           nc_updated_at = now()
     WHERE s.nocopk = p_nocopk
    RETURNING s.nocopk INTO v_id;
  END IF;

  RETURN QUERY
  SELECT s.nocopk, s.recipe_step_id, s.recipe_id, s.active, s.section,
         s.section_order, s.step_order, s.instruction, s.notes
  FROM public.recipe_steps s
  WHERE s.nocopk = v_id;
END;
$$;

COMMENT ON COLUMN public.recipes.description IS
  'Narrative recipe introduction/description suitable for generated human-readable instructions.';
COMMENT ON COLUMN public.recipes.batch_yield_text IS
  'Human-readable batch/output description, e.g. "6 x 8 oz jars" or "Enough to fill two sterilizer trays".';
COMMENT ON COLUMN public.recipe_ingredients.amount_max IS
  'Optional upper bound for quantity ranges such as 300-330 mL.';
COMMENT ON COLUMN public.recipe_ingredients.quantity_text IS
  'Optional source/display quantity text preserving equivalents, approximations, ratios, or qualitative quantities.';
COMMENT ON COLUMN public.recipe_ingredients.alternative_group IS
  'Groups mutually substitutable ingredient choices within one recipe definition.';
COMMENT ON COLUMN public.recipe_ingredients.parent_recipe_ingredient_id IS
  'Optional parent row for nested compositions such as the components of a prepared nutrient broth.';
COMMENT ON COLUMN public.recipe_ingredients.optional IS
  'True when the ingredient/component is optional rather than required.';
COMMENT ON TABLE public.recipe_steps IS
  'Ordered, sectioned human-readable preparation/processing instructions for a recipe. Actual lot history remains in lot_recipe_components.';
COMMENT ON FUNCTION public.mp_recipe_document_metadata_save(bigint,text,text) IS
  'Update recipe document metadata without changing operational component history.';
COMMENT ON FUNCTION public.mp_recipe_step_admin_save(bigint,bigint,text,numeric,numeric,text,boolean,text) IS
  'Create/update an ordered recipe instruction step for future recipe document generation.';

COMMIT;
