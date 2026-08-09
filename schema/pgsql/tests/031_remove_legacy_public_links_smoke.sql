BEGIN;

SET LOCAL statement_timeout = '60s';
SET LOCAL lock_timeout = '5s';

DO $$
DECLARE
  v_bad_columns text;
  v_missing text;
BEGIN
  SELECT string_agg(
           format('%I.%I.%I', table_schema, table_name, column_name),
           ', ' ORDER BY table_name, ordinal_position
         )
    INTO v_bad_columns
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name IN ('vc_lots', 'vc_products', 'vc_print_queue')
    AND column_name LIKE 'public_link%';

  IF v_bad_columns IS NOT NULL THEN
    RAISE EXCEPTION
      'Legacy public-link columns remain after migration 031: %',
      v_bad_columns;
  END IF;

  IF position('airtable.com' IN lower(pg_get_viewdef('public.vc_lots'::regclass, true))) > 0
     OR position('airtable.com' IN lower(pg_get_viewdef('public.vc_products'::regclass, true))) > 0
     OR position('airtable.com' IN lower(pg_get_viewdef('public.vc_print_queue'::regclass, true))) > 0 THEN
    RAISE EXCEPTION
      'An Airtable URL expression remains in vc_lots, vc_products, or vc_print_queue';
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
      'Expected target/dependent views were not restored: %',
      v_missing;
  END IF;

  -- Compile representative columns that are consumed by Appsmith, n8n, the
  -- print daemon, and QR routing after the legacy columns are removed.
  PERFORM
    lot_id,
    item_category_mat,
    strain_id,
    label_company_lot,
    label_title_lot,
    label_subtitle_lot,
    lot_component_summary
  FROM public.vc_lots
  LIMIT 0;

  PERFORM
    product_id,
    item_category_mat,
    package_class,
    origin_strain_regulated,
    label_company_prod,
    label_title_prod,
    label_subtitle_prod
  FROM public.vc_products
  LIMIT 0;

  PERFORM
    print_id,
    source_kind,
    lot_id,
    product_id,
    print_status,
    label_type,
    label_title_lot_from_lot_id,
    label_title_prod_from_product_id,
    print_target
  FROM public.vc_print_queue
  LIMIT 0;

  RAISE NOTICE
    'Issue #12 migration 031 legacy public-link cleanup smoke tests passed.';
END
$$;

ROLLBACK;
