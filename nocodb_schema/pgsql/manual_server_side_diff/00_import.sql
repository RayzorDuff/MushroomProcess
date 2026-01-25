--
-- Extracted from NocoDB NC_DB diff: schema/data for base pjeqn1nkx5sas6e
-- Source: after.sql minus before.sql, filtered to this base schema only.
--
SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

CREATE SCHEMA pjeqn1nkx5sas6e;


ALTER SCHEMA pjeqn1nkx5sas6e OWNER TO nocodb;
CREATE TABLE pjeqn1nkx5sas6e._nc_m2m_lots_lots (
	    lots1_id bigint NOT NULL,
	    lots_id bigint NOT NULL
);
ALTER TABLE pjeqn1nkx5sas6e._nc_m2m_lots_lots OWNER TO nocodb;

--
-- Name: _nc_m2m_lots_lots1; Type: TABLE; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE TABLE pjeqn1nkx5sas6e._nc_m2m_lots_lots1 (
	    lots1_id bigint NOT NULL,
	    lots_id bigint NOT NULL
);
ALTER TABLE pjeqn1nkx5sas6e._nc_m2m_lots_lots1 OWNER TO nocodb;

--
-- Name: _nc_m2m_lots_lots2; Type: TABLE; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE TABLE pjeqn1nkx5sas6e._nc_m2m_lots_lots2 (
	    lots1_id bigint NOT NULL,
	    lots_id bigint NOT NULL
);
ALTER TABLE pjeqn1nkx5sas6e._nc_m2m_lots_lots2 OWNER TO nocodb;

--
-- Name: _nc_m2m_lots_products; Type: TABLE; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE TABLE pjeqn1nkx5sas6e._nc_m2m_lots_products (
	    products_id bigint NOT NULL,
	    lots_id bigint NOT NULL
);
ALTER TABLE pjeqn1nkx5sas6e._nc_m2m_lots_products OWNER TO nocodb;

--
-- Name: _nc_m2m_lots_recipes; Type: TABLE; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE TABLE pjeqn1nkx5sas6e._nc_m2m_lots_recipes (
	    recipes_id bigint NOT NULL,
	    lots_id bigint NOT NULL
);
ALTER TABLE pjeqn1nkx5sas6e._nc_m2m_lots_recipes OWNER TO nocodb;

--
-- Name: _nc_m2m_products_products; Type: TABLE; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE TABLE pjeqn1nkx5sas6e._nc_m2m_products_products (
	    products1_id bigint NOT NULL,
	    products_id bigint NOT NULL
);
ALTER TABLE pjeqn1nkx5sas6e._nc_m2m_products_products OWNER TO nocodb;

--
-- Name: ecommerce; Type: TABLE; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE TABLE pjeqn1nkx5sas6e.ecommerce (
	    nocopk bigint NOT NULL,
	    created_at timestamp without time zone,
	    updated_at timestamp without time zone,
	    created_by character varying,
	    updated_by character varying,
	    nc_order numeric,
	    nocouuid uuid DEFAULT gen_random_uuid(),
	    name text,
	    status text,
	    ecwid_sku text,
	    sync_to_ecwid boolean DEFAULT false,
	    notes text,
	    ecwid_category text,
	    ecwid_price numeric,
	    ecwid_stock bigint,
	    ecwid_url text,
	    ecwid_image text
);
ALTER TABLE pjeqn1nkx5sas6e.ecommerce OWNER TO nocodb;

--
-- Name: ecommerce_nocopk_seq; Type: SEQUENCE; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE SEQUENCE pjeqn1nkx5sas6e.ecommerce_nocopk_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
CREATE TABLE pjeqn1nkx5sas6e.ecommerce_orders (
	    nocopk bigint NOT NULL,
	    created_at timestamp without time zone,
	    updated_at timestamp without time zone,
	    created_by character varying,
	    updated_by character varying,
	    nc_order numeric,
	    nocouuid uuid DEFAULT gen_random_uuid(),
	    name text,
	    ecwid_order_id text,
	    order_number bigint,
	    status text,
	    order_date timestamp without time zone,
	    customer_name text,
	    customer_email text,
	    items_json text,
	    ecwid_skus text
);
ALTER TABLE pjeqn1nkx5sas6e.ecommerce_orders OWNER TO nocodb;

