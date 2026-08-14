SET search_path = public, pg_catalog;

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

-- Issue #12 Phase 6 follow-up:
-- Airtable is no longer the production source of truth. The runtime consumers
-- of these legacy navigation/formula fields were removed in the preceding
-- Phase 6 patch. This migration now removes the fields from the live
-- PostgreSQL computed views themselves.
--
-- The three target view definitions below were captured from production on
-- 2026-08-08 and are protected by whitespace-normalized md5 signatures. If a
-- target view has changed since that preflight, abort instead of overwriting a
-- newer production definition.
--
-- Downstream view definitions, owners, options, comments, and explicit grants
-- are captured from the live catalog before the target views are dropped, then
-- recreated in dependency order. DROP ... CASCADE is intentionally not used.

DO $$
DECLARE
  v_actual text;
BEGIN
  IF to_regclass('public.vc_lots') IS NULL
     OR to_regclass('public.vc_products') IS NULL
     OR to_regclass('public.vc_print_queue') IS NULL THEN
    RAISE EXCEPTION
      '031_remove_legacy_public_links.sql requires vc_lots, vc_products, and vc_print_queue';
  END IF;

  SELECT md5(trim(regexp_replace(pg_get_viewdef('public.vc_lots'::regclass, true),
                                 '[[:space:]]+', ' ', 'g')))
    INTO v_actual;
  IF v_actual <> '42e1f19b81f1e3bb97a2ab9df5ecc9ac' THEN
    RAISE EXCEPTION
      'vc_lots changed since the Phase 6 production preflight (signature %); regenerate migration 031 from the current live view definition',
      v_actual;
  END IF;

  SELECT md5(trim(regexp_replace(pg_get_viewdef('public.vc_products'::regclass, true),
                                 '[[:space:]]+', ' ', 'g')))
    INTO v_actual;
  IF v_actual <> 'cd7fd32d7c4769895cd9257de33832b8' THEN
    RAISE EXCEPTION
      'vc_products changed since the Phase 6 production preflight (signature %); regenerate migration 031 from the current live view definition',
      v_actual;
  END IF;

  SELECT md5(trim(regexp_replace(pg_get_viewdef('public.vc_print_queue'::regclass, true),
                                 '[[:space:]]+', ' ', 'g')))
    INTO v_actual;
  IF v_actual <> 'ddffaa4ea9f1faf9780dfcb74f6df694' THEN
    RAISE EXCEPTION
      'vc_print_queue changed since the Phase 6 production preflight (signature %); regenerate migration 031 from the current live view definition',
      v_actual;
  END IF;
END
$$;

CREATE TEMP TABLE _mp031_dependency_walk (
  dependent_oid oid NOT NULL,
  depth integer NOT NULL
) ON COMMIT DROP;

WITH RECURSIVE walk(dependent_oid, depth, path) AS (
  SELECT
    dependent.oid,
    1,
    ARRAY[source.oid, dependent.oid]::oid[]
  FROM pg_class source
  JOIN pg_namespace source_ns
    ON source_ns.oid = source.relnamespace
  JOIN pg_depend d
    ON d.classid = 'pg_rewrite'::regclass
   AND d.refclassid = 'pg_class'::regclass
   AND d.refobjid = source.oid
  JOIN pg_rewrite r
    ON r.oid = d.objid
  JOIN pg_class dependent
    ON dependent.oid = r.ev_class
  WHERE source_ns.nspname = 'public'
    AND source.relname IN ('vc_lots', 'vc_products', 'vc_print_queue')
    AND dependent.oid <> source.oid

  UNION ALL

  SELECT
    dependent.oid,
    walk.depth + 1,
    walk.path || dependent.oid
  FROM walk
  JOIN pg_depend d
    ON d.classid = 'pg_rewrite'::regclass
   AND d.refclassid = 'pg_class'::regclass
   AND d.refobjid = walk.dependent_oid
  JOIN pg_rewrite r
    ON r.oid = d.objid
  JOIN pg_class dependent
    ON dependent.oid = r.ev_class
  WHERE dependent.oid <> ALL (walk.path)
)
INSERT INTO _mp031_dependency_walk (dependent_oid, depth)
SELECT dependent_oid, max(depth)
FROM walk
GROUP BY dependent_oid;

DO $$
DECLARE
  v_unsupported text;
BEGIN
  SELECT string_agg(format('%I.%I (%s)', n.nspname, c.relname, c.relkind), ', ')
    INTO v_unsupported
  FROM (
    SELECT dependent_oid, max(depth) AS depth
    FROM _mp031_dependency_walk
    GROUP BY dependent_oid
  ) d
  JOIN pg_class c
    ON c.oid = d.dependent_oid
  JOIN pg_namespace n
    ON n.oid = c.relnamespace
  WHERE c.relkind <> 'v';

  IF v_unsupported IS NOT NULL THEN
    RAISE EXCEPTION
      'Legacy-link cleanup found non-view downstream objects that require an explicit migration path: %',
      v_unsupported;
  END IF;
END
$$;

CREATE TEMP TABLE _mp031_views (
  schema_name text NOT NULL,
  view_name text NOT NULL,
  depth integer NOT NULL,
  definition text,
  owner_name text NOT NULL,
  reloptions text[],
  view_comment text,
  is_target boolean NOT NULL DEFAULT false,
  PRIMARY KEY (schema_name, view_name)
) ON COMMIT DROP;

INSERT INTO _mp031_views (
  schema_name, view_name, depth, definition, owner_name,
  reloptions, view_comment, is_target
)
SELECT
  n.nspname,
  c.relname,
  0,
  NULL,
  pg_get_userbyid(c.relowner),
  c.reloptions,
  obj_description(c.oid, 'pg_class'),
  true
FROM pg_class c
JOIN pg_namespace n
  ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname IN ('vc_lots', 'vc_products', 'vc_print_queue')
  AND c.relkind = 'v';

INSERT INTO _mp031_views (
  schema_name, view_name, depth, definition, owner_name,
  reloptions, view_comment, is_target
)
SELECT
  n.nspname,
  c.relname,
  d.depth,
  pg_get_viewdef(c.oid, true),
  pg_get_userbyid(c.relowner),
  c.reloptions,
  obj_description(c.oid, 'pg_class'),
  false
FROM (
  SELECT dependent_oid, max(depth) AS depth
  FROM _mp031_dependency_walk
  GROUP BY dependent_oid
) d
JOIN pg_class c
  ON c.oid = d.dependent_oid
JOIN pg_namespace n
  ON n.oid = c.relnamespace
WHERE c.relkind = 'v'
  AND NOT (
    n.nspname = 'public'
    AND c.relname IN ('vc_lots', 'vc_products', 'vc_print_queue')
  )
ON CONFLICT (schema_name, view_name) DO UPDATE
SET depth = GREATEST(_mp031_views.depth, EXCLUDED.depth),
    definition = EXCLUDED.definition,
    owner_name = EXCLUDED.owner_name,
    reloptions = EXCLUDED.reloptions,
    view_comment = EXCLUDED.view_comment,
    is_target = false;

DO $$
DECLARE
  v_hidden_consumer text;
BEGIN
  SELECT string_agg(
           format('%I.%I', schema_name, view_name),
           ', ' ORDER BY depth, schema_name, view_name
         )
    INTO v_hidden_consumer
  FROM _mp031_views
  WHERE NOT is_target
    AND definition ~* '(^|[^a-z0-9_])public_link(_[a-z0-9_]+)?([^a-z0-9_]|$)';

  IF v_hidden_consumer IS NOT NULL THEN
    RAISE EXCEPTION
      'Downstream PostgreSQL views still explicitly consume legacy public_link fields: %. Remove those consumers before running migration 031.',
      v_hidden_consumer;
  END IF;
END
$$;

CREATE TEMP TABLE _mp031_column_comments (
  schema_name text NOT NULL,
  view_name text NOT NULL,
  column_name text NOT NULL,
  comment_text text NOT NULL
) ON COMMIT DROP;

INSERT INTO _mp031_column_comments (
  schema_name, view_name, column_name, comment_text
)
SELECT
  v.schema_name,
  v.view_name,
  a.attname,
  col_description(c.oid, a.attnum)
FROM _mp031_views v
JOIN pg_namespace n
  ON n.nspname = v.schema_name
JOIN pg_class c
  ON c.relnamespace = n.oid
 AND c.relname = v.view_name
JOIN pg_attribute a
  ON a.attrelid = c.oid
 AND a.attnum > 0
 AND NOT a.attisdropped
WHERE col_description(c.oid, a.attnum) IS NOT NULL
  AND NOT (
    v.is_target
    AND a.attname IN (
      'public_link',
      'public_link_dark_room',
      'public_link_fruiting',
      'public_link_harvest',
      'public_link_spawn_to_bulk',
      'public_link_inoculate_flask',
      'public_link_inoculate_grain',
      'public_link_freeze_dry_package',
      'public_link_substrate_package',
      'public_link_lot_lineage',
      'public_link_from_lot_id',
      'public_link_from_product_id'
    )
  );

CREATE TEMP TABLE _mp031_grants (
  schema_name text NOT NULL,
  view_name text NOT NULL,
  grantee_name text NOT NULL,
  privilege_type text NOT NULL,
  is_grantable boolean NOT NULL
) ON COMMIT DROP;

INSERT INTO _mp031_grants (
  schema_name, view_name, grantee_name, privilege_type, is_grantable
)
SELECT
  v.schema_name,
  v.view_name,
  CASE
    WHEN acl.grantee = 0 THEN 'PUBLIC'
    ELSE pg_get_userbyid(acl.grantee)
  END,
  acl.privilege_type,
  acl.is_grantable
FROM _mp031_views v
JOIN pg_namespace n
  ON n.nspname = v.schema_name
JOIN pg_class c
  ON c.relnamespace = n.oid
 AND c.relname = v.view_name
CROSS JOIN LATERAL aclexplode(c.relacl) acl;

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT schema_name, view_name
    FROM _mp031_views
    WHERE NOT is_target
    ORDER BY depth DESC, schema_name, view_name
  LOOP
    EXECUTE format('DROP VIEW %I.%I', r.schema_name, r.view_name);
  END LOOP;
END
$$;

DROP VIEW public.vc_print_queue;
DROP VIEW public.vc_products;
DROP VIEW public.vc_lots;


