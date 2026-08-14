SET search_path = public, pg_catalog;

BEGIN;

/*
 * Issue #12, Phase 1B: PostgreSQL-native Ecwid catalog synchronization.
 *
 * This extension replaces the Airtable-dependent inventory rollups consumed by
 * integrations/ecwid/sync_ecommerce_to_ecwid.js. PostgreSQL derives sellable
 * inventory directly from ecommerce/item/strain mappings and current Product /
 * Lot state. n8n then performs the Ecwid API calls and writes returned metadata
 * back through mp_ecommerce_ecwid_catalog_sync_writeback().
 */

CREATE TABLE IF NOT EXISTS public.ecommerce_upc_pool (
  ordinal integer PRIMARY KEY,
  upc text NOT NULL UNIQUE
);

INSERT INTO public.ecommerce_upc_pool(ordinal, upc)
VALUES
  (1, '6865787500013'),
  (2, '6865787500020'),
  (3, '6865787500037'),
  (4, '6865787500044'),
  (5, '6865787500051'),
  (6, '6865787500068'),
  (7, '6865787500075'),
  (8, '6865787500082'),
  (9, '6865787500099'),
  (10, '6865787500105'),
  (11, '6865787500112'),
  (12, '6865787500129'),
  (13, '6865787500136'),
  (14, '6865787500143'),
  (15, '6865787500150'),
  (16, '6865787500167'),
  (17, '6865787500174'),
  (18, '6865787500181'),
  (19, '6865787500198'),
  (20, '6865787500204'),
  (21, '6865787500211'),
  (22, '6865787500228'),
  (23, '6865787500235'),
  (24, '6865787500242'),
  (25, '6865787500259'),
  (26, '6865787500266'),
  (27, '6865787500273'),
  (28, '6865787500280'),
  (29, '6865787500297'),
  (30, '6865787500303'),
  (31, '6865787500310'),
  (32, '6865787500327'),
  (33, '6865787500334'),
  (34, '6865787500341'),
  (35, '6865787500358'),
  (36, '6865787500365'),
  (37, '6865787500372'),
  (38, '6865787500389'),
  (39, '6865787500396'),
  (40, '6865787500402'),
  (41, '6865787500419'),
  (42, '6865787500426'),
  (43, '6865787500433'),
  (44, '6865787500440'),
  (45, '6865787500457'),
  (46, '6865787500464'),
  (47, '6865787500471'),
  (48, '6865787500488'),
  (49, '6865787500495'),
  (50, '6865787500501'),
  (51, '6865787500518'),
  (52, '6865787500525'),
  (53, '6865787500532'),
  (54, '6865787500549'),
  (55, '6865787500556'),
  (56, '6865787500563'),
  (57, '6865787500570'),
  (58, '6865787500587'),
  (59, '6865787500594'),
  (60, '6865787500600'),
  (61, '6865787500617'),
  (62, '6865787500624'),
  (63, '6865787500631'),
  (64, '6865787500648'),
  (65, '6865787500655'),
  (66, '6865787500662'),
  (67, '6865787500679'),
  (68, '6865787500686'),
  (69, '6865787500693'),
  (70, '6865787500709'),
  (71, '6865787500716'),
  (72, '6865787500723'),
  (73, '6865787500730'),
  (74, '6865787500747'),
  (75, '6865787500754'),
  (76, '6865787500761'),
  (77, '6865787500778'),
  (78, '6865787500785'),
  (79, '6865787500792'),
  (80, '6865787500808'),
  (81, '6865787500815'),
  (82, '6865787500822'),
  (83, '6865787500839'),
  (84, '6865787500846'),
  (85, '6865787500853'),
  (86, '6865787500860'),
  (87, '6865787500877'),
  (88, '6865787500884'),
  (89, '6865787500891'),
  (90, '6865787500907'),
  (91, '6865787500914'),
  (92, '6865787500921'),
  (93, '6865787500938'),
  (94, '6865787500945'),
  (95, '6865787500952'),
  (96, '6865787500969'),
  (97, '6865787500976'),
  (98, '6865787500983'),
  (99, '6865787500990'),
  (100, '6865787501003'),
  (101, '6865787501010'),
  (102, '6865787501027'),
  (103, '6865787501034'),
  (104, '6865787501041'),
  (105, '6865787501058'),
  (106, '6865787501065'),
  (107, '6865787501072'),
  (108, '6865787501089'),
  (109, '6865787501096'),
  (110, '6865787501102'),
  (111, '6865787501119'),
  (112, '6865787501126'),
  (113, '6865787501133'),
  (114, '6865787501140'),
  (115, '6865787501157'),
  (116, '6865787501164'),
  (117, '6865787501171'),
  (118, '6865787501188'),
  (119, '6865787501195'),
  (120, '6865787501201'),
  (121, '6865787501218'),
  (122, '6865787501225'),
  (123, '6865787501232'),
  (124, '6865787501249'),
  (125, '6865787501256'),
  (126, '6865787501263'),
  (127, '6865787501270'),
  (128, '6865787501287'),
  (129, '6865787501294'),
  (130, '6865787501300'),
  (131, '6865787501317'),
  (132, '6865787501324'),
  (133, '6865787501331'),
  (134, '6865787501348'),
  (135, '6865787501355'),
  (136, '6865787501362'),
  (137, '6865787501379'),
  (138, '6865787501386'),
  (139, '6865787501393'),
  (140, '6865787501409'),
  (141, '6865787501416'),
  (142, '6865787501423'),
  (143, '6865787501430'),
  (144, '6865787501447'),
  (145, '6865787501454'),
  (146, '6865787501461'),
  (147, '6865787501478'),
  (148, '6865787501485'),
  (149, '6865787501492'),
  (150, '6865787501508'),
  (151, '6865787501515'),
  (152, '6865787501522'),
  (153, '6865787501539'),
  (154, '6865787501546'),
  (155, '6865787501553'),
  (156, '6865787501560'),
  (157, '6865787501577'),
  (158, '6865787501584'),
  (159, '6865787501591'),
  (160, '6865787501607'),
  (161, '6865787501614'),
  (162, '6865787501621'),
  (163, '6865787501638'),
  (164, '6865787501645'),
  (165, '6865787501652'),
  (166, '6865787501669'),
  (167, '6865787501676'),
  (168, '6865787501683'),
  (169, '6865787501690'),
  (170, '6865787501706'),
  (171, '6865787501713'),
  (172, '6865787501720'),
  (173, '6865787501737'),
  (174, '6865787501744'),
  (175, '6865787501751'),
  (176, '6865787501768'),
  (177, '6865787501775'),
  (178, '6865787501782'),
  (179, '6865787501799'),
  (180, '6865787501805'),
  (181, '6865787501812'),
  (182, '6865787501829'),
  (183, '6865787501836'),
  (184, '6865787501843'),
  (185, '6865787501850'),
  (186, '6865787501867'),
  (187, '6865787501874'),
  (188, '6865787501881')
