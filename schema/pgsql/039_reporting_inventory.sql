-- 039_reporting_inventory.sql
-- Issue #87 Phase 7: canonical current-inventory reporting layer.

SET search_path = public, pg_catalog;

BEGIN;

/*
 * Classify product expiration against an explicit as-of date.  Active/terminal
 * inventory is deliberately a separate concept: an active product may already
 * be past its use-by date and Reporting must surface that condition.
 */
CREATE OR REPLACE FUNCTION public.mp_reporting_inventory_expiration_status(
  p_use_by date,
  p_as_of date DEFAULT CURRENT_DATE,
  p_expiring_days integer DEFAULT 30
)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_as_of date := COALESCE(p_as_of, CURRENT_DATE);
  v_days integer := COALESCE(p_expiring_days, 30);
BEGIN
  IF v_days < 0 THEN
    RAISE EXCEPTION 'Reporting inventory expiring-day horizon must be nonnegative: %', v_days
      USING ERRCODE = '22023';
  END IF;

  IF p_use_by IS NULL THEN
    RETURN 'unknown';
  ELSIF p_use_by < v_as_of THEN
    RETURN 'expired';
  ELSIF p_use_by <= (v_as_of + v_days) THEN
    RETURN 'expiring';
  ELSE
    RETURN 'current';
  END IF;
END;
$$;

COMMENT ON FUNCTION public.mp_reporting_inventory_expiration_status(date, date, integer) IS
  'Issue #87 Phase 7 deterministic product expiration classifier: expired, expiring, current, or unknown for an explicit as-of date and horizon.';

/*
 * One row per Product with the active/terminal rule centralized from the
 * existing Products interface.  This view is time-independent except for raw
 * dates; date-relative expiration is added by mp_reporting_product_inventory().
 */