--
-- Name: ecommerce_orders_nocopk_seq; Type: SEQUENCE; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE SEQUENCE pjeqn1nkx5sas6e.ecommerce_orders_nocopk_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
CREATE TABLE pjeqn1nkx5sas6e.events (
	    nocopk bigint NOT NULL,
	    created_at timestamp without time zone,
	    updated_at timestamp without time zone,
	    created_by character varying,
	    updated_by character varying,
	    nc_order numeric,
	    nocouuid uuid DEFAULT gen_random_uuid(),
	    event_id text,
	    event_id_legacy text,
	    type text,
	    "timestamp" timestamp without time zone,
	    operator text,
	    station text,
	    fields_json text,
	    lots text
);
ALTER TABLE pjeqn1nkx5sas6e.events OWNER TO nocodb;

--
-- Name: events_nocopk_seq; Type: SEQUENCE; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE SEQUENCE pjeqn1nkx5sas6e.events_nocopk_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
CREATE TABLE pjeqn1nkx5sas6e.items (
	    nocopk bigint NOT NULL,
	    created_at timestamp without time zone,
	    updated_at timestamp without time zone,
	    created_by character varying,
	    updated_by character varying,
	    nc_order numeric,
	    nocouuid uuid DEFAULT gen_random_uuid(),
	    item_id text,
	    name text,
	    category text,
	    default_unit_size_lb numeric,
	    default_unit_size_ml numeric,
	    default_unit_size_oz numeric,
	    default_unit_size_g numeric,
	    default_unit_size text
);
ALTER TABLE pjeqn1nkx5sas6e.items OWNER TO nocodb;

--
-- Name: items_nocopk_seq; Type: SEQUENCE; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE SEQUENCE pjeqn1nkx5sas6e.items_nocopk_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
CREATE TABLE pjeqn1nkx5sas6e.locations (
	    nocopk bigint NOT NULL,
	    created_at timestamp without time zone,
	    updated_at timestamp without time zone,
	    created_by character varying,
	    updated_by character varying,
	    nc_order numeric,
	    nocouuid uuid DEFAULT gen_random_uuid(),
	    name text,
	    type text,
	    notes text
);
ALTER TABLE pjeqn1nkx5sas6e.locations OWNER TO nocodb;

--
-- Name: locations_nocopk_seq; Type: SEQUENCE; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE SEQUENCE pjeqn1nkx5sas6e.locations_nocopk_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
CREATE TABLE pjeqn1nkx5sas6e.lots (
	    nocopk bigint NOT NULL,
	    created_at1 timestamp without time zone,
	    updated_at timestamp without time zone,
	    created_by character varying,
	    updated_by character varying,
	    nc_order numeric,
	    nocouuid uuid DEFAULT gen_random_uuid(),
	    lot_id text,
	    lot_id_legacy text,
	    item_name_mat text,
	    qty bigint,
	    unit_size numeric,
	    status text,
	    parents_json text,
	    operator text,
	    created_at timestamp without time zone,
	    use_by date,
	    action text,
	    item_category_mat text,
	    process_type_mat text,
	    lc_volume_ml numeric,
	    output_count bigint,
	    fruiting_goal text,
	    flush_no bigint,
	    harvest_weight_g numeric,
	    notes text,
	    syringe_count bigint,
	    source_type text,
	    vendor_name text,
	    vendor_batch text,
	    received_date date,
	    total_volume_ml numeric,
	    ui_error text,
	    ui_error_at timestamp without time zone,
	    remaining_volume_ml numeric,
	    fresh_tray_count bigint,
	    frozen_tray_count bigint,
	    casing_applied_at timestamp without time zone,
	    casing_notes text,
	    casing_qty_used_g numeric,
	    label_template text,
	    override_inoc_time timestamp without time zone,
	    inoculated_at timestamp without time zone,
	    override_spawn_time timestamp without time zone,
	    spawned_at timestamp without time zone,
	    sterilized_at timestamp without time zone,
	    plate_count bigint,
	    plate_group_id text,
	    strains_id bigint,
	    lots_id bigint,
	    lots_id1 bigint,
	    lots_id2 bigint,
	    sterilization_runs_id bigint,
	    label_inoc_line_formula_src_fallback text,
	    label_spawned_line_formula_src_fallback text,
	    label_graininputblocks_line_formula_src_fallback text,
	    label_substrateinputblocks_line_formula_src_fallback text
);
ALTER TABLE pjeqn1nkx5sas6e.lots OWNER TO nocodb;