ON CONFLICT (upc) DO UPDATE
SET ordinal = EXCLUDED.ordinal;

CREATE OR REPLACE FUNCTION public.mp_normalize_gtin_text(p_value text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v text := NULLIF(BTRIM(p_value), '');
BEGIN
  IF v IS NULL THEN
    RETURN NULL;
  END IF;

  /*
   * Some Airtable exports represented 13-digit UPC values as scientific
   * notation (for example 6.865787502055E12). PostgreSQL numeric preserves the
   * integer exactly, so normalize only exponent-form numeric strings.
   */
  IF v ~ '^[0-9]+([.][0-9]+)?[eE][+-]?[0-9]+$' THEN
    BEGIN
      RETURN round(v::numeric, 0)::text;
    EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
      RETURN v;
    END;
  END IF;

  RETURN v;
END;
$function$;

/* Repair scientific-notation UPC strings imported from Airtable. */
UPDATE public.ecommerce
SET
  ecwid_upc = public.mp_normalize_gtin_text(ecwid_upc),
  upc = public.mp_normalize_gtin_text(COALESCE(upc, ecwid_upc))
WHERE
  ecwid_upc IS DISTINCT FROM public.mp_normalize_gtin_text(ecwid_upc)
  OR upc IS DISTINCT FROM public.mp_normalize_gtin_text(COALESCE(upc, ecwid_upc));

CREATE OR REPLACE FUNCTION public.mp_ecommerce_reserve_upc(p_ecommerce_id bigint)
RETURNS text
LANGUAGE plpgsql
AS $function$
DECLARE
  v_existing text;
  v_upc text;
BEGIN
  IF p_ecommerce_id IS NULL THEN
    RAISE EXCEPTION 'ecommerce id is required';
  END IF;

  /*
   * Serialize allocations so two simultaneous workflow executions cannot
   * reserve the same pool value.
   */
  PERFORM pg_advisory_xact_lock(hashtext('mp_ecommerce_reserve_upc'));

  SELECT public.mp_normalize_gtin_text(COALESCE(NULLIF(upc, ''), NULLIF(ecwid_upc, '')))
  INTO v_existing
  FROM public.ecommerce
  WHERE nocopk = p_ecommerce_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ecommerce row not found: %', p_ecommerce_id;
  END IF;

  IF v_existing IS NOT NULL THEN
    UPDATE public.ecommerce
    SET
      ecwid_upc = v_existing,
      upc = v_existing
    WHERE nocopk = p_ecommerce_id;

    RETURN v_existing;
  END IF;

  SELECT pool.upc
  INTO v_upc
  FROM public.ecommerce_upc_pool pool
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.ecommerce e
    WHERE public.mp_normalize_gtin_text(
      COALESCE(NULLIF(e.upc, ''), NULLIF(e.ecwid_upc, ''))
    ) = pool.upc
  )
  ORDER BY pool.ordinal
  LIMIT 1;

  IF v_upc IS NULL THEN
    RAISE EXCEPTION 'No unused UPC codes remain in ecommerce_upc_pool';
  END IF;

  UPDATE public.ecommerce
  SET
    ecwid_upc = v_upc,
    upc = v_upc
  WHERE nocopk = p_ecommerce_id;

  RETURN v_upc;
