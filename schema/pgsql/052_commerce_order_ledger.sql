-- Additive provider-neutral inbox/reservations. No production lineage mutations.
BEGIN;
CREATE TABLE IF NOT EXISTS public.mp_commerce_orders (
  provider text NOT NULL, site_key text NOT NULL, external_order_id text NOT NULL,
  revision bigint NOT NULL, status text NOT NULL,
  snapshot jsonb NOT NULL, fulfilled boolean NOT NULL DEFAULT false,
  inventory_committed boolean NOT NULL DEFAULT false,
  PRIMARY KEY(provider,site_key,external_order_id)
);
CREATE TABLE IF NOT EXISTS public.mp_commerce_events (
  provider text NOT NULL, site_key text NOT NULL, event_id text NOT NULL,
  external_order_id text NOT NULL, payload jsonb NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(provider,site_key,event_id)
);
CREATE TABLE IF NOT EXISTS public.mp_commerce_reservations (
  provider text NOT NULL, site_key text NOT NULL, external_order_id text NOT NULL,
  line_id text NOT NULL, ecommerce_id bigint NOT NULL REFERENCES public.ecommerce(nocopk),
  item_id bigint NOT NULL, strain_id bigint, quantity bigint NOT NULL CHECK(quantity>0),
  PRIMARY KEY(provider,site_key,external_order_id,line_id),
  FOREIGN KEY(provider,site_key,external_order_id)
    REFERENCES public.mp_commerce_orders(provider,site_key,external_order_id)
);
CREATE TABLE IF NOT EXISTS public.mp_commerce_payment_matches (
  processor text NOT NULL, site_key text NOT NULL, payment_id text NOT NULL,
  provider text NOT NULL, external_order_id text NOT NULL,
  evidence jsonb NOT NULL,
  PRIMARY KEY(processor,site_key,payment_id),
  UNIQUE(provider,site_key,external_order_id),
  FOREIGN KEY(provider,site_key,external_order_id)
    REFERENCES public.mp_commerce_orders(provider,site_key,external_order_id)
);

CREATE OR REPLACE FUNCTION public.mp_commerce_ingest(p jsonb) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  provider_key text := p->>'provider'; site text := p->>'site_key';
  order_id text := p->>'external_order_id'; event_key text := p->>'event_id';
  previous public.mp_commerce_orders%ROWTYPE; old_event jsonb;
  line jsonb; candidate record; reserved bigint; duplicate_lines bigint;
  refund_total numeric; previous_refund jsonb;