--
-- Name: lots_nocopk_seq; Type: SEQUENCE; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE SEQUENCE pjeqn1nkx5sas6e.lots_nocopk_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
CREATE TABLE pjeqn1nkx5sas6e.print_queue (
	    nocopk bigint NOT NULL,
	    created_at1 timestamp without time zone,
	    updated_at timestamp without time zone,
	    created_by character varying,
	    updated_by character varying,
	    nc_order numeric,
	    nocouuid uuid DEFAULT gen_random_uuid(),
	    print_id text,
	    print_id_legacy text,
	    source_kind text,
	    print_status text,
	    label_type text,
	    error_msg text,
	    created_at timestamp without time zone,
	    claimed_by text,
	    claimed_at timestamp without time zone,
	    printed_by text,
	    printed_at timestamp without time zone,
	    pdf_path text
);
ALTER TABLE pjeqn1nkx5sas6e.print_queue OWNER TO nocodb;

--
-- Name: print_queue_nocopk_seq; Type: SEQUENCE; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE SEQUENCE pjeqn1nkx5sas6e.print_queue_nocopk_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
CREATE TABLE pjeqn1nkx5sas6e.products (
	    nocopk bigint NOT NULL,
	    created_at timestamp without time zone,
	    updated_at timestamp without time zone,
	    created_by character varying,
	    updated_by character varying,
	    nc_order numeric,
	    nocouuid uuid DEFAULT gen_random_uuid(),
	    product_id text,
	    product_id_legacy text,
	    name_mat text,
	    item_category_mat text,
	    net_weight_g numeric,
	    net_weight_oz numeric,
	    net_volume_ml numeric,
	    pack_date date,
	    use_by date,
	    package_size_g numeric,
	    package_count bigint,
	    action text,
	    origin_lot_ids_json text,
	    ui_error text,
	    ui_error_at timestamp without time zone,
	    tray_state text,
	    notes text,
	    strains_id bigint
);
ALTER TABLE pjeqn1nkx5sas6e.products OWNER TO nocodb;

--
-- Name: products_nocopk_seq; Type: SEQUENCE; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE SEQUENCE pjeqn1nkx5sas6e.products_nocopk_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
CREATE TABLE pjeqn1nkx5sas6e.recipes (
	    nocopk bigint NOT NULL,
	    created_at timestamp without time zone,
	    updated_at timestamp without time zone,
	    created_by character varying,
	    updated_by character varying,
	    nc_order numeric,
	    nocouuid uuid DEFAULT gen_random_uuid(),
	    recipe_id text,
	    name text,
	    category text,
	    ingredients text,
	    notes text
);
ALTER TABLE pjeqn1nkx5sas6e.recipes OWNER TO nocodb;

