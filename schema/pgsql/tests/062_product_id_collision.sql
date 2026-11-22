\set ON_ERROR_STOP on
BEGIN;
DO $$ DECLARE first_id bigint;second_id bigint;first_code text;second_code text;stamp timestamp:='2099-01-01T12:00:00';
BEGIN
 INSERT INTO products(nocouuid,nc_created_at) VALUES('00000000-0000-4000-8000-00000000abcd',stamp) RETURNING nocopk,product_id INTO first_id,first_code;
 INSERT INTO products(nocouuid,nc_created_at) VALUES('11111111-1111-4111-8111-11111111abcd',stamp) RETURNING nocopk,product_id INTO second_id,second_code;
 IF first_code<>'PROD-990101-abcd' OR second_code=first_code OR second_code<>first_code||'-'||second_id::text THEN RAISE EXCEPTION 'Forced suffix collision not resolved'; END IF;
 UPDATE products SET notes='updated' WHERE nocopk=first_id;
 IF (SELECT product_id FROM products WHERE nocopk=first_id)<>first_code THEN RAISE EXCEPTION 'Existing QR identity changed'; END IF;
 IF (SELECT nocouuid FROM products WHERE nocopk=second_id)<>'11111111-1111-4111-8111-11111111abcd'::uuid THEN RAISE EXCEPTION 'UUID changed to hide collision'; END IF;
 BEGIN
  INSERT INTO products(product_id) VALUES(first_code);RAISE EXCEPTION 'BAD duplicate explicit ID accepted';
 EXCEPTION WHEN unique_violation THEN NULL; END;
 INSERT INTO products(nocouuid,nc_created_at)
 SELECT (lpad(to_hex(i),8,'0')||'-0000-4000-8000-00000000abcd')::uuid,stamp FROM generate_series(2,12) i;
 IF (SELECT count(DISTINCT product_id) FROM products WHERE nc_created_at=stamp)<>13 THEN RAISE EXCEPTION 'Bulk collision uniqueness'; END IF;
 RAISE NOTICE '062 deterministic collision: unchanged old IDs/UUIDs, explicit duplicate refusal and bulk unique allocation passed';
END $$;
ROLLBACK;
