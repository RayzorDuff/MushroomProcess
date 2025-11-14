#!/usr/bin/env node
/**
 * create_nocodb_from_schema.js
 *
 * One-shot schema bootstrapper for NocoDB using the Airtable export.
 *
 * - Reads:   ./export/_schema.json   (from airtable_schema/export in your repo)
 * - Creates: one NocoDB table per Airtable table via Meta API
 *
 * Required environment variables:
 *   NOCODB_URL       = base URL of your NocoDB instance (e.g. http://localhost:8080 or https://app.nocodb.com)
 *   NOCODB_BASE_ID   = NocoDB "Base" (project) ID, like p_xxxxx
 *   NOCODB_API_TOKEN = API token with schema-edit permission
 *
 * Usage (from repo root, on nocodb_migration branch):
 *   cd airtable_schema
 *   node create_nocodb_from_schema.js
 *
 * NOTES:
 * - This focuses on "primitive" fields: text, number, checkbox, date/time, single/multi select.
 * - It deliberately SKIPS computed / virtual fields (formula, lookup, rollup, count, createdTime, lastModified*),
 *   because those require more specific NocoDB meta configuration.
 * - Linked-record fields from Airtable are currently created as plain Text columns; relationships can be wired up later.
 */

const fs = require("fs");
const path = require("path");
const axios = require("axios");

// ---------- CONFIG & ENV VALIDATION ----------

const NOCODB_URL = process.env.NOCODB_URL;       // e.g., "http://localhost:8080"
const NOCODB_BASE_ID = process.env.NOCODB_BASE_ID; // e.g., "p_xxxxx"
const NOCODB_API_TOKEN = process.env.NOCODB_API_TOKEN;

if (!NOCODB_URL || !NOCODB_BASE_ID || !NOCODB_API_TOKEN) {
  console.error(
    "[FATAL] Missing one or more required env vars: NOCODB_URL, NOCODB_BASE_ID, NOCODB_API_TOKEN"
  );
  console.error(
    "Example (PowerShell):",
    '$env:NOCODB_URL="http://localhost:8080"; ' +
      '$env:NOCODB_BASE_ID="p_xxxxx"; ' +
      '$env:NOCODB_API_TOKEN="your_token_here"; ' +
      "node create_nocodb_from_schema.js"
  );
  process.exit(1);
}

// Path to the Airtable schema JSON
const SCHEMA_PATH = path.join(__dirname, "export", "_schema.json");

// ---------- HELPER: LOAD AIRTABLE SCHEMA ----------

function loadAirtableSchema() {
  console.log("[INFO] Loading Airtable schema from", SCHEMA_PATH);
  const raw = fs.readFileSync(SCHEMA_PATH, "utf8");
  const json = JSON.parse(raw);

  // We expect something like: { "tables": [ { "id": "...", "name": "...", "fields": [ ... ] }, ... ] }
  if (!json.tables || !Array.isArray(json.tables)) {
    throw new Error("Unexpected _schema.json format: missing `tables` array.");
  }

  return json.tables;
}

// ---------- HELPER: MAP AIRTABLE FIELD TO NOCODB COLUMN ----------

/**
 * Map a single Airtable field descriptor to NocoDB column definition.
 *
 * We assume Airtable-ish shape:
 *   {
 *     id: "fldXXXX",
 *     name: "lot_id",
 *     type: "singleLineText" | "number" | "checkbox" | "date" | "dateTime" | ...
 *     options: { ... }
 *   }
 *
 * Returns:
 *   - Plain JS object with NocoDB column properties, or
 *   - null to indicate "skip" (for computed / unsupported field types).
 */
