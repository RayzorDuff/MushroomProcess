\set ON_ERROR_STOP on

-- Lightweight metadata contract coverage for the filterable fields in #66.
-- Do not execute vc_print_queue against production data here: the generated
-- view expands many nested computed views and correlated label subqueries.
BEGIN;
SET LOCAL statement_timeout = '5s';
SET LOCAL lock_timeout = '2s';

DO $$
DECLARE
  v_missing_columns text[];
  v_view_definition text;
BEGIN
  SELECT array_agg(required.column_name ORDER BY required.column_name)
  INTO v_missing_columns
  FROM (
    VALUES
      ('nocopk'),
      ('print_id'),
      ('source_kind'),
      ('lot_id'),
      ('product_id'),
      ('print_status'),
      ('label_type'),
      ('error_msg'),
      ('created_at'),
      ('run_id'),
      ('claimed_by'),
      ('claimed_at'),
      ('printed_by'),
      ('printed_at'),
      ('pdf_path'),
      ('item_category_mat_from_lot_id'),
      ('item_category_mat_from_product_id'),
      ('print_target')
  ) AS required(column_name)
  LEFT JOIN information_schema.columns actual
    ON actual.table_schema = 'public'
   AND actual.table_name = 'vc_print_queue'
   AND actual.column_name = required.column_name
  WHERE actual.column_name IS NULL;

  IF COALESCE(cardinality(v_missing_columns), 0) > 0 THEN
    RAISE EXCEPTION
      'vc_print_queue is missing required Appsmith filter columns: %',
      array_to_string(v_missing_columns, ', ');
  END IF;

  SELECT pg_get_viewdef('public.vc_print_queue'::regclass, true)
  INTO v_view_definition;

  IF v_view_definition IS NULL
     OR position('PRINT_TARGET' IN upper(v_view_definition)) = 0
     OR position('TRAYS' IN upper(v_view_definition)) = 0
     OR position('ZEBRA' IN upper(v_view_definition)) = 0
     OR position('SOURCE_KIND' IN upper(v_view_definition)) = 0
     OR position('ITEM_CATEGORY_MAT_FROM_LOT_ID' IN upper(v_view_definition)) = 0
     OR position('ITEM_CATEGORY_MAT_FROM_PRODUCT_ID' IN upper(v_view_definition)) = 0 THEN
    RAISE EXCEPTION
      'vc_print_queue definition no longer contains the expected ZEBRA/TRAYS routing contract.';
  END IF;

  -- Compile the view contract without scanning print_queue or evaluating any
  -- nested vc_lots/vc_products label expressions.
  PERFORM 1
  FROM public.vc_print_queue
  WHERE false;

  RAISE NOTICE
    'Print Queue view column and target-routing metadata contract smoke tests passed.';
END;
$$;

ROLLBACK;