CREATE OR REPLACE VIEW public.v_reporting_product_inventory AS
WITH state_tokens AS (
  SELECT
    p.nocopk AS product_nocopk,
    COALESCE(
      array_agg(DISTINCT regexp_replace(lower(btrim(ts.state)), '[^a-z0-9]', '', 'g')
        ORDER BY regexp_replace(lower(btrim(ts.state)), '[^a-z0-9]', '', 'g'))
        FILTER (WHERE NULLIF(btrim(ts.state), '') IS NOT NULL),
      ARRAY[]::text[]
    ) AS normalized_state_tokens
  FROM public.products p
  LEFT JOIN LATERAL regexp_split_to_table(COALESCE(p.tray_state::text, ''), '[,;|]+') AS ts(state)
    ON true
  GROUP BY p.nocopk
), resolved AS (
  SELECT
    p.*,
    COALESCE(i_scalar.nocopk, i_rel.nocopk) AS resolved_item_nocopk,
    COALESCE(i_scalar.item_id, i_rel.item_id) AS resolved_item_id,
    COALESCE(i_scalar.name, i_rel.name, p.name_mat) AS resolved_item_name,
    COALESCE(NULLIF(btrim(p.item_category_mat), ''), i_scalar.category, i_rel.category) AS resolved_item_category,
    COALESCE(s_scalar.nocopk, s_rel.nocopk) AS resolved_strain_nocopk,
    COALESCE(s_scalar.species_strain, s_rel.species_strain) AS resolved_strain_name,
    COALESCE(s_scalar.regulated, s_rel.regulated, false) AS resolved_strain_regulated,
    COALESCE(l_scalar.nocopk, l_rel.nocopk) AS resolved_location_nocopk,
    COALESCE(l_scalar.name, l_rel.name) AS resolved_location_name,
    COALESCE(st.normalized_state_tokens, ARRAY[]::text[]) AS normalized_state_tokens
  FROM public.products p
  LEFT JOIN public.items i_scalar
    ON i_scalar.nocopk = p.item_id
  LEFT JOIN public._m2m_products_items_item_id pi
    ON pi.products_id = p.nocopk
  LEFT JOIN public.items i_rel
    ON i_rel.nocopk = pi.items_id
  LEFT JOIN public.strains s_scalar
    ON s_scalar.nocopk = p.strain_id
  LEFT JOIN public._m2m_products_strains_strain_id ps
    ON ps.products_id = p.nocopk
  LEFT JOIN public.strains s_rel
    ON s_rel.nocopk = ps.strains_id
  LEFT JOIN public.locations l_scalar
    ON l_scalar.nocopk = p.storage_location_id
  LEFT JOIN public._m2m_products_locations_storage_location pl
    ON pl.products_id = p.nocopk
  LEFT JOIN public.locations l_rel
    ON l_rel.nocopk = pl.locations_id
  LEFT JOIN state_tokens st
    ON st.product_nocopk = p.nocopk
), classified AS (
  SELECT
    r.*,
    regexp_replace(lower(COALESCE(r.resolved_location_name, '')), '[^a-z0-9]', '', 'g') AS normalized_location_token,
    ARRAY(
      SELECT token
      FROM unnest(r.normalized_state_tokens) AS token
      WHERE token IN ('emptytray', 'compost', 'composted', 'spoiled', 'retired', 'expired', 'consumed', 'shipped')
      ORDER BY token
    )::text[] AS terminal_state_tokens
  FROM resolved r
)
SELECT
  c.nocopk AS product_nocopk,
  c.product_id,
  c.resolved_item_nocopk AS item_nocopk,
  c.resolved_item_id AS item_id,
  c.resolved_item_name AS item_name,
  c.resolved_item_category AS item_category,
  c.resolved_strain_nocopk AS strain_nocopk,
  c.resolved_strain_name AS strain_name,
  c.resolved_strain_regulated AS strain_regulated,
  c.resolved_location_nocopk AS storage_location_nocopk,
  c.resolved_location_name AS storage_location,
  c.package_class,
  c.package_size,
  c.package_count,
  c.net_weight_g,
  c.net_weight_oz,
  c.net_volume_ml,
  c.pack_date,
  c.use_by,
  c.harvested_at,
  c.harvest_flush_no,
  c.harvest_weight_g,
  c.tray_state,
  c.normalized_state_tokens,
  c.terminal_state_tokens,
  c.origin_lot_ids_json,
  c.notes,
  c.nc_created_at AS record_created_at,
  CASE WHEN c.airtable_id IS NOT NULL THEN 'airtable_migrated' ELSE 'postgres_native' END AS data_origin,
  NOT (
    cardinality(c.terminal_state_tokens) > 0
    OR c.normalized_location_token IN ('compost', 'consumed', 'expired', 'retired', 'shipped')
  ) AS active_inventory,
  CASE
    WHEN cardinality(c.terminal_state_tokens) > 0
      THEN 'tray_state:' || array_to_string(c.terminal_state_tokens, ',')
    WHEN c.normalized_location_token IN ('compost', 'consumed', 'expired', 'retired', 'shipped')
      THEN 'location:' || COALESCE(c.resolved_location_name, c.normalized_location_token)
    ELSE NULL
  END AS inactive_reason,
  (c.resolved_location_nocopk IS NULL) AS location_unknown,
  (c.pack_date IS NOT NULL AND c.use_by IS NOT NULL AND c.use_by < c.pack_date) AS use_by_before_pack,
  ARRAY_REMOVE(ARRAY[
    CASE WHEN c.resolved_location_nocopk IS NULL THEN 'unknown_storage_location' END,
    CASE WHEN c.pack_date IS NULL THEN 'missing_pack_date' END,
    CASE WHEN c.use_by IS NULL THEN 'missing_use_by' END,
    CASE WHEN c.pack_date IS NOT NULL AND c.use_by IS NOT NULL AND c.use_by < c.pack_date THEN 'use_by_before_pack_date' END,
    CASE WHEN c.resolved_item_nocopk IS NULL THEN 'unknown_item' END
  ], NULL)::text[] AS quality_flags
FROM classified c;