CREATE VIEW public.vc_lots AS
 WITH comp AS (
         SELECT base.nocopk,
            base.lot_id,
            base.item_id,
            base.item_name_mat,
            base.recipe_id,
            base.strain_id,
            base.qty,
            base.unit_size,
            base.status,
            base.parents_json,
            base.steri_run_id,
            base.location_id,
            base.operator,
            base.created_at,
            base.use_by,
            base.action,
            base.item_category_mat,
            base.process_type_mat,
            base.strain_species_strain_mat,
            base.vendor_name_mat,
            base.lc_volume_ml,
            base.output_count,
            base.fruiting_goal,
            base.flush_no,
            base.harvest_weight_g,
            base.notes,
            base.syringe_count,
            base.syringe_item_id,
            base.source_type,
            base.vendor_name,
            base.vendor_batch,
            base.received_date,
            base.total_volume_ml,
            base.ui_error,
            base.ui_error_at,
            base.remaining_volume_ml,
            base.fresh_tray_count,
            base.frozen_tray_count,
            base.casing_lot_id,
            base.casing_applied_at,
            base.casing_notes,
            base.casing_qty_used_g,
            base.label_template,
            base.override_inoc_time,
            base.inoculated_at,
            base.override_spawn_time,
            base.spawned_at,
            base.sterilized_at,
            base.source_lot_id,
            base.plate_count,
            base.plate_group_id,
            base.parent_lot_id,
            base.retired_at,
            base.beganfruiting_at,
            base.firstharvested_at,
            base.lastharvested_at,
            base.nocouuid,
            base.airtable_id,
            base.nc_created_at,
            base.nc_updated_at,
            base.__table,
            base.__primary,
            base.lots__events__events__ids,
            base.lots__lots__target_lot_ids__ids,
            base.lots__lots__grain_inputs__ids,
            base.lots__lots__substrate_inputs__ids,
            base.lots__items__harvest_item__ids,
            base.lots__products__products__ids,
            base.lots__print_queue__print_queue__ids,
            base.lots__ecommerce__ecommerce__ids,
            base.lots__lot_recipe_components__lot_recipe_components__ids,
            ( SELECT COALESCE(array_agg(btbl.name ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM items btbl
                  WHERE btbl.nocopk = base.item_id) AS item_name,
            ( SELECT COALESCE(array_agg(btbl.name ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM recipes btbl
                  WHERE btbl.nocopk = base.recipe_id) AS recipe_name,
            ( SELECT COALESCE(array_agg(btbl.regulated ORDER BY btbl.nocopk), ARRAY[]::boolean[]) AS "coalesce"
                   FROM strains btbl
                  WHERE btbl.nocopk = base.strain_id) AS regulated_from_strain_id,
            ( SELECT COALESCE(array_agg(btbl.species_strain ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM strains btbl
                  WHERE btbl.nocopk = base.strain_id) AS strain_species_strain,
            ( SELECT COALESCE(array_agg(btbl.process_type ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM sterilization_runs btbl
                  WHERE btbl.nocopk = base.steri_run_id) AS process_type_from_steri_run_id,
            ( SELECT COALESCE(array_agg(btbl.category ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM items btbl
                  WHERE btbl.nocopk = base.item_id) AS item_category,
            ( SELECT COALESCE(array_agg(btbl.item_name_mat ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM _m2m_lots_lots_grain_inputs j
                     JOIN v_lots btbl ON btbl.nocopk = j.lots1_id
                  WHERE j.lots_id = base.nocopk) AS item_name_mat_from_grain_inputs,
            ( SELECT COALESCE(array_agg(btbl.inoculated_at ORDER BY btbl.nocopk), ARRAY[]::timestamp without time zone[]) AS "coalesce"
                   FROM _m2m_lots_lots_grain_inputs j
                     JOIN v_lots btbl ON btbl.nocopk = j.lots1_id
                  WHERE j.lots_id = base.nocopk) AS inoculated_at_from_grain_inputs,
            ( SELECT COALESCE(array_agg(btbl.process_type_mat ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM _m2m_lots_lots_substrate_inputs j
                     JOIN v_lots btbl ON btbl.nocopk = j.lots1_id
                  WHERE j.lots_id = base.nocopk) AS process_type_mat_from_substrate_inputs,
            ( SELECT COALESCE(array_agg(btbl.item_name_mat ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM _m2m_lots_lots_substrate_inputs j
                     JOIN v_lots btbl ON btbl.nocopk = j.lots1_id
                  WHERE j.lots_id = base.nocopk) AS item_name_mat_from_substrate_inputs,
            ( SELECT COALESCE(array_agg(btbl.category ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM _m2m_lots_items_harvest_item j
                     JOIN items btbl ON btbl.nocopk = j.items_id
                  WHERE j.lots_id = base.nocopk) AS harvest_item_category,
            ( SELECT COALESCE(array_agg(btbl."timestamp" ORDER BY btbl.nocopk), ARRAY[]::timestamp without time zone[]) AS "coalesce"
                   FROM _m2m_lots_events_events j
                     JOIN events btbl ON btbl.nocopk = j.events_id
                  WHERE j.lots_id = base.nocopk) AS first_event_date,
            ( SELECT COALESCE(array_agg(btbl."timestamp" ORDER BY btbl.nocopk), ARRAY[]::timestamp without time zone[]) AS "coalesce"
                   FROM _m2m_lots_events_events j
                     JOIN events btbl ON btbl.nocopk = j.events_id
                  WHERE j.lots_id = base.nocopk) AS last_event_date,
            ( SELECT COALESCE(array_agg(((
                        CASE
                            WHEN NULLIF(btbl.component_role, ''::text) IS NOT NULL THEN COALESCE(btbl.component_role, ''::text) || ': '::text
                            ELSE ''::text
                        END || COALESCE(COALESCE(( SELECT ltbl.recipe_id
                           FROM v_recipes ltbl
                          WHERE ltbl.nocopk = btbl.recipe_id
                          ORDER BY ltbl.nocopk
                         LIMIT 1), ''::text), ''::text)) ||
                        CASE
                            WHEN COALESCE(btbl.component_weight_lb, 0::numeric) <> 0::numeric THEN (' — '::text || COALESCE(btbl.component_weight_lb::text, ''::text)) || ' lb'::text
                            ELSE ''::text
                        END) ||
                        CASE
                            WHEN COALESCE(btbl.component_percent, 0::numeric) <> 0::numeric THEN (' — '::text || COALESCE(btbl.component_percent::text, ''::text)) || '%'::text
                            ELSE ''::text
                        END ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM _m2m_lots_lot_recipe_components_lot_recipe_components j
                     JOIN vc_lot_recipe_components btbl ON btbl.nocopk = j.lot_recipe_components_id
                  WHERE j.lots_id = base.nocopk) AS lot_component_summary
           FROM v_lots base
        )
 SELECT nocopk,
    lot_id,
    item_id,
    item_name_mat,
    recipe_id,
    strain_id,
    qty,
    unit_size,
    status,
    parents_json,
    steri_run_id,
    location_id,
    operator,
    created_at,
    use_by,
    action,
    item_category_mat,
    process_type_mat,
    strain_species_strain_mat,
    vendor_name_mat,
    lc_volume_ml,
    output_count,
    fruiting_goal,
    flush_no,
    harvest_weight_g,
    notes,
    syringe_count,
    syringe_item_id,
    source_type,
    vendor_name,
    vendor_batch,
    received_date,
    total_volume_ml,
    ui_error,
    ui_error_at,
    remaining_volume_ml,
    fresh_tray_count,
    frozen_tray_count,
    casing_lot_id,
    casing_applied_at,
    casing_notes,
    casing_qty_used_g,
    label_template,
    override_inoc_time,
    inoculated_at,
    override_spawn_time,
    spawned_at,
    sterilized_at,
    source_lot_id,
    plate_count,
    plate_group_id,
    parent_lot_id,
    retired_at,
    beganfruiting_at,
    firstharvested_at,
    lastharvested_at,
    nocouuid,
    airtable_id,
    nc_created_at,
    nc_updated_at,
    __table,
    __primary,
    lots__events__events__ids,
    lots__lots__target_lot_ids__ids,
    lots__lots__grain_inputs__ids,
    lots__lots__substrate_inputs__ids,
    lots__items__harvest_item__ids,
    lots__products__products__ids,
    lots__print_queue__print_queue__ids,
    lots__ecommerce__ecommerce__ids,
    lots__lot_recipe_components__lot_recipe_components__ids,
    item_name,
    recipe_name,
    regulated_from_strain_id,
    strain_species_strain,
    process_type_from_steri_run_id,
    item_category,
    item_name_mat_from_grain_inputs,
    inoculated_at_from_grain_inputs,
    process_type_mat_from_substrate_inputs,
    item_name_mat_from_substrate_inputs,
    harvest_item_category,
    first_event_date,
    last_event_date,
    lot_component_summary,
    'Dank Mushrooms'::text AS label_company_lot,
        CASE
            WHEN lower(COALESCE(item_category_mat, ''::text)) = ANY (ARRAY['all_in_one_bag'::text, 'casing'::text, 'fruiting_block'::text, 'grain'::text, 'substrate'::text]) THEN
            CASE
                WHEN COALESCE(unit_size, 0::numeric) <> 0::numeric THEN round(unit_size, 2) || ' lb'::text
                ELSE ''::text
            END
            ELSE ''::text
        END AS unit_lbs,
        CASE
            WHEN NULLIF(inoculated_at::text, ''::text) IS NOT NULL THEN ('Inoculated: '::text || to_char(inoculated_at, 'YYYY-MM-DD'::text)) || ' '::text
            ELSE ''::text
        END || COALESCE(( SELECT ltbl.lot_id
           FROM v_lots ltbl
          WHERE ltbl.nocopk = comp.source_lot_id
          ORDER BY ltbl.nocopk
         LIMIT 1), ''::text) AS label_inoc_line,
        CASE
            WHEN NULLIF(spawned_at::text, ''::text) IS NOT NULL THEN 'Spawned: '::text || to_char(spawned_at, 'YYYY-MM-DD'::text)
            ELSE ''::text
        END AS label_spawned_line,
        CASE
            WHEN NULLIF(use_by::text, ''::text) IS NOT NULL THEN 'Use by: '::text || to_char(use_by::timestamp without time zone, 'YYYY-MM-DD'::text)
            ELSE ''::text
        END AS label_useby_line,
        CASE
            WHEN label_template = 'Grain_Inoculated'::text THEN ('Grain: '::text || COALESCE(item_name_mat, ''::text)) || ''::text
            WHEN label_template = 'All_In_One_Inoculated'::text THEN ('All-in-One: '::text || COALESCE(item_name_mat, ''::text)) || ''::text
            WHEN label_template = 'LC_Flask_Inoculated'::text THEN 'Liquid Culture — Flask'::text
            WHEN label_template = 'Cordyceps_Substrate_Inoculated'::text THEN COALESCE(item_name_mat, ''::text) || ''::text
            WHEN label_template = 'Plate_Inoculated'::text THEN COALESCE(item_name_mat, ''::text) || ''::text
            WHEN label_template = 'Bulk_Created'::text THEN COALESCE(item_name_mat, ''::text) || ''::text
            WHEN label_template = 'LC_Syringe_Received'::text THEN COALESCE(item_name_mat, ''::text) || ''::text
            WHEN label_template = 'LC_Syringe_Drawn'::text THEN COALESCE(item_name_mat, ''::text) || ''::text
            ELSE ''::text
        END AS label_title_lot,
        CASE
            WHEN label_template = 'Grain_Inoculated'::text THEN (((
            CASE
                WHEN COALESCE(unit_size, 0::numeric) <> 0::numeric THEN round(unit_size, 2) || ' lb • '::text
                ELSE ''::text
            END || COALESCE(strain_species_strain[1], ''::text)) || ' '::text) || COALESCE(vendor_name_mat, ''::text)) || ''::text
            WHEN label_template = 'All_In_One_Inoculated'::text THEN (((
            CASE
                WHEN COALESCE(unit_size, 0::numeric) <> 0::numeric THEN round(unit_size, 2) || ' lb • '::text
                ELSE ''::text
            END || COALESCE(strain_species_strain_mat, ''::text)) || ' '::text) || COALESCE(vendor_name_mat, ''::text)) || ''::text
            WHEN label_template = 'Cordyceps_Substrate_Inoculated'::text THEN (
            CASE
                WHEN COALESCE(COALESCE(unit_size, 0::numeric) <> 0::numeric, false) AND COALESCE(COALESCE(total_volume_ml, 0::numeric) <> 0::numeric, false) THEN round(total_volume_ml - unit_size, 2) || ' ml Inoc • '::text
                ELSE ''::text
            END || COALESCE(vendor_name_mat, ''::text)) || ''::text
            WHEN label_template = 'Plate_Inoculated'::text THEN
            CASE
                WHEN COALESCE(cardinality(strain_species_strain), 0) > 0 THEN strain_species_strain[1]
                ELSE notes
            END || ''::text
            WHEN label_template = 'LC_Flask_Inoculated'::text THEN (((
            CASE
                WHEN COALESCE(remaining_volume_ml, 0::numeric) <> 0::numeric THEN COALESCE(remaining_volume_ml::text, ''::text) || ' ml • '::text
                ELSE ''::text
            END || COALESCE(strain_species_strain[1], ''::text)) || ' '::text) || COALESCE(vendor_name_mat, ''::text)) || ''::text
            WHEN label_template = 'LC_Syringe_Received'::text THEN (((((
            CASE
                WHEN COALESCE(remaining_volume_ml, 0::numeric) <> 0::numeric THEN COALESCE(remaining_volume_ml::text, ''::text) || ' ml • '::text
                ELSE ''::text
            END || COALESCE(strain_species_strain[1], ''::text)) || ' '::text) || COALESCE(vendor_name, ''::text)) || ' '::text) || COALESCE(vendor_batch, ''::text)) || ''::text
            WHEN label_template = 'LC_Syringe_Drawn'::text THEN (((((
            CASE
                WHEN COALESCE(remaining_volume_ml, 0::numeric) <> 0::numeric THEN COALESCE(remaining_volume_ml::text, ''::text) || ' ml • '::text
                ELSE ''::text
            END || COALESCE(strain_species_strain[1], ''::text)) || ' '::text) || COALESCE(vendor_name, ''::text)) || ' '::text) || COALESCE(vendor_batch, ''::text)) || ''::text
            WHEN label_template = 'Bulk_Created'::text THEN (((
            CASE
                WHEN COALESCE(unit_size, 0::numeric) <> 0::numeric THEN round(unit_size, 2) || ' lb • '::text
                ELSE ''::text
            END || COALESCE(strain_species_strain[1], ''::text)) || ' '::text) || COALESCE(vendor_name_mat, ''::text)) || ''::text
            ELSE ''::text
        END AS label_subtitle_lot,
    'Lot: '::text || lot_id AS label_footer_lot,
        CASE
            WHEN NULLIF(received_date::text, ''::text) IS NOT NULL THEN 'Received: '::text || to_char(received_date::timestamp without time zone, 'YYYY-MM-DD'::text)
            ELSE
            CASE
                WHEN NULLIF(sterilized_at::text, ''::text) IS NOT NULL THEN
                CASE
                    WHEN lower(process_type_mat) = 'pasteurize'::text THEN 'Pasteurized: '::text || to_char(sterilized_at, 'YYYY-MM-DD'::text)
                    ELSE 'Sterilized: '::text || to_char(sterilized_at, 'YYYY-MM-DD'::text)
                END
                ELSE ''::text
            END
        END AS label_proc_line,
        CASE
            WHEN NULLIF(spawned_at::text, ''::text) IS NOT NULL THEN
            CASE
                WHEN COALESCE(cardinality(inoculated_at_from_grain_inputs), 0) > 0 THEN (COALESCE(item_name_mat_from_grain_inputs[1], ''::text) || ' '::text) || to_char(inoculated_at_from_grain_inputs[1], 'YYYY-MM-DD'::text)
                ELSE ''::text
            END
            ELSE ''::text
        END AS label_graininputblocks_line,
        CASE
            WHEN NULLIF(spawned_at::text, ''::text) IS NOT NULL THEN
            CASE
                WHEN 'Pasteurize'::text = ANY (process_type_mat_from_substrate_inputs) THEN 'Pasteurized '::text || COALESCE(item_name_mat_from_substrate_inputs[1], ''::text)
                ELSE 'Sterilized '::text || COALESCE(item_name_mat_from_substrate_inputs[1], ''::text)
            END
            ELSE ''::text
        END AS label_substrateinputblocks_line
 FROM comp;
CREATE VIEW public.vc_products AS
 WITH comp AS (
         SELECT base.nocopk,
            base.product_id,
            base.item_id,
            base.name_mat,
            base.item_category_mat,
            base.net_weight_g,
            base.net_weight_oz,
            base.net_volume_ml,
            base.pack_date,
            base.use_by,
            base.package_class,
            base.package_item_id,
            base.package_size,
            base.package_count,
            base.storage_location_id,
            base.action,
            base.origin_lot_ids_json,
            base.process_type_mat,
            base.strain_id,
            base.ui_error,
            base.ui_error_at,
            base.tray_state,
            base.notes,
            base.harvest_flush_no,
            base.harvest_weight_g,
            base.harvested_at,
            base.operator,
            base.nocouuid,
            base.airtable_id,
            base.nc_created_at,
            base.nc_updated_at,
            base.__table,
            base.__primary,
            base.products__products__merge_tray_products__ids,
            base.products__lots__origin_lots__ids,
            base.products__print_queue__print_queue__ids,
            base.products__ecommerce__ecommerce__ids,
            base.products__ecommerce_orders__ecommerce_orders__ids,
            base.products__events__events__ids,
            ( SELECT COALESCE(array_agg(btbl.name ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM items btbl
                  WHERE btbl.nocopk = base.item_id) AS name,
            ( SELECT COALESCE(array_agg(btbl.category ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM items btbl
                  WHERE btbl.nocopk = base.item_id) AS item_category,
            ( SELECT COALESCE(array_agg(btbl.name ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM items btbl
                  WHERE btbl.nocopk = base.package_item_id) AS name_from_package_item,
            ( SELECT COALESCE(array_agg(btbl.category ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM items btbl
                  WHERE btbl.nocopk = base.package_item_id) AS package_item_category,
            ( SELECT COALESCE(array_agg(
                        CASE
                            WHEN lower(COALESCE(btbl.item_category_mat, ''::text)) = ANY (ARRAY['all_in_one_bag'::text, 'casing'::text, 'fruiting_block'::text, 'grain'::text, 'substrate'::text]) THEN
                            CASE
                                WHEN COALESCE(btbl.unit_size, 0::numeric) <> 0::numeric THEN round(btbl.unit_size, 2) || ' lb'::text
                                ELSE ''::text
                            END
                            ELSE ''::text
                        END ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM _m2m_products_lots_origin_lots j
                     JOIN vc_lots btbl ON btbl.nocopk = j.lots_id
                  WHERE j.products_id = base.nocopk) AS unit_lbs,
            ( SELECT COALESCE(array_agg(btbl.unit_size ORDER BY btbl.nocopk), ARRAY[]::numeric[]) AS "coalesce"
                   FROM _m2m_products_lots_origin_lots j
                     JOIN lots btbl ON btbl.nocopk = j.lots_id
                  WHERE j.products_id = base.nocopk) AS unit_size,
            ( SELECT COALESCE(array_agg(
                        CASE
                            WHEN NULLIF(btbl.inoculated_at::text, ''::text) IS NOT NULL THEN ('Inoculated: '::text || to_char(btbl.inoculated_at, 'YYYY-MM-DD'::text)) || ' '::text
                            ELSE ''::text
                        END || COALESCE(( SELECT ltbl.lot_id
                           FROM v_lots ltbl
                          WHERE ltbl.nocopk = btbl.source_lot_id
                          ORDER BY ltbl.nocopk
                         LIMIT 1), ''::text) ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM _m2m_products_lots_origin_lots j
                     JOIN vc_lots btbl ON btbl.nocopk = j.lots_id
                  WHERE j.products_id = base.nocopk) AS label_inoc_prod,
            ( SELECT COALESCE(array_agg(
                        CASE
                            WHEN NULLIF(btbl.spawned_at::text, ''::text) IS NOT NULL THEN 'Spawned: '::text || to_char(btbl.spawned_at, 'YYYY-MM-DD'::text)
                            ELSE ''::text
                        END ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM _m2m_products_lots_origin_lots j
                     JOIN vc_lots btbl ON btbl.nocopk = j.lots_id
                  WHERE j.products_id = base.nocopk) AS label_spawned_prod,
            ( SELECT COALESCE(array_agg(
                        CASE
                            WHEN NULLIF(btbl.received_date::text, ''::text) IS NOT NULL THEN 'Received: '::text || to_char(btbl.received_date::timestamp without time zone, 'YYYY-MM-DD'::text)
                            ELSE
                            CASE
                                WHEN NULLIF(btbl.sterilized_at::text, ''::text) IS NOT NULL THEN
                                CASE
                                    WHEN lower(btbl.process_type_mat) = 'pasteurize'::text THEN 'Pasteurized: '::text || to_char(btbl.sterilized_at, 'YYYY-MM-DD'::text)
                                    ELSE 'Sterilized: '::text || to_char(btbl.sterilized_at, 'YYYY-MM-DD'::text)
                                END
                                ELSE ''::text
                            END
                        END ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM _m2m_products_lots_origin_lots j
                     JOIN vc_lots btbl ON btbl.nocopk = j.lots_id
                  WHERE j.products_id = base.nocopk) AS label_proc_prod,
            ( SELECT COALESCE(array_agg(btbl.process_type_mat ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM _m2m_products_lots_origin_lots j
                     JOIN lots btbl ON btbl.nocopk = j.lots_id
                  WHERE j.products_id = base.nocopk) AS process_type,
            ( SELECT COALESCE(array_agg(btbl.species_strain ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM strains btbl
                  WHERE btbl.nocopk = base.strain_id) AS species_strain,
            ( SELECT COALESCE(sum(
                        CASE
                            WHEN btbl.regulated IS TRUE THEN 1
                            ELSE 0
                        END), 0::bigint)::numeric AS "coalesce"
                   FROM strains btbl
                  WHERE btbl.nocopk = base.strain_id) AS origin_strain_regulated,
            ( SELECT COALESCE(array_agg(btbl.product_use ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM strains btbl
                  WHERE btbl.nocopk = base.strain_id) AS origin_strain_product_use,
            ( SELECT COALESCE(array_agg(btbl.ecwid_url ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM _m2m_products_ecommerce_ecommerce j
                     JOIN ecommerce btbl ON btbl.nocopk = j.ecommerce_id
                  WHERE j.products_id = base.nocopk) AS ecwid_url_from_ecommerce,
            ( SELECT COALESCE(array_agg(btbl.ecwid_upc ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM _m2m_products_ecommerce_ecommerce j
                     JOIN ecommerce btbl ON btbl.nocopk = j.ecommerce_id
                  WHERE j.products_id = base.nocopk) AS ecwid_upc_from_ecommerce,
            ( SELECT COALESCE(array_agg(btbl.ecwid_price ORDER BY btbl.nocopk), ARRAY[]::numeric[]) AS "coalesce"
                   FROM _m2m_products_ecommerce_ecommerce j
                     JOIN ecommerce btbl ON btbl.nocopk = j.ecommerce_id
                  WHERE j.products_id = base.nocopk) AS ecwid_price_from_ecommerce
           FROM v_products base
        )
 SELECT nocopk,
    product_id,
    item_id,
    name_mat,
    item_category_mat,
    net_weight_g,
    net_weight_oz,
    net_volume_ml,
    pack_date,
    use_by,
    package_class,
    package_item_id,
    package_size,
    package_count,
    storage_location_id,
    action,
    origin_lot_ids_json,
    process_type_mat,
    strain_id,
    ui_error,
    ui_error_at,
    tray_state,
    notes,
    harvest_flush_no,
    harvest_weight_g,
    harvested_at,
    operator,
    nocouuid,
    airtable_id,
    nc_created_at,
    nc_updated_at,
    __table,
    __primary,
    products__products__merge_tray_products__ids,
    products__lots__origin_lots__ids,
    products__print_queue__print_queue__ids,
    products__ecommerce__ecommerce__ids,
    products__ecommerce_orders__ecommerce_orders__ids,
    products__events__events__ids,
    name,
    item_category,
    name_from_package_item,
    package_item_category,
    unit_lbs,
    unit_size,
    label_inoc_prod,
    label_spawned_prod,
    label_proc_prod,
    process_type,
    species_strain,
    origin_strain_regulated,
    origin_strain_product_use,
    ecwid_url_from_ecommerce,
    ecwid_upc_from_ecommerce,
    ecwid_price_from_ecommerce,
        CASE
            WHEN package_size = '1 g'::text THEN 1::numeric
            WHEN package_size = '5 g'::text THEN 5::numeric
            WHEN package_size = '10 g'::text THEN 10::numeric
            WHEN package_size = '1 oz'::text THEN 28.349523125
            ELSE NULL::numeric
        END AS package_size_g,
        CASE
            WHEN origin_strain_regulated > 0::numeric THEN
            CASE
                WHEN COALESCE(item_category_mat = 'freezedriedmushrooms'::text, false) OR COALESCE(item_category_mat = 'fresh_mushrooms'::text, false) OR COALESCE(item_category_mat = 'freezer_tray'::text, false) OR COALESCE(item_category_mat = 'fresh_tray'::text, false) THEN 'Rooted Psyche'::text
                ELSE 'Dank Mushrooms'::text
            END
            ELSE 'Dank Mushrooms'::text
        END AS label_company_prod,
        CASE
            WHEN origin_strain_regulated > 0::numeric THEN
            CASE
                WHEN COALESCE(item_category_mat = 'freezedriedmushrooms'::text, false) OR COALESCE(item_category_mat = 'fresh_mushrooms'::text, false) OR COALESCE(item_category_mat = 'freezer_tray'::text, false) OR COALESCE(item_category_mat = 'fresh_tray'::text, false) THEN ((((((('PO Box 266'::text || chr(10)) || 'Johnstown, CO 80534'::text) || chr(10)) || 'https://www.rootedpsyche.com/'::text) || chr(10)) || '(970) 408-0858'::text) || chr(10)) || 'rootedpsyche@gmail.com'::text
                ELSE ((((((('1726 Goldenvue Drive'::text || chr(10)) || 'Johnstown, CO 80534'::text) || chr(10)) || 'https://www.danks.store'::text) || chr(10)) || '970-587-3294'::text) || chr(10)) || 'sales@danks.net'::text
            END
            ELSE ((((((('1726 Goldenvue Drive'::text || chr(10)) || 'Johnstown, CO 80534'::text) || chr(10)) || 'https://www.danks.store'::text) || chr(10)) || '970-587-3294'::text) || chr(10)) || 'sales@danks.net'::text
        END AS label_companyaddress_base_prod,
        CASE
            WHEN package_class = 'Sample'::text THEN replace(
            CASE
                WHEN origin_strain_regulated > 0::numeric THEN
                CASE
                    WHEN COALESCE(item_category_mat = 'freezedriedmushrooms'::text, false) OR COALESCE(item_category_mat = 'fresh_mushrooms'::text, false) OR COALESCE(item_category_mat = 'freezer_tray'::text, false) OR COALESCE(item_category_mat = 'fresh_tray'::text, false) THEN ((((((('PO Box 266'::text || chr(10)) || 'Johnstown, CO 80534'::text) || chr(10)) || 'https://www.rootedpsyche.com/'::text) || chr(10)) || '(970) 408-0858'::text) || chr(10)) || 'rootedpsyche@gmail.com'::text
                    ELSE ((((((('1726 Goldenvue Drive'::text || chr(10)) || 'Johnstown, CO 80534'::text) || chr(10)) || 'https://www.danks.store'::text) || chr(10)) || '970-587-3294'::text) || chr(10)) || 'sales@danks.net'::text
                END
                ELSE ((((((('1726 Goldenvue Drive'::text || chr(10)) || 'Johnstown, CO 80534'::text) || chr(10)) || 'https://www.danks.store'::text) || chr(10)) || '970-587-3294'::text) || chr(10)) || 'sales@danks.net'::text
            END, ''::text || chr(10), ' • '::text)
            ELSE
            CASE
                WHEN origin_strain_regulated > 0::numeric THEN
                CASE
                    WHEN COALESCE(item_category_mat = 'freezedriedmushrooms'::text, false) OR COALESCE(item_category_mat = 'fresh_mushrooms'::text, false) OR COALESCE(item_category_mat = 'freezer_tray'::text, false) OR COALESCE(item_category_mat = 'fresh_tray'::text, false) THEN ((((((('PO Box 266'::text || chr(10)) || 'Johnstown, CO 80534'::text) || chr(10)) || 'https://www.rootedpsyche.com/'::text) || chr(10)) || '(970) 408-0858'::text) || chr(10)) || 'rootedpsyche@gmail.com'::text
                    ELSE ((((((('1726 Goldenvue Drive'::text || chr(10)) || 'Johnstown, CO 80534'::text) || chr(10)) || 'https://www.danks.store'::text) || chr(10)) || '970-587-3294'::text) || chr(10)) || 'sales@danks.net'::text
                END
                ELSE ((((((('1726 Goldenvue Drive'::text || chr(10)) || 'Johnstown, CO 80534'::text) || chr(10)) || 'https://www.danks.store'::text) || chr(10)) || '970-587-3294'::text) || chr(10)) || 'sales@danks.net'::text
            END
        END AS label_companyaddress_prod,
        CASE
            WHEN origin_strain_regulated > 0::numeric THEN
            CASE
                WHEN item_category_mat = 'fresh_mushrooms'::text THEN ''::text
                WHEN item_category_mat = 'freezer_tray'::text THEN ''::text
                WHEN item_category_mat = 'fresh_tray'::text THEN ''::text
                WHEN item_category_mat = 'fruiting_block'::text THEN 'Disclaimer: Psilocybin is classified as a Schedule I controlled substance by the U.S. Drug Enforcement Administration (DEA). Unauthorized cultivation, possession, or distribution of psilocybin-containing mushrooms is illegal in most states. It is the responsibility of the buyer to research and comply with all local, state, and federal laws regarding mushroom cultivation. Please consult your local laws carefully before any attempt to grow mushrooms, as penalties for non-compliance can be significant.'::text
                WHEN item_category_mat = 'freezedriedmushrooms'::text THEN
                CASE
                    WHEN package_class = 'Sample'::text THEN (((('NOTICE'::text || chr(10)) || 'Psilocybin remains a Schedule I controlled substance under U.S. federal law. Under Colorado''s Natural Medicine Health Act, adults age 21+ may lawfully receive and possess natural medicine in certain circumstances, including uncompensated gifting.'::text) || chr(10)) || chr(10)) || 'By opening this package, I acknowledge that I am 21+, will use this sacrament responsibly and intentionally, understand Rooted Psyche provides no medical or mental health treatment, have no contraindicated condition or have consulted a healthcare professional, and accept full responsibility for my possession and use.'::text
                    ELSE ''::text
                END
                ELSE ''::text
            END
            ELSE ''::text
        END AS label_disclaimer_prod,
        CASE
            WHEN COALESCE(package_class = 'Sample'::text, false) AND COALESCE(item_category_mat = 'freezedriedmushrooms'::text, false) THEN
            CASE
                WHEN 'Sacrament'::text = ANY (origin_strain_product_use) THEN 'Approximate sample size: 5–10 portions of 0.1–0.2 g.'::text
                WHEN 'Functional'::text = ANY (origin_strain_product_use) THEN 'Approximate sample size: 3–5 daily servings.'::text
                WHEN 'Gourmet/Functional'::text = ANY (origin_strain_product_use) THEN 'Approximate sample size: 3–5 servings.'::text
                WHEN 'Gourmet'::text = ANY (origin_strain_product_use) THEN 'Sample size: Great for one recipe.'::text
                ELSE ''::text
            END
            ELSE
            CASE
                WHEN origin_strain_regulated > 0::numeric THEN
                CASE
                    WHEN item_category_mat = 'fruiting_block'::text THEN 'Dank Mushrooms offers delivery and shipment of fresh gourmet and specialty mushrooms, dried mushrooms, mushroom supplements, mushroom grow kits and mycology supplies.'::text
                    ELSE ''::text
                END
                ELSE
                CASE
                    WHEN item_category_mat = 'freezedriedmushrooms'::text THEN 'Dank Mushrooms offers delivery and shipment of fresh gourmet and specialty mushrooms, dried mushrooms, mushroom supplements, mushroom grow kits and mycology supplies.'::text
                    WHEN item_category_mat = 'fresh_mushrooms'::text THEN 'Dank Mushrooms offers delivery and shipment of fresh gourmet and specialty mushrooms, dried mushrooms, mushroom supplements, mushroom grow kits and mycology supplies.'::text
                    WHEN item_category_mat = 'fruiting_block'::text THEN 'Dank Mushrooms offers delivery and shipment of fresh gourmet and specialty mushrooms, dried mushrooms, mushroom supplements, mushroom grow kits and mycology supplies.'::text
                    ELSE ''::text
                END
            END
        END AS label_companyinfo_prod,
        CASE
            WHEN origin_strain_regulated > 0::numeric THEN
            CASE
                WHEN COALESCE(item_category_mat = 'freezedriedmushrooms'::text, false) OR COALESCE(item_category_mat = 'fresh_mushrooms'::text, false) OR COALESCE(item_category_mat = 'freezer_tray'::text, false) OR COALESCE(item_category_mat = 'fresh_tray'::text, false) THEN ''::text
                ELSE
                CASE
                    WHEN COALESCE(item_category_mat = 'freezedriedmushrooms'::text, false) OR COALESCE(item_category_mat = 'fresh_mushrooms'::text, false) THEN 'This product was produced in a home kitchen that is not subject to state licensure or inspection and that may also contain common food allergies such as tree nuts, peanuts, eggs, soy, wheat, milk, fish, and crustacean shellfish. This product is not intended for resale.'::text
                    ELSE
                    CASE
                        WHEN item_category_mat = 'fruiting_block'::text THEN 'This product contains ingredients designed for mushroom cultivation. This product is not intended for human consumption.'::text
                        ELSE ''::text
                    END
                END
            END
            ELSE
            CASE
                WHEN COALESCE(item_category_mat = 'freezedriedmushrooms'::text, false) OR COALESCE(item_category_mat = 'fresh_mushrooms'::text, false) THEN 'This product was produced in a home kitchen that is not subject to state licensure or inspection and that may also contain common food allergies such as tree nuts, peanuts, eggs, soy, wheat, milk, fish, and crustacean shellfish. This product is not intended for resale.'::text
                ELSE
                CASE
                    WHEN item_category_mat = 'fruiting_block'::text THEN 'This product contains ingredients designed for mushroom cultivation. This product is not intended for human consumption.'::text
                    ELSE ''::text
                END
            END
        END AS label_cottage_prod,
        CASE
            WHEN item_category_mat = 'grain'::text THEN COALESCE(name_mat, ''::text) || ' Grain'::text
            WHEN item_category_mat = 'substrate'::text THEN COALESCE(name_mat, ''::text) || ' Substrate'::text
            WHEN item_category_mat = 'all_in_one_bag'::text THEN name_mat
            WHEN item_category_mat = 'fruiting_block'::text THEN name_mat
            WHEN item_category_mat = 'lc_syringe'::text THEN name_mat
            WHEN item_category_mat = 'freezedriedmushrooms'::text THEN name_mat
            WHEN item_category_mat = 'freezer_tray'::text THEN name_mat
            WHEN item_category_mat = 'fresh_tray'::text THEN name_mat
            WHEN item_category_mat = 'fresh_mushrooms'::text THEN name_mat
            ELSE ''::text
        END AS label_title_prod,
        CASE
            WHEN item_category_mat = 'grain'::text THEN
            CASE
                WHEN COALESCE(cardinality(unit_lbs), 0) > 0 THEN (COALESCE(unit_lbs[1], ''::text) || ' • '::text) ||
                CASE
                    WHEN strpos(lower(lower(process_type_mat)), lower('pasteurize'::text)) > 0 THEN 'Pasteurized'::text
                    ELSE 'Sterilized'::text
                END
                ELSE ''::text
            END
            WHEN item_category_mat = 'substrate'::text THEN
            CASE
                WHEN COALESCE(cardinality(unit_lbs), 0) > 0 THEN (COALESCE(unit_lbs[1], ''::text) || ' • '::text) ||
                CASE
                    WHEN strpos(lower(lower(process_type_mat)), lower('pasteurize'::text)) > 0 THEN 'Pasteurized'::text
                    ELSE 'Sterilized'::text
                END
                ELSE ''::text
            END
            WHEN item_category_mat = 'all_in_one_bag'::text THEN
            CASE
                WHEN COALESCE(cardinality(unit_lbs), 0) > 0 THEN (COALESCE(unit_lbs[1], ''::text) || ' • '::text) ||
                CASE
                    WHEN strpos(lower(lower(process_type_mat)), lower('pasteurize'::text)) > 0 THEN 'Pasteurized'::text
                    ELSE 'Sterilized'::text
                END
                ELSE ''::text
            END
            WHEN item_category_mat = 'fruiting_block'::text THEN (
            CASE
                WHEN COALESCE(cardinality(unit_lbs), 0) > 0 THEN COALESCE(unit_lbs[1], ''::text) || ' • '::text
                ELSE ' '::text
            END || COALESCE(species_strain[1], ''::text)) || ''::text
            WHEN item_category_mat = 'lc_syringe'::text THEN (
            CASE
                WHEN COALESCE(net_volume_ml, 0::numeric) <> 0::numeric THEN round(net_volume_ml, 2) || ' mL • '::text
                ELSE ''::text
            END || COALESCE(species_strain[1], ''::text)) || ''::text
            WHEN item_category_mat = 'freezedriedmushrooms'::text THEN (
            CASE
                WHEN NULLIF(package_size, ''::text) IS NOT NULL THEN COALESCE(package_size, ''::text) || ' '::text
                ELSE
                CASE
                    WHEN COALESCE(net_weight_g, 0::numeric) <> 0::numeric THEN round(net_weight_g, 2) || ' g • '::text
                    ELSE ''::text
                END
            END || COALESCE(species_strain[1], ''::text)) || ''::text
            WHEN item_category_mat = 'freezer_tray'::text THEN (
            CASE
                WHEN COALESCE(net_weight_g, 0::numeric) <> 0::numeric THEN round(net_weight_g, 2) || ' g • '::text
                ELSE ''::text
            END || COALESCE(species_strain[1], ''::text)) || ''::text
            WHEN item_category_mat = 'fresh_tray'::text THEN (
            CASE
                WHEN COALESCE(net_weight_g, 0::numeric) <> 0::numeric THEN round(net_weight_g, 2) || ' g • '::text
                ELSE ''::text
            END || COALESCE(species_strain[1], ''::text)) || ''::text
            WHEN item_category_mat = 'fresh_mushrooms'::text THEN (
            CASE
                WHEN COALESCE(
                CASE
                    WHEN package_size = '1 g'::text THEN 1::numeric
                    WHEN package_size = '5 g'::text THEN 5::numeric
                    WHEN package_size = '10 g'::text THEN 10::numeric
                    WHEN package_size = '1 oz'::text THEN 28.349523125
                    ELSE NULL::numeric
                END::text, ''::text) <> ALL (ARRAY[''::text, '0'::text, 'false'::text]) THEN round(
                CASE
                    WHEN package_size = '1 g'::text THEN 1::numeric
                    WHEN package_size = '5 g'::text THEN 5::numeric
                    WHEN package_size = '10 g'::text THEN 10::numeric
                    WHEN package_size = '1 oz'::text THEN 28.349523125
                    ELSE NULL::numeric
                END, 2) || ' g • '::text
                ELSE ''::text
            END || COALESCE(species_strain[1], ''::text)) || ''::text
            ELSE ''::text
        END AS label_subtitle_prod,
    product_id AS label_footer_prod,
        CASE
            WHEN NULLIF(pack_date::text, ''::text) IS NOT NULL THEN 'Packaged: '::text || to_char(pack_date::timestamp without time zone, 'YYYY-MM-DD'::text)
            ELSE ''::text
        END AS label_packaged_prod,
        CASE
            WHEN NULLIF(use_by::text, ''::text) IS NOT NULL THEN 'Use by: '::text || to_char(use_by::timestamp without time zone, 'YYYY-MM-DD'::text)
            ELSE ''::text
        END AS label_useby_prod
 FROM comp;
CREATE VIEW public.vc_print_queue AS
 WITH comp AS (
         SELECT base.nocopk,
            base.print_id,
            base.source_kind,
            base.lot_id,
            base.product_id,
            base.print_status,
            base.label_type,
            base.error_msg,
            base.created_at,
            base.run_id,
            base.claimed_by,
            base.claimed_at,
            base.printed_by,
            base.printed_at,
            base.pdf_path,
            base.nocouuid,
            base.airtable_id,
            base.nc_created_at,
            base.nc_updated_at,
            base.__table,
            base.__primary,
            ( SELECT COALESCE(array_agg(btbl.item_category_mat ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM lots btbl
                  WHERE btbl.nocopk = base.lot_id) AS item_category_mat_from_lot_id,
            ( SELECT COALESCE(array_agg('Dank Mushrooms'::text ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM vc_lots btbl
                  WHERE btbl.nocopk = base.lot_id) AS label_company_lot_from_lot_id,
            ( SELECT COALESCE(array_agg(btbl.item_category_mat ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM products btbl
                  WHERE btbl.nocopk = base.product_id) AS item_category_mat_from_product_id,
            ( SELECT COALESCE(array_agg(
                        CASE
                            WHEN NULLIF(btbl.spawned_at::text, ''::text) IS NOT NULL THEN
                            CASE
                                WHEN 'Pasteurize'::text = ANY (btbl.process_type_mat_from_substrate_inputs) THEN 'Pasteurized '::text || COALESCE(btbl.item_name_mat_from_substrate_inputs[1], ''::text)
                                ELSE 'Sterilized '::text || COALESCE(btbl.item_name_mat_from_substrate_inputs[1], ''::text)
                            END
                            ELSE ''::text
                        END ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM vc_lots btbl
                  WHERE btbl.nocopk = base.lot_id) AS label_substrateinputblocks_line_from_lot_id,
            ( SELECT COALESCE(array_agg(
                        CASE
                            WHEN NULLIF(btbl.spawned_at::text, ''::text) IS NOT NULL THEN
                            CASE
                                WHEN COALESCE(cardinality(btbl.inoculated_at_from_grain_inputs), 0) > 0 THEN (COALESCE(btbl.item_name_mat_from_grain_inputs[1], ''::text) || ' '::text) || to_char(btbl.inoculated_at_from_grain_inputs[1], 'YYYY-MM-DD'::text)
                                ELSE ''::text
                            END
                            ELSE ''::text
                        END ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM vc_lots btbl
                  WHERE btbl.nocopk = base.lot_id) AS label_graininputblocks_line_from_lot_id,
            ( SELECT COALESCE(array_agg('Lot: '::text || btbl.lot_id ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM vc_lots btbl
                  WHERE btbl.nocopk = base.lot_id) AS label_footer_lot_from_lot_id,
            ( SELECT COALESCE(array_agg(
                        CASE
                            WHEN btbl.label_template = 'Grain_Inoculated'::text THEN (((
                            CASE
                                WHEN COALESCE(btbl.unit_size, 0::numeric) <> 0::numeric THEN round(btbl.unit_size, 2) || ' lb • '::text
                                ELSE ''::text
                            END || COALESCE(btbl.strain_species_strain[1], ''::text)) || ' '::text) || COALESCE(btbl.vendor_name_mat, ''::text)) || ''::text
                            WHEN btbl.label_template = 'All_In_One_Inoculated'::text THEN (((
                            CASE
                                WHEN COALESCE(btbl.unit_size, 0::numeric) <> 0::numeric THEN round(btbl.unit_size, 2) || ' lb • '::text
                                ELSE ''::text
                            END || COALESCE(btbl.strain_species_strain_mat, ''::text)) || ' '::text) || COALESCE(btbl.vendor_name_mat, ''::text)) || ''::text
                            WHEN btbl.label_template = 'Cordyceps_Substrate_Inoculated'::text THEN (
                            CASE
                                WHEN COALESCE(COALESCE(btbl.unit_size, 0::numeric) <> 0::numeric, false) AND COALESCE(COALESCE(btbl.total_volume_ml, 0::numeric) <> 0::numeric, false) THEN round(btbl.total_volume_ml - btbl.unit_size, 2) || ' ml Inoc • '::text
                                ELSE ''::text
                            END || COALESCE(btbl.vendor_name_mat, ''::text)) || ''::text
                            WHEN btbl.label_template = 'Plate_Inoculated'::text THEN
                            CASE
                                WHEN COALESCE(cardinality(btbl.strain_species_strain), 0) > 0 THEN btbl.strain_species_strain[1]
                                ELSE btbl.notes
                            END || ''::text
                            WHEN btbl.label_template = 'LC_Flask_Inoculated'::text THEN (((
                            CASE
                                WHEN COALESCE(btbl.remaining_volume_ml, 0::numeric) <> 0::numeric THEN COALESCE(btbl.remaining_volume_ml::text, ''::text) || ' ml • '::text
                                ELSE ''::text
                            END || COALESCE(btbl.strain_species_strain[1], ''::text)) || ' '::text) || COALESCE(btbl.vendor_name_mat, ''::text)) || ''::text
                            WHEN btbl.label_template = 'LC_Syringe_Received'::text THEN (((((
                            CASE
                                WHEN COALESCE(btbl.remaining_volume_ml, 0::numeric) <> 0::numeric THEN COALESCE(btbl.remaining_volume_ml::text, ''::text) || ' ml • '::text
                                ELSE ''::text
                            END || COALESCE(btbl.strain_species_strain[1], ''::text)) || ' '::text) || COALESCE(btbl.vendor_name, ''::text)) || ' '::text) || COALESCE(btbl.vendor_batch, ''::text)) || ''::text
                            WHEN btbl.label_template = 'LC_Syringe_Drawn'::text THEN (((((
                            CASE
                                WHEN COALESCE(btbl.remaining_volume_ml, 0::numeric) <> 0::numeric THEN COALESCE(btbl.remaining_volume_ml::text, ''::text) || ' ml • '::text
                                ELSE ''::text
                            END || COALESCE(btbl.strain_species_strain[1], ''::text)) || ' '::text) || COALESCE(btbl.vendor_name, ''::text)) || ' '::text) || COALESCE(btbl.vendor_batch, ''::text)) || ''::text
                            WHEN btbl.label_template = 'Bulk_Created'::text THEN (((
                            CASE
                                WHEN COALESCE(btbl.unit_size, 0::numeric) <> 0::numeric THEN round(btbl.unit_size, 2) || ' lb • '::text
                                ELSE ''::text
                            END || COALESCE(btbl.strain_species_strain[1], ''::text)) || ' '::text) || COALESCE(btbl.vendor_name_mat, ''::text)) || ''::text
                            ELSE ''::text
                        END ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM vc_lots btbl
                  WHERE btbl.nocopk = base.lot_id) AS label_subtitle_lot_from_lot_id,
            ( SELECT COALESCE(array_agg(
                        CASE
                            WHEN btbl.label_template = 'Grain_Inoculated'::text THEN ('Grain: '::text || COALESCE(btbl.item_name_mat, ''::text)) || ''::text
                            WHEN btbl.label_template = 'All_In_One_Inoculated'::text THEN ('All-in-One: '::text || COALESCE(btbl.item_name_mat, ''::text)) || ''::text
                            WHEN btbl.label_template = 'LC_Flask_Inoculated'::text THEN 'Liquid Culture — Flask'::text
                            WHEN btbl.label_template = 'Cordyceps_Substrate_Inoculated'::text THEN COALESCE(btbl.item_name_mat, ''::text) || ''::text
                            WHEN btbl.label_template = 'Plate_Inoculated'::text THEN COALESCE(btbl.item_name_mat, ''::text) || ''::text
                            WHEN btbl.label_template = 'Bulk_Created'::text THEN COALESCE(btbl.item_name_mat, ''::text) || ''::text
                            WHEN btbl.label_template = 'LC_Syringe_Received'::text THEN COALESCE(btbl.item_name_mat, ''::text) || ''::text
                            WHEN btbl.label_template = 'LC_Syringe_Drawn'::text THEN COALESCE(btbl.item_name_mat, ''::text) || ''::text
                            ELSE ''::text
                        END ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM vc_lots btbl
                  WHERE btbl.nocopk = base.lot_id) AS label_title_lot_from_lot_id,
            ( SELECT COALESCE(array_agg(btbl.label_template ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM lots btbl
                  WHERE btbl.nocopk = base.lot_id) AS label_template_from_lot_id,
            ( SELECT COALESCE(array_agg(
                        CASE
                            WHEN NULLIF(btbl.use_by::text, ''::text) IS NOT NULL THEN 'Use by: '::text || to_char(btbl.use_by::timestamp without time zone, 'YYYY-MM-DD'::text)
                            ELSE ''::text
                        END ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM vc_lots btbl
                  WHERE btbl.nocopk = base.lot_id) AS label_useby_line_from_lot_id,
            ( SELECT COALESCE(array_agg(
                        CASE
                            WHEN NULLIF(btbl.spawned_at::text, ''::text) IS NOT NULL THEN 'Spawned: '::text || to_char(btbl.spawned_at, 'YYYY-MM-DD'::text)
                            ELSE ''::text
                        END ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM vc_lots btbl
                  WHERE btbl.nocopk = base.lot_id) AS label_spawned_line_from_lot_id,
            ( SELECT COALESCE(array_agg(
                        CASE
                            WHEN NULLIF(btbl.inoculated_at::text, ''::text) IS NOT NULL THEN ('Inoculated: '::text || to_char(btbl.inoculated_at, 'YYYY-MM-DD'::text)) || ' '::text
                            ELSE ''::text
                        END || COALESCE(( SELECT ltbl.lot_id
                           FROM v_lots ltbl
                          WHERE ltbl.nocopk = btbl.source_lot_id
                          ORDER BY ltbl.nocopk
                         LIMIT 1), ''::text) ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM vc_lots btbl
                  WHERE btbl.nocopk = base.lot_id) AS label_inoc_line_from_lot_id,
            ( SELECT COALESCE(array_agg(
                        CASE
                            WHEN NULLIF(btbl.received_date::text, ''::text) IS NOT NULL THEN 'Received: '::text || to_char(btbl.received_date::timestamp without time zone, 'YYYY-MM-DD'::text)
                            ELSE
                            CASE
                                WHEN NULLIF(btbl.sterilized_at::text, ''::text) IS NOT NULL THEN
                                CASE
                                    WHEN lower(btbl.process_type_mat) = 'pasteurize'::text THEN 'Pasteurized: '::text || to_char(btbl.sterilized_at, 'YYYY-MM-DD'::text)
                                    ELSE 'Sterilized: '::text || to_char(btbl.sterilized_at, 'YYYY-MM-DD'::text)
                                END
                                ELSE ''::text
                            END
                        END ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM vc_lots btbl
                  WHERE btbl.nocopk = base.lot_id) AS label_proc_line_from_lot_id,
            ( SELECT COALESCE(array_agg(
                        CASE
                            WHEN btbl.origin_strain_regulated > 0::numeric THEN
                            CASE
                                WHEN COALESCE(btbl.item_category_mat = 'freezedriedmushrooms'::text, false) OR COALESCE(btbl.item_category_mat = 'fresh_mushrooms'::text, false) OR COALESCE(btbl.item_category_mat = 'freezer_tray'::text, false) OR COALESCE(btbl.item_category_mat = 'fresh_tray'::text, false) THEN 'Rooted Psyche'::text
                                ELSE 'Dank Mushrooms'::text
                            END
                            ELSE 'Dank Mushrooms'::text
                        END ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM vc_products btbl
                  WHERE btbl.nocopk = base.product_id) AS label_company_prod_from_product_id,
            ( SELECT COALESCE(array_agg(
                        CASE
                            WHEN btbl.item_category_mat = 'grain'::text THEN COALESCE(btbl.name_mat, ''::text) || ' Grain'::text
                            WHEN btbl.item_category_mat = 'substrate'::text THEN COALESCE(btbl.name_mat, ''::text) || ' Substrate'::text
                            WHEN btbl.item_category_mat = 'all_in_one_bag'::text THEN btbl.name_mat
                            WHEN btbl.item_category_mat = 'fruiting_block'::text THEN btbl.name_mat
                            WHEN btbl.item_category_mat = 'lc_syringe'::text THEN btbl.name_mat
                            WHEN btbl.item_category_mat = 'freezedriedmushrooms'::text THEN btbl.name_mat
                            WHEN btbl.item_category_mat = 'freezer_tray'::text THEN btbl.name_mat
                            WHEN btbl.item_category_mat = 'fresh_tray'::text THEN btbl.name_mat
                            WHEN btbl.item_category_mat = 'fresh_mushrooms'::text THEN btbl.name_mat
                            ELSE ''::text
                        END ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM vc_products btbl
                  WHERE btbl.nocopk = base.product_id) AS label_title_prod_from_product_id,
            ( SELECT COALESCE(array_agg(
                        CASE
                            WHEN btbl.item_category_mat = 'grain'::text THEN
                            CASE
                                WHEN COALESCE(cardinality(btbl.unit_lbs), 0) > 0 THEN (COALESCE(btbl.unit_lbs[1], ''::text) || ' • '::text) ||
                                CASE
                                    WHEN strpos(lower(lower(btbl.process_type_mat)), lower('pasteurize'::text)) > 0 THEN 'Pasteurized'::text
                                    ELSE 'Sterilized'::text
                                END
                                ELSE ''::text
                            END
                            WHEN btbl.item_category_mat = 'substrate'::text THEN
                            CASE
                                WHEN COALESCE(cardinality(btbl.unit_lbs), 0) > 0 THEN (COALESCE(btbl.unit_lbs[1], ''::text) || ' • '::text) ||
                                CASE
                                    WHEN strpos(lower(lower(btbl.process_type_mat)), lower('pasteurize'::text)) > 0 THEN 'Pasteurized'::text
                                    ELSE 'Sterilized'::text
                                END
                                ELSE ''::text
                            END
                            WHEN btbl.item_category_mat = 'all_in_one_bag'::text THEN
                            CASE
                                WHEN COALESCE(cardinality(btbl.unit_lbs), 0) > 0 THEN (COALESCE(btbl.unit_lbs[1], ''::text) || ' • '::text) ||
                                CASE
                                    WHEN strpos(lower(lower(btbl.process_type_mat)), lower('pasteurize'::text)) > 0 THEN 'Pasteurized'::text
                                    ELSE 'Sterilized'::text
                                END
                                ELSE ''::text
                            END
                            WHEN btbl.item_category_mat = 'fruiting_block'::text THEN (
                            CASE
                                WHEN COALESCE(cardinality(btbl.unit_lbs), 0) > 0 THEN COALESCE(btbl.unit_lbs[1], ''::text) || ' • '::text
                                ELSE ' '::text
                            END || COALESCE(btbl.species_strain[1], ''::text)) || ''::text
                            WHEN btbl.item_category_mat = 'lc_syringe'::text THEN (
                            CASE
                                WHEN COALESCE(btbl.net_volume_ml, 0::numeric) <> 0::numeric THEN round(btbl.net_volume_ml, 2) || ' mL • '::text
                                ELSE ''::text
                            END || COALESCE(btbl.species_strain[1], ''::text)) || ''::text
                            WHEN btbl.item_category_mat = 'freezedriedmushrooms'::text THEN (
                            CASE
                                WHEN NULLIF(btbl.package_size, ''::text) IS NOT NULL THEN COALESCE(btbl.package_size, ''::text) || ' '::text
                                ELSE
                                CASE
                                    WHEN COALESCE(btbl.net_weight_g, 0::numeric) <> 0::numeric THEN round(btbl.net_weight_g, 2) || ' g • '::text
                                    ELSE ''::text
                                END
                            END || COALESCE(btbl.species_strain[1], ''::text)) || ''::text
                            WHEN btbl.item_category_mat = 'freezer_tray'::text THEN (
                            CASE
                                WHEN COALESCE(btbl.net_weight_g, 0::numeric) <> 0::numeric THEN round(btbl.net_weight_g, 2) || ' g • '::text
                                ELSE ''::text
                            END || COALESCE(btbl.species_strain[1], ''::text)) || ''::text
                            WHEN btbl.item_category_mat = 'fresh_tray'::text THEN (
                            CASE
                                WHEN COALESCE(btbl.net_weight_g, 0::numeric) <> 0::numeric THEN round(btbl.net_weight_g, 2) || ' g • '::text
                                ELSE ''::text
                            END || COALESCE(btbl.species_strain[1], ''::text)) || ''::text
                            WHEN btbl.item_category_mat = 'fresh_mushrooms'::text THEN (
                            CASE
                                WHEN COALESCE(
                                CASE
                                    WHEN btbl.package_size = '1 g'::text THEN 1::numeric
                                    WHEN btbl.package_size = '5 g'::text THEN 5::numeric
                                    WHEN btbl.package_size = '10 g'::text THEN 10::numeric
                                    WHEN btbl.package_size = '1 oz'::text THEN 28.349523125
                                    ELSE NULL::numeric
                                END::text, ''::text) <> ALL (ARRAY[''::text, '0'::text, 'false'::text]) THEN round(
                                CASE
                                    WHEN btbl.package_size = '1 g'::text THEN 1::numeric
                                    WHEN btbl.package_size = '5 g'::text THEN 5::numeric
                                    WHEN btbl.package_size = '10 g'::text THEN 10::numeric
                                    WHEN btbl.package_size = '1 oz'::text THEN 28.349523125
                                    ELSE NULL::numeric
                                END, 2) || ' g • '::text
                                ELSE ''::text
                            END || COALESCE(btbl.species_strain[1], ''::text)) || ''::text
                            ELSE ''::text
                        END ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM vc_products btbl
                  WHERE btbl.nocopk = base.product_id) AS label_subtitle_prod_from_product_id,
            ( SELECT COALESCE(array_agg(btbl.product_id ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM vc_products btbl
                  WHERE btbl.nocopk = base.product_id) AS label_footer_prod_from_product_id,
            ( SELECT COALESCE(array_agg(
                        CASE
                            WHEN btbl.origin_strain_regulated > 0::numeric THEN
                            CASE
                                WHEN COALESCE(btbl.item_category_mat = 'freezedriedmushrooms'::text, false) OR COALESCE(btbl.item_category_mat = 'fresh_mushrooms'::text, false) OR COALESCE(btbl.item_category_mat = 'freezer_tray'::text, false) OR COALESCE(btbl.item_category_mat = 'fresh_tray'::text, false) THEN ''::text
                                ELSE
                                CASE
                                    WHEN COALESCE(btbl.item_category_mat = 'freezedriedmushrooms'::text, false) OR COALESCE(btbl.item_category_mat = 'fresh_mushrooms'::text, false) THEN 'This product was produced in a home kitchen that is not subject to state licensure or inspection and that may also contain common food allergies such as tree nuts, peanuts, eggs, soy, wheat, milk, fish, and crustacean shellfish. This product is not intended for resale.'::text
                                    ELSE
                                    CASE
WHEN btbl.item_category_mat = 'fruiting_block'::text THEN 'This product contains ingredients designed for mushroom cultivation. This product is not intended for human consumption.'::text
ELSE ''::text
                                    END
                                END
                            END
                            ELSE
                            CASE
                                WHEN COALESCE(btbl.item_category_mat = 'freezedriedmushrooms'::text, false) OR COALESCE(btbl.item_category_mat = 'fresh_mushrooms'::text, false) THEN 'This product was produced in a home kitchen that is not subject to state licensure or inspection and that may also contain common food allergies such as tree nuts, peanuts, eggs, soy, wheat, milk, fish, and crustacean shellfish. This product is not intended for resale.'::text
                                ELSE
                                CASE
                                    WHEN btbl.item_category_mat = 'fruiting_block'::text THEN 'This product contains ingredients designed for mushroom cultivation. This product is not intended for human consumption.'::text
                                    ELSE ''::text
                                END
                            END
                        END ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM vc_products btbl
                  WHERE btbl.nocopk = base.product_id) AS label_cottage_prod_from_product_id,
            ( SELECT COALESCE(array_agg(
                        CASE
                            WHEN COALESCE(btbl.package_class = 'Sample'::text, false) AND COALESCE(btbl.item_category_mat = 'freezedriedmushrooms'::text, false) THEN
                            CASE
                                WHEN 'Sacrament'::text = ANY (btbl.origin_strain_product_use) THEN 'Approximate sample size: 5–10 portions of 0.1–0.2 g.'::text
                                WHEN 'Functional'::text = ANY (btbl.origin_strain_product_use) THEN 'Approximate sample size: 3–5 daily servings.'::text
                                WHEN 'Gourmet/Functional'::text = ANY (btbl.origin_strain_product_use) THEN 'Approximate sample size: 3–5 servings.'::text
                                WHEN 'Gourmet'::text = ANY (btbl.origin_strain_product_use) THEN 'Sample size: Great for one recipe.'::text
                                ELSE ''::text
                            END
                            ELSE
                            CASE
                                WHEN btbl.origin_strain_regulated > 0::numeric THEN
                                CASE
                                    WHEN btbl.item_category_mat = 'fruiting_block'::text THEN 'Dank Mushrooms offers delivery and shipment of fresh gourmet and specialty mushrooms, dried mushrooms, mushroom supplements, mushroom grow kits and mycology supplies.'::text
                                    ELSE ''::text
                                END
                                ELSE
                                CASE
                                    WHEN btbl.item_category_mat = 'freezedriedmushrooms'::text THEN 'Dank Mushrooms offers delivery and shipment of fresh gourmet and specialty mushrooms, dried mushrooms, mushroom supplements, mushroom grow kits and mycology supplies.'::text
                                    WHEN btbl.item_category_mat = 'fresh_mushrooms'::text THEN 'Dank Mushrooms offers delivery and shipment of fresh gourmet and specialty mushrooms, dried mushrooms, mushroom supplements, mushroom grow kits and mycology supplies.'::text
                                    WHEN btbl.item_category_mat = 'fruiting_block'::text THEN 'Dank Mushrooms offers delivery and shipment of fresh gourmet and specialty mushrooms, dried mushrooms, mushroom supplements, mushroom grow kits and mycology supplies.'::text
                                    ELSE ''::text
                                END
                            END
                        END ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM vc_products btbl
                  WHERE btbl.nocopk = base.product_id) AS label_companyinfo_prod_from_product_id,
            ( SELECT COALESCE(array_agg(
                        CASE
                            WHEN btbl.origin_strain_regulated > 0::numeric THEN
                            CASE
                                WHEN btbl.item_category_mat = 'fresh_mushrooms'::text THEN ''::text
                                WHEN btbl.item_category_mat = 'freezer_tray'::text THEN ''::text
                                WHEN btbl.item_category_mat = 'fresh_tray'::text THEN ''::text
                                WHEN btbl.item_category_mat = 'fruiting_block'::text THEN 'Disclaimer: Psilocybin is classified as a Schedule I controlled substance by the U.S. Drug Enforcement Administration (DEA). Unauthorized cultivation, possession, or distribution of psilocybin-containing mushrooms is illegal in most states. It is the responsibility of the buyer to research and comply with all local, state, and federal laws regarding mushroom cultivation. Please consult your local laws carefully before any attempt to grow mushrooms, as penalties for non-compliance can be significant.'::text
                                WHEN btbl.item_category_mat = 'freezedriedmushrooms'::text THEN
                                CASE
                                    WHEN btbl.package_class = 'Sample'::text THEN (((('NOTICE'::text || chr(10)) || 'Psilocybin remains a Schedule I controlled substance under U.S. federal law. Under Colorado''s Natural Medicine Health Act, adults age 21+ may lawfully receive and possess natural medicine in certain circumstances, including uncompensated gifting.'::text) || chr(10)) || chr(10)) || 'By opening this package, I acknowledge that I am 21+, will use this sacrament responsibly and intentionally, understand Rooted Psyche provides no medical or mental health treatment, have no contraindicated condition or have consulted a healthcare professional, and accept full responsibility for my possession and use.'::text
                                    ELSE ''::text
                                END
                                ELSE ''::text
                            END
                            ELSE ''::text
                        END ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM vc_products btbl
                  WHERE btbl.nocopk = base.product_id) AS label_disclaimer_prod_from_product_id,
            ( SELECT COALESCE(array_agg(
                        CASE
                            WHEN btbl.package_class = 'Sample'::text THEN replace(
                            CASE
                                WHEN btbl.origin_strain_regulated > 0::numeric THEN
                                CASE
                                    WHEN COALESCE(btbl.item_category_mat = 'freezedriedmushrooms'::text, false) OR COALESCE(btbl.item_category_mat = 'fresh_mushrooms'::text, false) OR COALESCE(btbl.item_category_mat = 'freezer_tray'::text, false) OR COALESCE(btbl.item_category_mat = 'fresh_tray'::text, false) THEN ((((((('PO Box 266'::text || chr(10)) || 'Johnstown, CO 80534'::text) || chr(10)) || 'https://www.rootedpsyche.com/'::text) || chr(10)) || '(970) 408-0858'::text) || chr(10)) || 'rootedpsyche@gmail.com'::text
                                    ELSE ((((((('1726 Goldenvue Drive'::text || chr(10)) || 'Johnstown, CO 80534'::text) || chr(10)) || 'https://www.danks.store'::text) || chr(10)) || '970-587-3294'::text) || chr(10)) || 'sales@danks.net'::text
                                END
                                ELSE ((((((('1726 Goldenvue Drive'::text || chr(10)) || 'Johnstown, CO 80534'::text) || chr(10)) || 'https://www.danks.store'::text) || chr(10)) || '970-587-3294'::text) || chr(10)) || 'sales@danks.net'::text
                            END, ''::text || chr(10), ' • '::text)
                            ELSE
                            CASE
                                WHEN btbl.origin_strain_regulated > 0::numeric THEN
                                CASE
                                    WHEN COALESCE(btbl.item_category_mat = 'freezedriedmushrooms'::text, false) OR COALESCE(btbl.item_category_mat = 'fresh_mushrooms'::text, false) OR COALESCE(btbl.item_category_mat = 'freezer_tray'::text, false) OR COALESCE(btbl.item_category_mat = 'fresh_tray'::text, false) THEN ((((((('PO Box 266'::text || chr(10)) || 'Johnstown, CO 80534'::text) || chr(10)) || 'https://www.rootedpsyche.com/'::text) || chr(10)) || '(970) 408-0858'::text) || chr(10)) || 'rootedpsyche@gmail.com'::text
                                    ELSE ((((((('1726 Goldenvue Drive'::text || chr(10)) || 'Johnstown, CO 80534'::text) || chr(10)) || 'https://www.danks.store'::text) || chr(10)) || '970-587-3294'::text) || chr(10)) || 'sales@danks.net'::text
                                END
                                ELSE ((((((('1726 Goldenvue Drive'::text || chr(10)) || 'Johnstown, CO 80534'::text) || chr(10)) || 'https://www.danks.store'::text) || chr(10)) || '970-587-3294'::text) || chr(10)) || 'sales@danks.net'::text
                            END
                        END ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM vc_products btbl
                  WHERE btbl.nocopk = base.product_id) AS label_companyaddress_prod_from_product_id,
            ( SELECT COALESCE(array_agg(
                        CASE
                            WHEN NULLIF(btbl.pack_date::text, ''::text) IS NOT NULL THEN 'Packaged: '::text || to_char(btbl.pack_date::timestamp without time zone, 'YYYY-MM-DD'::text)
                            ELSE ''::text
                        END ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM vc_products btbl
                  WHERE btbl.nocopk = base.product_id) AS label_packaged_prod_from_product_id,
            ( SELECT COALESCE(array_agg(
                        CASE
                            WHEN NULLIF(btbl.use_by::text, ''::text) IS NOT NULL THEN 'Use by: '::text || to_char(btbl.use_by::timestamp without time zone, 'YYYY-MM-DD'::text)
                            ELSE ''::text
                        END ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM vc_products btbl
                  WHERE btbl.nocopk = base.product_id) AS label_useby_prod_from_product_id,
            ( SELECT COALESCE(array_agg(btbl.label_proc_prod::text ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM vc_products btbl
                  WHERE btbl.nocopk = base.product_id) AS label_proc_prod_from_product_id,
            ( SELECT COALESCE(array_agg(btbl.label_spawned_prod::text ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM vc_products btbl
                  WHERE btbl.nocopk = base.product_id) AS label_spawned_prod_from_product_id,
            ( SELECT COALESCE(array_agg(btbl.label_inoc_prod::text ORDER BY btbl.nocopk), ARRAY[]::text[]) AS "coalesce"
                   FROM vc_products btbl
                  WHERE btbl.nocopk = base.product_id) AS label_inoc_prod_from_product_id
 FROM v_print_queue base
        )
 SELECT nocopk,
    print_id,
    source_kind,
    lot_id,
    product_id,
    print_status,
    label_type,
    error_msg,
    created_at,
    run_id,
    claimed_by,
    claimed_at,
    printed_by,
    printed_at,
    pdf_path,
    nocouuid,
    airtable_id,
    nc_created_at,
    nc_updated_at,
    __table,
    __primary,
    item_category_mat_from_lot_id,
    label_company_lot_from_lot_id,
    item_category_mat_from_product_id,
    label_substrateinputblocks_line_from_lot_id,
    label_graininputblocks_line_from_lot_id,
    label_footer_lot_from_lot_id,
    label_subtitle_lot_from_lot_id,
    label_title_lot_from_lot_id,
    label_template_from_lot_id,
    label_useby_line_from_lot_id,
    label_spawned_line_from_lot_id,
    label_inoc_line_from_lot_id,
    label_proc_line_from_lot_id,
    label_company_prod_from_product_id,
    label_title_prod_from_product_id,
    label_subtitle_prod_from_product_id,
    label_footer_prod_from_product_id,
    label_cottage_prod_from_product_id,
    label_companyinfo_prod_from_product_id,
    label_disclaimer_prod_from_product_id,
    label_companyaddress_prod_from_product_id,
    label_packaged_prod_from_product_id,
    label_useby_prod_from_product_id,
    label_proc_prod_from_product_id,
    label_spawned_prod_from_product_id,
    label_inoc_prod_from_product_id,
        CASE
            WHEN source_kind = 'steri_sheet'::text THEN 'ZEBRA'::text
            ELSE
            CASE
                WHEN COALESCE('fresh_mushrooms'::text = ANY (item_category_mat_from_product_id), false) OR COALESCE('freezer_tray'::text = ANY (item_category_mat_from_product_id), false) OR COALESCE('fresh_tray'::text = ANY (item_category_mat_from_product_id), false) OR COALESCE('fresh_mushrooms'::text = ANY (item_category_mat_from_lot_id), false) OR COALESCE('freezer_tray'::text = ANY (item_category_mat_from_lot_id), false) OR COALESCE('fresh_tray'::text = ANY (item_category_mat_from_lot_id), false) THEN 'TRAYS'::text
                ELSE 'ZEBRA'::text
            END
        END AS print_target
 FROM comp;

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT schema_name, view_name, definition
    FROM _mp031_views
    WHERE NOT is_target
    ORDER BY depth ASC, schema_name, view_name
  LOOP
    EXECUTE format(
      'CREATE VIEW %I.%I AS %s',
      r.schema_name,
      r.view_name,
      r.definition
    );
  END LOOP;
END
$$;

-- Restore relation options while the migration role still owns the recreated
-- views. Ownership is transferred back only after ACLs/comments are restored.
DO $$
DECLARE
  r record;
  v_option text;
  v_key text;
  v_value text;
BEGIN
  FOR r IN
    SELECT schema_name, view_name, reloptions
    FROM _mp031_views
    ORDER BY is_target DESC, depth ASC, schema_name, view_name
  LOOP
    IF r.reloptions IS NOT NULL THEN
      FOREACH v_option IN ARRAY r.reloptions
      LOOP
        v_key := split_part(v_option, '=', 1);
        v_value := substr(v_option, length(v_key) + 2);
        EXECUTE format(
          'ALTER VIEW %I.%I SET (%I = %L)',
          r.schema_name,
          r.view_name,
          v_key,
          v_value
        );
      END LOOP;
    END IF;
  END LOOP;
END
$$;

-- Clear explicit ACLs that may have been introduced by default privileges on
-- recreation, then restore the ACLs captured from the live views.
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT DISTINCT
      v.schema_name,
      v.view_name,
      CASE
        WHEN acl.grantee = 0 THEN 'PUBLIC'
        ELSE pg_get_userbyid(acl.grantee)
      END AS grantee_name
    FROM _mp031_views v
    JOIN pg_namespace n
      ON n.nspname = v.schema_name
    JOIN pg_class c
      ON c.relnamespace = n.oid
     AND c.relname = v.view_name
    CROSS JOIN LATERAL aclexplode(c.relacl) acl
  LOOP
    IF r.grantee_name = 'PUBLIC' THEN
      EXECUTE format(
        'REVOKE ALL PRIVILEGES ON TABLE %I.%I FROM PUBLIC',
        r.schema_name,
        r.view_name
      );
    ELSE
      EXECUTE format(
        'REVOKE ALL PRIVILEGES ON TABLE %I.%I FROM %I',
        r.schema_name,
        r.view_name,
        r.grantee_name
      );
    END IF;
  END LOOP;

  FOR r IN
    SELECT schema_name, view_name, grantee_name, privilege_type, is_grantable
    FROM _mp031_grants
    ORDER BY schema_name, view_name, grantee_name, privilege_type
  LOOP
    IF r.grantee_name = 'PUBLIC' THEN
      EXECUTE format(
        'GRANT %s ON TABLE %I.%I TO PUBLIC%s',
        r.privilege_type,
        r.schema_name,
        r.view_name,
        CASE WHEN r.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END
      );
    ELSE
      EXECUTE format(
        'GRANT %s ON TABLE %I.%I TO %I%s',
        r.privilege_type,
        r.schema_name,
        r.view_name,
        r.grantee_name,
        CASE WHEN r.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END
      );
    END IF;
  END LOOP;
END
$$;

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT schema_name, view_name, view_comment
    FROM _mp031_views
    WHERE view_comment IS NOT NULL
  LOOP
    EXECUTE format(
      'COMMENT ON VIEW %I.%I IS %L',
      r.schema_name,
      r.view_name,
      r.view_comment
    );
  END LOOP;

  FOR r IN
    SELECT schema_name, view_name, column_name, comment_text
    FROM _mp031_column_comments
    ORDER BY schema_name, view_name, column_name
  LOOP
    EXECUTE format(
      'COMMENT ON COLUMN %I.%I.%I IS %L',
      r.schema_name,
      r.view_name,
      r.column_name,
      r.comment_text
    );
  END LOOP;
END
$$;

COMMENT ON VIEW public.vc_lots IS
  'Computed Lots view. Legacy Airtable public_link* navigation fields were retired by migration 031.';

COMMENT ON VIEW public.vc_products IS
  'Computed Products view. Legacy Airtable public_link navigation field was retired by migration 031.';

COMMENT ON VIEW public.vc_print_queue IS
  'Computed print queue view. Legacy Airtable public_link_from_* fields were retired by migration 031.';

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT schema_name, view_name, owner_name
    FROM _mp031_views
    ORDER BY is_target DESC, depth ASC, schema_name, view_name
  LOOP
    EXECUTE format(
      'ALTER VIEW %I.%I OWNER TO %I',
      r.schema_name,
      r.view_name,
      r.owner_name
    );
  END LOOP;
END
$$;

DO $$
DECLARE
  v_bad_columns text;
  v_missing text;
BEGIN
  SELECT string_agg(
           format('%I.%I.%I', table_schema, table_name, column_name),
           ', '
         )
    INTO v_bad_columns
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name IN ('vc_lots', 'vc_products', 'vc_print_queue')
    AND column_name LIKE 'public_link%';

  IF v_bad_columns IS NOT NULL THEN
    RAISE EXCEPTION
      'Migration 031 failed to remove legacy public-link columns: %',
      v_bad_columns;
  END IF;

  IF position('airtable.com' IN lower(pg_get_viewdef('public.vc_lots'::regclass, true))) > 0
     OR position('airtable.com' IN lower(pg_get_viewdef('public.vc_products'::regclass, true))) > 0
     OR position('airtable.com' IN lower(pg_get_viewdef('public.vc_print_queue'::regclass, true))) > 0 THEN
    RAISE EXCEPTION
      'Migration 031 left an Airtable URL expression in a cleaned target view';
  END IF;

  SELECT string_agg(name, ', ')
    INTO v_missing
  FROM (
    VALUES
      ('public.vc_lots'),
      ('public.vc_products'),
      ('public.vc_print_queue'),
      ('public.vc_events'),
      ('public.vc_ecommerce'),
      ('public.vc_ecommerce_orders')
  ) expected(name)
  WHERE to_regclass(expected.name) IS NULL;

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION
      'Migration 031 did not restore expected dependent views: %',
      v_missing;
  END IF;
END
$$;

COMMIT;
