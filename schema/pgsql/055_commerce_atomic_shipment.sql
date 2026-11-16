-- One operational transaction for physical Product movement and its order acknowledgment.
BEGIN;
CREATE OR REPLACE FUNCTION public.mp_commerce_ship_products(
    p_provider text, p_site text, p_order text, p_reference text, p_lines jsonb)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    shipped_location bigint;
    target_count bigint;
    target record;
    v_product_id bigint;
BEGIN
    PERFORM pg_advisory_xact_lock(520052);
    IF EXISTS (SELECT 1 FROM public.mp_commerce_shipments
        WHERE provider=p_provider AND site_key=p_site AND movement_reference=p_reference) THEN
        RETURN public.mp_commerce_acknowledge_products(p_provider,p_site,p_order,p_reference,p_lines);
    END IF;
    IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lines)=0 THEN
        RAISE EXCEPTION 'Nonempty shipment lines required';
    END IF;
    SELECT min(nocopk),count(*) INTO shipped_location,target_count FROM public.locations
      WHERE active AND regexp_replace(lower(name),'[^a-z0-9]','','g')='shipped';
    IF target_count<>1 THEN RAISE EXCEPTION 'One active Shipped location required'; END IF;

    FOR v_product_id IN
        SELECT DISTINCT (pid #>> '{}')::bigint
        FROM jsonb_array_elements(p_lines) line
        CROSS JOIN LATERAL jsonb_array_elements(line->'product_ids') pid
        ORDER BY 1
    LOOP
        SELECT p.use_by, l.active,
               regexp_replace(lower(l.name),'[^a-z0-9]','','g') AS location
          INTO STRICT target
          FROM public.products p JOIN public.locations l ON l.nocopk=p.storage_location_id
          WHERE p.nocopk=v_product_id FOR UPDATE OF p;
        IF target.active IS NOT TRUE OR target.use_by<CURRENT_DATE OR target.location IN
            ('shipped','consumed','expired','compost','composted','retired','missing','missingorlost') THEN
            RAISE EXCEPTION 'Product is not eligible for a new shipment';
        END IF;
        PERFORM public.mp_product_set_storage_location(v_product_id, shipped_location);
    END LOOP;
    RETURN public.mp_commerce_acknowledge_products(p_provider,p_site,p_order,p_reference,p_lines);
END $$;
REVOKE ALL ON FUNCTION public.mp_commerce_ship_products(text,text,text,text,jsonb) FROM PUBLIC;
COMMIT;