--
-- Name: recipes_nocopk_seq; Type: SEQUENCE; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE SEQUENCE pjeqn1nkx5sas6e.recipes_nocopk_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
CREATE TABLE pjeqn1nkx5sas6e.sterilization_runs (
	    nocopk bigint NOT NULL,
	    created_at timestamp without time zone,
	    updated_at timestamp without time zone,
	    created_by character varying,
	    updated_by character varying,
	    nc_order numeric,
	    nocouuid uuid DEFAULT gen_random_uuid(),
	    steri_run_id text,
	    steri_run_id_legacy text,
	    start_time timestamp without time zone,
	    end_time timestamp without time zone,
	    operator text,
	    planned_count bigint,
	    good_count bigint,
	    destroyed_count bigint,
	    planned_unit_size numeric,
	    ui_error text,
	    ui_error_at timestamp without time zone,
	    process_type text,
	    target_temp_c numeric,
	    pressure_mode text,
	    override_end_time timestamp without time zone,
	    recipes_id bigint
);
ALTER TABLE pjeqn1nkx5sas6e.sterilization_runs OWNER TO nocodb;

--
-- Name: sterilization_runs_nocopk_seq; Type: SEQUENCE; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE SEQUENCE pjeqn1nkx5sas6e.sterilization_runs_nocopk_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
CREATE TABLE pjeqn1nkx5sas6e.strains (
	    nocopk bigint NOT NULL,
	    created_at timestamp without time zone,
	    updated_at timestamp without time zone,
	    created_by character varying,
	    updated_by character varying,
	    nc_order numeric,
	    nocouuid uuid DEFAULT gen_random_uuid(),
	    strain_id text,
	    species_strain text,
	    regulated boolean DEFAULT false
);
ALTER TABLE pjeqn1nkx5sas6e.strains OWNER TO nocodb;

--
-- Name: strains_nocopk_seq; Type: SEQUENCE; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE SEQUENCE pjeqn1nkx5sas6e.strains_nocopk_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER TABLE ONLY pjeqn1nkx5sas6e.ecommerce ALTER COLUMN nocopk SET DEFAULT nextval('pjeqn1nkx5sas6e.ecommerce_nocopk_seq'::regclass);


--
-- Name: ecommerce_orders nocopk; Type: DEFAULT; Schema: pjeqn1nkx5sas6e; Owner: nocodb
ALTER TABLE ONLY pjeqn1nkx5sas6e.ecommerce_orders ALTER COLUMN nocopk SET DEFAULT nextval('pjeqn1nkx5sas6e.ecommerce_orders_nocopk_seq'::regclass);


--
-- Name: events nocopk; Type: DEFAULT; Schema: pjeqn1nkx5sas6e; Owner: nocodb
ALTER TABLE ONLY pjeqn1nkx5sas6e.events ALTER COLUMN nocopk SET DEFAULT nextval('pjeqn1nkx5sas6e.events_nocopk_seq'::regclass);


--
-- Name: items nocopk; Type: DEFAULT; Schema: pjeqn1nkx5sas6e; Owner: nocodb
ALTER TABLE ONLY pjeqn1nkx5sas6e.items ALTER COLUMN nocopk SET DEFAULT nextval('pjeqn1nkx5sas6e.items_nocopk_seq'::regclass);


--
-- Name: locations nocopk; Type: DEFAULT; Schema: pjeqn1nkx5sas6e; Owner: nocodb
ALTER TABLE ONLY pjeqn1nkx5sas6e.locations ALTER COLUMN nocopk SET DEFAULT nextval('pjeqn1nkx5sas6e.locations_nocopk_seq'::regclass);


--
-- Name: lots nocopk; Type: DEFAULT; Schema: pjeqn1nkx5sas6e; Owner: nocodb
ALTER TABLE ONLY pjeqn1nkx5sas6e.lots ALTER COLUMN nocopk SET DEFAULT nextval('pjeqn1nkx5sas6e.lots_nocopk_seq'::regclass);


--
-- Name: print_queue nocopk; Type: DEFAULT; Schema: pjeqn1nkx5sas6e; Owner: nocodb
ALTER TABLE ONLY pjeqn1nkx5sas6e.print_queue ALTER COLUMN nocopk SET DEFAULT nextval('pjeqn1nkx5sas6e.print_queue_nocopk_seq'::regclass);


