-- 005_helpers.sql

-- 1) Insert an event row and return its PK.
--    If you want stricter typing later, change fields_json to jsonb.
CREATE OR REPLACE FUNCTION public.mp_events_insert(
  p_lot_id bigint DEFAULT NULL,
  p_product_id bigint DEFAULT NULL,
  p_type text DEFAULT 'system',
  p_timestamp timestamp without time zone DEFAULT now(),
  p_operator text DEFAULT 'system',
  p_station text DEFAULT 'system',
  p_fields_json jsonb DEFAULT '{}'::jsonb
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  v_id bigint;
BEGIN
  INSERT INTO "public"."events" ("lot_id", "product_id", "type","timestamp","operator","station","fields_json")
  VALUES (p_lot_id, p_product_id, p_type, COALESCE(p_timestamp, now()), p_operator, p_station, COALESCE(p_fields_json, '{}'::jsonb))
  RETURNING "nocopk" INTO v_id;

  RETURN v_id;
END;
$$;

-- 2) Link an event to a lot (Airtable "linked record" equivalent).
CREATE OR REPLACE FUNCTION public.mp_events_link_lot(
  p_event_id bigint,
  p_lot_id bigint
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO "public"."_m2m_lots_events_events" ("lots_id","events_id")
  VALUES (p_lot_id, p_event_id)
  ON CONFLICT DO NOTHING;
END;
$$;

-- Convenience helper: insert + link to lot (optional)
CREATE OR REPLACE FUNCTION public.mp_events_insert_and_link_lot(
  p_lot_id       bigint,
  p_type         text,
  p_timestamp    timestamp without time zone,
  p_operator     text,
  p_station      text,
  p_fields_json  jsonb DEFAULT '{}'::jsonb
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  v_event_id bigint;
BEGIN
  v_event_id := public.mp_events_insert(
    p_lot_id::bigint, 
    NULL::bigint, 
    p_type::text, 
    p_timestamp::timestamp without time zone, 
    p_operator::text, 
    p_station::text, 
    p_fields_json::jsonb
  );
  -- link if helper exists
  BEGIN
    PERFORM public.mp_events_link_lot(
      v_event_id::bigint, 
	  p_lot_id::bigint
	);
  EXCEPTION WHEN undefined_function THEN
    -- If mp_events_link_lot isn't present yet, don't fail the whole action.
    NULL;
  END;
  RETURN v_event_id;
END;
$$;

-- Enqueue a print job and (optionally) link it to lot/product/run
CREATE OR REPLACE FUNCTION public.mp_print_queue_enqueue(
  p_source_kind text,
  p_label_type text,
  p_lot_id bigint DEFAULT NULL,
  p_product_id bigint DEFAULT NULL,
  p_run_id bigint DEFAULT NULL,
  p_print_status text DEFAULT 'Queued'
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  v_pq_id bigint;
BEGIN
  -- Create the queue record. The print-daemon will later set claimed_* and printed_* fields.
  INSERT INTO "public"."print_queue"
    ("source_kind","label_type","print_status","lot_id","product_id","run_id","created_at")
  VALUES
    (p_source_kind, p_label_type, p_print_status, p_lot_id, p_product_id, p_run_id, now())
  RETURNING "nocopk" INTO v_pq_id;

  -- Maintain Airtable-style multi-link fields (lots.print_queue / products.print_queue / sterilization_runs.print_queue)
  IF p_lot_id IS NOT NULL THEN
    BEGIN
      INSERT INTO "public"."_m2m_lots_print_queue_print_queue" ("lots_id","print_queue_id")
      VALUES (p_lot_id, v_pq_id)
      ON CONFLICT DO NOTHING;
    EXCEPTION WHEN undefined_table THEN NULL;
    END;
  END IF;

  IF p_product_id IS NOT NULL THEN
    BEGIN
      INSERT INTO "public"."_m2m_products_print_queue_print_queue" ("products_id","print_queue_id")
      VALUES (p_product_id, v_pq_id)
      ON CONFLICT DO NOTHING;
    EXCEPTION WHEN undefined_table THEN NULL;
    END;
  END IF;

  IF p_run_id IS NOT NULL THEN
    BEGIN
      INSERT INTO "public"."_m2m_sterilization_runs_print_queue_print_queue" ("sterilization_runs_id","print_queue_id")
      VALUES (p_run_id, v_pq_id)
      ON CONFLICT DO NOTHING;
    EXCEPTION WHEN undefined_table THEN NULL;
    END;
  END IF;

  -- Derived canonical FK link tables (e.g., _m2m_print_queue_lots_lot_id) are maintained by existing sync triggers on print_queue.lot_id/product_id
  RETURN v_pq_id;
END;
$$;

-- Link a sterilization run to a lot (maintains both NocoDB-style link tables, if present).
-- Safe to call even if one of the link tables is not used by your UI.
CREATE OR REPLACE FUNCTION public.mp_link_sterilization_run_lot(
  p_run_id bigint,
  p_lot_id bigint
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  -- Link table generated from lots.steri_run_id style relationship
  BEGIN
    INSERT INTO "public"."_m2m_lots_sterilization_runs_steri_run_id" ("lots_id","sterilization_runs_id")
    VALUES (p_lot_id, p_run_id)
    ON CONFLICT DO NOTHING;
  EXCEPTION WHEN undefined_table THEN
    -- ignore if table doesn't exist in this deployment
    NULL;
  END;

  -- Link table generated from sterilization_runs.lots style relationship (inverse direction)
  BEGIN
    INSERT INTO "public"."_m2m_sterilization_runs_lots_lots" ("sterilization_runs_id","lots_id")
    VALUES (p_run_id, p_lot_id)
    ON CONFLICT DO NOTHING;
  EXCEPTION WHEN undefined_table THEN
    NULL;
  END;
END;
$$;

-- Link a lot to an item (maintains both NocoDB-style link tables, if present).
CREATE OR REPLACE FUNCTION public.mp_link_lot_item(
  p_lot_id bigint,
  p_item_id bigint
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  IF p_item_id IS NULL THEN
    RETURN;
  END IF;

  BEGIN
    INSERT INTO "public"."_m2m_lots_items_item_id" ("lots_id","items_id")
    VALUES (p_lot_id, p_item_id)
    ON CONFLICT DO NOTHING;
  EXCEPTION WHEN undefined_table THEN NULL;
  END;

  BEGIN
    INSERT INTO "public"."_m2m_items_lots_lots" ("items_id","lots_id")
    VALUES (p_item_id, p_lot_id)
    ON CONFLICT DO NOTHING;
  EXCEPTION WHEN undefined_table THEN NULL;
  END;

  -- Some schemas include a second inverse link table; keep it in sync if present.
  BEGIN
    INSERT INTO "public"."_m2m_items_lots_lots_2" ("items_id","lots_id")
    VALUES (p_item_id, p_lot_id)
    ON CONFLICT DO NOTHING;
  EXCEPTION WHEN undefined_table THEN NULL;
  END;
END;
$$;

-- Link a lot to a recipe (maintains both NocoDB-style link tables, if present).
CREATE OR REPLACE FUNCTION public.mp_link_lot_recipe(
  p_lot_id bigint,
  p_recipe_id bigint
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  IF p_recipe_id IS NULL THEN
    RETURN;
  END IF;

  BEGIN
    INSERT INTO "public"."_m2m_lots_recipes_recipe_id" ("lots_id","recipes_id")
    VALUES (p_lot_id, p_recipe_id)
    ON CONFLICT DO NOTHING;
  EXCEPTION WHEN undefined_table THEN NULL;
  END;

  BEGIN
    INSERT INTO "public"."_m2m_recipes_lots_lots" ("recipes_id","lots_id")
    VALUES (p_recipe_id, p_lot_id)
    ON CONFLICT DO NOTHING;
  EXCEPTION WHEN undefined_table THEN NULL;
  END;
END;
$$;
