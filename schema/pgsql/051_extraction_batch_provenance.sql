\set ON_ERROR_STOP on
-- Apply revised extraction creation function and repair existing extraction Lots.
-- psql \ir resolves relative to this file; 050 is safe to reapply.
\ir 050_extraction_batch_phase_1.sql

BEGIN;
DO $$
DECLARE
  r record;
  v_origin_strain bigint;
  v_strain bigint;
  v_strain_display text;
  v_vendor text;
  v_vendor_batch text;
  v_updated integer := 0;
BEGIN
  FOR r IN
    SELECT l.nocopk AS extraction_id, p.strain_id AS product_strain,
           p.origin_lot_ids_json
    FROM public.lots l
    JOIN public.products p ON p.nocopk = l.source_product_id
    WHERE l.label_template = 'Extraction_Batch'
      AND (l.strain_id IS NULL
           OR NULLIF(btrim(l.strain_species_strain_mat), '') IS NULL
           OR NULLIF(btrim(l.vendor_name_mat), '') IS NULL)
  LOOP
    SELECT
      CASE WHEN count(*) > 0 AND count(DISTINCT o.strain_id) = 1
                  AND count(*) = count(o.strain_id)
           THEN min(o.strain_id) END,
      CASE WHEN count(*) > 0 AND count(DISTINCT NULLIF(btrim(COALESCE(o.vendor_name_mat,o.vendor_name)), '')) = 1
                  AND count(*) = count(NULLIF(btrim(COALESCE(o.vendor_name_mat,o.vendor_name)), ''))
           THEN min(NULLIF(btrim(COALESCE(o.vendor_name_mat,o.vendor_name)), '')) END,
      CASE WHEN count(*) > 0 AND count(DISTINCT NULLIF(btrim(o.vendor_batch), '')) = 1
                  AND count(*) = count(NULLIF(btrim(o.vendor_batch), ''))
           THEN min(NULLIF(btrim(o.vendor_batch), '')) END
    INTO v_origin_strain, v_vendor, v_vendor_batch
    FROM (
      SELECT DISTINCT l.nocopk, l.strain_id, l.vendor_name_mat, l.vendor_name, l.vendor_batch
      FROM public.lots l
      JOIN LATERAL jsonb_array_elements_text(
        CASE WHEN jsonb_typeof(COALESCE(NULLIF(r.origin_lot_ids_json,''), '[]')::jsonb) = 'array'
             THEN COALESCE(NULLIF(r.origin_lot_ids_json,''), '[]')::jsonb
             ELSE '[]'::jsonb END
      ) origin(ref) ON origin.ref = l.nocopk::text OR origin.ref = l.lot_id
    ) o;
    v_strain := COALESCE(r.product_strain, v_origin_strain);
    SELECT s.species_strain INTO v_strain_display
      FROM public.strains s WHERE s.nocopk = v_strain;
    UPDATE public.lots l
    SET strain_id = COALESCE(l.strain_id, v_strain),
        strain_species_strain_mat = COALESCE(NULLIF(btrim(l.strain_species_strain_mat), ''), v_strain_display),
        vendor_name_mat = COALESCE(NULLIF(btrim(l.vendor_name_mat), ''), v_vendor),
        vendor_name = COALESCE(NULLIF(btrim(l.vendor_name), ''), v_vendor),
        vendor_batch = COALESCE(NULLIF(btrim(l.vendor_batch), ''), v_vendor_batch)
    WHERE l.nocopk = r.extraction_id
      AND (v_strain IS NOT NULL OR v_strain_display IS NOT NULL OR v_vendor IS NOT NULL);
    GET DIAGNOSTICS v_updated = ROW_COUNT;
    IF v_updated > 0 THEN
      RAISE NOTICE 'Extraction Lot %: populated available provenance', r.extraction_id;
    END IF;
  END LOOP;
END $$;
COMMIT;