--
-- Name: products nocopk; Type: DEFAULT; Schema: pjeqn1nkx5sas6e; Owner: nocodb
ALTER TABLE ONLY pjeqn1nkx5sas6e.products ALTER COLUMN nocopk SET DEFAULT nextval('pjeqn1nkx5sas6e.products_nocopk_seq'::regclass);


--
-- Name: recipes nocopk; Type: DEFAULT; Schema: pjeqn1nkx5sas6e; Owner: nocodb
ALTER TABLE ONLY pjeqn1nkx5sas6e.recipes ALTER COLUMN nocopk SET DEFAULT nextval('pjeqn1nkx5sas6e.recipes_nocopk_seq'::regclass);


--
-- Name: sterilization_runs nocopk; Type: DEFAULT; Schema: pjeqn1nkx5sas6e; Owner: nocodb
ALTER TABLE ONLY pjeqn1nkx5sas6e.sterilization_runs ALTER COLUMN nocopk SET DEFAULT nextval('pjeqn1nkx5sas6e.sterilization_runs_nocopk_seq'::regclass);


--
-- Name: strains nocopk; Type: DEFAULT; Schema: pjeqn1nkx5sas6e; Owner: nocodb
ALTER TABLE ONLY pjeqn1nkx5sas6e.strains ALTER COLUMN nocopk SET DEFAULT nextval('pjeqn1nkx5sas6e.strains_nocopk_seq'::regclass);


--
-- Name: nc_api_tokens id; Type: DEFAULT; Schema: public; Owner: nocodb
COPY pjeqn1nkx5sas6e._nc_m2m_lots_lots (lots1_id, lots_id) FROM stdin;
\.
COPY pjeqn1nkx5sas6e._nc_m2m_lots_lots1 (lots1_id, lots_id) FROM stdin;
\.
COPY pjeqn1nkx5sas6e._nc_m2m_lots_lots2 (lots1_id, lots_id) FROM stdin;
\.
COPY pjeqn1nkx5sas6e._nc_m2m_lots_products (products_id, lots_id) FROM stdin;
\.
COPY pjeqn1nkx5sas6e._nc_m2m_lots_recipes (recipes_id, lots_id) FROM stdin;
\.
COPY pjeqn1nkx5sas6e._nc_m2m_products_products (products1_id, products_id) FROM stdin;
\.
COPY pjeqn1nkx5sas6e.ecommerce (nocopk, created_at, updated_at, created_by, updated_by, nc_order, nocouuid, name, status, ecwid_sku, sync_to_ecwid, notes, ecwid_category, ecwid_price, ecwid_stock, ecwid_url, ecwid_image) FROM stdin;
\.
COPY pjeqn1nkx5sas6e.ecommerce_orders (nocopk, created_at, updated_at, created_by, updated_by, nc_order, nocouuid, name, ecwid_order_id, order_number, status, order_date, customer_name, customer_email, items_json, ecwid_skus) FROM stdin;
\.
COPY pjeqn1nkx5sas6e.events (nocopk, created_at, updated_at, created_by, updated_by, nc_order, nocouuid, event_id, event_id_legacy, type, "timestamp", operator, station, fields_json, lots) FROM stdin;
\.
COPY pjeqn1nkx5sas6e.items (nocopk, created_at, updated_at, created_by, updated_by, nc_order, nocouuid, item_id, name, category, default_unit_size_lb, default_unit_size_ml, default_unit_size_oz, default_unit_size_g, default_unit_size) FROM stdin;
\.
COPY pjeqn1nkx5sas6e.locations (nocopk, created_at, updated_at, created_by, updated_by, nc_order, nocouuid, name, type, notes) FROM stdin;
\.
COPY pjeqn1nkx5sas6e.lots (nocopk, created_at1, updated_at, created_by, updated_by, nc_order, nocouuid, lot_id, lot_id_legacy, item_name_mat, qty, unit_size, status, parents_json, operator, created_at, use_by, action, item_category_mat, process_type_mat, lc_volume_ml, output_count, fruiting_goal, flush_no, harvest_weight_g, notes, syringe_count, source_type, vendor_name, vendor_batch, received_date, total_volume_ml, ui_error, ui_error_at, remaining_volume_ml, fresh_tray_count, frozen_tray_count, casing_applied_at, casing_notes, casing_qty_used_g, label_template, override_inoc_time, inoculated_at, override_spawn_time, spawned_at, sterilized_at, plate_count, plate_group_id, strains_id, lots_id, lots_id1, lots_id2, sterilization_runs_id, label_inoc_line_formula_src_fallback, label_spawned_line_formula_src_fallback, label_graininputblocks_line_formula_src_fallback, label_substrateinputblocks_line_formula_src_fallback) FROM stdin;
\.
COPY pjeqn1nkx5sas6e.print_queue (nocopk, created_at1, updated_at, created_by, updated_by, nc_order, nocouuid, print_id, print_id_legacy, source_kind, print_status, label_type, error_msg, created_at, claimed_by, claimed_at, printed_by, printed_at, pdf_path) FROM stdin;
\.
COPY pjeqn1nkx5sas6e.products (nocopk, created_at, updated_at, created_by, updated_by, nc_order, nocouuid, product_id, product_id_legacy, name_mat, item_category_mat, net_weight_g, net_weight_oz, net_volume_ml, pack_date, use_by, package_size_g, package_count, action, origin_lot_ids_json, ui_error, ui_error_at, tray_state, notes, strains_id) FROM stdin;
\.
COPY pjeqn1nkx5sas6e.recipes (nocopk, created_at, updated_at, created_by, updated_by, nc_order, nocouuid, recipe_id, name, category, ingredients, notes) FROM stdin;
\.
COPY pjeqn1nkx5sas6e.sterilization_runs (nocopk, created_at, updated_at, created_by, updated_by, nc_order, nocouuid, steri_run_id, steri_run_id_legacy, start_time, end_time, operator, planned_count, good_count, destroyed_count, planned_unit_size, ui_error, ui_error_at, process_type, target_temp_c, pressure_mode, override_end_time, recipes_id) FROM stdin;
\.
COPY pjeqn1nkx5sas6e.strains (nocopk, created_at, updated_at, created_by, updated_by, nc_order, nocouuid, strain_id, species_strain, regulated) FROM stdin;
\.
ALTER TABLE ONLY pjeqn1nkx5sas6e._nc_m2m_lots_lots1
    ADD CONSTRAINT _nc_m2m_lots_lots1_pkey PRIMARY KEY (lots1_id, lots_id);
