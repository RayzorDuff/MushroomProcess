-- Auto-generated views to expose M2M link relationships as array columns.
-- Schema: pjeqn1nkx5sas6e
-- These views are designed to be safe: they only depend on existing base tables and _nc_m2m_* junction tables.

BEGIN;

	-- Lots
CREATE OR REPLACE VIEW "pjeqn1nkx5sas6e".v_lots AS
SELECT
  t.*,

  -- lots <-> products
  (SELECT COALESCE(array_agg(j.products_id ORDER BY j.products_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_products" j
	   WHERE j.lots_id = t.nocopk) AS lots__products_ids,

  (SELECT COALESCE(array_agg(j.lots_id ORDER BY j.lots_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_products" j
	   WHERE j.products_id = t.nocopk) AS products__lots_ids,

  -- lots <-> recipes
  (SELECT COALESCE(array_agg(j.recipes_id ORDER BY j.recipes_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_recipes" j
	   WHERE j.lots_id = t.nocopk) AS lots__recipes_ids,

  (SELECT COALESCE(array_agg(j.lots_id ORDER BY j.lots_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_recipes" j
	   WHERE j.recipes_id = t.nocopk) AS recipes__lots_ids,

  -- lots <-> lots (three distinct link fields in Airtable; NocoDB emitted three junction tables)
  (SELECT COALESCE(array_agg(j.lots1_id ORDER BY j.lots1_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_lots" j
	   WHERE j.lots_id = t.nocopk) AS lots__lots_a_ids,

  (SELECT COALESCE(array_agg(j.lots_id ORDER BY j.lots_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_lots" j
	   WHERE j.lots1_id = t.nocopk) AS lots_a__lots_ids,

  (SELECT COALESCE(array_agg(j.lots1_id ORDER BY j.lots1_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_lots1" j
	   WHERE j.lots_id = t.nocopk) AS lots__lots_b_ids,

  (SELECT COALESCE(array_agg(j.lots_id ORDER BY j.lots_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_lots1" j
	   WHERE j.lots1_id = t.nocopk) AS lots_b__lots_ids,

  (SELECT COALESCE(array_agg(j.lots1_id ORDER BY j.lots1_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_lots2" j
	   WHERE j.lots_id = t.nocopk) AS lots__lots_c_ids,

  (SELECT COALESCE(array_agg(j.lots_id ORDER BY j.lots_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_lots2" j
	   WHERE j.lots1_id = t.nocopk) AS lots_c__lots_ids

FROM "pjeqn1nkx5sas6e".lots t;

-- Products
CREATE OR REPLACE VIEW "pjeqn1nkx5sas6e".v_products AS
SELECT
  t.*,

  -- products <-> products (self link)
  (SELECT COALESCE(array_agg(j.products1_id ORDER BY j.products1_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_products_products" j
	   WHERE j.products_id = t.nocopk) AS products__products_a_ids,

  (SELECT COALESCE(array_agg(j.products_id ORDER BY j.products_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_products_products" j
	   WHERE j.products1_id = t.nocopk) AS products_a__products_ids,

  -- products <-> lots (inverse convenience; primary is in v_lots)
  (SELECT COALESCE(array_agg(j.lots_id ORDER BY j.lots_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_products" j
	   WHERE j.products_id = t.nocopk) AS products__lots_ids

FROM "pjeqn1nkx5sas6e".products t;

-- Recipes
CREATE OR REPLACE VIEW "pjeqn1nkx5sas6e".v_recipes AS
SELECT
  t.*,

  (SELECT COALESCE(array_agg(j.lots_id ORDER BY j.lots_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_recipes" j
	   WHERE j.recipes_id = t.nocopk) AS recipes__lots_ids

FROM "pjeqn1nkx5sas6e".recipes t;

-- Other tables: passthrough views (kept simple and compatible)
CREATE OR REPLACE VIEW "pjeqn1nkx5sas6e".v_items AS SELECT t.* FROM "pjeqn1nkx5sas6e".items t;
CREATE OR REPLACE VIEW "pjeqn1nkx5sas6e".v_locations AS SELECT t.* FROM "pjeqn1nkx5sas6e".locations t;
CREATE OR REPLACE VIEW "pjeqn1nkx5sas6e".v_strains AS SELECT t.* FROM "pjeqn1nkx5sas6e".strains t;
CREATE OR REPLACE VIEW "pjeqn1nkx5sas6e".v_events AS SELECT t.* FROM "pjeqn1nkx5sas6e".events t;
CREATE OR REPLACE VIEW "pjeqn1nkx5sas6e".v_print_queue AS SELECT t.* FROM "pjeqn1nkx5sas6e".print_queue t;
CREATE OR REPLACE VIEW "pjeqn1nkx5sas6e".v_sterilization_runs AS SELECT t.* FROM "pjeqn1nkx5sas6e".sterilization_runs t;
CREATE OR REPLACE VIEW "pjeqn1nkx5sas6e".v_ecommerce AS SELECT t.* FROM "pjeqn1nkx5sas6e".ecommerce t;
CREATE OR REPLACE VIEW "pjeqn1nkx5sas6e".v_ecommerce_orders AS SELECT t.* FROM "pjeqn1nkx5sas6e".ecommerce_orders t;

COMMIT;

