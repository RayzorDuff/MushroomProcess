#!/usr/bin/env node
/**
 * create_nocodb_from_schema.js
 *
 * One-shot schema bootstrapper for NocoDB using your Airtable export.
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
 * - This focuses on "primitive" fields: text, number, checkbox, date/time, single/multi select, etc.
 * - It deliberately SKIPS computed / virtual fields (formula, lookup, rollup, count, createdTime, lastModified*),
 *   because those require more specific NocoDB meta configuration.
 * - Linked-record fields from Airtable are currently created as plain columns with uidt=LinkToAnotherRecord;
 *   actual relationships can be wired up later.
 */

const fs = require("fs");
const path = require("path");
const axios = require("axios");

// ---------- CONFIG & ENV VALIDATION ----------

const NOCODB_URL = process.env.NOCODB_URL;
const NOCODB_BASE_ID = process.env.NOCODB_BASE_ID;
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

const SCHEMA_PATH = path.join(__dirname, "export", "_schema.json");

// ---------- LOAD SCHEMA ----------

function loadAirtableSchema() {
  console.log("[INFO] Loading Airtable schema from", SCHEMA_PATH);
  const raw = fs.readFileSync(SCHEMA_PATH, "utf8");
  const json = JSON.parse(raw);

  if (!json.tables || !Array.isArray(json.tables)) {
    throw new Error("Unexpected _schema.json format: missing `tables` array.");
  }

  return json.tables;
}

// ---------- FIELD ? COLUMN MAPPER ----------

function mapFieldToNocoColumn(field) {
  const name = field.name;
  const type = field.type;

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

  // >>> NEW: skip link fields for now <<<
  if (
    type === "multipleRecordLinks" ||
    type === "singleRecordLink" ||
    type === "linkToAnotherRecord"
  ) {
    console.log(
      `  [SKIP] Link-to-record field "${name}" of type "${type}" (will be modeled as relationships later)`
    );
    return null;
  }

  const col = {
    column_name: name,
    title: name,
    dt: "varchar",
    dtx: "string",
    uidt: "SingleLineText",
  };

  switch (type) {
    // ----- TEXT -----
    case "singleLineText":
      col.uidt = "SingleLineText";
      col.dt = "varchar";
      col.dtx = "string";
      break;

    case "multilineText":
    case "richText":
    case "longText":
      col.uidt = "LongText";
      col.dt = "text";
      col.dtx = "string";
      break;

    case "email":
      col.uidt = "Email";
      col.dt = "varchar";
      col.dtx = "string";
      break;

    case "phoneNumber":
      col.uidt = "PhoneNumber";
      col.dt = "varchar";
      col.dtx = "string";
      break;

    case "url":
      col.uidt = "URL";
      col.dt = "varchar";
      col.dtx = "string";
      break;

    // ----- NUMERIC -----
    case "number":
      col.uidt = "Decimal";
      col.dt = "decimal";
      col.dtx = "number";
      break;

    case "currency":
      col.uidt = "Currency";
      col.dt = "decimal";
      col.dtx = "number";
      break;

    case "percent":
      col.uidt = "Percent";
      col.dt = "decimal";
      col.dtx = "number";
      break;

    case "rating":
      col.uidt = "Rating";
      col.dt = "int";
      col.dtx = "integer";
      break;

    // ----- BOOLEAN -----
    case "checkbox":
      col.uidt = "Checkbox";
      col.dt = "boolean";
      col.dtx = "boolean";
      break;

    // ----- DATE/TIME -----
    case "date":
      col.uidt = "Date";
      col.dt = "date";
      col.dtx = "date";
      break;

    case "dateTime":
    case "created_time":
    case "last_modified_time":
      col.uidt = "DateTime";
      col.dt = "timestamp";
      col.dtx = "datetime";
      break;

    // ----- SELECTS -----
    case "singleSelect": {
      col.uidt = "SingleSelect";
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

    // ----- ATTACHMENT -----
    case "attachment":
      col.uidt = "Attachment";
      col.dt = "json";
      col.dtx = "json";
      break;

    // ----- FALLBACK -----
    default:
      console.warn(
        `  [WARN] Unknown/unsupported Airtable type "${type}" for field "${name}", defaulting to SingleLineText`
      );
  }

  return col;
}

// ---------- TABLE CREATION ----------

async function createNocoTableFromAirtableTable(ncClient, baseId, airTable) {
  const tableName = airTable.name;
  console.log(`\n[INFO] Creating NocoDB table for Airtable table: "${tableName}"`);

  const columnDefs = [];
  for (const field of airTable.fields || []) {
    const col = mapFieldToNocoColumn(field);
    if (col) columnDefs.push(col);
  }

  if (!columnDefs.length) {
    console.warn(
      `  [WARN] No concrete fields mapped for "${tableName}". Skipping table creation.`
    );
    return;
  }

  const payload = {
    table_name: tableName,
    title: tableName,
    columns: columnDefs,
  };

  try {
    const url = `${NOCODB_URL.replace(/\/+$/, "")}/api/v2/meta/bases/${baseId}/tables`;
    console.log(
      `  [DEBUG] Payload for table "${tableName}":`,
      JSON.stringify(payload, null, 2)
    );
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
  console.log(
    "[INFO] Tables found in ", SCHEMA_PATH,
    tables.map((t) => t.name).join(", ")
  );

  const ncClient = axios.create({
    baseURL: NOCODB_URL.replace(/\/+$/, ""),
    headers: {
      "xc-token": NOCODB_API_TOKEN,
      "Content-Type": "application/json",
      Accept: "application/json",
    },
  });

  console.log(`[INFO] Creating ${tables.length} table(s) in NocoDB...`);

  for (const t of tables) {
    await createNocoTableFromAirtableTable(ncClient, NOCODB_BASE_ID, t);
  }

  console.log("\n[INFO] Done. Review tables in NocoDB UI and adjust relationships / formulas as needed.");
}

main().catch((err) => {
  console.error("[FATAL] Unhandled error:", err);
  process.exit(1);
});
