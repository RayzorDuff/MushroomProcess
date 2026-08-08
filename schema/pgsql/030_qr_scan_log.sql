SET search_path = public, pg_catalog;

BEGIN;

/*
 * QR scan analytics foundation.
 *
 * The resolver records one row for every public QR request (successful or
 * failed). Entity/item/strain/location fields are denormalized snapshots so
 * later reporting remains meaningful even after inventory moves or catalog
 * mappings change.
 */

CREATE TABLE IF NOT EXISTS public.qr_scan_log (
  nocopk bigserial PRIMARY KEY,
  request_id uuid NOT NULL DEFAULT gen_random_uuid(),
  requested_at timestamptz NOT NULL DEFAULT now(),

  inventory_id text,
  entity_type text,
  entity_nocopk bigint,
  resolution_status text NOT NULL,
  route_kind text,
  response_code integer,
  destination_url text,
  success boolean NOT NULL DEFAULT false,

  ecommerce_id bigint,
  provider text,
  site_key text,

  company_key text,
  company_name text,
  item_nocopk bigint,
  item_id text,
  item_name text,
  item_category text,
  strain_nocopk bigint,
  strain_id text,
  strain_name text,
  regulated boolean,
  package_class text,
  location_nocopk bigint,
  location_name text,
  entity_status text,

  client_ip inet,
  forwarded_for text,
  cf_country text,
  cf_continent text,
  cf_city text,
  cf_region text,
  cf_region_code text,
  cf_postal_code text,
  cf_timezone text,
  cf_latitude numeric,
  cf_longitude numeric,
  cf_metro_code text,
  cf_ray text,

  user_agent text,
  browser_name text,
  browser_version text,
  os_name text,
  os_version text,
  device_type text,
  referer text,
  accept_language text,
  request_host text,
  request_method text,
  request_path text,
  query_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  source text NOT NULL DEFAULT 'qr',
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,

  nc_created_at timestamp without time zone NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_qr_scan_log_request_id
  ON public.qr_scan_log(request_id);
CREATE INDEX IF NOT EXISTS ix_qr_scan_log_requested_at
  ON public.qr_scan_log(requested_at DESC);
CREATE INDEX IF NOT EXISTS ix_qr_scan_log_inventory_id
  ON public.qr_scan_log(inventory_id, requested_at DESC);
CREATE INDEX IF NOT EXISTS ix_qr_scan_log_entity_type
  ON public.qr_scan_log(entity_type, requested_at DESC);
CREATE INDEX IF NOT EXISTS ix_qr_scan_log_company_name
  ON public.qr_scan_log(company_name, requested_at DESC);
CREATE INDEX IF NOT EXISTS ix_qr_scan_log_resolution_status
  ON public.qr_scan_log(resolution_status, requested_at DESC);
CREATE INDEX IF NOT EXISTS ix_qr_scan_log_route_kind
  ON public.qr_scan_log(route_kind, requested_at DESC);

CREATE OR REPLACE FUNCTION public.mp_qr_log_scan(p_payload jsonb)
RETURNS bigint
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
  v_id bigint;
  v_entity_type text := lower(NULLIF(BTRIM(p_payload ->> 'entity_type'), ''));
  v_entity_nocopk bigint;
  v_client_ip inet;
  v_response_code integer;
  v_latitude numeric;
  v_longitude numeric;
  v_item_nocopk bigint;
  v_item_id text;
  v_item_name text;
  v_item_category text;
  v_strain_nocopk bigint;
  v_strain_id text;
  v_strain_name text;
  v_regulated boolean;
  v_package_class text;
  v_location_nocopk bigint;
  v_location_name text;
  v_entity_status text;
  v_success boolean := false;
  v_payload_regulated boolean;
BEGIN
  IF p_payload IS NULL THEN
    RAISE EXCEPTION 'QR scan payload is required';
  END IF;


  IF lower(COALESCE(NULLIF(BTRIM(p_payload ->> 'success'), ''), 'false')) IN ('true', 't', '1', 'yes', 'on') THEN
    v_success := true;
  END IF;

  IF p_payload ? 'regulated' THEN
    IF lower(COALESCE(NULLIF(BTRIM(p_payload ->> 'regulated'), ''), 'false')) IN ('true', 't', '1', 'yes', 'on') THEN
      v_payload_regulated := true;
    ELSIF lower(COALESCE(NULLIF(BTRIM(p_payload ->> 'regulated'), ''), 'false')) IN ('false', 'f', '0', 'no', 'off') THEN
      v_payload_regulated := false;
    END IF;
  END IF;

  BEGIN
    v_entity_nocopk := NULLIF(BTRIM(p_payload ->> 'entity_nocopk'), '')::bigint;
  EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    v_entity_nocopk := NULL;
  END;

  BEGIN
    v_client_ip := NULLIF(BTRIM(p_payload ->> 'client_ip'), '')::inet;
  EXCEPTION WHEN invalid_text_representation THEN
    v_client_ip := NULL;
  END;

  BEGIN
    v_response_code := NULLIF(BTRIM(p_payload ->> 'response_code'), '')::integer;
  EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    v_response_code := NULL;
  END;

  BEGIN
    v_latitude := NULLIF(BTRIM(p_payload ->> 'cf_latitude'), '')::numeric;
  EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    v_latitude := NULL;
  END;

  BEGIN
    v_longitude := NULLIF(BTRIM(p_payload ->> 'cf_longitude'), '')::numeric;
  EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    v_longitude := NULL;
  END;

  /* Snapshot inventory metadata at scan time instead of depending on future state. */
  IF v_entity_type = 'product' AND v_entity_nocopk IS NOT NULL THEN
    SELECT
      p.item_id,
      i.item_id,
      COALESCE(i.name, p.name_mat),
      COALESCE(NULLIF(p.item_category_mat, ''), i.category),
      p.strain_id,
      s.strain_id,
      s.species_strain,
      COALESCE(s.regulated, false),
      p.package_class,
      p.storage_location_id,
      loc.name,
      NULLIF(BTRIM(p.tray_state), '')
    INTO
      v_item_nocopk,
      v_item_id,
      v_item_name,
      v_item_category,
      v_strain_nocopk,
      v_strain_id,
      v_strain_name,
      v_regulated,
      v_package_class,
      v_location_nocopk,
      v_location_name,
      v_entity_status
    FROM public.products p
    LEFT JOIN public.items i ON i.nocopk = p.item_id
    LEFT JOIN public.strains s ON s.nocopk = p.strain_id
    LEFT JOIN public.locations loc ON loc.nocopk = p.storage_location_id
    WHERE p.nocopk = v_entity_nocopk;
  ELSIF v_entity_type = 'lot' AND v_entity_nocopk IS NOT NULL THEN
    SELECT
      l.item_id,
      i.item_id,
      COALESCE(i.name, l.item_name_mat),
      COALESCE(NULLIF(l.item_category_mat, ''), i.category),
      l.strain_id,
      s.strain_id,
      s.species_strain,
      COALESCE(s.regulated, false),
      NULL::text,
      l.location_id,
      loc.name,
      NULLIF(BTRIM(l.status), '')
    INTO
      v_item_nocopk,
      v_item_id,
      v_item_name,
      v_item_category,
      v_strain_nocopk,
      v_strain_id,
      v_strain_name,
      v_regulated,
      v_package_class,
      v_location_nocopk,
      v_location_name,
      v_entity_status
    FROM public.lots l
    LEFT JOIN public.items i ON i.nocopk = l.item_id
    LEFT JOIN public.strains s ON s.nocopk = l.strain_id
    LEFT JOIN public.locations loc ON loc.nocopk = l.location_id
    WHERE l.nocopk = v_entity_nocopk;
  END IF;

  INSERT INTO public.qr_scan_log (
    inventory_id,
    entity_type,
    entity_nocopk,
    resolution_status,
    route_kind,
    response_code,
    destination_url,
    success,
    ecommerce_id,
    provider,
    site_key,
    company_key,
    company_name,
    item_nocopk,
    item_id,
    item_name,
    item_category,
    strain_nocopk,
    strain_id,
    strain_name,
    regulated,
    package_class,
    location_nocopk,
    location_name,
    entity_status,
    client_ip,
    forwarded_for,
    cf_country,
    cf_continent,
    cf_city,
    cf_region,
    cf_region_code,
    cf_postal_code,
    cf_timezone,
    cf_latitude,
    cf_longitude,
    cf_metro_code,
    cf_ray,
    user_agent,
    browser_name,
    browser_version,
    os_name,
    os_version,
    device_type,
    referer,
    accept_language,
    request_host,
    request_method,
    request_path,
    query_json,
    source,
    metadata
  ) VALUES (
    NULLIF(BTRIM(p_payload ->> 'inventory_id'), ''),
    v_entity_type,
    v_entity_nocopk,
    COALESCE(NULLIF(BTRIM(p_payload ->> 'status'), ''), 'unknown'),
    NULLIF(BTRIM(p_payload ->> 'route_kind'), ''),
    v_response_code,
    NULLIF(BTRIM(p_payload ->> 'destination_url'), ''),
    v_success,
    CASE WHEN COALESCE(p_payload ->> 'ecommerce_id', '') ~ '^[0-9]+$' THEN (p_payload ->> 'ecommerce_id')::bigint END,
    NULLIF(BTRIM(p_payload ->> 'provider'), ''),
    NULLIF(BTRIM(p_payload ->> 'site_key'), ''),
    NULLIF(BTRIM(p_payload ->> 'company_key'), ''),
    NULLIF(BTRIM(p_payload ->> 'company_name'), ''),
    v_item_nocopk,
    v_item_id,
    v_item_name,
    COALESCE(v_item_category, NULLIF(BTRIM(p_payload ->> 'item_category'), '')),
    v_strain_nocopk,
    v_strain_id,
    v_strain_name,
    COALESCE(v_regulated, v_payload_regulated),
    COALESCE(v_package_class, NULLIF(BTRIM(p_payload ->> 'package_class'), '')),
    v_location_nocopk,
    v_location_name,
    v_entity_status,
    v_client_ip,
    NULLIF(BTRIM(p_payload ->> 'forwarded_for'), ''),
    NULLIF(BTRIM(p_payload ->> 'cf_country'), ''),
    NULLIF(BTRIM(p_payload ->> 'cf_continent'), ''),
    NULLIF(BTRIM(p_payload ->> 'cf_city'), ''),
    NULLIF(BTRIM(p_payload ->> 'cf_region'), ''),
    NULLIF(BTRIM(p_payload ->> 'cf_region_code'), ''),
    NULLIF(BTRIM(p_payload ->> 'cf_postal_code'), ''),
    NULLIF(BTRIM(p_payload ->> 'cf_timezone'), ''),
    v_latitude,
    v_longitude,
    NULLIF(BTRIM(p_payload ->> 'cf_metro_code'), ''),
    NULLIF(BTRIM(p_payload ->> 'cf_ray'), ''),
    NULLIF(BTRIM(p_payload ->> 'user_agent'), ''),
    NULLIF(BTRIM(p_payload ->> 'browser_name'), ''),
    NULLIF(BTRIM(p_payload ->> 'browser_version'), ''),
    NULLIF(BTRIM(p_payload ->> 'os_name'), ''),
    NULLIF(BTRIM(p_payload ->> 'os_version'), ''),
    NULLIF(BTRIM(p_payload ->> 'device_type'), ''),
    NULLIF(BTRIM(p_payload ->> 'referer'), ''),
    NULLIF(BTRIM(p_payload ->> 'accept_language'), ''),
    NULLIF(BTRIM(p_payload ->> 'request_host'), ''),
    NULLIF(BTRIM(p_payload ->> 'request_method'), ''),
    NULLIF(BTRIM(p_payload ->> 'request_path'), ''),
    COALESCE(p_payload -> 'query_json', '{}'::jsonb),
    COALESCE(NULLIF(BTRIM(p_payload ->> 'source'), ''), 'qr'),
    COALESCE(p_payload -> 'metadata', '{}'::jsonb)
  )
  RETURNING nocopk INTO v_id;

  RETURN v_id;
END;
$function$;

COMMENT ON TABLE public.qr_scan_log IS
'QR resolver request log. Stores request/device/geolocation metadata and denormalized inventory/company snapshots for later reporting.';
COMMENT ON FUNCTION public.mp_qr_log_scan(jsonb) IS
'Writes one QR scan/request record and snapshots current Product/Lot item, strain, location, status, and regulation metadata.';

COMMIT;
