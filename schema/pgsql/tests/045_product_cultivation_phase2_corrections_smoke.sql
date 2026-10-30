\set ON_ERROR_STOP on

-- Issue #57 Phase 2 corrective smoke test.
-- Validates operating-date handling, unprefixed PROD-* identifiers, and
-- function timezone configuration. All fixtures are rolled back.
BEGIN;

DO $test$
DECLARE
  v_operating_date date := public.mp_cultivation_operating_date();
  v_far_timezone text;
  v_products_loc bigint;
  v_consumed_loc bigint;
  v_grain_item bigint;
  v_origin bigint;
  v_product bigint;
  v_viewdef text;
  v_cfg text[];
BEGIN
  IF v_operating_date <> (CURRENT_TIMESTAMP AT TIME ZONE 'America/Denver')::date THEN
    RAISE EXCEPTION 'mp_cultivation_operating_date() is not using America/Denver.';
  END IF;

  -- Force the session calendar date away from the cultivation operating date.
  -- This reproduces the production failure where the UTC host crossed midnight
  -- before Colorado did, without depending on what time this test is run.
  IF (CURRENT_TIMESTAMP AT TIME ZONE 'Pacific/Kiritimati')::date <> v_operating_date THEN
    v_far_timezone := 'Pacific/Kiritimati';
  ELSE
    v_far_timezone := 'Etc/GMT+12';
  END IF;
  PERFORM set_config('TimeZone', v_far_timezone, true);

  IF CURRENT_DATE = v_operating_date THEN
    RAISE EXCEPTION 'Smoke test could not force a session date different from the cultivation operating date.';
  END IF;

  SELECT pg_get_viewdef('public.v_product_cultivation_candidates'::regclass, true)
  INTO v_viewdef;

  IF position('PRODUCT ·' in v_viewdef) > 0 THEN
    RAISE EXCEPTION 'Candidate view still adds the redundant PRODUCT identifier prefix.';
  END IF;

  IF position('mp_cultivation_operating_date' in v_viewdef) = 0 THEN
    RAISE EXCEPTION 'Candidate view does not use the cultivation operating date.';
  END IF;

  SELECT proconfig INTO v_cfg
  FROM pg_proc
  WHERE oid = 'public.mp_product_return_to_lot(bigint,text,text,timestamp without time zone,text,text,bigint)'::regprocedure;
  IF NOT COALESCE(v_cfg, ARRAY[]::text[]) @> ARRAY['TimeZone=America/Denver']::text[] THEN
    RAISE EXCEPTION 'mp_product_return_to_lot is not pinned to the cultivation timezone.';
  END IF;

  SELECT proconfig INTO v_cfg
  FROM pg_proc
  WHERE oid = 'public.mp_inoculate_with_products_result(bigint,bigint,bigint[],bigint[],bigint,numeric,timestamp without time zone,text,text,timestamp without time zone,text)'::regprocedure;
  IF NOT COALESCE(v_cfg, ARRAY[]::text[]) @> ARRAY['TimeZone=America/Denver']::text[] THEN
    RAISE EXCEPTION 'mp_inoculate_with_products_result is not pinned to the cultivation timezone.';
  END IF;

  SELECT proconfig INTO v_cfg
  FROM pg_proc
  WHERE oid = 'public.mp_spawn_to_bulk_with_products(bigint[],bigint[],bigint[],integer,jsonb,bigint,timestamp without time zone,text,text,timestamp without time zone,text,text)'::regprocedure;
  IF NOT COALESCE(v_cfg, ARRAY[]::text[]) @> ARRAY['TimeZone=America/Denver']::text[] THEN
    RAISE EXCEPTION 'mp_spawn_to_bulk_with_products is not pinned to the cultivation timezone.';
  END IF;

  SELECT nocopk INTO v_products_loc
  FROM public.locations
  WHERE regexp_replace(lower(btrim(name)), '[^a-z0-9]', '', 'g') IN ('productsstorage','productstorage')
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;
  IF v_products_loc IS NULL THEN
    INSERT INTO public.locations(name, active, type)
    VALUES ('Products Storage', true, 'Storage')
    RETURNING nocopk INTO v_products_loc;
  END IF;

  SELECT nocopk INTO v_consumed_loc
  FROM public.locations
  WHERE regexp_replace(lower(btrim(name)), '[^a-z0-9]', '', 'g') = 'consumed'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;
  IF v_consumed_loc IS NULL THEN
    INSERT INTO public.locations(name, active, type)
    VALUES ('Consumed', true, 'Terminal')
    RETURNING nocopk INTO v_consumed_loc;
  END IF;

  SELECT nocopk INTO v_grain_item
  FROM public.items
  WHERE item_id = 'GRAIN-BAG'
  LIMIT 1;
  IF v_grain_item IS NULL THEN
    RAISE EXCEPTION 'Issue #57 corrective smoke requires imported GRAIN-BAG item data.';
  END IF;

  INSERT INTO public.lots(
    lot_id, item_id, item_name_mat, item_category_mat,
    qty, unit_size, status, location_id, created_at, sterilized_at, use_by
  )
  SELECT
    'LOT-ISS57-P2-DATE-ORIGIN', v_grain_item, i.name, 'grain',
    1, 2, 'Consumed', v_consumed_loc, now() - interval '30 days',
    now() - interval '30 days', v_operating_date
  FROM public.items i
  WHERE i.nocopk = v_grain_item
  RETURNING nocopk INTO v_origin;

  INSERT INTO public.products(
    product_id, item_id, name_mat, item_category_mat, net_weight_g,
    pack_date, use_by, storage_location_id, origin_lot_ids_json
  )
  SELECT
    'PROD-ISS57-P2-DATE', v_grain_item, i.name, 'grain', 907.18474,
    v_operating_date - 30, v_operating_date, v_products_loc,
    to_jsonb(ARRAY['LOT-ISS57-P2-DATE-ORIGIN'])::text
  FROM public.items i
  WHERE i.nocopk = v_grain_item
  RETURNING nocopk INTO v_product;

  INSERT INTO public._m2m_products_lots_origin_lots(products_id, lots_id)
  VALUES (v_product, v_origin);

  IF NOT EXISTS (
    SELECT 1
    FROM public.v_product_cultivation_candidates c
    WHERE c.product_nocopk = v_product
      AND c.can_inoculate_target
      AND c.lot_id = 'PROD-ISS57-P2-DATE'
      AND c.use_by = v_operating_date
  ) THEN
    RAISE EXCEPTION 'Product valid through the Colorado operating date was hidden by the session/server date.';
  END IF;
END;
$test$;

ROLLBACK;
