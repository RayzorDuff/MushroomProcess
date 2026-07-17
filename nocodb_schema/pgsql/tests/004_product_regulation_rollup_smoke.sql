\set ON_ERROR_STOP on

-- Transactional smoke test for #68 regulation rollup and product label formulas.
-- Run after 004_computed_views.sql. All fixtures are rolled back.
BEGIN;

DO $$
DECLARE
  v_regulated_strain_id bigint;
  v_unregulated_strain_id bigint;
  v_regulated_product_id bigint;
  v_unregulated_product_id bigint;
  v_row record;
BEGIN
  INSERT INTO public.strains (
    strain_id,
    active,
    species_strain,
    regulated,
    product_use
  ) VALUES (
    'STRAIN-RC5-REG-ROLLUP',
    true,
    'RC5 Regulated Rollup Test',
    true,
    'regulated_psychedelic'
  )
  RETURNING nocopk INTO v_regulated_strain_id;

  INSERT INTO public.strains (
    strain_id,
    active,
    species_strain,
    regulated,
    product_use
  ) VALUES (
    'STRAIN-RC5-UNREG-ROLLUP',
    true,
    'RC5 Unregulated Rollup Test',
    false,
    'gourmet'
  )
  RETURNING nocopk INTO v_unregulated_strain_id;

  INSERT INTO public.products (
    product_id,
    name_mat,
    item_category_mat,
    net_weight_g,
    pack_date,
    package_class,
    package_size,
    package_count,
    strain_id,
    notes
  ) VALUES (
    'PROD-RC5-REG-ROLLUP',
    'RC5 Regulated Sample',
    'freezedriedmushrooms',
    1,
    current_date,
    'Sample',
    '1 g',
    1,
    v_regulated_strain_id,
    'Rollback-only regulated rollup fixture'
  )
  RETURNING nocopk INTO v_regulated_product_id;

  INSERT INTO public.products (
    product_id,
    name_mat,
    item_category_mat,
    net_weight_g,
    pack_date,
    package_class,
    package_size,
    package_count,
    strain_id,
    notes
  ) VALUES (
    'PROD-RC5-UNREG-ROLLUP',
    'RC5 Unregulated Sample',
    'freezedriedmushrooms',
    5,
    current_date,
    'Sample',
    '5 g',
    1,
    v_unregulated_strain_id,
    'Rollback-only unregulated rollup fixture'
  )
  RETURNING nocopk INTO v_unregulated_product_id;

  SELECT
    pg_typeof(origin_strain_regulated)::text AS regulation_type,
    origin_strain_regulated,
    public_link,
    label_company_prod,
    label_companyaddress_base_prod,
    label_companyaddress_prod,
    label_disclaimer_prod,
    label_companyinfo_prod,
    label_cottage_prod
  INTO v_row
  FROM public.vc_products
  WHERE nocopk = v_regulated_product_id;

  IF v_row.regulation_type <> 'numeric'
     OR v_row.origin_strain_regulated <> 1
     OR v_row.public_link <> 'https://www.regulatedbusiness.com/'
     OR v_row.label_company_prod <> 'Regulated Business'
     OR v_row.label_companyaddress_base_prod <> 'RegulatedBusinessAddressAndContact'
     OR v_row.label_companyaddress_prod <> 'RegulatedBusinessAddressAndContact'
     OR COALESCE(v_row.label_disclaimer_prod, '') NOT LIKE 'NOTICE%Psilocybin%'
     OR COALESCE(v_row.label_companyinfo_prod, '') <> ''
     OR COALESCE(v_row.label_cottage_prod, '') <> '' THEN
    RAISE EXCEPTION 'Regulated Sample label fields are incorrect: %', row_to_json(v_row);
  END IF;

  SELECT
    pg_typeof(origin_strain_regulated)::text AS regulation_type,
    origin_strain_regulated,
    public_link,
    label_company_prod,
    label_companyaddress_base_prod,
    label_companyaddress_prod,
    label_disclaimer_prod,
    label_companyinfo_prod,
    label_cottage_prod
  INTO v_row
  FROM public.vc_products
  WHERE nocopk = v_unregulated_product_id;

  IF v_row.regulation_type <> 'numeric'
     OR v_row.origin_strain_regulated <> 0
     OR v_row.public_link <> 'https://www.mybusiness.com/'
     OR v_row.label_company_prod <> 'My Business'
     OR v_row.label_companyaddress_base_prod <> 'MyBusinessAddressAndContact'
     OR v_row.label_companyaddress_prod <> 'MyBusinessAddressAndContact'
     OR COALESCE(v_row.label_disclaimer_prod, '') <> ''
     OR v_row.label_companyinfo_prod <> 'MyBusinessOffering'
     OR COALESCE(v_row.label_cottage_prod, '') NOT ILIKE '%home kitchen%' THEN
    RAISE EXCEPTION 'Unregulated Sample label fields are incorrect: %', row_to_json(v_row);
  END IF;

  RAISE NOTICE 'Product regulation rollup and regulated/unregulated Sample label smoke tests passed.';
END
$$;

ROLLBACK;
