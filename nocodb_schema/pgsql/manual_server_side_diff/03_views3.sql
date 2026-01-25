-- Views for externalized MushroomProcess schema
-- Schema: pjeqn1nkx5sas6e
-- Generated to be compatible with existing v_* views: this script DROPS and recreates them.

BEGIN;

	-- Drop existing views so CREATE VIEW can change column layout safely

DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_lots CASCADE;
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_products CASCADE;
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_recipes CASCADE;
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_items CASCADE;
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_locations CASCADE;
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_strains CASCADE;
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_events CASCADE;
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_print_queue CASCADE;
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_sterilization_runs CASCADE;
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_ecommerce CASCADE;
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_ecommerce_orders CASCADE;

-- Recreate views

CREATE VIEW "pjeqn1nkx5sas6e".v_lots AS
SELECT
  t.*,
  'pjeqn1nkx5sas6e.lots'::text AS __table,
  COALESCE(t.lot_id, t.item_name_mat, t.nocopk::text) AS __primary,

  -- Links (arrays of nocopk ids via junction tables)
  (SELECT COALESCE(array_agg(j.products_id ORDER BY j.products_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_products" j
	   WHERE j.lots_id = t.nocopk) AS lots__products_ids,

  (SELECT COALESCE(array_agg(j.recipes_id ORDER BY j.recipes_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_recipes" j
	   WHERE j.lots_id = t.nocopk) AS lots__recipes_ids,

  (SELECT COALESCE(array_agg(j.lots1_id ORDER BY j.lots1_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_lots" j
	   WHERE j.lots_id = t.nocopk) AS lots__lots_a_ids,

  (SELECT COALESCE(array_agg(j.lots1_id ORDER BY j.lots1_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_lots1" j
	   WHERE j.lots_id = t.nocopk) AS lots__lots_b_ids,

  (SELECT COALESCE(array_agg(j.lots1_id ORDER BY j.lots1_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_lots2" j
	   WHERE j.lots_id = t.nocopk) AS lots__lots_c_ids

FROM "pjeqn1nkx5sas6e".lots t;

CREATE VIEW "pjeqn1nkx5sas6e".v_products AS
SELECT
  t.*,
  'pjeqn1nkx5sas6e.products'::text AS __table,
  COALESCE(t.product_id, t.name_mat, t.nocopk::text) AS __primary,

  (SELECT COALESCE(array_agg(j.lots_id ORDER BY j.lots_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_products" j
	   WHERE j.products_id = t.nocopk) AS products__lots_ids,

  (SELECT COALESCE(array_agg(j.products1_id ORDER BY j.products1_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_products_products" j
	   WHERE j.products_id = t.nocopk) AS products__products_ids

FROM "pjeqn1nkx5sas6e".products t;

CREATE VIEW "pjeqn1nkx5sas6e".v_recipes AS
SELECT
  t.*,
  'pjeqn1nkx5sas6e.recipes'::text AS __table,
  COALESCE(t.name, t.recipe_id, t.nocopk::text) AS __primary,

  (SELECT COALESCE(array_agg(j.lots_id ORDER BY j.lots_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_recipes" j
	   WHERE j.recipes_id = t.nocopk) AS recipes__lots_ids

FROM "pjeqn1nkx5sas6e".recipes t;

CREATE VIEW "pjeqn1nkx5sas6e".v_items AS
SELECT
  t.*,
  'pjeqn1nkx5sas6e.items'::text AS __table,
  COALESCE(t.name, t.item_id, t.nocopk::text) AS __primary
FROM "pjeqn1nkx5sas6e".items t;

CREATE VIEW "pjeqn1nkx5sas6e".v_locations AS
SELECT
  t.*,
  'pjeqn1nkx5sas6e.locations'::text AS __table,
  COALESCE(t.name, t.nocopk::text) AS __primary
FROM "pjeqn1nkx5sas6e".locations t;

CREATE VIEW "pjeqn1nkx5sas6e".v_strains AS
SELECT
  t.*,
  'pjeqn1nkx5sas6e.strains'::text AS __table,
  COALESCE(t.species_strain, t.strain_id, t.nocopk::text) AS __primary
FROM "pjeqn1nkx5sas6e".strains t;

CREATE VIEW "pjeqn1nkx5sas6e".v_events AS
SELECT
  t.*,
  'pjeqn1nkx5sas6e.events'::text AS __table,
  COALESCE(t.event_id, t.nocopk::text) AS __primary
FROM "pjeqn1nkx5sas6e".events t;

CREATE VIEW "pjeqn1nkx5sas6e".v_print_queue AS
SELECT
  t.*,
  'pjeqn1nkx5sas6e.print_queue'::text AS __table,
  COALESCE(t.print_id, t.nocopk::text) AS __primary
FROM "pjeqn1nkx5sas6e".print_queue t;

CREATE VIEW "pjeqn1nkx5sas6e".v_sterilization_runs AS
SELECT
  t.*,
  'pjeqn1nkx5sas6e.sterilization_runs'::text AS __table,
  COALESCE(t.steri_run_id, t.nocopk::text) AS __primary
FROM "pjeqn1nkx5sas6e".sterilization_runs t;

CREATE VIEW "pjeqn1nkx5sas6e".v_ecommerce AS
SELECT
  t.*,
  'pjeqn1nkx5sas6e.ecommerce'::text AS __table,
  COALESCE(t.name, t.ecwid_sku, t.nocopk::text) AS __primary
FROM "pjeqn1nkx5sas6e".ecommerce t;

CREATE VIEW "pjeqn1nkx5sas6e".v_ecommerce_orders AS
SELECT
  t.*,
  'pjeqn1nkx5sas6e.ecommerce_orders'::text AS __table,
  COALESCE(t.name, t.ecwid_order_id, t.nocopk::text) AS __primary
FROM "pjeqn1nkx5sas6e".ecommerce_orders t;

COMMIT;

