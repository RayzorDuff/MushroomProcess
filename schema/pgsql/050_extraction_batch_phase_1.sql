\set ON_ERROR_STOP on

-- 050_extraction_batch_phase_1.sql
-- Phase 1: active freezer-tray Product -> identified extraction Lot.
-- The extraction batch is an in-process material/container, not a finished Product.
-- Keep measured dry-material weight separate from lots.unit_size.

SET search_path = public, pg_catalog;

BEGIN;

ALTER TABLE public.lots
  ADD COLUMN IF NOT EXISTS source_product_id bigint,
  ADD COLUMN IF NOT EXISTS material_weight_g numeric,
  ADD COLUMN IF NOT EXISTS solvent_type text,
  ADD COLUMN IF NOT EXISTS solvent_volume_ml numeric,
  ADD COLUMN IF NOT EXISTS process_stage text,
  ADD COLUMN IF NOT EXISTS material_state text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'fk_lots_source_product'
      AND conrelid = 'public.lots'::regclass
  ) THEN
    ALTER TABLE public.lots
      ADD CONSTRAINT fk_lots_source_product
      FOREIGN KEY (source_product_id) REFERENCES public.products(nocopk)
      DEFERRABLE INITIALLY DEFERRED;
  END IF;
END $$;

INSERT INTO public.items (item_id, active, name, category)
VALUES ('EXTRACTION-BATCH', true, 'Extraction Batch', 'extraction_batch')
ON CONFLICT (item_id) DO UPDATE
SET active = true, name = EXCLUDED.name, category = EXCLUDED.category;

CREATE INDEX IF NOT EXISTS ix_lots_source_product_id ON public.lots(source_product_id);
CREATE INDEX IF NOT EXISTS ix_lots_process_stage ON public.lots(process_stage);

CREATE OR REPLACE FUNCTION public.mp_generate_lot_id()
RETURNS text
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
  v_id text;
