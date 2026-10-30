\set ON_ERROR_STOP on

-- Issue #57 follow-up: expired packaged cultivation materials may be returned
-- to cultivation only when the UI explicitly exposes them.  Expiration is a
-- warning/selection policy, not a destructive terminal state.  Shipped,
-- consumed, retired, composted, missing, order-linked, already-returned, and
-- otherwise structurally invalid Products remain ineligible.

BEGIN;

CREATE OR REPLACE FUNCTION public.mp_product_cultivation_eligibility(
  p_product_id bigint,
  p_as_of date DEFAULT CURRENT_DATE
)
RETURNS TABLE (
  product_nocopk bigint,
  product_id text,
  item_category text,
  eligible_for_return boolean,
  can_inoculate_target boolean,
  can_inoculate_source boolean,
  can_spawn_substrate boolean,
  ineligibility_reason text
)
LANGUAGE sql
STABLE
AS $$
WITH product_row AS (
  SELECT
    p.nocopk,
    p.product_id,
    regexp_replace(
      lower(COALESCE(NULLIF(btrim(p.item_category_mat), ''), NULLIF(btrim(i.category), ''), '')),
      '[^a-z0-9]', '', 'g'
    ) AS category_norm,
    p.use_by,
    p.tray_state,
    p.strain_id AS product_strain_id,
    p.net_volume_ml,
    loc.name AS storage_location,
    EXISTS (
      SELECT 1
      FROM public.lots returned
      WHERE returned.source_product_id = p.nocopk
    ) AS already_returned,
    EXISTS (
      SELECT 1
      FROM public._m2m_products_ecommerce_orders_ecommerce_orders x
      WHERE x.products_id = p.nocopk
    ) OR EXISTS (
      SELECT 1
      FROM public._m2m_ecommerce_orders_products_products x
      WHERE x.products_id = p.nocopk
    ) AS linked_order,
    origin.origin_count,
    origin.origin_strain_id,
    origin.origin_inoculated_at
  FROM public.products p
  LEFT JOIN public.items i ON i.nocopk = p.item_id
  LEFT JOIN public.locations loc ON loc.nocopk = p.storage_location_id
  LEFT JOIN LATERAL (
    SELECT
      count(*)::bigint AS origin_count,
      max(l.strain_id) AS origin_strain_id,
      max(l.inoculated_at) AS origin_inoculated_at
    FROM public._m2m_products_lots_origin_lots x
    JOIN public.lots l ON l.nocopk = x.lots_id
    WHERE x.products_id = p.nocopk
  ) origin ON true
  WHERE p.nocopk = p_product_id
), classified AS (
  SELECT
    pr.*,
    regexp_replace(lower(COALESCE(pr.storage_location, '')), '[^a-z0-9]', '', 'g') AS location_norm,
    regexp_replace(lower(COALESCE(pr.tray_state, '')), '[^a-z0-9]', '', 'g') AS state_norm,
    pr.category_norm IN ('grain', 'substrate', 'lcsyringe') AS category_supported
  FROM product_row pr
), reasoned AS (
  SELECT
    c.*,
    CASE
      WHEN NOT c.category_supported THEN 'Product category is not eligible for cultivation return.'
      WHEN c.already_returned THEN 'Product has already been returned to Lot inventory.'
      WHEN c.linked_order THEN 'Product is linked to an ecommerce order.'
      WHEN COALESCE(c.origin_count, 0) <> 1 THEN 'Product must have exactly one explicit origin Lot.'
      -- "Expired" is intentionally not terminal here.  The caller/UI controls
      -- whether expired-but-otherwise-valid rows are visible for reuse.
      WHEN c.location_norm IN ('shipped','consumed','retired','compost','composted','missing','missingorlost')
        THEN 'Product is in a terminal or unavailable storage location.'
      WHEN c.state_norm IN ('emptytray','compost','composted','spoiled','retired','consumed','shipped','deproductized')
        THEN 'Product is in a terminal lifecycle state.'
      WHEN c.category_norm IN ('grain', 'substrate')
        AND (c.product_strain_id IS NOT NULL OR c.origin_strain_id IS NOT NULL OR c.origin_inoculated_at IS NOT NULL)
        THEN 'Packaged grain/substrate is already inoculated and cannot be reused as sterile production input.'
      WHEN c.category_norm = 'lcsyringe'
        AND COALESCE(c.product_strain_id, c.origin_strain_id) IS NULL
        THEN 'LC syringe Product has no strain lineage and cannot be used as an inoculation source.'
      WHEN c.category_norm = 'lcsyringe' AND COALESCE(c.net_volume_ml, 0) <= 0
        THEN 'LC syringe Product has no usable volume.'
      ELSE NULL
    END AS reason
  FROM classified c
)
SELECT
  r.nocopk,
  r.product_id,
  r.category_norm,
  r.reason IS NULL AS eligible_for_return,
  r.reason IS NULL AND r.category_norm = 'grain' AS can_inoculate_target,
  r.reason IS NULL AND r.category_norm = 'lcsyringe' AS can_inoculate_source,
  r.reason IS NULL AND r.category_norm = 'substrate' AS can_spawn_substrate,
  r.reason
FROM reasoned r;
$$;

COMMENT ON FUNCTION public.mp_product_cultivation_eligibility(bigint, date) IS
  'Issue #57 canonical structural Product eligibility contract. Expiration alone does not make a cultivation Product ineligible; UI visibility controls expired reuse.';

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
  CROSS JOIN LATERAL public.mp_product_cultivation_eligibility(
    p.nocopk,
    public.mp_cultivation_operating_date()
  ) e
), shaped AS (
  SELECT
    pr.*,
    LEAST(pr.product_use_by, pr.origin_use_by) AS preserved_use_by
  FROM product_rows pr
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
  CASE
    WHEN pr.preserved_use_by IS NOT NULL
      AND pr.preserved_use_by < public.mp_cultivation_operating_date()
      THEN 'Packaged Product · Expired'
    ELSE 'Packaged Product'
  END::text AS status,
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
  pr.preserved_use_by AS use_by,
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
  pr.ineligibility_reason,
  (pr.preserved_use_by IS NOT NULL
    AND pr.preserved_use_by < public.mp_cultivation_operating_date()) AS is_expired
FROM shaped pr
LEFT JOIN public.strains s2 ON s2.nocopk = pr.strain_id
WHERE pr.eligible_for_return;

COMMENT ON VIEW public.v_product_cultivation_candidates IS
  'Issue #57 UI contract: structurally eligible packaged grain, substrate, and LC syringe Products, including expired rows. is_expired lets Appsmith require explicit Show Expired Products opt-in.';

COMMIT;
