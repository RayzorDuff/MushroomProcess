-- 000_example_recipe_seed.sql
-- Optional EXAMPLE DATA ONLY for MushroomProcess release/demo environments.
--
-- This file intentionally contains synthetic recipes, ingredients, and vendor
-- names. It is not Dank Mushrooms production recipe data and should not be
-- treated as an operational source of truth.
--
-- Prerequisites:
--   032_recipe_management.sql
--   033_recipe_document_model.sql
--
-- The seed is idempotent. Re-running it updates the same EXAMPLE-* records.

SET client_min_messages TO WARNING;
BEGIN;

-- ---------------------------------------------------------------------------
-- Example ingredient master
-- ---------------------------------------------------------------------------
INSERT INTO public.ingredients (
  ingredient_id, active, name, category, default_unit,
  preferred_vendor, notes, nc_created_at, nc_updated_at
)
VALUES
  ('ING-EXAMPLE-MALT',      true, 'Malt Extract (Example)',      'nutrient',  'g',  'Example Lab Supply Co.',  'Synthetic release/demo ingredient.' , now(), now()),
  ('ING-EXAMPLE-DEXTROSE',  true, 'Dextrose (Example)',          'nutrient',  'g',  'Example Lab Supply Co.',  'Synthetic release/demo ingredient.' , now(), now()),
  ('ING-EXAMPLE-PEPTONE',   true, 'Soy Peptone (Example)',       'nutrient',  'g',  'Example Lab Supply Co.',  'Synthetic release/demo ingredient.' , now(), now()),
  ('ING-EXAMPLE-WATER',     true, 'Filtered Water (Example)',    'water',     'ml', 'Example Water Source',    'Synthetic release/demo ingredient.' , now(), now()),
  ('ING-EXAMPLE-HARDWOOD',  true, 'Hardwood Pellets (Example)',  'substrate', 'lb', 'Example Forest Supply',   'Synthetic release/demo ingredient.' , now(), now()),
  ('ING-EXAMPLE-SOY-HULLS', true, 'Soy Hulls (Example)',         'substrate', 'lb', 'Example Farm Supply',     'Synthetic release/demo ingredient.' , now(), now()),
  ('ING-EXAMPLE-GYPSUM',    true, 'Gypsum (Example)',            'mineral',   'g',  'Example Farm Supply',     'Synthetic release/demo ingredient.' , now(), now())
ON CONFLICT (ingredient_id) DO UPDATE
SET active = EXCLUDED.active,
    name = EXCLUDED.name,
    category = EXCLUDED.category,
    default_unit = EXCLUDED.default_unit,
    preferred_vendor = EXCLUDED.preferred_vendor,
    notes = EXCLUDED.notes,
    nc_updated_at = now();

-- ---------------------------------------------------------------------------
-- Example recipes
-- ---------------------------------------------------------------------------
INSERT INTO public.recipes (
  recipe_id, active, name, category, notes,
  description, batch_yield_text, nc_created_at, nc_updated_at
)
VALUES
  (
    'REC-EXAMPLE-LC', true, 'Example Liquid Culture Formula', 'liquid_culture',
    'Synthetic example recipe distributed with MushroomProcess releases.',
    'A simple example liquid-culture formulation showing structured ingredients, vendor sources, and ordered processing instructions.',
    'Example batch: 1 L', now(), now()
  ),
  (
    'REC-EXAMPLE-HW75', true, 'Example Hardwood/Soy 75/25 Substrate', 'substrate',
    'Synthetic example recipe distributed with MushroomProcess releases.',
    'A simple example supplemented-hardwood substrate showing dry ingredients, hydration, bagging, and sterilization instructions.',
    'Example batch: 10 lb hydrated substrate', now(), now()
  )
ON CONFLICT (recipe_id) DO UPDATE
SET active = EXCLUDED.active,
    name = EXCLUDED.name,
    category = EXCLUDED.category,
    notes = EXCLUDED.notes,
    description = EXCLUDED.description,
    batch_yield_text = EXCLUDED.batch_yield_text,
    nc_updated_at = now();