function mapFieldToNocoColumn(field) {
  const name = field.name;
  const type = field.type; // Airtable type string

  // Common NocoDB column base
  const col = {
    column_name: name, // DB column name
    title: name,       // Human label in UI
    // dt / dtx are DB meta types; uidt is NocoDB's UI type
    dt: "varchar",
    dtx: "string",
    uidt: "Text",
  };

  // Treat some Airtable types as "virtual" and skip them entirely from schema creation.
  const VIRTUAL_TYPES = new Set([
    "formula",
    "rollup",
    "lookup",
    "count",
    "createdTime",
    "lastModifiedTime",
    "lastModifiedBy",
    "createdBy",
  ]);

  if (VIRTUAL_TYPES.has(type)) {
    console.log(`  [SKIP] Virtual/computed field "${name}" of type "${type}"`);
    return null;
  }

  switch (type) {
    case "singleLineText":
    case "multilineText":
    case "richText":
    case "longText":
      // Defaults above are fine
      break;

    case "email":
    case "phoneNumber":
    case "url":
      // Keep as text for now; could be specialized later
      break;

    case "number":
    case "currency":
    case "percent":
      col.dt = "decimal";
      col.dtx = "number";
      col.uidt = "Number";
      break;

    case "rating":
      col.dt = "int";
      col.dtx = "integer";
      col.uidt = "Number";
      break;

    case "checkbox":
      col.dt = "boolean";
      col.dtx = "boolean";
      col.uidt = "Bool";
      break;

    case "date":
      col.dt = "date";
      col.dtx = "date";
      col.uidt = "Date";
      break;

    case "dateTime":
    case "created_time":
    case "last_modified_time":
      col.dt = "timestamp";
      col.dtx = "datetime";
      col.uidt = "DateTime";
      break;

    case "singleSelect": {
      col.uidt = "SingleSelect";
      col.dt = "varchar";
      col.dtx = "string";
      if (field.options && Array.isArray(field.options.choices)) {
        // NocoDB stores select options as a comma-separated dtxp string
        col.dtxp = field.options.choices
          .map((c) => (typeof c === "string" ? c : c.name || ""))
          .filter(Boolean)
          .join(",");
      }
      break;
    }

    case "multipleSelects": {
      col.uidt = "MultiSelect";
      col.dt = "varchar";
      col.dtx = "string";
      if (field.options && Array.isArray(field.options.choices)) {
        col.dtxp = field.options.choices
          .map((c) => (typeof c === "string" ? c : c.name || ""))
          .filter(Boolean)
          .join(",");
      }
      break;
    }

    case "attachment":
      col.uidt = "Attachment";
      col.dt = "json";
      col.dtx = "json";
      break;

    case "barcode":
      // Store as text for now (common pattern)
      col.uidt = "Text";
      col.dt = "varchar";
      col.dtx = "string";
      break;

    case "multipleRecordLinks":
    case "singleRecordLink":
    case "linkToAnotherRecord":
      // These will be turned into actual Noco relationships later.
      // For now, store as Text containing IDs (or you can skip, but text is handy).
      col.uidt = "LinkToAnotherRecord"; // doesn't break anything even if relationship not wired yet
      col.dt = "varchar";
      col.dtx = "string";
      break;

    case "rollup":
    case "lookup":
    case "count":
    case "createdBy":
    case "lastModifiedBy":
      // Already covered above in VIRTUAL_TYPES; but keep as safety
      console.log(`  [SKIP] Computed field "${name}" of type "${type}"`);
      return null;

    default:
      console.warn(
        `  [WARN] Unknown/unsupported Airtable type "${type}" for field "${name}", defaulting to Text`
      );
      // Keep default Text config
  }

  return col;
}

// ---------- HELPER: CREATE TABLE IN NOCODB ----------

async function createNocoTableFromAirtableTable(ncClient, baseId, airTable) {
  const tableName = airTable.name;
  console.log(`\n[INFO] Creating NocoDB table for Airtable table: "${tableName}"`);

  const columnDefs = [];
  for (const field of airTable.fields || []) {
    const col = mapFieldToNocoColumn(field);
    if (col) {
      columnDefs.push(col);
    }
  }

  if (!columnDefs.length) {
    console.warn(
      `  [WARN] No concrete fields mapped for "${tableName}". Skipping table creation.`
    );
    return;
  }

  const payload = {
    table_name: tableName, // physical table name; you can slugify if desired
    title: tableName,      // display name in UI
    columns: columnDefs,
  };

  try {
    const url = `${NOCODB_URL.replace(/\/+$/, "")}/api/v2/meta/bases/${baseId}/tables`;
    const res = await ncClient.post(url, payload);
    console.log(`  [OK] Created table "${tableName}" (id: ${res.data?.id || "unknown"})`);
  } catch (err) {
    console.error(`  [ERROR] Failed to create table "${tableName}"`);
    if (err.response) {
      console.error("    Status:", err.response.status);
      console.error("    Data  :", JSON.stringify(err.response.data, null, 2));
    } else {
      console.error("    Error :", err.message);
    }
  }
}

// ---------- MAIN ----------

async function main() {
  console.log("[INFO] NocoDB URL      :", NOCODB_URL);
  console.log("[INFO] NocoDB Base ID  :", NOCODB_BASE_ID);
  console.log("[INFO] Schema JSON path:", SCHEMA_PATH);

  const tables = loadAirtableSchema();

  const ncClient = axios.create({
    headers: {
      "xc-token": NOCODB_API_TOKEN,
      "Content-Type": "application/json",
    },
  });

  console.log(`[INFO] Found ${tables.length} Airtable tables in _schema.json`);

  for (const t of tables) {
    await createNocoTableFromAirtableTable(ncClient, NOCODB_BASE_ID, t);
  }

  console.log("\n[INFO] Done. Review tables in NocoDB UI and adjust relationships / formulas as needed.");
}

main().catch((err) => {
  console.error("[FATAL] Unhandled error:", err);
  process.exit(1);
});
