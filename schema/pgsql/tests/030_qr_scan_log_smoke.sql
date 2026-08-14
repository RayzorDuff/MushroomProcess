BEGIN;
SET LOCAL client_min_messages TO NOTICE;
SET LOCAL search_path = public, pg_catalog;

DO $test$
DECLARE
  v_item bigint;
  v_strain bigint;
  v_location bigint;
  v_product bigint;
  v_log_id bigint;
  v_row public.qr_scan_log%ROWTYPE;
BEGIN
  INSERT INTO public.items(item_id, active, name, category)
  VALUES ('ITEM-QRLOG-TEST', true, 'QR Log Test Item', 'freezer_tray')
  RETURNING nocopk INTO v_item;

  INSERT INTO public.strains(strain_id, active, species_strain, regulated)
  VALUES ('STRAIN-QRLOG-TEST', true, 'QR Log Test Strain', true)
  RETURNING nocopk INTO v_strain;

  INSERT INTO public.locations(name, active, type)
  VALUES ('QR Log Test Location', true, 'Products')
  RETURNING nocopk INTO v_location;

  INSERT INTO public.products(
    product_id, item_id, strain_id, name_mat, item_category_mat,
    package_class, storage_location_id, tray_state
  ) VALUES (
    'PROD-QRLOG-TEST', v_item, v_strain, 'QR Log Product', 'freezer_tray',
    'Sample', v_location, 'Active'
  ) RETURNING nocopk INTO v_product;

  v_log_id := public.mp_qr_log_scan(jsonb_build_object(
    'inventory_id', 'PROD-QRLOG-TEST',
    'entity_type', 'product',
    'entity_nocopk', v_product,
    'status', 'ok',
    'route_kind', 'product_internal',
    'response_code', 302,
    'destination_url', 'https://appsmith.example.invalid/products?product=PROD-QRLOG-TEST',
    'success', true,
    'company_key', 'regulated',
    'company_name', 'QR Regulated Business',
    'client_ip', '2001:db8::1234',
    'forwarded_for', '2001:db8::1234, 198.51.100.7',
    'cf_country', 'US',
    'cf_continent', 'NA',
    'cf_city', 'Johnstown',
    'cf_region', 'Colorado',
    'cf_region_code', 'CO',
    'cf_postal_code', '80534',
    'cf_timezone', 'America/Denver',
    'cf_latitude', '40.3369',
    'cf_longitude', '-104.9122',
    'cf_ray', 'issue30-test-ray',
    'user_agent', 'Mozilla/5.0 Test',
    'browser_name', 'Chrome',
    'browser_version', '140.0',
    'os_name', 'macOS',
    'os_version', '15.0',
    'device_type', 'desktop',
    'request_host', 'qr.example.invalid',
    'request_method', 'GET',
    'request_path', '/r',
    'query_json', jsonb_build_object('i', 'PROD-QRLOG-TEST'),
    'source', 'qr'
  ));

  SELECT * INTO v_row FROM public.qr_scan_log WHERE nocopk = v_log_id;

  IF v_row.inventory_id <> 'PROD-QRLOG-TEST'
     OR v_row.entity_type <> 'product'
     OR v_row.entity_nocopk <> v_product
     OR v_row.resolution_status <> 'ok'
     OR v_row.route_kind <> 'product_internal'
     OR v_row.response_code <> 302
     OR v_row.success IS DISTINCT FROM true
     OR v_row.company_name <> 'QR Regulated Business'
     OR v_row.item_id <> 'ITEM-QRLOG-TEST'
     OR v_row.item_name <> 'QR Log Test Item'
     OR v_row.item_category <> 'freezer_tray'
     OR v_row.strain_id <> 'STRAIN-QRLOG-TEST'
     OR v_row.strain_name <> 'QR Log Test Strain'
     OR v_row.regulated IS DISTINCT FROM true
     OR v_row.package_class <> 'Sample'
     OR v_row.location_name <> 'QR Log Test Location'
     OR v_row.entity_status <> 'Active'
     OR host(v_row.client_ip) <> '2001:db8::1234'
     OR v_row.cf_country <> 'US'
     OR v_row.cf_city <> 'Johnstown'
     OR v_row.browser_name <> 'Chrome'
     OR v_row.os_name <> 'macOS'
     OR v_row.device_type <> 'desktop'
     OR v_row.query_json ->> 'i' <> 'PROD-QRLOG-TEST'
  THEN
    RAISE EXCEPTION 'QR scan logging snapshot failed: %', row_to_json(v_row);
  END IF;

  /* Invalid identifiers should still be reportable without entity metadata. */
  v_log_id := public.mp_qr_log_scan(jsonb_build_object(
    'inventory_id', 'garbage',
    'status', 'invalid_id',
    'response_code', 400,
    'success', false,
    'client_ip', 'not-an-ip',
    'source', 'qr'
  ));

  SELECT * INTO v_row FROM public.qr_scan_log WHERE nocopk = v_log_id;
  IF v_row.resolution_status <> 'invalid_id'
     OR v_row.response_code <> 400
     OR v_row.success IS DISTINCT FROM false
     OR v_row.client_ip IS NOT NULL
  THEN
    RAISE EXCEPTION 'Invalid QR request logging failed: %', row_to_json(v_row);
  END IF;

  RAISE NOTICE 'QR scan analytics schema/logging smoke tests passed.';
END;
$test$;

ROLLBACK;
