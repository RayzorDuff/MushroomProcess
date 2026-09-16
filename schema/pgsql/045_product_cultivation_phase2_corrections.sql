\set ON_ERROR_STOP on

-- Issue #57 Phase 2 corrective follow-up.
--
-- Fixes three production findings after deployment:
--   1. Candidate expiration must use the Colorado operating date rather than
--      the PostgreSQL host's UTC CURRENT_DATE.  Otherwise inventory expiring
--      on a local calendar date disappears several hours early.
--   2. Product identifiers are already self-identifying (PROD-*), so the
--      candidate row should expose the real Product identifier without a
--      redundant "PRODUCT · " display prefix.
--   3. Product-return wrapper functions use local operating time when they
--      derive an as-of date from now(), keeping server-side validation aligned
--      with the candidate view.
--
-- The timezone is deliberately centralized in mp_cultivation_operating_date()
-- so a future Settings-table implementation can replace this one function.

BEGIN;

CREATE OR REPLACE FUNCTION public.mp_cultivation_operating_date()
RETURNS date
LANGUAGE sql
STABLE
AS $$
  SELECT (CURRENT_TIMESTAMP AT TIME ZONE 'America/Denver')::date;
$$;

COMMENT ON FUNCTION public.mp_cultivation_operating_date() IS
  'Issue #57 operating calendar date for cultivation inventory eligibility. Centralized for future Settings-table timezone configuration.';

CREATE OR REPLACE VIEW public.v_product_cultivation_candidates AS
WITH product_rows AS (
  SELECT
    p.nocopk AS product_nocopk,
    p.product_id,
    p.item_id,
    COALESCE(NULLIF(btrim(p.name_mat), ''), NULLIF(btrim(i.name), '')) AS item_name_mat,
    COALESCE(NULLIF(btrim(p.item_category_mat), ''), NULLIF(btrim(i.category), '')) AS item_category_mat,
    COALESCE(p.strain_id, origin.strain_id) AS strain_id,
    COALESCE(NULLIF(btrim(s.species_strain), ''), NULLIF(btrim(origin.strain_species_strain_mat), '')) AS strain_species_strain_mat,
    COALESCE(NULLIF(btrim(origin.vendor_name_mat), ''), NULLIF(btrim(origin.vendor_name), '')) AS vendor_name_mat,
    p.storage_location_id AS location_id,
    loc.name AS storage_location,
    p.process_type_mat,
    p.pack_date,
    p.use_by AS product_use_by,
    p.net_weight_g,
    p.net_weight_oz,
    p.net_volume_ml,
    p.nc_created_at,
    origin.nocopk AS origin_lot_nocopk,
    origin.lot_id AS origin_lot_id,
    origin.recipe_id,
    origin.created_at AS origin_created_at,
    origin.sterilized_at,
    origin.received_date,
    origin.use_by AS origin_use_by,
    origin.process_type_mat AS origin_process_type_mat,
    origin.source_type AS origin_source_type,
    origin.label_template AS origin_label_template,
    e.eligible_for_return,
    e.can_inoculate_target,
    e.can_inoculate_source,
    e.can_spawn_substrate,
    e.ineligibility_reason
  FROM public.products p
  LEFT JOIN public.items i ON i.nocopk = p.item_id
  LEFT JOIN public.locations loc ON loc.nocopk = p.storage_location_id
  LEFT JOIN LATERAL (
    SELECT l.*
    FROM public._m2m_products_lots_origin_lots x
    JOIN public.lots l ON l.nocopk = x.lots_id
    WHERE x.products_id = p.nocopk
    ORDER BY l.nocopk
    LIMIT 1
  ) origin ON true
  LEFT JOIN public.strains s ON s.nocopk = COALESCE(p.strain_id, origin.strain_id)
  CROSS JOIN LATERAL public.mp_product_cultivation_eligibility(p.nocopk, public.mp_cultivation_operating_date()) e
)
SELECT
  'product'::text AS inventory_kind,
  ('product:' || pr.product_nocopk::text) AS row_key,
  NULL::bigint AS nocopk,
  pr.product_nocopk,
  pr.product_id,
  pr.product_id AS lot_id,
  pr.item_id,
  pr.item_name_mat,
  pr.item_category_mat,
  pr.item_category_mat AS item_category,
  pr.strain_id,
  pr.strain_species_strain_mat,
  pr.vendor_name_mat,
  'Packaged Product'::text AS status,
  1::numeric AS qty,
  CASE
    WHEN regexp_replace(lower(COALESCE(pr.item_category_mat, '')), '[^a-z0-9]', '', 'g') = 'lcsyringe'
      THEN pr.net_volume_ml
    WHEN COALESCE(pr.net_weight_g, 0) > 0
      THEN pr.net_weight_g / 453.59237
    WHEN COALESCE(pr.net_weight_oz, 0) > 0
      THEN pr.net_weight_oz / 16.0
    ELSE NULL
  END AS unit_size,
  COALESCE(pr.pack_date::timestamp without time zone, pr.nc_created_at, pr.origin_created_at) AS created_at,
  pr.sterilized_at,
  pr.received_date,
  NULL::timestamp without time zone AS inoculated_at,
  NULL::timestamp without time zone AS spawned_at,
  pr.net_volume_ml AS remaining_volume_ml,
  pr.net_volume_ml AS total_volume_ml,
  NULL::numeric AS lc_volume_ml,
  NULL::numeric AS plate_count,
  pr.location_id,
  pr.storage_location,
  COALESCE(NULLIF(btrim(pr.process_type_mat), ''), pr.origin_process_type_mat) AS process_type_mat,
  pr.recipe_id,
  LEAST(pr.product_use_by, pr.origin_use_by) AS use_by,
  CASE
    WHEN s2.regulated IS NULL THEN ARRAY[FALSE]::boolean[]
    ELSE ARRAY[s2.regulated]::boolean[]
  END AS regulated_from_strain_id,
  COALESCE(s2.regulated, false) AS is_regulated,
  pr.origin_lot_nocopk,
  pr.origin_lot_id,
  pr.origin_source_type,
  pr.origin_label_template,
  pr.eligible_for_return,
  pr.can_inoculate_target,
  pr.can_inoculate_source,
  pr.can_spawn_substrate,
  pr.ineligibility_reason