END;
$function$;

CREATE OR REPLACE FUNCTION public.mp_ecommerce_ecwid_catalog_sync_candidates()
RETURNS TABLE (
  ecommerce_id bigint,
  ecommerce_name text,
  ecommerce_status text,
  item_id bigint,
  strain_id bigint,
  provider text,
  site_key text,
  external_sku text,
  upc text,
  external_product_id text,
  external_variation_id text,
  available_from_products bigint,
  available_from_lots bigint,
  desired_quantity bigint
)
LANGUAGE sql
STABLE
AS $function$
  SELECT
    e.nocopk AS ecommerce_id,
    e.name AS ecommerce_name,
    e.status AS ecommerce_status,
    e.item_id,
    e.strain_id,
    COALESCE(NULLIF(BTRIM(e.provider), ''), 'ecwid') AS provider,
    COALESCE(NULLIF(BTRIM(e.site_key), ''), 'dank_mushrooms') AS site_key,
    COALESCE(NULLIF(BTRIM(e.external_sku), ''), NULLIF(BTRIM(e.ecwid_sku), '')) AS external_sku,
    public.mp_normalize_gtin_text(COALESCE(NULLIF(e.upc, ''), NULLIF(e.ecwid_upc, ''))) AS upc,
    e.external_product_id,
    e.external_variation_id,
    COALESCE(product_inventory.available_count, 0)::bigint AS available_from_products,
    COALESCE(lot_inventory.available_count, 0)::bigint AS available_from_lots,
    (
      COALESCE(product_inventory.available_count, 0)
      + COALESCE(lot_inventory.available_count, 0)
    )::bigint AS desired_quantity
  FROM public.ecommerce e
  LEFT JOIN LATERAL (
    SELECT COUNT(*)::bigint AS available_count
    FROM public.products p
    LEFT JOIN public.locations loc
      ON loc.nocopk = p.storage_location_id
    WHERE p.item_id = e.item_id
      AND p.strain_id IS NOT DISTINCT FROM e.strain_id
      AND (p.use_by IS NULL OR p.use_by >= CURRENT_DATE)
      AND regexp_replace(
            lower(COALESCE(loc.name, '')),
            '[^a-z0-9]',
            '',
            'g'
          ) NOT IN (
            'shipped',
            'expired',
            'consumed',
            'compost',
            'composted',
            'retired',
            'missing',
            'missingorlost'
          )
  ) product_inventory ON true
  LEFT JOIN LATERAL (
    SELECT COUNT(*)::bigint AS available_count
    FROM public.lots l
    WHERE l.item_id = e.item_id
      AND l.strain_id IS NOT DISTINCT FROM e.strain_id
      AND (l.use_by IS NULL OR l.use_by >= CURRENT_DATE)
      AND (
        CASE regexp_replace(lower(COALESCE(e.status, '')), '[^a-z0-9]', '', 'g')
          WHEN 'sterilized' THEN
            regexp_replace(lower(COALESCE(l.status, '')), '[^a-z0-9]', '', 'g')
              IN ('sterilized', 'sealed')
          WHEN 'pasteurized' THEN
            regexp_replace(lower(COALESCE(l.status, '')), '[^a-z0-9]', '', 'g')
              IN ('pasteurized')
          WHEN 'fullycolonized' THEN
            regexp_replace(lower(COALESCE(l.status, '')), '[^a-z0-9]', '', 'g')
              IN ('fullycolonized', 'fridge', 'coldshock')
          WHEN 'inoculated' THEN
            regexp_replace(lower(COALESCE(l.status, '')), '[^a-z0-9]', '', 'g')
              IN ('inoculated', 'colonizing')
          ELSE false
        END
      )
  ) lot_inventory ON true
  WHERE lower(COALESCE(NULLIF(BTRIM(e.provider), ''), 'ecwid')) = 'ecwid'
    AND COALESCE(e.sync_enabled, e.sync_to_ecwid, false)
    AND e.item_id IS NOT NULL
    AND COALESCE(NULLIF(BTRIM(e.external_sku), ''), NULLIF(BTRIM(e.ecwid_sku), '')) IS NOT NULL
  ORDER BY e.nocopk;
