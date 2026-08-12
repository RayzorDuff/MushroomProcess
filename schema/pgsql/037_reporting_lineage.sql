-- 037_reporting_lineage.sql
-- Issue #87 Phase 4: explicit adjacent lot/product lineage for Reporting.

SET search_path = public, pg_catalog;

BEGIN;

/*
 * v_reporting_lot_lineage expands the explicit relationships adjacent to every
 * lot into one UI-friendly row per related entity.  It deliberately does not
 * infer lineage from matching strain/item/date values.
 *
 * Lot-to-lot relationships are emitted in both directions so Reporting can
 * answer either of these without recursive SQL in Appsmith:
 *   fruiting block -> source grain/substrate
 *   source grain/substrate -> resulting fruiting block(s)
 *
 * Products are emitted downstream from each explicit origin-lot relationship.
 * Product-to-product branching remains available from the underlying schema but
 * is intentionally deferred from the Phase 4 lot-rooted interface.
 */
CREATE OR REPLACE VIEW public.v_reporting_lot_lineage AS
WITH lot_edges AS (
  SELECT
    'grain_input'::text AS relationship_type,
    j.lots1_id AS source_lot_nocopk,
    j.lots_id AS target_lot_nocopk
  FROM public._m2m_lots_lots_grain_inputs j
  WHERE j.lots1_id <> j.lots_id

  UNION ALL

  SELECT
    'substrate_input'::text,
    j.lots1_id,
    j.lots_id
  FROM public._m2m_lots_lots_substrate_inputs j
  WHERE j.lots1_id <> j.lots_id

  UNION ALL

  SELECT
    'source_lot'::text,
    l.source_lot_id,
    l.nocopk
  FROM public.lots l
  WHERE l.source_lot_id IS NOT NULL
    AND l.source_lot_id <> l.nocopk

  UNION ALL

  SELECT
    'parent_lot'::text,
    l.parent_lot_id,
    l.nocopk
  FROM public.lots l
  WHERE l.parent_lot_id IS NOT NULL
    AND l.parent_lot_id <> l.nocopk
),
lot_adjacency AS (
  SELECT
    e.target_lot_nocopk AS root_lot_nocopk,
    'upstream'::text AS direction,
    e.relationship_type,
    e.source_lot_nocopk AS related_lot_nocopk,
    e.source_lot_nocopk AS input_lot_nocopk,
    e.target_lot_nocopk AS output_lot_nocopk
  FROM lot_edges e

  UNION ALL

  SELECT
    e.source_lot_nocopk AS root_lot_nocopk,
    'downstream'::text AS direction,
    e.relationship_type,
    e.target_lot_nocopk AS related_lot_nocopk,
    e.source_lot_nocopk AS input_lot_nocopk,
    e.target_lot_nocopk AS output_lot_nocopk
  FROM lot_edges e
),
lot_rows AS (
  SELECT
    root.lot_nocopk,
    root.lot_id,
    a.direction,
    a.relationship_type,
    CASE
      WHEN a.direction = 'upstream' AND a.relationship_type = 'grain_input' THEN 'Source grain'
      WHEN a.direction = 'upstream' AND a.relationship_type = 'substrate_input' THEN 'Source substrate'
      WHEN a.direction = 'upstream' AND a.relationship_type = 'source_lot' THEN 'Source lot'
      WHEN a.direction = 'upstream' AND a.relationship_type = 'parent_lot' THEN 'Parent lot'
      WHEN a.direction = 'downstream' AND a.relationship_type = 'grain_input' THEN 'Resulting fruiting block'
      WHEN a.direction = 'downstream' AND a.relationship_type = 'substrate_input' THEN 'Resulting fruiting block'
      WHEN a.direction = 'downstream' AND a.relationship_type = 'source_lot' THEN 'Derived lot'
      WHEN a.direction = 'downstream' AND a.relationship_type = 'parent_lot' THEN 'Child lot'
      ELSE initcap(replace(a.relationship_type, '_', ' '))
    END AS relationship_label,
    'lot'::text AS related_entity_type,
    rel.lot_nocopk AS related_nocopk,
    rel.lot_id AS related_id,
    rel.item_name AS related_item_name,
    rel.item_category AS related_item_category,
    rel.species_strain AS related_species_strain,
    rel.status AS related_status,
    rel.lifecycle_start_at AS related_lifecycle_start_at,
    rel.inoculated_at AS related_inoculated_at,
    rel.fully_colonized_at AS related_fully_colonized_at,
    rel.spawned_at AS related_spawned_at,
    rel.fruiting_start_at AS related_fruiting_start_at,
    rel.first_harvest_at AS related_first_harvest_at,
    rel.last_harvest_at AS related_last_harvest_at,
    rel.contaminated_at AS related_contaminated_at,
    rel.terminal_at AS related_terminal_at,
    rel.terminal_reason AS related_terminal_reason,
    rel.days_inoculation_to_fully_colonized AS related_days_inoculation_to_fully_colonized,
    rel.days_spawn_to_fruiting AS related_days_spawn_to_fruiting,
    rel.days_in_fruiting AS related_days_in_fruiting,
    rel.flush_count AS related_flush_count,
    rel.first_flush_g AS related_first_flush_g,
    rel.total_harvest_g AS related_total_harvest_g,
    CASE
      WHEN a.relationship_type = 'grain_input'
           AND input_lifecycle.inoculated_at IS NOT NULL
           AND output_lifecycle.spawned_at IS NOT NULL
        THEN round((extract(epoch FROM (output_lifecycle.spawned_at - input_lifecycle.inoculated_at)) / 86400.0)::numeric, 3)
      WHEN a.relationship_type = 'substrate_input'
           AND input_lifecycle.processed_at IS NOT NULL
           AND output_lifecycle.spawned_at IS NOT NULL
        THEN round((extract(epoch FROM (output_lifecycle.spawned_at - input_lifecycle.processed_at)) / 86400.0)::numeric, 3)
      ELSE NULL
    END AS input_age_at_use_days,
    NULL::timestamp without time zone AS related_product_harvested_at,
    NULL::numeric AS related_product_flush_no,
    NULL::numeric AS related_product_weight_g,
    NULL::text AS related_product_tray_state,
    NULL::date AS related_product_pack_date,
    NULL::date AS related_product_use_by,
    NULL::text AS related_product_location
  FROM lot_adjacency a
  JOIN public.v_reporting_lot_lifecycle root
    ON root.lot_nocopk = a.root_lot_nocopk
  JOIN public.v_reporting_lot_lifecycle rel
    ON rel.lot_nocopk = a.related_lot_nocopk
  JOIN public.v_reporting_lot_lifecycle input_lifecycle
    ON input_lifecycle.lot_nocopk = a.input_lot_nocopk
  JOIN public.v_reporting_lot_lifecycle output_lifecycle
    ON output_lifecycle.lot_nocopk = a.output_lot_nocopk
),
product_rows AS (
  SELECT
    root.lot_nocopk,
    root.lot_id,
    'downstream'::text AS direction,
    'origin_product'::text AS relationship_type,
    'Resulting product'::text AS relationship_label,
    'product'::text AS related_entity_type,
    p.nocopk AS related_nocopk,
    p.product_id AS related_id,
    p.name_mat AS related_item_name,
    p.item_category_mat AS related_item_category,
    root.species_strain AS related_species_strain,
    COALESCE(NULLIF(p.tray_state, ''), loc.name, 'Product') AS related_status,
    COALESCE(p.harvested_at, p.pack_date::timestamp, p.nc_created_at) AS related_lifecycle_start_at,
    NULL::timestamp without time zone AS related_inoculated_at,
    NULL::timestamp without time zone AS related_fully_colonized_at,
    NULL::timestamp without time zone AS related_spawned_at,
    NULL::timestamp without time zone AS related_fruiting_start_at,
    NULL::timestamp without time zone AS related_first_harvest_at,
    NULL::timestamp without time zone AS related_last_harvest_at,
    NULL::timestamp without time zone AS related_contaminated_at,
    NULL::timestamp without time zone AS related_terminal_at,
    NULL::text AS related_terminal_reason,
    NULL::numeric AS related_days_inoculation_to_fully_colonized,
    NULL::numeric AS related_days_spawn_to_fruiting,
    NULL::numeric AS related_days_in_fruiting,
    NULL::bigint AS related_flush_count,
    NULL::numeric AS related_first_flush_g,
    NULL::numeric AS related_total_harvest_g,
    NULL::numeric AS input_age_at_use_days,
    p.harvested_at AS related_product_harvested_at,
    p.harvest_flush_no AS related_product_flush_no,
    COALESCE(p.harvest_weight_g, p.net_weight_g) AS related_product_weight_g,
    p.tray_state AS related_product_tray_state,
    p.pack_date AS related_product_pack_date,
    p.use_by AS related_product_use_by,
    loc.name AS related_product_location
  FROM public._m2m_products_lots_origin_lots j
  JOIN public.v_reporting_lot_lifecycle root
    ON root.lot_nocopk = j.lots_id
  JOIN public.products p
    ON p.nocopk = j.products_id
  LEFT JOIN public.locations loc
    ON loc.nocopk = p.storage_location_id
)
SELECT DISTINCT ON (
  x.lot_nocopk,
  x.direction,
  x.relationship_type,
  x.related_entity_type,
  x.related_nocopk
)
  x.*
FROM (
  SELECT * FROM lot_rows
  UNION ALL
  SELECT * FROM product_rows
) x
ORDER BY
  x.lot_nocopk,
  x.direction,
  x.relationship_type,
  x.related_entity_type,
  x.related_nocopk;

COMMENT ON VIEW public.v_reporting_lot_lineage IS
  'Issue #87 Phase 4 explicit adjacent lineage for lot-rooted Reporting. Exposes upstream/downstream lot relationships and resulting products without inferred links.';

COMMIT;