FROM product_rows pr
LEFT JOIN public.strains s2 ON s2.nocopk = pr.strain_id
WHERE pr.eligible_for_return
  AND (LEAST(pr.product_use_by, pr.origin_use_by) IS NULL
       OR LEAST(pr.product_use_by, pr.origin_use_by) >= public.mp_cultivation_operating_date());

COMMENT ON VIEW public.v_product_cultivation_candidates IS
  'Issue #57 UI contract: currently eligible packaged grain, substrate, and LC syringe Products shaped like cultivation inventory rows. Product rows are explicitly identified by inventory_kind/product_nocopk and must be consumed through contextual wrapper functions.';

-- Functions that derive v_ts from now() must do so in the same operating
-- timezone used by candidate visibility.  Explicit override/p_timestamp values
-- are preserved unchanged.
ALTER FUNCTION public.mp_product_return_to_lot(
  bigint, text, text, timestamp without time zone, text, text, bigint
) SET TimeZone TO 'America/Denver';

ALTER FUNCTION public.mp_inoculate_with_products_result(
  bigint, bigint, bigint[], bigint[], bigint, numeric,
  timestamp without time zone, text, text, timestamp without time zone, text
) SET TimeZone TO 'America/Denver';

ALTER FUNCTION public.mp_spawn_to_bulk_with_products(
  bigint[], bigint[], bigint[], integer, jsonb, bigint,
  timestamp without time zone, text, text, timestamp without time zone, text, text
) SET TimeZone TO 'America/Denver';

COMMIT;