-- ---------------------------------------------------------------------------
-- Structured ingredients for the example recipes
-- ---------------------------------------------------------------------------
WITH ids AS (
  SELECT
    (SELECT nocopk FROM public.recipes WHERE recipe_id = 'REC-EXAMPLE-LC') AS lc_recipe,
    (SELECT nocopk FROM public.recipes WHERE recipe_id = 'REC-EXAMPLE-HW75') AS hw_recipe,
    (SELECT nocopk FROM public.ingredients WHERE ingredient_id = 'ING-EXAMPLE-MALT') AS malt,
    (SELECT nocopk FROM public.ingredients WHERE ingredient_id = 'ING-EXAMPLE-DEXTROSE') AS dextrose,
    (SELECT nocopk FROM public.ingredients WHERE ingredient_id = 'ING-EXAMPLE-PEPTONE') AS peptone,
    (SELECT nocopk FROM public.ingredients WHERE ingredient_id = 'ING-EXAMPLE-WATER') AS water,
    (SELECT nocopk FROM public.ingredients WHERE ingredient_id = 'ING-EXAMPLE-HARDWOOD') AS hardwood,
    (SELECT nocopk FROM public.ingredients WHERE ingredient_id = 'ING-EXAMPLE-SOY-HULLS') AS soy_hulls,
    (SELECT nocopk FROM public.ingredients WHERE ingredient_id = 'ING-EXAMPLE-GYPSUM') AS gypsum
)
INSERT INTO public.recipe_ingredients (
  recipe_ingredient_id, recipe_id, ingredient_id,
  amount, amount_max, quantity_text, unit, vendor_name,
  alternative_group, parent_recipe_ingredient_id, optional,
  sort_order, active, notes, nc_created_at, nc_updated_at
)
SELECT * FROM (
  SELECT 'RING-EXAMPLE-LC-001', ids.lc_recipe, ids.malt,
         16::numeric, NULL::numeric, NULL::text, 'g'::text, 'Example Lab Supply Co.'::text,
         NULL::text, NULL::bigint, false, 10::numeric, true,
         'Example vendor-sourced malt extract.'::text, now(), now()
  FROM ids
  UNION ALL
  SELECT 'RING-EXAMPLE-LC-002', ids.lc_recipe, ids.dextrose,
         3::numeric, NULL::numeric, NULL::text, 'g'::text, 'Example Lab Supply Co.'::text,
         NULL::text, NULL::bigint, false, 20::numeric, true,
         'Example vendor-sourced dextrose.'::text, now(), now()
  FROM ids
  UNION ALL
  SELECT 'RING-EXAMPLE-LC-003', ids.lc_recipe, ids.peptone,
         1::numeric, NULL::numeric, NULL::text, 'g'::text, 'Example Lab Supply Co.'::text,
         NULL::text, NULL::bigint, false, 30::numeric, true,
         'Example vendor-sourced soy peptone.'::text, now(), now()
  FROM ids
  UNION ALL
  SELECT 'RING-EXAMPLE-LC-004', ids.lc_recipe, ids.water,
         1000::numeric, NULL::numeric, NULL::text, 'ml'::text, 'Example Water Source'::text,
         NULL::text, NULL::bigint, false, 40::numeric, true,
         NULL::text, now(), now()
  FROM ids
  UNION ALL
  SELECT 'RING-EXAMPLE-HW75-001', ids.hw_recipe, ids.hardwood,
         3.75::numeric, NULL::numeric, '75% of dry substrate blend'::text, 'lb'::text, 'Example Forest Supply'::text,
         NULL::text, NULL::bigint, false, 10::numeric, true,
         'Example hardwood component.'::text, now(), now()
  FROM ids
  UNION ALL
  SELECT 'RING-EXAMPLE-HW75-002', ids.hw_recipe, ids.soy_hulls,
         1.25::numeric, NULL::numeric, '25% of dry substrate blend'::text, 'lb'::text, 'Example Farm Supply'::text,
         NULL::text, NULL::bigint, false, 20::numeric, true,
         'Example soy-hull supplement.'::text, now(), now()
  FROM ids
  UNION ALL
  SELECT 'RING-EXAMPLE-HW75-003', ids.hw_recipe, ids.gypsum,
         90::numeric, NULL::numeric, NULL::text, 'g'::text, 'Example Farm Supply'::text,
         NULL::text, NULL::bigint, true, 30::numeric, true,
         'Optional example mineral amendment.'::text, now(), now()
  FROM ids
  UNION ALL
  SELECT 'RING-EXAMPLE-HW75-004', ids.hw_recipe, ids.water,
         5::numeric, 6::numeric, 'Add approximately 5-6 lb water to reach field capacity'::text, 'lb'::text, 'Example Water Source'::text,
         NULL::text, NULL::bigint, false, 40::numeric, true,
         'Example quantity range.'::text, now(), now()
  FROM ids
) AS seeded(
  recipe_ingredient_id, recipe_id, ingredient_id,
  amount, amount_max, quantity_text, unit, vendor_name,
  alternative_group, parent_recipe_ingredient_id, optional,
  sort_order, active, notes, nc_created_at, nc_updated_at
)
ON CONFLICT (recipe_ingredient_id) DO UPDATE
SET recipe_id = EXCLUDED.recipe_id,
    ingredient_id = EXCLUDED.ingredient_id,
    amount = EXCLUDED.amount,
    amount_max = EXCLUDED.amount_max,
    quantity_text = EXCLUDED.quantity_text,
    unit = EXCLUDED.unit,
    vendor_name = EXCLUDED.vendor_name,
    alternative_group = EXCLUDED.alternative_group,
    parent_recipe_ingredient_id = EXCLUDED.parent_recipe_ingredient_id,
    optional = EXCLUDED.optional,
    sort_order = EXCLUDED.sort_order,
    active = EXCLUDED.active,
    notes = EXCLUDED.notes,
    nc_updated_at = now();

