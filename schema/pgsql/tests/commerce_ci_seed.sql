\set ON_ERROR_STOP on
-- Synthetic lookup definitions for the disposable GitHub Actions database only.
-- Production CSVs are deliberately not imported. Never apply to a live database.
BEGIN;
DO $$ BEGIN
 IF current_database() <> 'commerce_test' OR EXISTS (SELECT 1 FROM public.products)
    OR EXISTS (SELECT 1 FROM public.lots) OR EXISTS (SELECT 1 FROM public.strains) THEN
   RAISE EXCEPTION 'Synthetic seed requires the empty disposable commerce_test database';
 END IF;
END $$;
INSERT INTO public.locations(name,active,type) VALUES
 ('Products Storage',true,'Storage'),('Consumed',true,'Terminal'),
 ('Fridge',true,'Storage'),('Dark Room',true,'Production');
INSERT INTO public.strains(strain_id,species_strain,active)
 VALUES ('CI-SYNTHETIC-STRAIN','Synthetic CI strain',true);
INSERT INTO public.items(item_id,name,category,active) VALUES
 ('GRAIN-BAG','Synthetic grain','grain',true),
 ('SUB-CVG-BAG','Synthetic substrate','substrate',true),
 ('LC-SYRINGE','Synthetic LC syringe','lc_syringe',true),
 ('LC-FLASK','Synthetic LC flask','lc_flask',true),
 ('TRAY-FREEZE','Synthetic freezer tray','freezer_tray',true),
 ('FB-COCO-LG','Synthetic large CVG block','fruiting_block',true),
 ('FB-COCO-SM','Synthetic small CVG block','fruiting_block',true),
 ('FB-MM75-LG','Synthetic large block 75','fruiting_block',true),
 ('FB-MM75-SM','Synthetic small block 75','fruiting_block',true),
 ('FB-MM50-LG','Synthetic large block 50','fruiting_block',true),
 ('FB-MM50-SM','Synthetic small block 50','fruiting_block',true);
INSERT INTO public.recipes(recipe_id,name,category,active) VALUES
 ('REC-GRAIN-WBS','Synthetic grain recipe','grain',true),
 ('REC-SUB-CVG-V2','Synthetic substrate recipe','substrate',true);
COMMIT;