ALTER TABLE ONLY pjeqn1nkx5sas6e._nc_m2m_lots_lots2
    ADD CONSTRAINT _nc_m2m_lots_lots2_pkey PRIMARY KEY (lots1_id, lots_id);
ALTER TABLE ONLY pjeqn1nkx5sas6e._nc_m2m_lots_lots
    ADD CONSTRAINT _nc_m2m_lots_lots_pkey PRIMARY KEY (lots1_id, lots_id);
ALTER TABLE ONLY pjeqn1nkx5sas6e._nc_m2m_lots_products
    ADD CONSTRAINT _nc_m2m_lots_products_pkey PRIMARY KEY (products_id, lots_id);
ALTER TABLE ONLY pjeqn1nkx5sas6e._nc_m2m_lots_recipes
    ADD CONSTRAINT _nc_m2m_lots_recipes_pkey PRIMARY KEY (recipes_id, lots_id);
ALTER TABLE ONLY pjeqn1nkx5sas6e._nc_m2m_products_products
    ADD CONSTRAINT _nc_m2m_products_products_pkey PRIMARY KEY (products1_id, products_id);
ALTER TABLE ONLY pjeqn1nkx5sas6e.ecommerce_orders
    ADD CONSTRAINT ecommerce_orders_pkey PRIMARY KEY (nocopk);
ALTER TABLE ONLY pjeqn1nkx5sas6e.ecommerce
    ADD CONSTRAINT ecommerce_pkey PRIMARY KEY (nocopk);