BEGIN
  LOOP
    v_id := 'LOT-' || to_char(current_date, 'YYMMDD') || '-' ||
            upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 4));
    EXIT WHEN NOT EXISTS (SELECT 1 FROM public.lots WHERE lot_id = v_id);
  END LOOP;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.mp_products_start_extraction_batch(
  p_source_product_id bigint,
  p_material_weight_g numeric,
  p_solvent_type text,
  p_solvent_volume_ml numeric,
  p_operator text DEFAULT 'system',
  p_station text DEFAULT 'Products',
  p_timestamp timestamp without time zone DEFAULT NULL,
  p_note text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  v_ts timestamp without time zone := COALESCE(p_timestamp, now());
  v_source public.products%ROWTYPE;
  v_lot_id bigint;
  v_lot_business_id text;
  v_item_id bigint;
  v_location_id bigint;
  v_consumed_location_id bigint;
  v_event_id bigint;
  v_source_business_id text;
BEGIN
  IF p_source_product_id IS NULL THEN
    RAISE EXCEPTION 'Source Product is required';
  END IF;
  IF p_material_weight_g IS NULL OR p_material_weight_g <= 0 THEN
    RAISE EXCEPTION 'Material weight must be greater than zero';
  END IF;
  IF p_solvent_type IS NULL OR btrim(p_solvent_type) = '' THEN
    RAISE EXCEPTION 'Solvent type is required';
  END IF;
  IF p_solvent_volume_ml IS NULL OR p_solvent_volume_ml <= 0 THEN
    RAISE EXCEPTION 'Solvent volume must be greater than zero';
  END IF;

  SELECT * INTO v_source
  FROM public.products
  WHERE nocopk = p_source_product_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Source Product not found: %', p_source_product_id;
  END IF;
  IF lower(COALESCE(v_source.item_category_mat, '')) <> 'freezer_tray' THEN
    RAISE EXCEPTION 'Start Extraction accepts freezer_tray Products only';
  END IF;
  IF COALESCE(v_source.net_weight_g, 0) <= 0 THEN
    RAISE EXCEPTION 'Source freezer tray Product has no positive remaining weight';
  END IF;
  IF abs(p_material_weight_g - v_source.net_weight_g) > 0.01 THEN
    RAISE EXCEPTION 'Phase 1 requires the full source Product weight: entered % g, source has % g',
      p_material_weight_g, v_source.net_weight_g;
  END IF;
  IF lower(COALESCE(v_source.tray_state, '')) IN
     ('empty_tray','retired','spoiled','compost','composted','expired','shipped','consumed') THEN
    RAISE EXCEPTION 'Source freezer tray Product is no longer active';
  END IF;

  SELECT i.nocopk INTO v_item_id
  FROM public.items i
  WHERE i.item_id = 'EXTRACTION-BATCH' AND COALESCE(i.active, true);
  IF v_item_id IS NULL THEN
    RAISE EXCEPTION 'Extraction Batch item is not available';
  END IF;

  SELECT l.nocopk INTO v_location_id
  FROM public.locations l
  WHERE lower(btrim(l.name)) IN ('products storage', 'product storage')
  ORDER BY CASE WHEN COALESCE(l.active, false) THEN 0 ELSE 1 END, l.nocopk
  LIMIT 1;
  IF v_location_id IS NULL THEN
    RAISE EXCEPTION 'Products Storage location is required';
  END IF;

  SELECT l.nocopk INTO v_consumed_location_id
  FROM public.locations l
  WHERE lower(btrim(l.name)) = 'consumed'
  ORDER BY CASE WHEN COALESCE(l.active, false) THEN 0 ELSE 1 END, l.nocopk
  LIMIT 1;
  IF v_consumed_location_id IS NULL THEN
    RAISE EXCEPTION 'Consumed location is required';
  END IF;

  v_lot_business_id := public.mp_generate_lot_id();
  v_source_business_id := COALESCE(NULLIF(btrim(v_source.product_id), ''), p_source_product_id::text);

  INSERT INTO public.lots (
    lot_id, item_id, item_name_mat, item_category_mat, strain_id, qty,
    status, location_id, operator, created_at, process_stage, material_state,
    material_weight_g, solvent_type, solvent_volume_ml, source_product_id,
    parents_json, label_template, notes
  )
  VALUES (
    v_lot_business_id, v_item_id, 'Extraction Batch', 'extraction_batch',
    v_source.strain_id, 1, 'Extraction', v_location_id, p_operator, v_ts,
    'initial_solvent_extraction', 'solvent_bearing', p_material_weight_g,
    btrim(p_solvent_type), p_solvent_volume_ml, p_source_product_id,
    COALESCE(NULLIF(btrim(v_source.origin_lot_ids_json), ''), '[]'),
    'Extraction_Batch', NULLIF(btrim(p_note), '')
  )
  RETURNING nocopk INTO v_lot_id;

  PERFORM public.mp_lot_set_location(v_lot_id, v_location_id);

  v_event_id := public.mp_events_insert(
    p_lot_id => v_lot_id,
    p_product_id => p_source_product_id,
    p_type => 'ExtractionStarted',
    p_timestamp => v_ts,
    p_operator => COALESCE(p_operator, ''),
    p_station => COALESCE(p_station, 'Products'),
    p_fields_json => jsonb_build_object(
      'action', 'Start Extraction',
      'source_product_id', p_source_product_id,
      'source_product_business_id', v_source_business_id,
      'source_product_weight_g', v_source.net_weight_g,
      'material_weight_g', p_material_weight_g,
      'solvent_type', btrim(p_solvent_type),
      'solvent_volume_ml', p_solvent_volume_ml,
      'created_lot_id', v_lot_id,
      'created_lot_business_id', v_lot_business_id,
      'process_stage', 'initial_solvent_extraction',
      'material_state', 'solvent_bearing',
      'note', NULLIF(btrim(p_note), '')
    )
  );

  PERFORM public.mp_events_link_lot(v_event_id, v_lot_id);
  PERFORM public.mp_events_link_product(v_event_id, p_source_product_id);

  PERFORM public.mp_print_queue_enqueue(
    'lot', 'Extraction_Batch', v_lot_id, NULL, NULL, 'Queued'
  );

  UPDATE public.products
  SET net_weight_g = 0,
      net_weight_oz = 0,
      tray_state = 'empty_tray',
      storage_location_id = v_consumed_location_id,
      nc_updated_at = now(),
      notes = CASE
        WHEN COALESCE(p_note, '') = '' THEN notes
        WHEN COALESCE(notes, '') = '' THEN p_note
        ELSE notes || E'\n' || p_note
      END
  WHERE nocopk = p_source_product_id;

  PERFORM public.mp_product_set_storage_location(p_source_product_id, v_consumed_location_id);
  RETURN v_lot_id;
END;
$$;

COMMIT;