-- ---------------------------------------------------------------------------
-- Ordered example instructions
-- ---------------------------------------------------------------------------
WITH ids AS (
  SELECT
    (SELECT nocopk FROM public.recipes WHERE recipe_id = 'REC-EXAMPLE-LC') AS lc_recipe,
    (SELECT nocopk FROM public.recipes WHERE recipe_id = 'REC-EXAMPLE-HW75') AS hw_recipe
)
INSERT INTO public.recipe_steps (
  recipe_step_id, recipe_id, active, section, section_order,
  step_order, instruction, notes, nc_created_at, nc_updated_at
)
SELECT * FROM (
  SELECT 'RSTEP-EXAMPLE-LC-001', ids.lc_recipe, true, 'Preparation', 10::numeric, 10::numeric,
         'Dissolve the example dry nutrients in a portion of the filtered water, then bring the mixture to the final batch volume.'::text,
         'Synthetic example instruction.'::text, now(), now()
  FROM ids
  UNION ALL
  SELECT 'RSTEP-EXAMPLE-LC-002', ids.lc_recipe, true, 'Sterilization', 20::numeric, 10::numeric,
         'Transfer the example medium to suitable vessels and sterilize using the validated process for the installation.'::text,
         'Intentionally generic; not a production process specification.'::text, now(), now()
  FROM ids
  UNION ALL
  SELECT 'RSTEP-EXAMPLE-HW75-001', ids.hw_recipe, true, 'Preparation', 10::numeric, 10::numeric,
         'Mix the example hardwood, soy hulls, and optional gypsum evenly while dry.'::text,
         'Synthetic example instruction.'::text, now(), now()
  FROM ids
  UNION ALL
  SELECT 'RSTEP-EXAMPLE-HW75-002', ids.hw_recipe, true, 'Hydration', 20::numeric, 10::numeric,
         'Add water gradually until the example substrate reaches the desired field-capacity consistency.'::text,
         'Synthetic example instruction.'::text, now(), now()
  FROM ids
  UNION ALL
  SELECT 'RSTEP-EXAMPLE-HW75-003', ids.hw_recipe, true, 'Sterilization', 30::numeric, 10::numeric,
         'Package the hydrated example substrate and sterilize using the validated process for the installation.'::text,
         'Intentionally generic; not a production process specification.'::text, now(), now()
  FROM ids
) AS seeded(
  recipe_step_id, recipe_id, active, section, section_order,
  step_order, instruction, notes, nc_created_at, nc_updated_at
)
ON CONFLICT (recipe_step_id) DO UPDATE
SET recipe_id = EXCLUDED.recipe_id,
    active = EXCLUDED.active,
    section = EXCLUDED.section,
    section_order = EXCLUDED.section_order,
    step_order = EXCLUDED.step_order,
    instruction = EXCLUDED.instruction,
    notes = EXCLUDED.notes,
    nc_updated_at = now();

COMMIT;

-- Optional verification summary.
SELECT
  r.recipe_id,
  r.name,
  count(DISTINCT ri.nocopk) AS structured_ingredients,
  count(DISTINCT rs.nocopk) AS instruction_steps
FROM public.recipes r
LEFT JOIN public.recipe_ingredients ri ON ri.recipe_id = r.nocopk AND ri.active = true
LEFT JOIN public.recipe_steps rs ON rs.recipe_id = r.nocopk AND rs.active = true
WHERE r.recipe_id LIKE 'REC-EXAMPLE-%'
GROUP BY r.recipe_id, r.name
ORDER BY r.recipe_id;
