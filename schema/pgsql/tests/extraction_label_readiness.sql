\set ON_ERROR_STOP on
-- Extraction label readiness diagnostic; read-only, safe on production.
-- Run after 050_extraction_batch_phase_1.sql, before consuming a test tray.
-- Fail fast if an existing view has not been refreshed with extraction columns.
BEGIN READ ONLY;
DO $$
DECLARE
  v_missing text;
  v_view text;
  v_required text[];
BEGIN
  FOREACH v_view IN ARRAY ARRAY['v_lots','vc_lots'] LOOP
    v_required := CASE WHEN v_view = 'v_lots'
      THEN ARRAY['source_product_id','material_weight_g','solvent_type','solvent_proof','solvent_volume_ml','process_stage','material_state']
      ELSE ARRAY['label_title_lot','label_subtitle_lot','label_proc_line'] END;
    SELECT string_agg(c.col, ', ' ORDER BY c.col) INTO v_missing
      FROM unnest(v_required) AS c(col)
     WHERE NOT EXISTS (
       SELECT 1 FROM information_schema.columns ic
        WHERE ic.table_schema = 'public' AND ic.table_name = v_view
          AND ic.column_name = c.col
     );
    IF v_missing IS NOT NULL THEN
      RAISE EXCEPTION 'Extraction labels NOT READY: %.% missing columns: %',
        'public', v_view, v_missing;
    END IF;
  END LOOP;
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc WHERE oid =
      to_regprocedure('public.mp_products_start_extraction_batch(bigint,numeric,text,numeric,text,text,timestamp without time zone,text,numeric)')
  ) THEN
    RAISE EXCEPTION 'Extraction batch function missing (apply 050 migration)';
  END IF;
  RAISE NOTICE 'Extraction schema columns present. Check label content below.';
END $$;
-- Existing batches, if any: verify actual material, labels and queue together.
SELECT l.nocopk AS lot_nocopk, l.lot_id, l.source_product_id,
       l.material_weight_g, l.solvent_type, l.solvent_proof,
       l.solvent_volume_ml, l.process_stage, l.material_state,
       vc.label_title_lot, vc.label_subtitle_lot, vc.label_proc_line,
       CASE WHEN vc.label_title_lot = 'Extraction Batch'
                  AND nullif(btrim(vc.label_subtitle_lot),'') IS NOT NULL
            THEN 'READY' ELSE 'LABEL_NOT_READY' END AS label_readiness
  FROM public.lots l
  LEFT JOIN public.vc_lots vc ON vc.nocopk = l.nocopk
 WHERE l.label_template = 'Extraction_Batch'
 ORDER BY l.nocopk DESC LIMIT 20;
ROLLBACK;