$function$;

CREATE OR REPLACE FUNCTION public.mp_ecommerce_ecwid_catalog_sync_writeback(p_payload jsonb)
RETURNS TABLE (
  action text,
  ecommerce_id bigint,
  external_sku text,
  external_product_id text,
  external_variation_id text,
  public_url text,
  external_stock numeric,
  upc text
)
LANGUAGE plpgsql
AS $function$
DECLARE
  v_id bigint;
  v_provider text;
  v_sku text;
  v_category text;
  v_price numeric;
  v_stock numeric;
  v_url text;
  v_upc text;
  v_product_id text;
  v_variation_id text;
  v_site_key text;
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'Ecwid catalog writeback payload must be a JSON object';
  END IF;

  v_id := NULLIF(BTRIM(p_payload ->> 'ecommerce_id'), '')::bigint;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'Ecwid catalog writeback requires ecommerce_id';
  END IF;

  SELECT lower(COALESCE(NULLIF(BTRIM(e.provider), ''), 'ecwid'))
  INTO v_provider
  FROM public.ecommerce e
  WHERE e.nocopk = v_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ecommerce row not found: %', v_id;
  END IF;

  IF v_provider <> 'ecwid' THEN
    RAISE EXCEPTION
      'Refusing Ecwid catalog writeback for ecommerce row % because provider is %',
      v_id,
      v_provider;
  END IF;

  v_sku := NULLIF(BTRIM(p_payload ->> 'external_sku'), '');
  v_category := NULLIF(BTRIM(p_payload ->> 'external_category'), '');
  v_price := NULLIF(BTRIM(p_payload ->> 'external_price'), '')::numeric;
  v_stock := NULLIF(BTRIM(p_payload ->> 'external_stock'), '')::numeric;
  v_url := NULLIF(BTRIM(p_payload ->> 'public_url'), '');
  v_upc := public.mp_normalize_gtin_text(p_payload ->> 'upc');
  v_product_id := NULLIF(BTRIM(p_payload ->> 'external_product_id'), '');
  v_variation_id := NULLIF(BTRIM(p_payload ->> 'external_variation_id'), '');
  v_site_key := COALESCE(NULLIF(BTRIM(p_payload ->> 'site_key'), ''), 'dank_mushrooms');

  UPDATE public.ecommerce e
  SET
    provider = 'ecwid',
    site_key = v_site_key,
    ecwid_sku = COALESCE(v_sku, e.ecwid_sku),
    external_sku = COALESCE(v_sku, e.external_sku, e.ecwid_sku),
    ecwid_category = v_category,
    external_category = v_category,
    ecwid_price = v_price,
    external_price = v_price,
    ecwid_stock = v_stock,
    external_stock = v_stock,
    ecwid_url = v_url,
    public_url = v_url,
    ecwid_upc = COALESCE(v_upc, e.ecwid_upc),
    upc = COALESCE(v_upc, e.upc, e.ecwid_upc),
    external_product_id = COALESCE(v_product_id, e.external_product_id),
    external_variation_id = v_variation_id,
    is_primary_public_listing = true
  WHERE e.nocopk = v_id;

  RETURN QUERY
  SELECT
    'updated'::text,
    e.nocopk,
    e.external_sku,
    e.external_product_id,
    e.external_variation_id,
    e.public_url,
    e.external_stock,
    e.upc
  FROM public.ecommerce e
  WHERE e.nocopk = v_id;
END;
$function$;

COMMIT;
