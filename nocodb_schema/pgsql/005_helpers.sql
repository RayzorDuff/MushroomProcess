-- 005_helpers.sql

CREATE OR REPLACE FUNCTION public.mp_events_insert(
  p_type text,
  p_timestamp timestamp without time zone,
  p_operator text,
  p_station text,
  p_fields_json text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  v_id bigint;
BEGIN
  INSERT INTO "public"."events" ("type","timestamp","operator","station","fields_json")
  VALUES (p_type, p_timestamp, p_operator, p_station, p_fields_json)
  RETURNING "nocopk" INTO v_id;

  RETURN v_id;
END;
$$;

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

CREATE OR REPLACE FUNCTION public.mp_print_queue_enqueue(
  p_source_kind text,
  p_lot_id bigint DEFAULT NULL,
  p_product_id bigint DEFAULT NULL,
  p_run_id bigint DEFAULT NULL,
  p_printer text DEFAULT NULL,
  p_label text DEFAULT NULL,
  p_printed_at timestamp without time zone DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  v_pq_id bigint;
BEGIN
  INSERT INTO "public"."print_queue" ("source_kind","printer","label","printed_at","lot_id","product_id")
  VALUES (p_source_kind, p_printer, p_label, p_printed_at, p_lot_id, p_product_id)
  RETURNING "nocopk" INTO v_pq_id;

  -- mirror Airtable linking fields via the m2m tables (even if lot_id/product_id are also set)
  IF p_lot_id IS NOT NULL THEN
    INSERT INTO "public"."_m2m_print_queue_lots_lot_id" ("print_queue_id","lots_id")
    VALUES (v_pq_id, p_lot_id)
    ON CONFLICT DO NOTHING;
  END IF;

  IF p_product_id IS NOT NULL THEN
    INSERT INTO "public"."_m2m_print_queue_products_product_id" ("print_queue_id","products_id")
    VALUES (v_pq_id, p_product_id)
    ON CONFLICT DO NOTHING;
  END IF;

  IF p_run_id IS NOT NULL THEN
    INSERT INTO "public"."_m2m_print_queue_sterilization_runs_run_id" ("print_queue_id","sterilization_runs_id")
    VALUES (v_pq_id, p_run_id)
    ON CONFLICT DO NOTHING;
  END IF;

  RETURN v_pq_id;
END;
$$;

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