BEGIN
  -- Serialize admissions across provider aliases that share physical inventory.
  -- This deliberately conservative global lock trades throughput for safety.
  PERFORM pg_advisory_xact_lock(520052);
  IF jsonb_typeof(p)<>'object' OR p->>'schema_version' IS DISTINCT FROM '1'
     OR COALESCE(btrim(provider_key),'')='' OR COALESCE(btrim(site),'')=''
     OR COALESCE(btrim(order_id),'')='' OR COALESCE(btrim(event_key),'')=''
     OR COALESCE(p->>'revision','') !~ '^[0-9]+$'
     OR COALESCE(p->>'currency','') !~ '^[A-Z]{3}$'
     OR COALESCE(p->>'total','') !~ '^[0-9]+(\.[0-9]+)?$'
     OR COALESCE(p->>'status','') NOT IN ('pending','on-hold','processing','completed','cancelled','failed','refunded')
     OR jsonb_typeof(p->'lines') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'lines')=0
     OR jsonb_typeof(p->'refunds') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Invalid normalized commerce event';
  END IF;
  SELECT payload INTO old_event FROM public.mp_commerce_events
    WHERE provider=provider_key AND site_key=site AND event_id=event_key;
  IF FOUND THEN
    IF old_event IS DISTINCT FROM p THEN RAISE EXCEPTION 'Event identity reused with different payload'; END IF;
    RETURN 'duplicate';
  END IF;
  SELECT * INTO previous FROM public.mp_commerce_orders
    WHERE provider=provider_key AND site_key=site AND external_order_id=order_id FOR UPDATE;
  IF FOUND THEN
    IF (p->>'revision')::bigint < previous.revision THEN RETURN 'stale'; END IF;
    IF (p->>'revision')::bigint = previous.revision THEN
      IF (p-'event_id') IS DISTINCT FROM (previous.snapshot-'event_id') THEN
        RAISE EXCEPTION 'Same-revision conflict; fetch current authoritative order';
      END IF;
      INSERT INTO public.mp_commerce_events VALUES(provider_key,site,event_key,order_id,p,now());
      RETURN 'duplicate';
    END IF;
    IF p->'lines' IS DISTINCT FROM previous.snapshot->'lines'
       OR p->>'currency' IS DISTINCT FROM previous.snapshot->>'currency'
       OR (p->>'total')::numeric IS DISTINCT FROM (previous.snapshot->>'total')::numeric THEN
      RAISE EXCEPTION 'Order line/currency/total edit requires manual reconciliation';
    END IF;
    IF previous.status IN ('cancelled','failed','refunded') AND p->>'status' NOT IN ('cancelled','failed','refunded') THEN
      RAISE EXCEPTION 'Terminal order cannot be reopened automatically';
    END IF;
    IF NULLIF(previous.snapshot->>'processor_payment_id','') IS NOT NULL
       AND p->>'processor_payment_id' IS DISTINCT FROM previous.snapshot->>'processor_payment_id' THEN
      RAISE EXCEPTION 'Payment identity drift';
    END IF;
    FOR previous_refund IN SELECT value FROM jsonb_array_elements(previous.snapshot->'refunds') LOOP
      IF NOT (p->'refunds' @> jsonb_build_array(previous_refund)) THEN
        RAISE EXCEPTION 'Refund history cannot disappear or change';
      END IF;
    END LOOP;
  END IF;
  SELECT count(*)-count(DISTINCT value->>'line_id') INTO duplicate_lines FROM jsonb_array_elements(p->'lines');
  IF duplicate_lines<>0 THEN RAISE EXCEPTION 'Duplicate line identities'; END IF;
  SELECT count(*)-count(DISTINCT value->>'external_refund_id') INTO duplicate_lines FROM jsonb_array_elements(p->'refunds');
  IF duplicate_lines<>0 THEN RAISE EXCEPTION 'Duplicate refund identities'; END IF;
  FOR line IN SELECT value FROM jsonb_array_elements(p->'refunds') LOOP
    IF COALESCE(btrim(line->>'external_refund_id'),'')='' OR COALESCE(line->>'amount','') !~ '^[0-9]+(\.[0-9]+)?$' THEN
      RAISE EXCEPTION 'Invalid refund snapshot';
    END IF;
  END LOOP;
  SELECT coalesce(sum((value->>'amount')::numeric),0) INTO refund_total FROM jsonb_array_elements(p->'refunds');
  IF refund_total>(p->>'total')::numeric OR (p->>'status'='refunded' AND refund_total<>(p->>'total')::numeric) THEN
    RAISE EXCEPTION 'Refund total mismatch';
  END IF;
  INSERT INTO public.mp_commerce_orders(provider,site_key,external_order_id,revision,status,snapshot)
    VALUES(provider_key,site,order_id,(p->>'revision')::bigint,p->>'status',p)
    ON CONFLICT(provider,site_key,external_order_id) DO UPDATE
      SET revision=excluded.revision,status=excluded.status,snapshot=excluded.snapshot;
  -- Fulfilled orders retain their hold until the operator commits physical stock
  -- movement. Refunds never restock shipped products or create return lineage.
  IF NOT coalesce(previous.fulfilled,false) THEN
    DELETE FROM public.mp_commerce_reservations
      WHERE provider=provider_key AND site_key=site AND external_order_id=order_id;
    IF p->>'status' NOT IN ('cancelled','failed','refunded') THEN
      FOR line IN SELECT value FROM jsonb_array_elements(p->'lines') LOOP
        IF COALESCE(line->>'line_id','')='' OR COALESCE(line->>'quantity','') !~ '^[1-9][0-9]*$' THEN
          RAISE EXCEPTION 'Invalid operational line';
        END IF;
        SELECT * INTO candidate FROM public.mp_ecommerce_catalog_inventory()
          WHERE ecommerce_id=(line->>'ecommerce_id')::bigint;
        IF NOT FOUND OR candidate.provider<>provider_key OR candidate.site_key<>site
           OR candidate.erp_item_code IS DISTINCT FROM line->>'erp_item_code'
           OR candidate.erp_item_code IS NULL THEN RAISE EXCEPTION 'Unapproved operational mapping'; END IF;
        SELECT coalesce(sum(quantity),0) INTO reserved FROM public.mp_commerce_reservations
          WHERE item_id=candidate.item_id AND strain_id IS NOT DISTINCT FROM candidate.strain_id;
        IF candidate.desired_quantity-reserved < (line->>'quantity')::bigint THEN
          RAISE EXCEPTION 'Insufficient sellable operational quantity';
        END IF;
        INSERT INTO public.mp_commerce_reservations VALUES(provider_key,site,order_id,line->>'line_id',
          candidate.ecommerce_id,candidate.item_id,candidate.strain_id,(line->>'quantity')::bigint);
      END LOOP;
    END IF;
  END IF;
  INSERT INTO public.mp_commerce_events VALUES(provider_key,site,event_key,order_id,p,now());
  RETURN 'applied';
END $$;

