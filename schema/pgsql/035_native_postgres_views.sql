SET search_path = public, pg_catalog;

BEGIN;

/*
 * PostgreSQL-native view layer.
 *
 * 003_views.sql / 004_computed_views.sql are retained Airtable-generation
 * artifacts. Tables introduced after that migration boundary need their own
 * stable v_/vc_ interfaces instead of being folded back into the deprecated
 * Airtable generator output.
 *
 * v_recipes predates the document fields added by migration 033. Recreate it
 * with its existing output contract first, then append the new fields so
 * CREATE OR REPLACE VIEW remains safe for existing consumers.
 */
DO $migration$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'v_recipes'
      AND column_name = 'description'
  ) OR NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'v_recipes'
      AND column_name = 'batch_yield_text'
  ) THEN
    EXECUTE $view$
      CREATE OR REPLACE VIEW public.v_recipes AS
      SELECT
        t.nocopk,
        t.recipe_id,
        t.active,
        t.name,
        t.category,
        t.ingredients,
        t.notes,
        t.nocouuid,
        t.airtable_id,
        t.nc_created_at,
        t.nc_updated_at,
        'public.recipes'::text AS __table,
        COALESCE(t.recipe_id::text, t.nocopk::text) AS __primary,
        (
          SELECT COALESCE(array_agg(j.lots_id ORDER BY j.lots_id), '{}'::bigint[])
          FROM public._m2m_recipes_lots_lots j
          WHERE j.recipes_id = t.nocopk
        ) AS recipes__lots__lots__ids,
        (
          SELECT COALESCE(array_agg(j.sterilization_runs_id ORDER BY j.sterilization_runs_id), '{}'::bigint[])
          FROM public._m2m_recipes_sterilization_runs_sterilization_runs j
          WHERE j.recipes_id = t.nocopk
        ) AS recipes__sterilization_runs__sterilization_runs__ids,
        (
          SELECT COALESCE(array_agg(j.item_recipe_components_id ORDER BY j.item_recipe_components_id), '{}'::bigint[])
          FROM public._m2m_recipes_item_recipe_components_item_recipe_components j
          WHERE j.recipes_id = t.nocopk
        ) AS recipes__item_recipe_components__item_recipe_components__ids,
        (
          SELECT COALESCE(array_agg(j.lot_recipe_components_id ORDER BY j.lot_recipe_components_id), '{}'::bigint[])
          FROM public._m2m_recipes_lot_recipe_components_lot_recipe_components j
          WHERE j.recipes_id = t.nocopk
        ) AS recipes__lot_recipe_components__lot_recipe_components__ids,
        t.description,
        t.batch_yield_text
      FROM public.recipes t
    $view$;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'vc_recipes'
      AND column_name = 'description'
  ) OR NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'vc_recipes'
      AND column_name = 'batch_yield_text'
  ) THEN
    EXECUTE 'CREATE OR REPLACE VIEW public.vc_recipes AS SELECT * FROM public.v_recipes';
  END IF;
END
$migration$;

CREATE OR REPLACE VIEW public.v_ingredients AS
SELECT
  t.*,
  'public.ingredients'::text AS __table,
  COALESCE(t.ingredient_id::text, t.nocopk::text) AS __primary
FROM public.ingredients t;

CREATE OR REPLACE VIEW public.vc_ingredients AS
SELECT *
FROM public.v_ingredients;

CREATE OR REPLACE VIEW public.v_recipe_ingredients AS
SELECT
  t.*,
  'public.recipe_ingredients'::text AS __table,
  COALESCE(t.recipe_ingredient_id::text, t.nocopk::text) AS __primary
FROM public.recipe_ingredients t;

CREATE OR REPLACE VIEW public.vc_recipe_ingredients AS
SELECT
  base.*,
  r.recipe_id AS recipe_code,
  r.name AS recipe_name,
  i.ingredient_id AS ingredient_code,
  i.name AS ingredient_name,
  pri.recipe_ingredient_id AS parent_recipe_ingredient_code,
  pi.ingredient_id AS parent_ingredient_code,
  pi.name AS parent_ingredient_name
FROM public.v_recipe_ingredients base
JOIN public.recipes r ON r.nocopk = base.recipe_id
JOIN public.ingredients i ON i.nocopk = base.ingredient_id
LEFT JOIN public.recipe_ingredients pri ON pri.nocopk = base.parent_recipe_ingredient_id
LEFT JOIN public.ingredients pi ON pi.nocopk = pri.ingredient_id;

CREATE OR REPLACE VIEW public.v_recipe_steps AS
SELECT
  t.*,
  'public.recipe_steps'::text AS __table,
  COALESCE(t.recipe_step_id::text, t.nocopk::text) AS __primary
FROM public.recipe_steps t;

CREATE OR REPLACE VIEW public.vc_recipe_steps AS
SELECT
  base.*,
  r.recipe_id AS recipe_code,
  r.name AS recipe_name
FROM public.v_recipe_steps base
JOIN public.recipes r ON r.nocopk = base.recipe_id;

/*
 * QR analytics rows intentionally carry scan-time snapshots. Keep vc_qr_scan_log
 * as a passthrough instead of joining current Product/Lot/Item/Strain state and
 * accidentally rewriting historical meaning.
 */
CREATE OR REPLACE VIEW public.v_qr_scan_log AS
SELECT
  t.*,
  'public.qr_scan_log'::text AS __table,
  COALESCE(t.request_id::text, t.nocopk::text) AS __primary
FROM public.qr_scan_log t;

CREATE OR REPLACE VIEW public.vc_qr_scan_log AS
SELECT *
FROM public.v_qr_scan_log;

COMMENT ON VIEW public.v_ingredients IS
  'Base compatibility view for PostgreSQL-native Ingredient definitions introduced by Issue #79.';
COMMENT ON VIEW public.vc_ingredients IS
  'Computed/public interface for Ingredient definitions; currently a passthrough of v_ingredients.';
COMMENT ON VIEW public.v_recipe_ingredients IS
  'Base compatibility view for structured Recipe Ingredient rows introduced by Issue #79.';
COMMENT ON VIEW public.vc_recipe_ingredients IS
  'Structured Recipe Ingredient view enriched with Recipe, Ingredient, and optional parent Ingredient display values.';
COMMENT ON VIEW public.v_recipe_steps IS
  'Base compatibility view for ordered Recipe instruction steps introduced by Issue #79.';
COMMENT ON VIEW public.vc_recipe_steps IS
  'Recipe instruction-step view enriched with Recipe code and name.';
COMMENT ON VIEW public.v_qr_scan_log IS
  'Base compatibility view for QR resolver analytics introduced by Issue #81.';
COMMENT ON VIEW public.vc_qr_scan_log IS
  'QR analytics public interface preserving the scan-time snapshot stored in qr_scan_log.';

COMMIT;
