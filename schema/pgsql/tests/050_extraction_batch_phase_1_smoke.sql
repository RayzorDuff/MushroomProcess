\set ON_ERROR_STOP on

-- 050_extraction_batch_phase_1_smoke.sql
-- Structural and behavioral smoke test; the transaction is rolled back.

BEGIN;

DO $$
DECLARE
  v_item_id bigint;
  v_location_id bigint;
  v_consumed_location_id bigint;
  v_source_product_id bigint;
  v_lot_id bigint;
  v_lot record;
  v_event_count integer;
  v_print_count integer;
BEGIN
  SELECT nocopk INTO v_item_id FROM public.items WHERE item_id='EXTRACTION-BATCH';
  IF v_item_id IS NULL THEN RAISE EXCEPTION 'EXTRACTION-BATCH item was not seeded'; END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='lots' AND column_name='source_product_id') THEN RAISE EXCEPTION 'lots.source_product_id missing'; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='lots' AND column_name='material_weight_g') THEN RAISE EXCEPTION 'lots.material_weight_g missing'; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='lots' AND column_name='solvent_volume_ml') THEN RAISE EXCEPTION 'lots.solvent_volume_ml missing'; END IF;

  SELECT nocopk INTO v_location_id FROM public.locations WHERE lower(btrim(name)) IN ('products storage','product storage') ORDER BY nocopk LIMIT 1;
  SELECT nocopk INTO v_consumed_location_id FROM public.locations WHERE lower(btrim(name))='consumed' ORDER BY nocopk LIMIT 1;
  IF v_location_id IS NULL OR v_consumed_location_id IS NULL THEN
    RAISE NOTICE 'Skipping behavioral portion: required locations are absent in this test database.';
    RETURN;
  END IF;

  INSERT INTO public.products(product_id,item_id,name_mat,item_category_mat,net_weight_g,net_weight_oz,tray_state,storage_location_id,origin_lot_ids_json)
  VALUES ('TEST-EXTRACT-TRAY',(SELECT nocopk FROM public.items WHERE item_id='TRAY-FREEZE'),'Freezer Tray','freezer_tray',125,125/28.349523125,'freezer_tray',v_location_id,'[]')
  RETURNING nocopk INTO v_source_product_id;

  v_lot_id := public.mp_products_start_extraction_batch(v_source_product_id,125,'Ethanol',500,'test','Products',now()::timestamp,'phase 1 smoke',200);
  SELECT * INTO v_lot FROM public.lots WHERE nocopk=v_lot_id;

  IF v_lot.lot_id !~ '^LOT-[0-9]{6}-[A-Z0-9]{4}$' THEN RAISE EXCEPTION 'Unexpected extraction Lot ID: %', v_lot.lot_id; END IF;
  IF v_lot.source_product_id <> v_source_product_id THEN RAISE EXCEPTION 'Source Product relationship missing'; END IF;
  IF v_lot.material_weight_g <> 125 THEN RAISE EXCEPTION 'Material weight not persisted'; END IF;
  IF v_lot.solvent_volume_ml <> 500 OR v_lot.solvent_type <> 'Ethanol' OR v_lot.solvent_proof <> 200 THEN RAISE EXCEPTION 'Solvent data not persisted'; END IF;
  IF v_lot.label_template <> 'Extraction_Batch' THEN RAISE EXCEPTION 'Extraction label template not persisted'; END IF;

  SELECT count(*) INTO v_event_count FROM public.events WHERE lot_id=v_lot_id AND product_id=v_source_product_id AND type='ExtractionStarted';
  IF v_event_count <> 1 THEN RAISE EXCEPTION 'ExtractionStarted event missing or not linked to both entities'; END IF;

  SELECT count(*) INTO v_print_count FROM public.print_queue WHERE lot_id=v_lot_id AND source_kind='lot' AND label_type='Extraction_Batch';
  IF v_print_count <> 1 THEN RAISE EXCEPTION 'Extraction Lot print job missing'; END IF;

  PERFORM 1 FROM public.products WHERE nocopk=v_source_product_id AND net_weight_g=0 AND tray_state='empty_tray' AND storage_location_id=v_consumed_location_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Source Product was not transitioned to terminal state'; END IF;
END $$;

ROLLBACK;
