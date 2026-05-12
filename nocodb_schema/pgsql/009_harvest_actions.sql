/*
  009_harvest_actions.sql

*/

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS harvest_flush_no integer,
  ADD COLUMN IF NOT EXISTS harvest_weight_g numeric,
  ADD COLUMN IF NOT EXISTS harvested_at timestamp without time zone;

ALTER TABLE public.lots
  ADD COLUMN IF NOT EXISTS beganfruiting_at timestamp without time zone,
  ADD COLUMN IF NOT EXISTS firstharvested_at timestamp without time zone,
  ADD COLUMN IF NOT EXISTS lastharvested_at timestamp without time zone;

CREATE INDEX IF NOT EXISTS idx_products_tray_state
  ON public.products(tray_state);

CREATE INDEX IF NOT EXISTS idx_products_harvested_at
  ON public.products(harvested_at);

CREATE OR REPLACE FUNCTION public.mp_lots_harvest_create_tray_products(
  p_block_lot_id bigint,
  p_harvest_item_id bigint,
  p_harvest_weight_g numeric,
  p_flush_no integer,
  p_fresh_tray_count integer DEFAULT 0,
  p_frozen_tray_count integer DEFAULT 0,
  p_storage_location_id bigint DEFAULT NULL,
  p_operator text DEFAULT NULL,
  p_station text DEFAULT 'Lots',
  p_timestamp timestamp without time zone DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
  v_ts timestamp without time zone := COALESCE(p_timestamp, now());
  v_block record;
  v_item record;
  v_created_id bigint;
  v_event_id bigint;
  v_total_count integer;
  v_count integer := 0;
  v_per_tray_g numeric;
  v_loc_id bigint := COALESCE(
    p_storage_location_id,
    (
      SELECT nocopk
      FROM public.locations
      WHERE lower(btrim(name)) = lower(btrim('Products Storage'))
      ORDER BY CASE WHEN COALESCE(active, false) THEN 0 ELSE 1 END, nocopk
      LIMIT 1
    )
  );
BEGIN
  IF p_block_lot_id IS NULL THEN RAISE EXCEPTION 'Fruiting block lot is required'; END IF;
  IF p_harvest_item_id IS NULL THEN RAISE EXCEPTION 'Harvest item is required'; END IF;
  IF p_harvest_weight_g IS NULL OR p_harvest_weight_g <= 0 THEN RAISE EXCEPTION 'Harvest weight must be > 0'; END IF;
  IF p_flush_no IS NULL OR p_flush_no <= 0 THEN RAISE EXCEPTION 'Flush number must be > 0'; END IF;

  v_total_count := COALESCE(p_fresh_tray_count, 0) + COALESCE(p_frozen_tray_count, 0);
  IF v_total_count <= 0 THEN
    RAISE EXCEPTION 'At least one fresh or freezer tray is required';
  END IF;

  SELECT * INTO v_block
  FROM public.lots
  WHERE nocopk = p_block_lot_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'Fruiting block lot not found: %', p_block_lot_id; END IF;
  IF COALESCE(v_block.item_category_mat, '') NOT IN ('fruiting_block','cordyceps_substrate') THEN
    RAISE EXCEPTION 'Source lot must be fruiting_block or cordyceps_substrate, got %', v_block.item_category_mat;
  END IF;

  SELECT * INTO v_item
  FROM public.items
  WHERE nocopk = p_harvest_item_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'Harvest item not found: %', p_harvest_item_id; END IF;
  IF COALESCE(v_item.category, '') NOT IN ('fresh_tray', 'freezer_tray') THEN
    RAISE EXCEPTION 'Harvest item category must be fresh_tray or freezer_tray, got %', v_item.category;
  END IF;

  v_per_tray_g := p_harvest_weight_g / v_total_count;

  FOR i IN 1..v_total_count LOOP
    INSERT INTO public.products (
      item_id,
      strain_id,
      name_mat,
      item_category_mat,
      net_weight_g,
      net_weight_oz,
      pack_date,
      origin_lot_ids_json,
      process_type_mat,
      tray_state,
      storage_location_id,
      harvest_flush_no,
      harvest_weight_g,
      harvested_at,
      notes
    )
    VALUES (
      p_harvest_item_id,
      v_block.strain_id,
      v_item.name,
      v_item.category,
      v_per_tray_g,
      v_per_tray_g / 28.349523125,
      v_ts::date,
      to_jsonb(ARRAY[COALESCE(NULLIF(btrim(v_block.lot_id), ''), p_block_lot_id::text)])::text,
      v_block.process_type_mat,
      v_item.category,
      v_loc_id,
      p_flush_no,
      v_per_tray_g,
      v_ts,
      p_notes
    )
    RETURNING nocopk INTO v_created_id;

    INSERT INTO public._m2m_products_lots_origin_lots(products_id, lots_id)
    VALUES (v_created_id, p_block_lot_id)
    ON CONFLICT DO NOTHING;

    BEGIN
      PERFORM public.mp_product_set_storage_location(v_created_id, v_loc_id);
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    BEGIN
      PERFORM public.mp_print_queue_enqueue(
        'product',
        'Harvest_Tray',
        NULL::bigint,
        v_created_id,
        NULL::bigint,
        'Queued'
      );
    EXCEPTION WHEN undefined_function THEN NULL;
    END;

    v_count := v_count + 1;
  END LOOP;

  UPDATE public.lots
  SET harvest_weight_g = p_harvest_weight_g,
      flush_no = p_flush_no,
      fresh_tray_count = COALESCE(p_fresh_tray_count, 0),
      frozen_tray_count = COALESCE(p_frozen_tray_count, 0),
      firstharvested_at = COALESCE(firstharvested_at, v_ts),
      lastharvested_at = v_ts,
      nc_updated_at = now()
  WHERE nocopk = p_block_lot_id;

  BEGIN
    v_event_id := public.mp_events_insert(
      'Harvest',
      COALESCE(p_operator, ''),
      COALESCE(p_station, 'Lots'),
      v_ts,
      jsonb_build_object(
        'source_lot_id', p_block_lot_id,
        'harvest_item_id', p_harvest_item_id,
        'harvest_weight_g', p_harvest_weight_g,
        'flush_no', p_flush_no,
        'fresh_tray_count', p_fresh_tray_count,
        'frozen_tray_count', p_frozen_tray_count,
        'total_trays', v_total_count,
        'per_tray_weight_g', v_per_tray_g,
        'notes', p_notes
      )
    );

    PERFORM public.mp_events_link_lot(v_event_id, p_block_lot_id);
  EXCEPTION WHEN undefined_function THEN NULL;
  END;

  RETURN v_count;
END;
$$;