ALTER TABLE ONLY pjeqn1nkx5sas6e.events
    ADD CONSTRAINT events_pkey PRIMARY KEY (nocopk);
ALTER TABLE ONLY pjeqn1nkx5sas6e.items
    ADD CONSTRAINT items_pkey PRIMARY KEY (nocopk);
ALTER TABLE ONLY pjeqn1nkx5sas6e.locations
    ADD CONSTRAINT locations_pkey PRIMARY KEY (nocopk);
ALTER TABLE ONLY pjeqn1nkx5sas6e.lots
    ADD CONSTRAINT lots_pkey PRIMARY KEY (nocopk);
ALTER TABLE ONLY pjeqn1nkx5sas6e.print_queue
    ADD CONSTRAINT print_queue_pkey PRIMARY KEY (nocopk);
ALTER TABLE ONLY pjeqn1nkx5sas6e.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (nocopk);
ALTER TABLE ONLY pjeqn1nkx5sas6e.recipes
    ADD CONSTRAINT recipes_pkey PRIMARY KEY (nocopk);
ALTER TABLE ONLY pjeqn1nkx5sas6e.sterilization_runs
    ADD CONSTRAINT sterilization_runs_pkey PRIMARY KEY (nocopk);
ALTER TABLE ONLY pjeqn1nkx5sas6e.strains
    ADD CONSTRAINT strains_pkey PRIMARY KEY (nocopk);
CREATE INDEX ecommerce_order_idx ON pjeqn1nkx5sas6e.ecommerce USING btree (nc_order);


--
-- Name: ecommerce_orders_order_idx; Type: INDEX; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE INDEX ecommerce_orders_order_idx ON pjeqn1nkx5sas6e.ecommerce_orders USING btree (nc_order);


--
-- Name: events_order_idx; Type: INDEX; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE INDEX events_order_idx ON pjeqn1nkx5sas6e.events USING btree (nc_order);


--
-- Name: fk_lots_lots_1c7fu834ps; Type: INDEX; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE INDEX fk_lots_lots_1c7fu834ps ON pjeqn1nkx5sas6e._nc_m2m_lots_lots2 USING btree (lots1_id);


--
-- Name: fk_lots_lots_2h8strwh7z; Type: INDEX; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE INDEX fk_lots_lots_2h8strwh7z ON pjeqn1nkx5sas6e._nc_m2m_lots_lots USING btree (lots_id);


--
-- Name: fk_lots_lots_52qd1x7ljo; Type: INDEX; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE INDEX fk_lots_lots_52qd1x7ljo ON pjeqn1nkx5sas6e.lots USING btree (lots_id1);


--
-- Name: fk_lots_lots_a0qg443mpl; Type: INDEX; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE INDEX fk_lots_lots_a0qg443mpl ON pjeqn1nkx5sas6e.lots USING btree (lots_id);


--
-- Name: fk_lots_lots_clori18icq; Type: INDEX; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE INDEX fk_lots_lots_clori18icq ON pjeqn1nkx5sas6e.lots USING btree (lots_id2);


--
-- Name: fk_lots_lots_kbld7f9o_7; Type: INDEX; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE INDEX fk_lots_lots_kbld7f9o_7 ON pjeqn1nkx5sas6e._nc_m2m_lots_lots1 USING btree (lots1_id);


--
-- Name: fk_lots_lots_kw29vwr6fk; Type: INDEX; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE INDEX fk_lots_lots_kw29vwr6fk ON pjeqn1nkx5sas6e._nc_m2m_lots_lots USING btree (lots1_id);


--
-- Name: fk_lots_lots_m6owpxo78f; Type: INDEX; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE INDEX fk_lots_lots_m6owpxo78f ON pjeqn1nkx5sas6e._nc_m2m_lots_lots1 USING btree (lots_id);


--
-- Name: fk_lots_lots_p8je530lxe; Type: INDEX; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE INDEX fk_lots_lots_p8je530lxe ON pjeqn1nkx5sas6e._nc_m2m_lots_lots2 USING btree (lots_id);


