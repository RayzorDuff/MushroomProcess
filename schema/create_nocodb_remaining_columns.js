#!/usr/bin/env node
/**
 * create_nocodb_remaining_columns.js
 *
 * Second-pass schema importer for NocoDB.
 *
 * Goal:
 *   After running create_nocodb_from_schema.js (which creates core tables
 *   and “simple” columns), this script adds the remaining Airtable fields
 *   that were intentionally skipped in the first pass:
 *
 *   - formula / rollup / lookup / count
 *   - createdTime / lastModifiedTime / createdBy / lastModifiedBy
 *   - linked-record style fields (multipleRecordLinks, etc.)
 *   - any other “complex” field types you want to represent
 *
 * Strategy:
 *   - Read Airtable schema from _schema.json
 *   - Fetch the list of NocoDB tables for the configured base
 *   - For each Airtable field whose type is in EXTRA_FIELD_TYPES:
 *       * Attempt to create a NocoDB column with uidt = "LongText"
 *         (or a specific uidt for created/modified meta fields)
 *   - If NocoDB returns an error (e.g. column already exists), we log and continue.
 *
 * Notes:
 *   - These columns are **not** wired up as formula / lookup / rollup logic.
 *     They are simply placeholders so the schema matches and data can be
 *     migrated / stored. You can later hand-convert critical ones to true
 *     NocoDB formulas or links.
 *
 * Environment variables (same as the first script):
 *   - NOCODB_BASE_URL   : e.g. "http://localhost:8080"
 *   - NOCODB_API_TOKEN  : NocoDB API token
 *   - NOCODB_BASE_ID    : NocoDB Base/Project ID
 *   - SCHEMA_PATH       : (optional) path to _schema.json
 *
 * Usage:
 *   NODE_ENV=production \
 *   NOCODB_URL=http://localhost:8080 \
 *   NOCODB_API_TOKEN=xxxx \
 *   NOCODB_BASE_ID=proj_xxxx \
 *   node create_nocodb_remaining_columns.js > remaining_columns.log 2>&1
 */

const fs = require("fs");
const path = require("path");
const axios = require("axios");

// ---------- Config & helpers ----------

const BASE_URL = process.env.NOCODB_BASE_URL || process.env.NOCODB_URL;
const API_TOKEN = process.env.NOCODB_API_TOKEN;
const BASE_ID = process.env.NOCODB_BASE_ID;
const SCHEMA_PATH =
  process.env.SCHEMA_PATH || path.join(__dirname, "export", "_schema.json");

const DEBUG = process.env.DEBUG === "1" || process.env.DEBUG === "true";

if (!BASE_URL || !API_TOKEN || !BASE_ID) {
  console.error(
    "[FATAL] Missing env vars. Need NOCODB_BASE_URL (or NOCODB_URL), NOCODB_API_TOKEN, NOCODB_BASE_ID"
  );
  process.exit(1);
}

// These are the Airtable field types we assume were *skipped* in first pass
// and that we now want to materialize as plain columns in NocoDB.
const EXTRA_FIELD_TYPES = new Set([
  "formula",
  "rollup",
  "lookup",
  "count",
  "createdTime",
  "lastModifiedTime",
  "createdBy",
  "lastModifiedBy",
  "multipleRecordLinks",
  "singleRecordLink",
  "multipleLookupValues",
  "multipleCollaborators",
  "autoNumber", // if skipped before
  "button",     // just for completeness
  "barcode",
  // Add more here if you discover additional types in _schema.json
]);

// For some special Airtable meta types, we can map to a closer NocoDB uidt.
// Otherwise we fall back to "LongText".
function uidtForExtraFieldType(type) {
  switch (type) {
    case "createdTime":
      return "CreatedTime";
    case "lastModifiedTime":
      return "LastModifiedTime";
    case "createdBy":
      return "CreatedBy";
    case "lastModifiedBy":
      return "LastModifiedBy";
    default:
      // Generic textual representation
      return "LongText";
  }
}

function logDebug(...args) {
  if (DEBUG) console.log("[DEBUG]", ...args);
}

const nocodb = axios.create({
  baseURL: BASE_URL.replace(/\/+$/, ""),
  headers: {
    "xc-token": API_TOKEN,
    "Content-Type": "application/json",
  },
});

// Normalize table names for matching
function normName(name) {
  return (name || "").trim().toLowerCase();
}

// Given "nc_o7y3___strains" -> "strains"
function stripPrefix(name) {
  if (!name) return name;
  const idx = name.lastIndexOf("___");
  if (idx >= 0 && idx + 3 < name.length) {
    return name.substring(idx + 3);
  }
  return name;
}

// ---------- Core logic ----------

