-- Woo follow-up ONLY. Do not apply to an Ecwid-only deployment.
BEGIN;
SET LOCAL lock_timeout='10s';
SELECT pg_advisory_xact_lock(520052);
DO $$ BEGIN
 IF to_regprocedure('public.mp_inventory_units()') IS NULL
 OR to_regprocedure('public.mp_commerce_pick(jsonb)') IS NULL
 OR to_regprocedure('public.mp_commerce_lot_eligible(bigint,bigint)') IS NULL
 OR to_regclass('public.mp_commerce_lot_picks') IS NULL THEN
  RAISE EXCEPTION '059 requires reviewed 054-058 Woo fulfillment prerequisites'; END IF;
END $$;
CREATE TABLE IF NOT EXISTS public.mp_commerce_059_backup(name text PRIMARY KEY,definition text NOT NULL,applied_definition text);
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM public.mp_commerce_059_backup b WHERE pg_get_functiondef(name::regprocedure)
 IS DISTINCT FROM coalesce(applied_definition,definition)) THEN RAISE EXCEPTION 'Later function change requires review before 059'; END IF;
END $$;
INSERT INTO public.mp_commerce_059_backup(name,definition)
 SELECT p.oid::regprocedure::text,pg_get_functiondef(p.oid) FROM pg_proc p WHERE p.oid IN (
 'public.mp_commerce_pick(jsonb)'::regprocedure,'public.mp_commerce_ingest(jsonb)'::regprocedure,
 'public.mp_commerce_lot_eligible(bigint,bigint)'::regprocedure,
 'public.mp_commerce_acknowledge_products(text,text,text,text,jsonb)'::regprocedure) ON CONFLICT DO NOTHING;
CREATE OR REPLACE FUNCTION public.mp_commerce_product_eligible(p_product bigint,p_ecommerce bigint)
RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT EXISTS(SELECT 1 FROM public.mp_inventory_units() u JOIN public.mp_inventory_specs() s
 ON u.pool_key=s.pool_key WHERE s.ecommerce_id=p_ecommerce AND u.kind='product'
 AND u.unit_id=p_product AND u.eligible);
$$;
CREATE OR REPLACE FUNCTION public.mp_commerce_lot_eligible(p_lot bigint,p_ecommerce bigint)
RETURNS boolean LANGUAGE sql STABLE AS $$
 SELECT EXISTS(SELECT 1 FROM public.mp_inventory_units() u JOIN public.mp_inventory_specs() s
 ON u.pool_key=s.pool_key WHERE s.ecommerce_id=p_ecommerce AND u.kind='lot'
 AND u.unit_id=p_lot AND u.eligible);
$$;
-- Change only known predicates; preserve the installed retry/atomicity contract.
DO $$ DECLARE original text;changed text;
BEGIN
 SELECT pg_get_functiondef('public.mp_commerce_pick(jsonb)'::regprocedure) INTO original;
 IF position('mp_commerce_product_eligible(product.nocopk,r.ecommerce_id)' IN original)=0 THEN
  changed:=replace(original,'product.item_id<>r.item_id OR product.strain_id IS DISTINCT FROM r.strain_id',
    'NOT public.mp_commerce_product_eligible(product.nocopk,r.ecommerce_id)');
  IF original=changed THEN RAISE EXCEPTION 'Unknown Product pick predicate'; END IF;
  EXECUTE changed;
 END IF;
 SELECT pg_get_functiondef('public.mp_commerce_acknowledge_products(text,text,text,text,jsonb)'::regprocedure) INTO original;
 IF position('inventory.expected_ecommerce' IN original)=0 THEN
  changed:=replace(original,'e.item_id AS expected_item,e.strain_id AS expected_strain',
   'e.item_id AS expected_item,e.strain_id AS expected_strain,r.ecommerce_id AS expected_ecommerce');
  IF changed=original THEN RAISE EXCEPTION 'Unknown Product acknowledgment mapping'; END IF;
  original:=changed;
  changed:=replace(original,'inventory.item_id<>inventory.expected_item OR inventory.strain_id IS DISTINCT FROM inventory.expected_strain',
   'NOT EXISTS(SELECT 1 FROM public.mp_inventory_units() u JOIN public.mp_inventory_specs() s ON u.pool_key=s.pool_key WHERE s.ecommerce_id=inventory.expected_ecommerce AND u.kind=''product'' AND u.unit_id=(pid#>>''{}'')::bigint AND u.shipped)');
  IF changed=original THEN RAISE EXCEPTION 'Unknown Product acknowledgment predicate'; END IF;
  EXECUTE changed;
 END IF;
 SELECT pg_get_functiondef('public.mp_commerce_ingest(jsonb)'::regprocedure) INTO original;
 IF position('mp_inventory_reserved(candidate.ecommerce_id)' IN original)=0 THEN
  changed:=regexp_replace(original,
   'SELECT coalesce\(sum\(quantity\),0\) INTO reserved FROM public.mp_commerce_reservations[[:space:]]+WHERE item_id=candidate.item_id AND strain_id IS NOT DISTINCT FROM candidate.strain_id;',
   'SELECT public.mp_inventory_reserved(candidate.ecommerce_id)+public.mp_inventory_legacy_hold(candidate.ecommerce_id) INTO reserved;','g');
  IF changed=original THEN RAISE EXCEPTION 'Unknown installed reservation predicate'; END IF;
  EXECUTE changed;
 END IF;
