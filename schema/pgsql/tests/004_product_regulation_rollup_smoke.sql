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
    'Sacrament'
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
    'Gourmet'
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
     OR v_row.label_company_prod <> 'Rooted Psyche'
     OR COALESCE(v_row.label_companyaddress_base_prod, '') NOT ILIKE '%rootedpsyche.com%'
     OR COALESCE(v_row.label_companyaddress_prod, '') NOT ILIKE '%rootedpsyche.com%'
     OR COALESCE(v_row.label_disclaimer_prod, '') NOT LIKE 'NOTICE%Psilocybin%'
     OR v_row.label_companyinfo_prod <> 'Approximate sample size: 5–10 portions of 0.1–0.2 g.'
     OR COALESCE(v_row.label_cottage_prod, '') <> '' THEN
    RAISE EXCEPTION 'Regulated Sample label fields are incorrect: %', row_to_json(v_row);
  END IF;

  SELECT
    pg_typeof(origin_strain_regulated)::text AS regulation_type,
    origin_strain_regulated,
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
     OR v_row.label_company_prod <> 'Dank Mushrooms'
     OR COALESCE(v_row.label_companyaddress_base_prod, '') NOT ILIKE '%danks.store%'
     OR COALESCE(v_row.label_companyaddress_prod, '') NOT ILIKE '%danks.store%'
     OR COALESCE(v_row.label_disclaimer_prod, '') <> ''
     OR v_row.label_companyinfo_prod <> 'Sample size: Great for one recipe.'
     OR COALESCE(v_row.label_cottage_prod, '') NOT ILIKE '%home kitchen%' THEN
    RAISE EXCEPTION 'Unregulated Sample label fields are incorrect: %', row_to_json(v_row);
  END IF;

  RAISE NOTICE 'Product regulation rollup and regulated/unregulated Sample label smoke tests passed.';
END
$$;

ROLLBACK;