CREATE OR REPLACE FUNCTION public.mp_commerce_inventory() RETURNS TABLE(ecommerce_id bigint, available_quantity bigint)
LANGUAGE sql STABLE AS $$
  SELECT c.ecommerce_id,greatest(0,c.desired_quantity-coalesce(r.quantity,0))::bigint
  FROM public.mp_ecommerce_catalog_inventory() c
  LEFT JOIN LATERAL (SELECT sum(quantity) quantity FROM public.mp_commerce_reservations
    WHERE item_id=c.item_id AND strain_id IS NOT DISTINCT FROM c.strain_id) r ON true;
$$;

-- Explicit operator-only acknowledgment AFTER operational fulfillment has moved
-- products/lots out of sellable inventory. Caller supplies an auditable reference.
ALTER TABLE public.mp_commerce_orders ADD COLUMN IF NOT EXISTS fulfillment_reference text;
CREATE OR REPLACE FUNCTION public.mp_commerce_commit_fulfillment(p_provider text,p_site text,p_order text,p_reference text)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE o public.mp_commerce_orders%ROWTYPE;
BEGIN
  PERFORM pg_advisory_xact_lock(520052);
  IF coalesce(btrim(p_reference),'')='' THEN RAISE EXCEPTION 'Operational movement reference required'; END IF;
  SELECT * INTO STRICT o FROM public.mp_commerce_orders WHERE provider=p_provider AND site_key=p_site
    AND external_order_id=p_order FOR UPDATE;
  IF o.inventory_committed THEN
    IF o.fulfillment_reference<>p_reference THEN RAISE EXCEPTION 'Fulfillment identity drift'; END IF;
    RETURN 'duplicate';
  END IF;
  IF o.status IN ('cancelled','failed','refunded') THEN RAISE EXCEPTION 'Terminal order requires manual fulfillment review'; END IF;
  UPDATE public.mp_commerce_orders SET fulfilled=true,inventory_committed=true,fulfillment_reference=p_reference
    WHERE provider=p_provider AND site_key=p_site AND external_order_id=p_order;
  DELETE FROM public.mp_commerce_reservations WHERE provider=p_provider AND site_key=p_site AND external_order_id=p_order;
  RETURN 'committed';
END $$;

-- This function accepts evidence only from the trusted verification adapter role.
-- Never grant it to the webhook receiver; Woo status is not capture evidence.
CREATE OR REPLACE FUNCTION public.mp_commerce_match_payment(p jsonb) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE o public.mp_commerce_orders%ROWTYPE; old_match public.mp_commerce_payment_matches%ROWTYPE;
BEGIN
  PERFORM pg_advisory_xact_lock(520052);
  SELECT * INTO STRICT o FROM public.mp_commerce_orders
    WHERE provider=p->>'provider' AND site_key=p->>'site_key' AND external_order_id=p->>'external_order_id' FOR UPDATE;
  IF p->>'processor' IS DISTINCT FROM 'clover' OR p->>'verification' IS DISTINCT FROM 'verified_adapter'
     OR p->>'state' IS DISTINCT FROM 'captured'
     OR coalesce(p->>'payment_id','')='' OR p->>'payment_id' IS DISTINCT FROM o.snapshot->>'processor_payment_id'
     OR p->>'currency' IS DISTINCT FROM o.snapshot->>'currency'
     OR coalesce(p->>'captured_amount','') !~ '^[0-9]+(\.[0-9]+)?$'
     OR coalesce(p->>'refunded_amount','') !~ '^[0-9]+(\.[0-9]+)?$' THEN
    RAISE EXCEPTION 'Invalid verified payment evidence';
  END IF;
  IF (p->>'captured_amount')::numeric<>(o.snapshot->>'total')::numeric
     OR (p->>'refunded_amount')::numeric<>(SELECT coalesce(sum((value->>'amount')::numeric),0)
       FROM jsonb_array_elements(o.snapshot->'refunds')) THEN
    RAISE EXCEPTION 'Capture/refund reconciliation mismatch';
  END IF;
  SELECT * INTO old_match FROM public.mp_commerce_payment_matches
    WHERE processor=p->>'processor' AND site_key=p->>'site_key' AND payment_id=p->>'payment_id';
  IF FOUND AND (old_match.provider<>p->>'provider' OR old_match.external_order_id<>p->>'external_order_id') THEN
    RAISE EXCEPTION 'Payment already belongs to another order';
  END IF;
  INSERT INTO public.mp_commerce_payment_matches VALUES(p->>'processor',p->>'site_key',p->>'payment_id',
    p->>'provider',p->>'external_order_id',p)
    ON CONFLICT(processor,site_key,payment_id) DO UPDATE SET evidence=excluded.evidence;
  RETURN 'matched';
END $$;

-- Invoker rights; new write functions are unavailable to PUBLIC. Deployment must
-- grant the inbox function only to an authenticated integration role, and the
-- fulfillment acknowledgment only to the operational fulfillment role.
REVOKE ALL ON FUNCTION public.mp_commerce_ingest(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mp_commerce_commit_fulfillment(text,text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mp_commerce_match_payment(jsonb) FROM PUBLIC;
COMMIT;
