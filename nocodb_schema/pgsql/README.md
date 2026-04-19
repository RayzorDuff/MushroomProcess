# MushroomProcess Postgres Rebuild / Reload

This directory contains the generated SQL used to rebuild the MushroomProcess bridge database, which runs inside the RootedOps Docker stack.

---

## Overview

This process is used after:

- Exporting Airtable
- Regenerating nocodb_schema/pgsql/*.sql
- Needing to rebuild the Postgres schema from scratch

Workflow:

1. Backup current database
2. Drop and recreate database
3. Import SQL files in order

---

## Target Database

Container:
mushroomprocess-bridge-postgres

Configuration source:
RootedOps/.env

Variables:
MP_BRIDGE_DB_NAME
MP_BRIDGE_DB_USER
MP_BRIDGE_DB_PASSWORD

Compose file:
RootedOps/docker/docker-compose.yml

---

## SQL File Order

Import in lexical order:

001_tables.sql
002_links.sql
003_views.sql
004_computed_views.sql
005_helpers.sql
006_triggers.sql
007_sterilizer.sql
008_lot_actions.sql
021_personnel_reviews.sql
022_personnel_reviews_seeds.sql
023_operator_identity.sql
100_load.sql
124_operator_identity_backfill_and_review_integration.sql

Notes:
- Tables → Views → Functions → Triggers → Data load
- 100_load.sql = seed/reference data
- 124_* = post-load patch (must remain last)

---

## Full Rebuild Procedure

### 1. Change into RootedOps

cd /path/to/RootedOps

### 2. Load Environment Variables

set -a
source ./.env
set +a

### 3. Start Postgres Container

sudo docker compose --env-file .env -f docker/docker-compose.yml up -d mushroomprocess-bridge-postgres

### 4. Backup Existing Database

mkdir -p ./tmp

sudo docker exec \
  -e PGPASSWORD="$MP_BRIDGE_DB_PASSWORD" \
  mushroomprocess-bridge-postgres \
  pg_dump \
    -U "$MP_BRIDGE_DB_USER" \
    -d "$MP_BRIDGE_DB_NAME" \
    --clean --if-exists --no-owner --no-privileges \
  > "./tmp/mushroomprocess-bridge-pre-reimport-$(date +%Y%m%d-%H%M%S).sql"

### 5. Drop and Recreate Database

sudo docker exec \
  -e PGPASSWORD="$MP_BRIDGE_DB_PASSWORD" \
  mushroomprocess-bridge-postgres \
  psql -U "$MP_BRIDGE_DB_USER" -d postgres \
  -c "DROP DATABASE IF EXISTS \"$MP_BRIDGE_DB_NAME\";"

sudo docker exec \
  -e PGPASSWORD="$MP_BRIDGE_DB_PASSWORD" \
  mushroomprocess-bridge-postgres \
  psql -U "$MP_BRIDGE_DB_USER" -d postgres \
  -c "CREATE DATABASE \"$MP_BRIDGE_DB_NAME\";"

### 6. Import SQL Files

cd /path/to/MushroomProcess

for f in $(ls -1 nocodb_schema/pgsql/*.sql | sort); do
  echo "Importing $f"
  sudo docker exec -i \
    -e PGPASSWORD="$MP_BRIDGE_DB_PASSWORD" \
    mushroomprocess-bridge-postgres \
    psql -v ON_ERROR_STOP=1 \
      -U "$MP_BRIDGE_DB_USER" \
      -d "$MP_BRIDGE_DB_NAME" \
    < "$f"
done

### 7. Verify Import

sudo docker exec \
  -e PGPASSWORD="$MP_BRIDGE_DB_PASSWORD" \
  mushroomprocess-bridge-postgres \
  psql -U "$MP_BRIDGE_DB_USER" -d "$MP_BRIDGE_DB_NAME" \
  -c "\dt"

sudo docker exec \
  -e PGPASSWORD="$MP_BRIDGE_DB_PASSWORD" \
  mushroomprocess-bridge-postgres \
  psql -U "$MP_BRIDGE_DB_USER" -d "$MP_BRIDGE_DB_NAME" \
  -c "\dv"

---

## Important Notes

- Targets bridge Postgres DB, not NocoDB metadata DB
- Uses docker exec (no local psql required)
- Always backup before rebuild
- Stops on first SQL error
- Loads schema + seed data only

---

