\set ON_ERROR_STOP on

-- Issue #57 expired Product opt-in smoke test. All fixtures roll back.
BEGIN;

DO $test$
DECLARE
  v_operating_date date := public.mp_cultivation_operating_date();
  v_products_loc bigint;
  v_expired_loc bigint;
  v_consumed_loc bigint;
  v_grain_item bigint;
  v_origin bigint;
  v_product bigint;
  v_returned bigint;
BEGIN
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

  SELECT nocopk INTO v_expired_loc
  FROM public.locations
  WHERE regexp_replace(lower(btrim(name)), '[^a-z0-9]', '', 'g') = 'expired'
  ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
  LIMIT 1;
  IF v_expired_loc IS NULL THEN
    INSERT INTO public.locations(name, active, type)
    VALUES ('Expired', true, 'Storage')
    RETURNING nocopk INTO v_expired_loc;
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
    RAISE EXCEPTION 'Issue #57 expired Product smoke requires imported GRAIN-BAG item data.';
  END IF;

  INSERT INTO public.lots(
    lot_id, item_id, item_name_mat, item_category_mat,
    qty, unit_size, status, location_id, created_at, sterilized_at, use_by
  )
  SELECT
    'LOT-ISS57-EXPIRED-ORIGIN', v_grain_item, i.name, 'grain',
    1, 2, 'Consumed', v_consumed_loc, now() - interval '120 days',
    now() - interval '120 days', v_operating_date - 1
  FROM public.items i
  WHERE i.nocopk = v_grain_item
  RETURNING nocopk INTO v_origin;

  INSERT INTO public.products(
    product_id, item_id, name_mat, item_category_mat, net_weight_g,
    pack_date, use_by, storage_location_id, origin_lot_ids_json
  )
  SELECT
    'PROD-ISS57-EXPIRED-GRAIN', v_grain_item, i.name, 'grain', 907.18474,
    v_operating_date - 120, v_operating_date - 1, v_expired_loc,
    to_jsonb(ARRAY['LOT-ISS57-EXPIRED-ORIGIN'])::text
  FROM public.items i
  WHERE i.nocopk = v_grain_item
  RETURNING nocopk INTO v_product;

  INSERT INTO public._m2m_products_lots_origin_lots(products_id, lots_id)
  VALUES (v_product, v_origin);

  IF NOT EXISTS (
    SELECT 1
    FROM public.mp_product_cultivation_eligibility(v_product, v_operating_date) e
    WHERE e.eligible_for_return
      AND e.can_inoculate_target
      AND e.ineligibility_reason IS NULL
  ) THEN
    RAISE EXCEPTION 'Expired grain Product was not structurally eligible for cultivation return.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.v_product_cultivation_candidates c
    WHERE c.product_nocopk = v_product
      AND c.product_id = 'PROD-ISS57-EXPIRED-GRAIN'
      AND c.can_inoculate_target
      AND c.is_expired
      AND c.use_by = v_operating_date - 1
  ) THEN
    RAISE EXCEPTION 'Expired grain Product was not exposed with is_expired=true.';
  END IF;

  SELECT public.mp_product_return_to_lot(
    v_product,
    'Issue #57 expired Product opt-in smoke',
    'Smoke Test',
    NULL,
    NULL,
    'Expired cultivation Product smoke',
    NULL
  ) INTO v_returned;

  IF v_returned IS NULL THEN
    RAISE EXCEPTION 'Expired Product could not be returned to Lot inventory.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.lots l
    WHERE l.nocopk = v_returned
      AND l.source_product_id = v_product
      AND l.use_by = v_operating_date - 1
  ) THEN
    RAISE EXCEPTION 'Returned Lot did not preserve the expired Product use-by date.';
  END IF;
END;
$test$;

ROLLBACK;
