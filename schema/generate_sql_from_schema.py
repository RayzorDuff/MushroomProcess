#!/usr/bin/env python3
"""
Generate SQL CREATE TABLE statements from Airtable export/_schema.json

This is tailored to the MushroomProcess schema zip you shared:

  - Top-level JSON shape: { "tables": [ ... ] }
  - Tables: strains, recipes, products, lots, items, events, locations,
            sterilization_runs, print_queue
  - Field types include: multilineText, singleLineText, number, autoNumber,
    checkbox, singleSelect, date, dateTime, createdTime, formula, rollup,
    multipleRecordLinks, multipleLookupValues, etc.

Usage examples (run from the schema directory):

  # Generate Postgres SQL to stdout
  python generate_sql_from_schema.py

  # Generate Postgres SQL to schema.sql
  python generate_sql_from_schema.py --dialect postgres --output schema.sql

  # Generate MySQL SQL
  python generate_sql_from_schema.py --dialect mysql --output schema_mysql.sql

  # Generate SQLite SQL
  python generate_sql_from_schema.py --dialect sqlite --output schema_sqlite.sql
"""

import argparse
import json
import os
import sys
from typing import Any, Dict, List, Tuple


# ---------------------------
# Logging helpers
# ---------------------------

def debug(msg: str) -> None:
    """Basic stderr logger."""
    sys.stderr.write(msg + "\n")


# ---------------------------
# Schema loading
# ---------------------------

def load_schema(path: str) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def normalize_tables(schema: Dict[str, Any]) -> List[Dict[str, Any]]:
    """
    From your zip, _schema.json has the form:

        {
          "tables": [
            {
              "id": "tbl...",
              "name": "strains",
              "fields": [ { "id": "fld...", "name": "strain_id", "type": "multilineText", ... }, ... ],
              "primaryFieldId": "...",
              "views": [ ... ]
            },
            ...
          ]
        }

    This function just returns schema["tables"] but keeps it defensive.
    """
    if not isinstance(schema, dict):
        raise ValueError("Expected _schema.json to be a JSON object")

    tables = schema.get("tables")
    if not isinstance(tables, list):
        raise ValueError("Expected _schema.json to contain key 'tables' with a list")

    return tables


# ---------------------------
# SQL quoting / dialect helpers
# ---------------------------

def quote_ident(name: str, dialect: str) -> str:
    """
    Quote an identifier safely.
    - For postgres/sqlite: "name"
    - For mysql: `name`
    """
    if dialect in ("postgres", "sqlite"):
        return '"' + name.replace('"', '""') + '"'
    elif dialect == "mysql":
        return "`" + name.replace("`", "``") + "`"
    else:
        raise ValueError(f"Unsupported dialect: {dialect}")


def column_type_for_dialect(base_type: str, dialect: str) -> str:
    """
    Map a generic SQL type to a concrete one for the chosen dialect.

    base_type is one of:
      - VARCHAR(255)
      - TEXT
      - BOOLEAN
      - NUMERIC
      - NUMERIC(18,4)
      - DATE
      - TIMESTAMPTZ
    """
    base_type = base_type.upper()

    if dialect == "postgres":
        if base_type == "TIMESTAMPTZ":
            return "TIMESTAMP WITH TIME ZONE"
        return base_type

    if dialect == "mysql":
        if base_type == "BOOLEAN":
            return "TINYINT(1)"
        if base_type == "TIMESTAMPTZ":
            return "DATETIME"
        if base_type == "NUMERIC":
            return "DECIMAL(18,4)"
        return base_type

    if dialect == "sqlite":
        # SQLite is very relaxed; we just use TEXT/INTEGER/REAL where sane
        if base_type in ("VARCHAR(255)", "TEXT"):
            return "TEXT"
        if base_type == "BOOLEAN":
            return "INTEGER"
        if base_type in ("NUMERIC", "NUMERIC(18,4)"):
            return "REAL"
        if base_type in ("DATE", "TIMESTAMPTZ"):
            return "TEXT"
        return "TEXT"

    raise ValueError(f"Unsupported dialect: {dialect}")


def serial_pk_for_dialect(dialect: str) -> str:
    """Return a suitable auto-increment primary key type for the dialect."""
    if dialect == "postgres":
        return "SERIAL PRIMARY KEY"
    if dialect == "mysql":
        return "INT AUTO_INCREMENT PRIMARY KEY"
    if dialect == "sqlite":
        return "INTEGER PRIMARY KEY AUTOINCREMENT"
    raise ValueError(f"Unsupported dialect: {dialect}")


# ---------------------------
# Airtable type -> generic SQL type
# ---------------------------

