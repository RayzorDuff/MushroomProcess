-- views_all.sql
-- Rebuild all v_* views in schema pjeqn1nkx5sas6e.
-- Drops existing v_* views then recreates:
--  - v_lots and v_products with friendly link arrays + rollups (from views4.sql)
--  - v_recipes with recipes__lots_ids link array
--  - other v_* as passthrough with __table and __primary helpers

BEGIN;

	-- Drop all existing v_* views in this schema (safe rebuild)
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_ecommerce_orders CASCADE;
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_ecommerce CASCADE;
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_events CASCADE;
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_items CASCADE;
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_locations CASCADE;
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_lots CASCADE;
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_print_queue CASCADE;
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_products CASCADE;
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_recipes CASCADE;
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_sterilization_runs CASCADE;
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_strains CASCADE;

-- v_lots (links + friendly arrays + rollups)
CREATE VIEW "pjeqn1nkx5sas6e".v_lots AS
SELECT
  t.*,
  'pjeqn1nkx5sas6e.lots'::text AS __table,
  COALESCE(t.lot_id, t.item_name_mat, t.nocopk::text) AS __primary,

  (SELECT COALESCE(array_agg(j.products_id ORDER BY j.products_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_products" j
	   WHERE j.lots_id = t.nocopk) AS lots__products_ids,

  (SELECT COALESCE(
		            array_agg(p.product_id ORDER BY p.product_id) FILTER (WHERE p.product_id IS NOT NULL),
			            '{}'::text[])
			   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_products" j
			   JOIN "pjeqn1nkx5sas6e".products p ON p.nocopk = j.products_id
			   WHERE j.lots_id = t.nocopk) AS lots__products_product_id,

		  (SELECT COALESCE(
				            array_agg(p.name_mat ORDER BY p.name_mat) FILTER (WHERE p.name_mat IS NOT NULL),
					            '{}'::text[])
					   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_products" j
					   JOIN "pjeqn1nkx5sas6e".products p ON p.nocopk = j.products_id
					   WHERE j.lots_id = t.nocopk) AS lots__products_name_mat,

				  (SELECT COUNT(*)
					   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_products" j
					   WHERE j.lots_id = t.nocopk) AS lots__products_count,

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

				-- v_products (links + friendly arrays + rollups)
CREATE VIEW "pjeqn1nkx5sas6e".v_products AS
SELECT
  t.*,
  'pjeqn1nkx5sas6e.products'::text AS __table,
  COALESCE(t.product_id, t.name_mat, t.nocopk::text) AS __primary,

  (SELECT COALESCE(array_agg(j.lots_id ORDER BY j.lots_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_products" j
	   WHERE j.products_id = t.nocopk) AS products__lots_ids,

  (SELECT COALESCE(
		            array_agg(l.lot_id ORDER BY l.lot_id) FILTER (WHERE l.lot_id IS NOT NULL),
			            '{}'::text[])
			   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_products" j
			   JOIN "pjeqn1nkx5sas6e".lots l ON l.nocopk = j.lots_id
			   WHERE j.products_id = t.nocopk) AS products__lots_lot_id,

		  (SELECT COALESCE(
				            array_agg(l.item_name_mat ORDER BY l.item_name_mat) FILTER (WHERE l.item_name_mat IS NOT NULL),
					            '{}'::text[])
					   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_products" j
					   JOIN "pjeqn1nkx5sas6e".lots l ON l.nocopk = j.lots_id
					   WHERE j.products_id = t.nocopk) AS products__lots_item_name_mat,

				  (SELECT COUNT(*)
					   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_products" j
					   WHERE j.products_id = t.nocopk) AS products__lots_count,

				  (SELECT COALESCE(array_agg(j.products1_id ORDER BY j.products1_id), '{}'::bigint[])
					   FROM "pjeqn1nkx5sas6e"."_nc_m2m_products_products" j
					   WHERE j.products_id = t.nocopk) AS products__products_ids

				FROM "pjeqn1nkx5sas6e".products t;

				-- v_recipes (links)
CREATE VIEW "pjeqn1nkx5sas6e".v_recipes AS
SELECT
  t.*,
  'pjeqn1nkx5sas6e.recipes'::text AS __table,
  COALESCE(t.name, t.recipe_id, t.nocopk::text) AS __primary,

  (SELECT COALESCE(array_agg(j.lots_id ORDER BY j.lots_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_recipes" j
	   WHERE j.recipes_id = t.nocopk) AS recipes__lots_ids

FROM "pjeqn1nkx5sas6e".recipes t;

-- Passthrough views with __primary helpers
CREATE VIEW "pjeqn1nkx5sas6e".v_items AS
SELECT t.*, 'pjeqn1nkx5sas6e.items'::text AS __table,
       COALESCE(t.name, t.item_id, t.nocopk::text) AS __primary
FROM "pjeqn1nkx5sas6e".items t;

CREATE VIEW "pjeqn1nkx5sas6e".v_locations AS
SELECT t.*, 'pjeqn1nkx5sas6e.locations'::text AS __table,
       COALESCE(t.name, t.nocopk::text) AS __primary
FROM "pjeqn1nkx5sas6e".locations t;

CREATE VIEW "pjeqn1nkx5sas6e".v_strains AS
SELECT t.*, 'pjeqn1nkx5sas6e.strains'::text AS __table,
       COALESCE(t.species_strain, t.strain_id, t.nocopk::text) AS __primary
FROM "pjeqn1nkx5sas6e".strains t;

CREATE VIEW "pjeqn1nkx5sas6e".v_sterilization_runs AS
SELECT t.*, 'pjeqn1nkx5sas6e.sterilization_runs'::text AS __table,
       COALESCE(t.steri_run_id, t.nocopk::text) AS __primary
FROM "pjeqn1nkx5sas6e".sterilization_runs t;

CREATE VIEW "pjeqn1nkx5sas6e".v_print_queue AS
SELECT t.*, 'pjeqn1nkx5sas6e.print_queue'::text AS __table,
       COALESCE(t.print_id, t.nocopk::text) AS __primary
FROM "pjeqn1nkx5sas6e".print_queue t;

CREATE VIEW "pjeqn1nkx5sas6e".v_events AS
SELECT t.*, 'pjeqn1nkx5sas6e.events'::text AS __table,
       COALESCE(t.event_id, t.nocopk::text) AS __primary
FROM "pjeqn1nkx5sas6e".events t;

CREATE VIEW "pjeqn1nkx5sas6e".v_ecommerce AS
SELECT t.*, 'pjeqn1nkx5sas6e.ecommerce'::text AS __table,
       COALESCE(t.name, t.ecwid_sku, t.nocopk::text) AS __primary
FROM "pjeqn1nkx5sas6e".ecommerce t;

CREATE VIEW "pjeqn1nkx5sas6e".v_ecommerce_orders AS
SELECT t.*, 'pjeqn1nkx5sas6e.ecommerce_orders'::text AS __table,
       COALESCE(t.name, t.ecwid_order_id, t.order_number::text, t.nocopk::text) AS __primary
FROM "pjeqn1nkx5sas6e".ecommerce_orders t;

COMMIT;
-- views_all.sql
-- Rebuild all v_* views in schema pjeqn1nkx5sas6e.
-- Drops existing v_* views then recreates:
--  - v_lots and v_products with friendly link arrays + rollups (from views4.sql)
--  - v_recipes with recipes__lots_ids link array
--  - other v_* as passthrough with __table and __primary helpers

BEGIN;

	-- Drop all existing v_* views in this schema (safe rebuild)
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_ecommerce_orders CASCADE;
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_ecommerce CASCADE;
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_events CASCADE;
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_items CASCADE;
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_locations CASCADE;
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_lots CASCADE;
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_print_queue CASCADE;
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_products CASCADE;
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_recipes CASCADE;
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_sterilization_runs CASCADE;
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_strains CASCADE;

-- v_lots (links + friendly arrays + rollups)
CREATE VIEW "pjeqn1nkx5sas6e".v_lots AS
SELECT
  t.*,
  'pjeqn1nkx5sas6e.lots'::text AS __table,
  COALESCE(t.lot_id, t.item_name_mat, t.nocopk::text) AS __primary,

  (SELECT COALESCE(array_agg(j.products_id ORDER BY j.products_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_products" j
	   WHERE j.lots_id = t.nocopk) AS lots__products_ids,

  (SELECT COALESCE(
		            array_agg(p.product_id ORDER BY p.product_id) FILTER (WHERE p.product_id IS NOT NULL),
			            '{}'::text[])
			   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_products" j
			   JOIN "pjeqn1nkx5sas6e".products p ON p.nocopk = j.products_id
			   WHERE j.lots_id = t.nocopk) AS lots__products_product_id,

		  (SELECT COALESCE(
				            array_agg(p.name_mat ORDER BY p.name_mat) FILTER (WHERE p.name_mat IS NOT NULL),
					            '{}'::text[])
					   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_products" j
					   JOIN "pjeqn1nkx5sas6e".products p ON p.nocopk = j.products_id
					   WHERE j.lots_id = t.nocopk) AS lots__products_name_mat,

				  (SELECT COUNT(*)
					   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_products" j
					   WHERE j.lots_id = t.nocopk) AS lots__products_count,

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

				-- v_products (links + friendly arrays + rollups)
CREATE VIEW "pjeqn1nkx5sas6e".v_products AS
SELECT
  t.*,
  'pjeqn1nkx5sas6e.products'::text AS __table,
  COALESCE(t.product_id, t.name_mat, t.nocopk::text) AS __primary,

  (SELECT COALESCE(array_agg(j.lots_id ORDER BY j.lots_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_products" j
	   WHERE j.products_id = t.nocopk) AS products__lots_ids,

  (SELECT COALESCE(
		            array_agg(l.lot_id ORDER BY l.lot_id) FILTER (WHERE l.lot_id IS NOT NULL),
			            '{}'::text[])
			   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_products" j
			   JOIN "pjeqn1nkx5sas6e".lots l ON l.nocopk = j.lots_id
			   WHERE j.products_id = t.nocopk) AS products__lots_lot_id,

		  (SELECT COALESCE(
				            array_agg(l.item_name_mat ORDER BY l.item_name_mat) FILTER (WHERE l.item_name_mat IS NOT NULL),
					            '{}'::text[])
					   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_products" j
					   JOIN "pjeqn1nkx5sas6e".lots l ON l.nocopk = j.lots_id
					   WHERE j.products_id = t.nocopk) AS products__lots_item_name_mat,

				  (SELECT COUNT(*)
					   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_products" j
					   WHERE j.products_id = t.nocopk) AS products__lots_count,

				  (SELECT COALESCE(array_agg(j.products1_id ORDER BY j.products1_id), '{}'::bigint[])
					   FROM "pjeqn1nkx5sas6e"."_nc_m2m_products_products" j
					   WHERE j.products_id = t.nocopk) AS products__products_ids

				FROM "pjeqn1nkx5sas6e".products t;

				-- v_recipes (links)
CREATE VIEW "pjeqn1nkx5sas6e".v_recipes AS
SELECT
  t.*,
  'pjeqn1nkx5sas6e.recipes'::text AS __table,
  COALESCE(t.name, t.recipe_id, t.nocopk::text) AS __primary,

  (SELECT COALESCE(array_agg(j.lots_id ORDER BY j.lots_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_recipes" j
	   WHERE j.recipes_id = t.nocopk) AS recipes__lots_ids

FROM "pjeqn1nkx5sas6e".recipes t;

-- Passthrough views with __primary helpers
CREATE VIEW "pjeqn1nkx5sas6e".v_items AS
SELECT t.*, 'pjeqn1nkx5sas6e.items'::text AS __table,
       COALESCE(t.name, t.item_id, t.nocopk::text) AS __primary
FROM "pjeqn1nkx5sas6e".items t;

CREATE VIEW "pjeqn1nkx5sas6e".v_locations AS
SELECT t.*, 'pjeqn1nkx5sas6e.locations'::text AS __table,
       COALESCE(t.name, t.nocopk::text) AS __primary
FROM "pjeqn1nkx5sas6e".locations t;

CREATE VIEW "pjeqn1nkx5sas6e".v_strains AS
SELECT t.*, 'pjeqn1nkx5sas6e.strains'::text AS __table,
       COALESCE(t.species_strain, t.strain_id, t.nocopk::text) AS __primary
FROM "pjeqn1nkx5sas6e".strains t;

CREATE VIEW "pjeqn1nkx5sas6e".v_sterilization_runs AS
SELECT t.*, 'pjeqn1nkx5sas6e.sterilization_runs'::text AS __table,
       COALESCE(t.steri_run_id, t.nocopk::text) AS __primary
FROM "pjeqn1nkx5sas6e".sterilization_runs t;

CREATE VIEW "pjeqn1nkx5sas6e".v_print_queue AS
SELECT t.*, 'pjeqn1nkx5sas6e.print_queue'::text AS __table,
       COALESCE(t.print_id, t.nocopk::text) AS __primary
FROM "pjeqn1nkx5sas6e".print_queue t;

CREATE VIEW "pjeqn1nkx5sas6e".v_events AS
SELECT t.*, 'pjeqn1nkx5sas6e.events'::text AS __table,
       COALESCE(t.event_id, t.nocopk::text) AS __primary
FROM "pjeqn1nkx5sas6e".events t;

CREATE VIEW "pjeqn1nkx5sas6e".v_ecommerce AS
SELECT t.*, 'pjeqn1nkx5sas6e.ecommerce'::text AS __table,
       COALESCE(t.name, t.ecwid_sku, t.nocopk::text) AS __primary
FROM "pjeqn1nkx5sas6e".ecommerce t;

CREATE VIEW "pjeqn1nkx5sas6e".v_ecommerce_orders AS
SELECT t.*, 'pjeqn1nkx5sas6e.ecommerce_orders'::text AS __table,
       COALESCE(t.name, t.ecwid_order_id, t.order_number::text, t.nocopk::text) AS __primary
FROM "pjeqn1nkx5sas6e".ecommerce_orders t;

COMMIT;