--
-- Name: fk_lots_products_fmn8ij7_ho; Type: INDEX; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE INDEX fk_lots_products_fmn8ij7_ho ON pjeqn1nkx5sas6e._nc_m2m_lots_products USING btree (products_id);


--
-- Name: fk_lots_products_qrrnp5myym; Type: INDEX; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE INDEX fk_lots_products_qrrnp5myym ON pjeqn1nkx5sas6e._nc_m2m_lots_products USING btree (lots_id);


--
-- Name: fk_lots_recipes_dn73_rrowr; Type: INDEX; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE INDEX fk_lots_recipes_dn73_rrowr ON pjeqn1nkx5sas6e._nc_m2m_lots_recipes USING btree (recipes_id);


--
-- Name: fk_lots_recipes_gr0op56_wh; Type: INDEX; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE INDEX fk_lots_recipes_gr0op56_wh ON pjeqn1nkx5sas6e._nc_m2m_lots_recipes USING btree (lots_id);


--
-- Name: fk_products_products_l5azt_7opk; Type: INDEX; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE INDEX fk_products_products_l5azt_7opk ON pjeqn1nkx5sas6e._nc_m2m_products_products USING btree (products1_id);


--
-- Name: fk_products_products_xxyjs528fl; Type: INDEX; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE INDEX fk_products_products_xxyjs528fl ON pjeqn1nkx5sas6e._nc_m2m_products_products USING btree (products_id);


--
-- Name: fk_recipes_sterilizat_yvn458nyec; Type: INDEX; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE INDEX fk_recipes_sterilizat_yvn458nyec ON pjeqn1nkx5sas6e.sterilization_runs USING btree (recipes_id);


--
-- Name: fk_sterilizat_lots_xi5d40maoz; Type: INDEX; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE INDEX fk_sterilizat_lots_xi5d40maoz ON pjeqn1nkx5sas6e.lots USING btree (sterilization_runs_id);


--
-- Name: fk_strains_lots_ab84k4fjhr; Type: INDEX; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE INDEX fk_strains_lots_ab84k4fjhr ON pjeqn1nkx5sas6e.lots USING btree (strains_id);


--
-- Name: fk_strains_products_8k2yikcgrf; Type: INDEX; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE INDEX fk_strains_products_8k2yikcgrf ON pjeqn1nkx5sas6e.products USING btree (strains_id);


--
-- Name: items_order_idx; Type: INDEX; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE INDEX items_order_idx ON pjeqn1nkx5sas6e.items USING btree (nc_order);


--
-- Name: locations_order_idx; Type: INDEX; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE INDEX locations_order_idx ON pjeqn1nkx5sas6e.locations USING btree (nc_order);


--
-- Name: lots_order_idx; Type: INDEX; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE INDEX lots_order_idx ON pjeqn1nkx5sas6e.lots USING btree (nc_order);


--
-- Name: print_queue_order_idx; Type: INDEX; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE INDEX print_queue_order_idx ON pjeqn1nkx5sas6e.print_queue USING btree (nc_order);


--
-- Name: products_order_idx; Type: INDEX; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE INDEX products_order_idx ON pjeqn1nkx5sas6e.products USING btree (nc_order);


--
-- Name: recipes_order_idx; Type: INDEX; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE INDEX recipes_order_idx ON pjeqn1nkx5sas6e.recipes USING btree (nc_order);


--
-- Name: sterilization_runs_order_idx; Type: INDEX; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE INDEX sterilization_runs_order_idx ON pjeqn1nkx5sas6e.sterilization_runs USING btree (nc_order);


--
-- Name: strains_order_idx; Type: INDEX; Schema: pjeqn1nkx5sas6e; Owner: nocodb
CREATE INDEX strains_order_idx ON pjeqn1nkx5sas6e.strains USING btree (nc_order);


--
-- Name: nc_api_tokens_fk_sso_client_id_index; Type: INDEX; Schema: public; Owner: nocodb

