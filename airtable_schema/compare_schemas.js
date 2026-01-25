#!/usr/bin/env node

/**
 * compare_schemas.js
 *
 * Compares Airtable _schema.json with NocoDB _schema_nocodb.json.
 *
 * Reports:
 *   - Missing tables
 *   - Extra tables
 *   - Missing fields per table
 *   - Extra fields per table
 *   - Duplicate link fields (normalized name collisions)
 */

const fs = require("fs");
const path = require("path");

// Input paths
const AIRTABLE_SCHEMA = process.argv[2] || path.join(process.cwd(), "export", "_schema.json");
const NOCO_SCHEMA = process.argv[3] || path.join(process.cwd(), "../nocodb_schema/export", "_schema_nocodb.json");

// Utility: normalized field name (same logic as migration script)
function normalizeName(name) {
  if (!name) return "";
  let n = name.trim();

  // Strip "From field:" prefix
  n = n.replace(/^From field:\s*/i, "");

  // Strip trailing "(n)" or " n"
  n = n.replace(/\s*\(\d+\)\s*$/, "");
  n = n.replace(/\s+\d+$/, "");

  return n.toLowerCase();
}

// Load files
function loadJson(pathname) {
  return JSON.parse(fs.readFileSync(pathname, "utf8"));
}

const airtable = loadJson(AIRTABLE_SCHEMA);
const nocodb = loadJson(NOCO_SCHEMA);

function byNameMap(list, key = "name") {
  const map = Object.create(null);
  for (const t of list) {
    const n = (t[key] || "").toString().toLowerCase();
    map[n] = t;
  }
  return map;
}

// Create table maps
const atTables = byNameMap(airtable.tables || []);
const ncTables = byNameMap(nocodb.tables || []);

console.log("\n=== SCHEMA COMPARISON ===\n");

// ------------------------------
// TABLE COMPARISON
// ------------------------------
console.log("TABLES:");

const atNames = Object.keys(atTables);
const ncNames = Object.keys(ncTables);

const missingTables = atNames.filter((n) => !ncNames.includes(n));
const extraTables = ncNames.filter((n) => !atNames.includes(n));

if (missingTables.length === 0 && extraTables.length === 0) {
  console.log("  ✔ Table sets match");
} else {
  if (missingTables.length > 0) {
    console.log("  ✖ Missing tables in NocoDB:");
    missingTables.forEach((n) => console.log("    - " + n));
  }
  if (extraTables.length > 0) {
    console.log("  ✖ Extra tables in NocoDB:");
    extraTables.forEach((n) => console.log("    - " + n));
  }
}

console.log("\nFIELDS PER TABLE:");
console.log("(✔ = exact match, ✖ = differences)\n");

// ------------------------------
// FIELD COMPARISON
// ------------------------------
for (const tableName of atNames) {
  const at = atTables[tableName];
  const nc = ncTables[tableName];

  if (!nc) {
    console.log(`TABLE "${tableName}": missing entirely in NocoDB`);
    continue;
  }

  const atFieldNames = (at.fields || []).map((f) => f.name);
  const ncFieldNames = (nc.fields || []).map((f) => f.name);

  const missing = atFieldNames.filter(
    (n) => !ncFieldNames.includes(n)
  );

  const extra = ncFieldNames.filter(
    (n) => !atFieldNames.includes(n)
  );

  if (missing.length === 0 && extra.length === 0) {
    console.log(`✔ ${tableName}`);
  } else {
    console.log(`✖ ${tableName}:`);
    if (missing.length > 0) {
      console.log("    Missing in NocoDB:");
      missing.forEach((f) => console.log("      - " + f));
    }
    if (extra.length > 0) {
      console.log("    Extra in NocoDB:");
      extra.forEach((f) => console.log("      - " + f));
    }
  }
}

// ------------------------------
// DUPLICATE LINK DETECTION
// ------------------------------
console.log("\nPOTENTIAL DUPLICATE LINK FIELDS (normalized-name collisions):\n");

for (const tableName of Object.keys(ncTables)) {
  const t = ncTables[tableName];
  if (!t.fields || !t.fields.length) continue;

  const seen = {};
  const duplicates = [];

  for (const f of t.fields) {
    const norm = normalizeName(f.name);
    if (!seen[norm]) {
      seen[norm] = [f.name];
    } else {
      seen[norm].push(f.name);
    }
  }

  const groups = Object.values(seen).filter((arr) => arr.length > 1);

  if (groups.length > 0) {
    console.log(`TABLE: ${tableName}`);
    groups.forEach((g) => console.log("   " + g.join(", ")));
    console.log();
  }
}

console.log("\n=== END SCHEMA COMPARISON ===\n");
