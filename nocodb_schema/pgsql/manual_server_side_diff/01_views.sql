-- Auto-generated views.sql (safe pass-through views + primary display helper)
SET search_path = pjeqn1nkx5sas6e, public;

CREATE OR REPLACE VIEW pjeqn1nkx5sas6e."v_strains" AS
SELECT
  t.*,
  t."strain_id" AS "__primary",
  'strains'::text AS "__table"
FROM pjeqn1nkx5sas6e."strains" t;

--CREATE OR REPLACE VIEW pjeqn1nkx5sas6e."v_recipes" AS
--SELECT
--  t.*,
--  t."recipe_id" AS "__primary",
--  'recipes'::text AS "__table"
--FROM pjeqn1nkx5sas6e."recipes" t;

CREATE OR REPLACE VIEW pjeqn1nkx5sas6e."v_products" AS
SELECT
  t.*,
  t."product_id" AS "__primary",
  'products'::text AS "__table"
FROM pjeqn1nkx5sas6e."products" t;

CREATE OR REPLACE VIEW pjeqn1nkx5sas6e."v_lots" AS
SELECT
  t.*,
  t."lot_id" AS "__primary",
  'lots'::text AS "__table"
FROM pjeqn1nkx5sas6e."lots" t;

CREATE OR REPLACE VIEW pjeqn1nkx5sas6e."v_items" AS
SELECT
  t.*,
  t."item_id" AS "__primary",
  'items'::text AS "__table"
FROM pjeqn1nkx5sas6e."items" t;

CREATE OR REPLACE VIEW pjeqn1nkx5sas6e."v_events" AS
SELECT
  t.*,
  t."event_id" AS "__primary",
  'events'::text AS "__table"
FROM pjeqn1nkx5sas6e."events" t;

CREATE OR REPLACE VIEW pjeqn1nkx5sas6e."v_locations" AS
SELECT
  t.*,
  t."name" AS "__primary",
  'locations'::text AS "__table"
FROM pjeqn1nkx5sas6e."locations" t;

CREATE OR REPLACE VIEW pjeqn1nkx5sas6e."v_sterilization_runs" AS
SELECT
  t.*,
  t."steri_run_id" AS "__primary",
  'sterilization_runs'::text AS "__table"
FROM pjeqn1nkx5sas6e."sterilization_runs" t;

CREATE OR REPLACE VIEW pjeqn1nkx5sas6e."v_print_queue" AS
SELECT
  t.*,
  t."print_id" AS "__primary",
  'print_queue'::text AS "__table"
FROM pjeqn1nkx5sas6e."print_queue" t;

--CREATE OR REPLACE VIEW pjeqn1nkx5sas6e."v_ecommerce" AS
--SELECT
--  t.*,
--  t."name" AS "__primary",
-- 'ecommerce'::text AS "__table"
--FROM pjeqn1nkx5sas6e."ecommerce" t;

--CREATE OR REPLACE VIEW pjeqn1nkx5sas6e."v_ecommerce_orders" AS
--SELECT
--  t.*,
--  t."name" AS "__primary",
--  'ecommerce_orders'::text AS "__table"
--FROM pjeqn1nkx5sas6e."ecommerce_orders" t;