COMMENT ON VIEW public.v_reporting_product_inventory IS
  'Issue #87 Phase 7 canonical one-row-per-product inventory fact view. Centralizes the Products-page active/terminal state and location rule while preserving raw expiration dates and quality conditions.';

/*
 * Apply current/as-of inventory semantics and optional exact filters.  This is
 * the source for the Inventory Snapshot product KPIs, rollups, and detail table.
 */
CREATE OR REPLACE FUNCTION public.mp_reporting_product_inventory(
  p_as_of date DEFAULT CURRENT_DATE,
  p_expiring_days integer DEFAULT 30,
  p_scope text DEFAULT 'active',
  p_item_category text DEFAULT NULL,
  p_item_name text DEFAULT NULL,
  p_strain text DEFAULT NULL,
  p_location text DEFAULT NULL,
  p_expiration_status text DEFAULT NULL
)
RETURNS TABLE (
  product_nocopk bigint,
  product_id text,
  item_nocopk bigint,
  item_id text,
  item_name text,
  item_category text,
  strain_nocopk bigint,
  strain_name text,
  strain_regulated boolean,
  storage_location_nocopk bigint,
  storage_location text,
  package_class text,
  package_size text,
  package_count numeric,
  net_weight_g numeric,
  net_weight_oz numeric,
  net_volume_ml numeric,
  pack_date date,
  use_by date,
  harvested_at timestamp without time zone,
  harvest_flush_no numeric,
  harvest_weight_g numeric,
  tray_state text,
  data_origin text,
  active_inventory boolean,
  inactive_reason text,
  location_unknown boolean,
  use_by_before_pack boolean,
  quality_flags text[],
  stock_age_days integer,
  days_until_expiry integer,
  expiration_status text
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_as_of date := COALESCE(p_as_of, CURRENT_DATE);
  v_expiring_days integer := COALESCE(p_expiring_days, 30);
  v_scope text := lower(COALESCE(NULLIF(btrim(p_scope), ''), 'active'));
  v_item_category text := NULLIF(btrim(p_item_category), '');
  v_item_name text := NULLIF(btrim(p_item_name), '');
  v_strain text := NULLIF(btrim(p_strain), '');
  v_location text := NULLIF(btrim(p_location), '');
  v_expiration text := lower(COALESCE(NULLIF(btrim(p_expiration_status), ''), 'all'));
BEGIN
  IF v_expiring_days < 0 THEN
    RAISE EXCEPTION 'Reporting inventory expiring-day horizon must be nonnegative: %', v_expiring_days
      USING ERRCODE = '22023';
  END IF;

  IF v_scope NOT IN ('active', 'terminal', 'all') THEN
    RAISE EXCEPTION 'Unsupported Reporting inventory scope: %', p_scope
      USING ERRCODE = '22023';
  END IF;

  IF v_expiration NOT IN ('all', 'expired', 'expiring', 'current', 'unknown') THEN
    RAISE EXCEPTION 'Unsupported Reporting expiration status: %', p_expiration_status
      USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  SELECT
    v.product_nocopk,
    v.product_id,
    v.item_nocopk,
    v.item_id,
    v.item_name,
    v.item_category,
    v.strain_nocopk,
    v.strain_name,
    v.strain_regulated,
    v.storage_location_nocopk,
    v.storage_location,
    v.package_class,
    v.package_size,
    v.package_count,
    v.net_weight_g,
    v.net_weight_oz,
    v.net_volume_ml,
    v.pack_date,
    v.use_by,
    v.harvested_at,
    v.harvest_flush_no,
    v.harvest_weight_g,
    v.tray_state,
    v.data_origin,
    v.active_inventory,
    v.inactive_reason,
    v.location_unknown,
    v.use_by_before_pack,
    v.quality_flags,
    CASE WHEN v.pack_date IS NOT NULL THEN (v_as_of - v.pack_date)::integer ELSE NULL END AS stock_age_days,
    CASE WHEN v.use_by IS NOT NULL THEN (v.use_by - v_as_of)::integer ELSE NULL END AS days_until_expiry,
    public.mp_reporting_inventory_expiration_status(v.use_by, v_as_of, v_expiring_days) AS expiration_status
  FROM public.v_reporting_product_inventory v
  WHERE
    (v_scope = 'all'
      OR (v_scope = 'active' AND v.active_inventory)
      OR (v_scope = 'terminal' AND NOT v.active_inventory))
    AND (v_item_category IS NULL OR lower(btrim(COALESCE(v.item_category, ''))) = lower(v_item_category))
    AND (v_item_name IS NULL OR lower(btrim(COALESCE(v.item_name, ''))) = lower(v_item_name))
    AND (v_strain IS NULL OR lower(btrim(COALESCE(v.strain_name, ''))) = lower(v_strain))
    AND (
      v_location IS NULL
      OR (lower(v_location) = 'unknown' AND v.storage_location IS NULL)
      OR lower(btrim(COALESCE(v.storage_location, ''))) = lower(v_location)
    )
    AND (
      v_expiration = 'all'
      OR public.mp_reporting_inventory_expiration_status(v.use_by, v_as_of, v_expiring_days) = v_expiration
    );
END;
$$;

COMMENT ON FUNCTION public.mp_reporting_product_inventory(date, integer, text, text, text, text, text, text) IS
  'Issue #87 Phase 7 canonical product inventory filter. Applies explicit as-of expiration semantics, active/terminal scope, exact inventory dimensions, and an Unknown location bucket.';

/*
 * Current in-process lot inventory.  It reuses the Phase 2 lifecycle view so
 * terminal evidence remains consistent with Lifecycle Trace.  The stage group
 * mirrors the operational status families already exposed by the Lots page.
 */
CREATE OR REPLACE VIEW public.v_reporting_lot_inventory AS
SELECT
  l.lot_nocopk,
  l.lot_id,
  l.item_nocopk,
  l.item_id,
  l.item_name,
  l.item_category,
  l.strain_nocopk,
  l.species_strain AS strain_name,
  l.strain_regulated,
  l.location_nocopk,
  l.location_name,
  l.status,
  CASE
    WHEN lower(COALESCE(l.status, '')) IN ('planned', 'sterilized', 'pasteurized', 'sealed') THEN 'New / processed'
    WHEN lower(COALESCE(l.status, '')) IN ('inoculated', 'spawned', 'colonizing') THEN 'Colonizing'
    WHEN lower(COALESCE(l.status, '')) IN ('fullycolonized', 'fridge', 'coldshock') THEN 'Colonized / holding'
    WHEN lower(COALESCE(l.status, '')) = 'fruiting' THEN 'Fruiting'
    WHEN lower(COALESCE(l.status, '')) = 'frozen' THEN 'Frozen'
    WHEN l.terminal_at IS NOT NULL
      OR lower(COALESCE(l.status, '')) IN ('consumed', 'retired', 'compost', 'composted', 'expired', 'contaminated', 'inviable', 'destroyed')
      THEN 'Terminal'
    ELSE 'Other active'
  END AS inventory_stage,
  NOT (
    l.terminal_at IS NOT NULL
    OR lower(COALESCE(l.status, '')) IN ('consumed', 'retired', 'compost', 'composted', 'expired', 'contaminated', 'inviable', 'destroyed')
  ) AS active_inventory,
  l.lifecycle_start_at,
  l.lifecycle_start_source,
  CASE
    WHEN l.lifecycle_start_at IS NOT NULL
      THEN floor(extract(epoch FROM (CURRENT_TIMESTAMP::timestamp - l.lifecycle_start_at)) / 86400.0)::integer
    ELSE NULL
  END AS current_age_days,
  l.data_origin,
  l.quality_flags
FROM public.v_reporting_lot_lifecycle l;

COMMENT ON VIEW public.v_reporting_lot_inventory IS
  'Issue #87 Phase 7 current in-process lot inventory derived from the canonical lifecycle view, with active/terminal classification and operational stage grouping.';

COMMIT;