END $$;
UPDATE public.mp_commerce_059_backup SET applied_definition=pg_get_functiondef(name::regprocedure);

-- Explicit cutover configuration, invoked only after both checkouts/stock writers
-- are paused. No owner is changed by installing this migration.
CREATE TABLE IF NOT EXISTS public.mp_commerce_pool_owner_changes (
 token uuid PRIMARY KEY,pool_key text NOT NULL,new_owner bigint NOT NULL REFERENCES public.ecommerce(nocopk),
 before_flags jsonb NOT NULL,after_flags jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),restored_at timestamptz);
CREATE OR REPLACE FUNCTION public.mp_commerce_select_woo_inventory_owner(p_ecommerce bigint,p_expected_owner bigint)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE target record;key text;owner bigint;old_flags jsonb;new_flags jsonb;receipt uuid:=gen_random_uuid();
BEGIN
 PERFORM pg_advisory_xact_lock(520052);
 SELECT * INTO STRICT target FROM public.ecommerce WHERE nocopk=p_ecommerce FOR UPDATE;
 SELECT pool_key INTO STRICT key FROM public.mp_inventory_specs() WHERE ecommerce_id=p_ecommerce AND size_kind IS DISTINCT FROM 'review';
 IF target.provider<>'woocommerce' OR target.site_key<>'danks.store' OR target.sync_enabled IS NOT TRUE
 OR coalesce(target.external_product_id,'') !~ '^[1-9][0-9]*$' OR coalesce(target.erp_item_code,'')='' THEN
  RAISE EXCEPTION 'Exact enabled Woo/ERP mapping required for owner handoff'; END IF;
 SELECT ecommerce_id INTO owner FROM public.mp_inventory_specs() WHERE pool_key=key AND is_owner;
 IF owner IS DISTINCT FROM p_expected_owner OR owner=p_ecommerce THEN RAISE EXCEPTION 'Current pool owner changed or already selected'; END IF;
 IF EXISTS(SELECT 1 FROM public.mp_ecwid_inventory_publications p JOIN public.mp_inventory_specs() s USING(ecommerce_id)
 WHERE s.pool_key=key AND p.pending_token IS NOT NULL) THEN RAISE EXCEPTION 'Resolve pending Ecwid stock writes before handoff'; END IF;
 SELECT jsonb_agg(jsonb_build_object('id',e.nocopk,'value',e.is_primary_public_listing) ORDER BY e.nocopk)
 INTO old_flags FROM public.ecommerce e JOIN public.mp_inventory_specs() s ON s.ecommerce_id=e.nocopk WHERE s.pool_key=key;
 UPDATE public.ecommerce e SET is_primary_public_listing=(e.nocopk=p_ecommerce)
 FROM public.mp_inventory_specs() s WHERE s.ecommerce_id=e.nocopk AND s.pool_key=key;
 IF NOT EXISTS(SELECT 1 FROM public.mp_inventory_specs() WHERE ecommerce_id=p_ecommerce AND is_owner) THEN RAISE EXCEPTION 'Woo owner readback failed'; END IF;
 SELECT jsonb_agg(jsonb_build_object('id',e.nocopk,'value',e.is_primary_public_listing) ORDER BY e.nocopk)
 INTO new_flags FROM public.ecommerce e JOIN public.mp_inventory_specs() s ON s.ecommerce_id=e.nocopk WHERE s.pool_key=key;
 INSERT INTO public.mp_commerce_pool_owner_changes(token,pool_key,new_owner,before_flags,after_flags)
 VALUES(receipt,key,p_ecommerce,old_flags,new_flags);
 RETURN receipt;
END $$;
CREATE OR REPLACE FUNCTION public.mp_commerce_restore_inventory_owner(p_token uuid)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE saved public.mp_commerce_pool_owner_changes%ROWTYPE;current_flags jsonb;entry jsonb;
BEGIN
 PERFORM pg_advisory_xact_lock(520052);
 SELECT * INTO STRICT saved FROM public.mp_commerce_pool_owner_changes WHERE token=p_token FOR UPDATE;
 IF saved.restored_at IS NOT NULL THEN RETURN 'duplicate'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.mp_inventory_specs() WHERE ecommerce_id=saved.new_owner AND pool_key=saved.pool_key) THEN
  RAISE EXCEPTION 'Inventory specification changed: review owner rollback'; END IF;
 SELECT jsonb_agg(jsonb_build_object('id',e.nocopk,'value',e.is_primary_public_listing) ORDER BY e.nocopk)
 INTO current_flags FROM public.ecommerce e JOIN public.mp_inventory_specs() s ON s.ecommerce_id=e.nocopk WHERE s.pool_key=saved.pool_key;
 IF current_flags IS DISTINCT FROM saved.after_flags THEN RAISE EXCEPTION 'Pool membership/flags changed: review owner rollback'; END IF;
 FOR entry IN SELECT value FROM jsonb_array_elements(saved.before_flags) LOOP
  UPDATE public.ecommerce SET is_primary_public_listing=(entry->>'value')::boolean WHERE nocopk=(entry->>'id')::bigint;
 END LOOP;
 UPDATE public.mp_commerce_pool_owner_changes SET restored_at=now() WHERE token=p_token;
 RETURN 'restored';
END $$;
REVOKE ALL ON FUNCTION public.mp_commerce_select_woo_inventory_owner(bigint,bigint),public.mp_commerce_restore_inventory_owner(uuid) FROM PUBLIC;
COMMIT;
