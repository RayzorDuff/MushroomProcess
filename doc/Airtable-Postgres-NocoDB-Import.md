# Airtable → Postgres → NocoDB Import Pipeline

This document captures the **final architecture, design decisions, and hard‑won fixes** involved in migrating an Airtable base into a Postgres database used by **NocoDB**, using the custom SQL generator in `airtable_schema`.

It is intended to explain *why the system looks the way it does*, not just *what it does*, so future changes do not regress critical behavior.

---

## High‑level Architecture

```
Airtable Schema JSON
        ↓
airtable_export_to_postgres_sql.js
        ↓
Postgres SQL (pgsql/)
        ↓
Postgres DB (data + views + triggers)
        ↓
NocoDB (UI, metadata, CRUD)
```

Two key principles guide the design:

1. **Base tables are writable** (NocoDB / Appsmith insert & update here)
2. **Computed behavior lives either in triggers or views**, never in application code

---

## Directory Overview

### `airtable_schema/`

Contains the **source of truth** for schema generation.

Key files:

* **`airtable_export_to_postgres_sql.js`**
  The primary generator. It reads Airtable schema JSON and emits:

  * `001_tables.sql` (tables, triggers)
  * `002_links.sql` (m2m tables)
  * `003_views.sql` (base views)
  * `004_computed_views.sql` (computed / Airtable‑style formula views)
  * `010_load.sql` (CSV import)

* **`create_nocodb_schema_full/`**
  Legacy / alternate path: generates a full schema import using env vars. Kept for reference and comparison.

---

### `nocodb_schema/`

Contains **outputs and experiments** derived from the generator.

Subdirectories:

#### `pgsql/`

The **canonical SQL‑only import** produced by `airtable_export_to_postgres_sql.js`.

This is now the *preferred* path for rebuilding the DB.

#### `signaturegate/`

Represents the **pre‑migration baseline** database created by the SignatureGate project. Useful only as historical reference.

#### `manual_server_side_diff/`

Diff artifacts created by comparing NocoDB’s internal metadata DB *before vs after* schema import.

This helped identify:

* how NocoDB infers PV / display fields
* what metadata NocoDB auto‑creates vs what must be set manually

---

## Base Tables vs Views (Critical Concept)

### Base tables (`public.<table>`)

* **Writable** by NocoDB / Appsmith
* Contain:

  * raw Airtable fields
  * internal Noco fields (`nocopk`, `nocouuid`, timestamps)
  * *materialized* ID fields (`lot_id`, `product_id`, etc.)

### Views

#### `v_<table>`

* Thin normalization layer
* Mostly selects from base table
* May simplify naming / joins

#### `vc_<table>`

* Airtable‑semantic computed views
* Include:

  * formulas
  * lookups
  * rollups
* **Read‑only by design**

**Rule:**

> Write to base tables, read from `vc_*` views.

---

## Materialized ID Fields (`*_id`)

### What they are

Fields like:

* `lot_id`
* `product_id`
* `event_id`

Originally Airtable **formula fields**, now **materialized columns**.

### Why they are materialized

* NocoDB cannot insert into computed views
* These IDs are needed as:

  * human‑readable identifiers
  * display values (PV)
  * external references

### How they are populated

* Columns are created as **nullable `text`**
* A **BEFORE INSERT / UPDATE trigger** sets the value if missing

Pseudo‑logic:

```
IF id IS NULL OR id = '' THEN
  id := PREFIX + YYMMDD(nc_created_at)
        + '-' + RIGHT(record_fallback, 4)
END IF
```

Where `record_fallback` =

```
COALESCE(airtable_id,
         nocouuid (no dashes),
         nocopk)
```

### Why they MUST be nullable

NocoDB validates required fields **before insert**.

If a trigger‑populated column is `NOT NULL`, NocoDB refuses to insert the row and highlights the field in red.

**Therefore:**

> Trigger‑computed fields must be nullable, even if logically required.

Uniqueness is enforced via **UNIQUE constraints**, not NOT NULL.

---

## Column Ordering (PV / Display Value Behavior)

NocoDB heuristically chooses a display field when none is explicitly set.

To make this predictable, the generator enforces this base‑table column order:

1. `nocopk` (PK)
2. materialized ID fields (`*_id`)
3. first Airtable schema field (often `*_id` or `name`)
4. remaining Airtable fields
5. internal Noco fields:

   * `nocouuid`
   * `airtable_id`
   * `nc_created_at`
   * `nc_updated_at`

This causes NocoDB to default the PV to a meaningful human identifier instead of `nocouuid`.

---

## Constraints & Indexes

### Current behavior

* UNIQUE constraints are generated for:

  * materialized `*_id` fields
  * first Airtable field if it ends with `_id`

* Constraints are emitted **idempotently** using `pg_constraint` checks

* Index creation is re‑enabled only after trigger behavior was validated

### Important notes

* `UNIQUE` + nullable is intentional
* Multiple NULLs are allowed by Postgres
* This avoids breaking NocoDB inserts while still enforcing uniqueness

---

## CSV Import (`010_load.sql`)

Key lessons captured in the generator:

* Use `\copy`, not `COPY`
* Paths must be **single SQL string literals**
* Never use `:/path` (colon implies psql variable)

Correct pattern:

```
\copy table(col1, col2)
FROM 'csv/file.csv'
WITH (FORMAT csv, HEADER true);
```

Always run imports with:

```
psql -v ON_ERROR_STOP=1 -f 010_load.sql
```

This prevents half‑applied schemas.

---

## Known Gotchas (Now Resolved)

* ❌ CASE text vs text[] → fixed via explicit casting
* ❌ lookup of link field → expanded via m2m join
* ❌ array vs scalar comparisons → rewritten as `= ANY(array)`
* ❌ polymorphic `array_agg(unknown)` → explicit casts
* ❌ NULL propagation in `&` formulas → NULL‑safe concatenation
* ❌ trigger columns missing → materialized columns added
* ❌ NOT NULL trigger fields → changed to nullable
* ❌ duplicate constraints → deduped + idempotent
* ❌ regclass misuse → fixed to `'schema.table'::regclass`

---

## Current Recommended Workflow

1. Modify Airtable
2. Export schema JSON
3. Run `airtable_export_to_postgres_sql.js`
4. Drop & recreate Postgres DB
5. Apply SQL in order:

   * `001_tables.sql`
   * `002_links.sql`
   * `003_views.sql`
   * `004_computed_views.sql`
   * `010_load.sql`
6. Connect NocoDB
7. Set PV only if needed (often automatic now)

---

## Future Improvements (Optional)

* Partial unique indexes (`WHERE col IS NOT NULL`)
* Automated PV setting via NocoDB API
* Schema diff validation step
* Trigger unit tests

---

## Final Note

This system now correctly reproduces Airtable semantics while remaining:

* writable
* deterministic
* inspectable
* and safe for long‑term evolution

Any future changes should preserve the invariants documented above.