def map_airtable_type(field: Dict[str, Any]) -> Tuple[str, Dict[str, Any]]:
    """
    Map Airtable field.type to a *generic* SQL type (before dialect mapping).

    Returns (base_sql_type, extra_info).

    Types in your schema include (from the zip):
      multilineText, singleLineText, number, autoNumber, checkbox,
      singleSelect, date, dateTime, createdTime, formula, rollup,
      multipleRecordLinks, multipleLookupValues, etc.
    """
    t = field.get("type")
    options = field.get("options") or {}

    # Text-ish
    if t in ("singleLineText",):
        return "VARCHAR(255)", {}
    if t in ("multilineText",):
        return "TEXT", {}

    # Numeric-ish
    if t in ("number", "autoNumber"):
        # We can tighten this later if needed (e.g. INT vs DECIMAL).
        return "NUMERIC", {}

    # Booleans
    if t == "checkbox":
        return "BOOLEAN", {}

    # Date/time
    if t == "date":
        return "DATE", {}
    if t in ("dateTime", "createdTime", "lastModifiedTime"):
        return "TIMESTAMPTZ", {}

    # Single select
    if t == "singleSelect":
        return "VARCHAR(255)", {"airtable_type": t, "choices": options.get("choices")}

    # Multiple selects / lookups – simplest is TEXT (e.g. JSON or comma-separated)
    if t in ("multipleLookupValues", "multipleSelects"):
        return "TEXT", {"airtable_type": t}

    # Linked records
    if t in ("multipleRecordLinks", "singleRecordLink"):
        # Real FK support would require a second pass and mapping table IDs.
        # For first pass, store as TEXT (record ID array / JSON).
        return "TEXT", {"airtable_type": t, "is_link": True}

    # Formula / rollup / lookup (derived fields)
    if t in ("formula", "rollup", "lookup"):
        # Your schema's options["result"]["type"] could be inspected here,
        # but we keep them as TEXT and you can refine individually if needed.
        return "TEXT", {"airtable_type": t, "is_derived": True}

    # Fallback
    return "TEXT", {"airtable_type": t, "unknown": True}


# ---------------------------
# SQL generation
# ---------------------------

def generate_create_table_sql(table: Dict[str, Any], dialect: str) -> str:
    """
    Produce a CREATE TABLE statement for a single table.

    Strategy:
      - Table name := table["name"]
      - Synthetic primary key: id SERIAL / AUTO_INCREMENT / AUTOINCREMENT
      - Keep original Airtable record id in 'airtable_id' (VARCHAR(255) UNIQUE)
      - Add one column per Airtable field, mapped via map_airtable_type()
    """

    table_name = table.get("name") or table.get("id")
    if not table_name:
        raise ValueError(f"Table without name/id: {table}")

    q_table = quote_ident(table_name, dialect)

    columns_sql: List[str] = []

    # Synthetic PK for NocoDB / general DB usage
    columns_sql.append(f"{quote_ident('id', dialect)} {serial_pk_for_dialect(dialect)}")

    # Airtable record ID column (for mapping when importing data)
    columns_sql.append(
        f"{quote_ident('airtable_id', dialect)} "
        f"{column_type_for_dialect('VARCHAR(255)', dialect)} UNIQUE"
    )

    fields = table.get("fields") or []

    for field in fields:
        field_name = field.get("name")
        if not field_name:
            continue

        # Avoid clobbering synthetic columns
        if field_name in ("id", "airtable_id"):
            debug(f"Skipping field '{field_name}' on table '{table_name}' (reserved).")
            continue

        base_type, _extra = map_airtable_type(field)
        col_type = column_type_for_dialect(base_type, dialect)
        q_col = quote_ident(field_name, dialect)

        columns_sql.append(f"{q_col} {col_type}")

    cols_joined = ",\n  ".join(columns_sql)
    sql = f"CREATE TABLE {q_table} (\n  {cols_joined}\n);"

    return sql


def generate_sql(schema: Dict[str, Any], dialect: str) -> str:
    tables = normalize_tables(schema)
    statements: List[str] = []

    for table in tables:
        stmt = generate_create_table_sql(table, dialect)
        statements.append(stmt)

    return "\n\n".join(statements) + "\n"


# ---------------------------
# CLI
# ---------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate SQL CREATE TABLE statements from Airtable export/_schema.json"
    )
    parser.add_argument(
        "--schema-path",
        default=os.path.join("export", "_schema.json"),
        help="Path to _schema.json (default: export/_schema.json in current dir)",
    )
    parser.add_argument(
        "--dialect",
        choices=("postgres", "mysql", "sqlite"),
        default="postgres",
        help="SQL dialect for output types (default: postgres)",
    )
    parser.add_argument(
        "--output",
        default="-",
        help="Output file path, or '-' for stdout (default: -)",
    )

    args = parser.parse_args()

    schema_path = args.schema_path
    dialect = args.dialect
    output_path = args.output

    if not os.path.exists(schema_path):
        debug(f"ERROR: schema file not found: {schema_path}")
        sys.exit(1)

    debug(f"Reading schema from: {schema_path}")
    debug(f"Dialect: {dialect}")

    schema = load_schema(schema_path)
    sql = generate_sql(schema, dialect)

    if output_path == "-" or not output_path:
        sys.stdout.write(sql)
    else:
        os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
        with open(output_path, "w", encoding="utf-8") as f:
            f.write(sql)
        debug(f"Wrote SQL to: {output_path}")


if __name__ == "__main__":
    main()