async function main() {
  console.log("[INFO] Starting remaining-column import for NocoDB...");
  console.log("[INFO] Base URL : ", BASE_URL);
  console.log("[INFO] Base ID  : ", BASE_ID);
  console.log("[INFO] Schema   : ", SCHEMA_PATH);

  // 1) Load Airtable schema
  const schemaRaw = fs.readFileSync(SCHEMA_PATH, "utf8");
  const schema = JSON.parse(schemaRaw);

  if (!schema.tables || !Array.isArray(schema.tables)) {
    console.error("[FATAL] _schema.json does not contain a 'tables' array");
    process.exit(1);
  }

  // 2) Fetch NocoDB tables for this base
  let nocoTables = [];
  try {
    const tablesResp = await nocodb.get(
      `/api/v2/meta/bases/${encodeURIComponent(BASE_ID)}/tables`
    );

    const raw = tablesResp.data;
    // Be defensive about shape of response
    if (Array.isArray(raw)) {
      nocoTables = raw;
    } else if (raw && Array.isArray(raw.list)) {
      nocoTables = raw.list;
    } else if (raw && Array.isArray(raw.tables)) {
      nocoTables = raw.tables;
    } else {
      console.error(
        "[FATAL] Unexpected response shape from /meta/bases/{baseId}/tables"
      );
      console.error(
        "[FATAL] Got:",
        JSON.stringify(raw, null, 2).slice(0, 2000)
      );
      process.exit(1);
    }
  } catch (err) {
    console.error(
      "[FATAL] Failed to fetch tables from NocoDB meta API:",
      err.response?.status,
      err.response?.data || err.message
    );
    process.exit(1);
  }

  console.log(
    "[INFO] NocoDB tables in base:",
    nocoTables
      .map((t) => `${t.table_name || t.title || "(no-name)"} [${t.id}]`)
      .join(", ")
  );

  // Map normalizedName -> table meta
  const tablesByName = new Map();
  for (const t of nocoTables) {
    const rawName = t.table_name || t.title || "";
    const keyFull = normName(rawName);
    if (keyFull) {
      tablesByName.set(keyFull, t);
    }

    // Also register stripped version (after "___") to match Airtable names
    const stripped = stripPrefix(rawName);
    const keyStripped = normName(stripped);
    if (keyStripped && keyStripped !== keyFull) {
      tablesByName.set(keyStripped, t);
    }
  }

  // 3) For each Airtable table, add extra fields
  for (const atTable of schema.tables) {
    const tableName = atTable.name;
    const key = normName(tableName);

    console.log(`\n[INFO] Processing Airtable table "${tableName}"...`);
    const nocoTableMeta = tablesByName.get(key);
    if (!nocoTableMeta) {
      console.warn(
        `[WARN] Skipping table "${tableName}" – not found in NocoDB base "${BASE_ID}"`
      );
      continue;
    }

    const tableId = nocoTableMeta.id;
    if (!tableId) {
      console.warn(
        `[WARN] Skipping table "${tableName}" – NocoDB table has no 'id'`
      );
      continue;
    }

    // Optionally, we could fetch existing columns to avoid duplicate creates.
    // For now, we optimistically try creates and treat "already exists" as non-fatal.
    const fields = atTable.fields || [];
    const extraFields = fields.filter((f) =>
      EXTRA_FIELD_TYPES.has((f.type || "").trim())
    );

    if (!extraFields.length) {
      console.log(
        `[INFO] No extra fields to add for table "${tableName}". Skipping.`
      );
      continue;
    }

    console.log(
      `[INFO] Extra fields to add for "${tableName}": ${extraFields
        .map((f) => `${f.name} [${f.type}]`)
        .join(", ")}`
    );

    for (const field of extraFields) {
      const colName = field.name;
      const type = field.type;

      // Build minimal column payload; this avoids the SQLite "near" errors we hit
      // when providing dt/dtx incorrectly.
      const payload = {
        column_name: colName,
        title: colName,
        uidt: uidtForExtraFieldType(type),
      };

      logDebug(
        `[DEBUG] Creating extra column "${colName}" (${type}) on table "${tableName}" with:`,
        payload
      );

      try {
        await nocodb.post(
          `/api/v2/meta/tables/${encodeURIComponent(tableId)}/columns`,
          payload
        );
        console.log(
          `[INFO]   + Created extra column "${colName}" (${type}) on "${tableName}"`
        );
      } catch (err) {
        const status = err.response?.status;
        const data = err.response?.data;
        console.warn(
          `[WARN]   ! Failed to create column "${colName}" on "${tableName}" (status ${
            status || "?"
          })`
        );
        if (data) {
          console.warn("        Response:", JSON.stringify(data));
        } else {
          console.warn("        Error:", err.message);
        }
        // carry on to next column
      }
    }
  }

  console.log("\n[INFO] Remaining-column import finished.");
}

main().catch((err) => {
  console.error("[FATAL] Unhandled error in remaining-column import:", err);
  process.exit(1);
});
