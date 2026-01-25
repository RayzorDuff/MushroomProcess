-- views4.sql
-- Extends v_lots and v_products with friendly link lookup arrays and simple rollups.
-- Assumes junction tables:
--   pjeqn1nkx5sas6e._nc_m2m_lots_products(lots_id, products_id)
--   pjeqn1nkx5sas6e._nc_m2m_products_products(products_id, products1_id)
-- Uses base tables:
--   pjeqn1nkx5sas6e.lots(nocopk, lot_id, item_name_mat, ...)
--   pjeqn1nkx5sas6e.products(nocopk, product_id, name_mat, ...)

BEGIN;

	-- Drop only the views we are redefining (required to change column layout safely)
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_lots CASCADE;
DROP VIEW IF EXISTS "pjeqn1nkx5sas6e".v_products CASCADE;

-- Recreate v_lots
CREATE VIEW "pjeqn1nkx5sas6e".v_lots AS
SELECT
  t.*,
  'pjeqn1nkx5sas6e.lots'::text AS __table,
  COALESCE(t.lot_id, t.item_name_mat, t.nocopk::text) AS __primary,

  -- Links: lots <-> products (ids)
  (SELECT COALESCE(array_agg(j.products_id ORDER BY j.products_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_products" j
	   WHERE j.lots_id = t.nocopk) AS lots__products_ids,

  -- Friendly lookups for linked products
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

				  -- Rollup: count of linked products
  (SELECT COUNT(*)
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_products" j
	   WHERE j.lots_id = t.nocopk) AS lots__products_count,

  -- Links: lots <-> recipes (ids)
  (SELECT COALESCE(array_agg(j.recipes_id ORDER BY j.recipes_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_recipes" j
	   WHERE j.lots_id = t.nocopk) AS lots__recipes_ids,

  -- Self-links (three distinct junction tables in this base)
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

-- Recreate v_products
CREATE VIEW "pjeqn1nkx5sas6e".v_products AS
SELECT
  t.*,
  'pjeqn1nkx5sas6e.products'::text AS __table,
  COALESCE(t.product_id, t.name_mat, t.nocopk::text) AS __primary,

  -- Links: products <-> lots (ids)
  (SELECT COALESCE(array_agg(j.lots_id ORDER BY j.lots_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_products" j
	   WHERE j.products_id = t.nocopk) AS products__lots_ids,

  -- Friendly lookups for linked lots
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

				  -- Rollup: count of linked lots
  (SELECT COUNT(*)
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_lots_products" j
	   WHERE j.products_id = t.nocopk) AS products__lots_count,

  -- Self-link: products <-> products (ids)
  (SELECT COALESCE(array_agg(j.products1_id ORDER BY j.products1_id), '{}'::bigint[])
	   FROM "pjeqn1nkx5sas6e"."_nc_m2m_products_products" j
	   WHERE j.products_id = t.nocopk) AS products__products_ids

FROM "pjeqn1nkx5sas6e".products t;

COMMIT;

