#!/usr/bin/env node
require('./load_env');
/**
 * Script: create_nocodb_schema_full.js
 * Version: 2025-12-24.2
 * =============================================================================
 *  Copyright © 2025 Dank Mushrooms, LLC
 *  Licensed under the GNU General Public License v3 (GPL-3.0-only)
 *
 *  This program is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation, either version 3 of the License.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program. If not, see <https://www.gnu.org/licenses/>.
 * =============================================================================
 *
 * Combined first-pass + second-pass migration script:
 *   - Creates NocoDB tables & primitive fields from Airtable schema (_schema.json)
 *   - Creates LinkToAnotherRecord relations for Airtable multipleRecordLinks
 *   - Creates Formula fields for Airtable formula fields
 *   - Creates Rollup and Lookup fields (when enabled via env flags)
 *   - Preserves Airtable formulas through fallback LongText fields when unsupported
 *   - Adds dependency-graph analysis and multi-phase processing to handle chained
 *     lookup→lookup, lookup→rollup, rollup→rollup dependencies
 *   - Adds stabilization waits for NocoDB v3 LTAR metadata
 *   - Generates a JSON debug file containing details about each migration phase,
 *     created fields, failures, retry attempts, dependency info, and relevant
 *     Airtable → NocoDB mappings (moderate detail)
 *
 * ENV:
 *   NOCODB_URL               (default: http://localhost:8080)
 *   NOCODB_BASE_ID           (required)
 *   NOCODB_API_TOKEN         (or NC_TOKEN)
 *   NOCODB_API_VERSION       ("v2" or "v3"; default: "v2")
 *   SCHEMA_PATH              (default: ./export/_schema.json)
 *
 *   NOCODB_RECREATE_LINKS    ("true" to create LTAR columns)
 *   NOCODB_RECREATE_ROLLUPS  ("true" to create rollup columns)
 *   NOCODB_RECREATE_LOOKUPS  ("true" to create lookup columns)
 *
 *   NOCODB_DEBUG_PATH        (optional path to JSON debug file)
 *                             Falls back to ./nocodb_migration_debug.json
 *
 * NOTES:
 *   - Structural approach is preserved from the original scripts for diff clarity.
 *   - Merges first-pass table creation (from create_nocodb_from_schema.js)
 *     with second-pass logic without altering original function order except where
 *     required to merge responsibilities or add dependency logic.
 *   - Whitespace and comments kept as close as possible to the originals.
 */

const fs = require('fs');
const path = require('path');
const axios = require('axios');

// Shared API client + caller (already configured w/ NOCODB_URL + xc-token)
const apiCall = ENV.apiCall;
if (!NOCODB_BASE_ID) {
  console.error(
    'ERROR: NOCODB_BASE_ID is required (the NocoDB base / project id).'
  );
  process.exit(1);
}

if (!fs.existsSync(SCHEMA_PATH)) {
  console.error(`ERROR: SCHEMA_PATH does not exist: ${SCHEMA_PATH}`);
  process.exit(1);
}
console.log(`[INFO] NOCODB_API_VERSION = ${NOCODB_API_VERSION}, IS_V3 = ${IS_V3}, IS_V2 = ${IS_V2}`);
console.log(`[INFO] NOCODB_API_VERSION_LINKS = ${NOCODB_API_VERSION_LINKS}, LINKS_IS_V3 = ${LINKS_IS_V3}, LINKS_IS_V2 = ${LINKS_IS_V2}`);

// New env toggles for link / rollup / lookup recreation
const RECREATE_LINKS = /^true$/i.test(
  process.env.NOCODB_RECREATE_LINKS || ''
);
const RECREATE_ROLLUPS = /^true$/i.test(
  process.env.NOCODB_RECREATE_ROLLUPS || ''
);
const RECREATE_LOOKUPS = /^true$/i.test(
  process.env.NOCODB_RECREATE_LOOKUPS || ''
);

// Debug JSON output file (Option 3)
const DEBUG_OUTPUT_PATH =
  process.env.NOCODB_DEBUG_PATH ||
  path.join(process.cwd(), 'nocodb_migration_debug.json');
  
// Optional: export of final NocoDB schema for comparison with Airtable _schema.json
const NOCO_SCHEMA_EXPORT_PATH =
  process.env.NOCODB_SCHEMA_EXPORT_PATH ||
  path.join(process.cwd(), 'export', '_schema_nocodb.json');  

// In-memory debug structure
const debugData = {
  phases: {
    links: [],
    simpleLookups: [],
    simpleRollups: [],
    chainedLookups: [],
    chainedRollups: []
  },
  created: {
    links: [],
    lookups: [],
    rollups: [],
    formulas: []
  },
  failed: {
    links: [],
    lookups: [],
    rollups: [],
    formulas: []
  }
};

// NEW: formulas we want to retry at the end
const deferredFormulaCreates = [];

// Track which Airtable link pairs we've already created in NocoDB
const processedAirtableLinkPairs = new Set();

const nocopkName = 'nocopk';
const nocoUUIDName = 'nocouuid';
const nocoCreatedTime = 'CreatedAt';
const nocoModifiedTime = 'UpdatedAt';
  
console.log(`[INFO] Base URL : ${NOCODB_URL}`);
console.log(`[INFO] Base ID  : ${NOCODB_BASE_ID}`);
console.log(`[INFO] Schema   : ${SCHEMA_PATH}`);
console.log(
  `[INFO] Links API: ${
    LINKS_IS_V2 ? 'v2 (/api/v2/meta)' : 'v3 (/api/v3/meta)'
  }`
);
console.log(`[INFO] Recreate links  : ${RECREATE_LINKS}`);
console.log(`[INFO] Recreate rollups: ${RECREATE_ROLLUPS}`);
console.log(`[INFO] Recreate lookups: ${RECREATE_LOOKUPS}`);
console.log(`[INFO] Debug JSON path : ${DEBUG_OUTPUT_PATH}`);

// --------------------------------------------
// LOADING AIRTABLE SCHEMA
// --------------------------------------------

function loadAirtableSchema(schemaPath) {
  const full = path.resolve(schemaPath);
  if (!fs.existsSync(full)) {
    throw new Error(`Schema file not found: ${full}`);
  }
  const raw = fs.readFileSync(full, 'utf8');
  return JSON.parse(raw);
}

// Build convenient maps: tablesById, tablesByName, fieldsById, fieldsByTableAndId
function buildAirtableMaps(schema) {
  const tablesById = {};
  const tablesByName = {};
  const fieldsById = {};
  const fieldsByTableAndId = {};

  for (const table of schema.tables || []) {
    tablesById[table.id] = table;
    tablesByName[table.name] = table;

    const perTable = {};
    for (const field of table.fields || []) {
      fieldsById[field.id] = field;
      perTable[field.id] = field;
    }
    fieldsByTableAndId[table.id] = perTable;
  }

  return { tablesById, tablesByName, fieldsById, fieldsByTableAndId };
}

// --------------------------------------------
// (Merged) FIRST-PASS: CREATE TABLES IN NOCO (from Airtable schema)
// (Preserves original code structure from create_nocodb_from_schema.js)
// --------------------------------------------

function mapFieldToNocoColumn_FirstPass(field) {
  const name = field.name;

  // Base definition – NOTE: no dt / dtx here.
  const col = {
    column_name: name,
    title: name,
  };

  const type = field.type;

  // --- Text-ish fields ---
  if (
    type === 'singleLineText' ||
    type === 'richText' ||
    type === 'multilineText' ||
    type === 'longText'
  ) {
    col.uidt = 'LongText';
    return col;
  }

  // --- Percent ---
  if (type === 'percent') {
    col.uidt = 'Percent';
    return col;
  }

  // --- Numbers & decimals ---
  // Airtable "number" fields can be either integer-like or decimal-like depending
  // on the configured precision (decimal places). If precision > 0, we must create
  // a Decimal column in NocoDB (Postgres numeric) to avoid silent rounding and
  // import failures when payloads contain decimals.
  if (type === 'number' ) {
    const precision =
      field && field.options && typeof field.options.precision === 'number'
        ? field.options.precision
        : 0;
    col.uidt = precision > 0 ? 'Decimal' : 'Number';
    return col;
  }

  if (type === 'currency' || type === 'decimal') {
    col.uidt = 'Decimal';
    return col;
  }

  // --- Dates & times ---
  if (type === 'date') {
    col.uidt = 'Date';
    return col;
  }

  if (type === 'dateTime' || type === 'createdTime' || type === 'lastModifiedTime') {
    col.uidt = 'DateTime';
    return col;
  }

  // --- Selects ---
  if (type === 'singleSelect') {
    col.uidt = 'SingleSelect';
    if (field.options && Array.isArray(field.options.choices)) {
      // NocoDB’s meta API accepts comma separated options via dtxp
      col.dtxp = field.options.choices.map((c) => c.name || c).join(',');
    }
    return col;
  }

  if (type === 'multipleSelect') {
    col.uidt = 'MultiSelect';
    if (field.options && Array.isArray(field.options.choices)) {
      col.dtxp = field.options.choices.map((c) => c.name || c).join(',');
    }
    return col;
  }

  // --- Linked-record, lookup, rollup (placeholder removed) ---
  if (
    type === 'multipleRecordLinks' ||
    type === 'multipleLookupValues' ||
    type === 'rollup' ||
    type === 'formula'
  ) {
    // skip creating placeholder; second-pass handles creation
    return null;
  }

  // --- Checkboxes ---
  if (type === 'checkbox') {
    col.uidt = 'Checkbox';
    return col;
  }

  // --- Attachments ---
  if (type === 'multipleAttachments') {
    col.uidt = 'Attachment';
    return col;
  }

  // --- Fallback ---
  col.uidt = 'LongText';
  return col;
}

async function createNocoTableFromAirtableTable_FirstPass(
  ncClient,
  baseId,
  airTable
) {
  const tableName = airTable.name;
  console.log(`\n[INFO] Creating NocoDB table for Airtable table: "${tableName}"`);

  const columnDefs = [];
  const fields = airTable.fields || [];
  const primaryField = fields[0] || null;

  //
  // STEP 1: always create a dedicated NocoDB numeric PK.
  //         This avoids trying to back the primary key with a formula type,
  //         which is not a real SQL type in Postgres.
  //
  if (primaryField) {
    //
    // Primary key: dedicated auto-increment numeric column
    //
    if (IS_V3) {
      // v3 style PK – AutoNumber
      const pkCol = {
        column_name: nocopkName,
        title: nocopkName,
        type: 'AutoNumber',
        ai: true,
        pk: true,
        description: 'Auto-generated Primary Key',
      };
      columnDefs.push(pkCol);
    } else {
      // v2 style PK – ID with autoincrement
      const pkCol = {
        column_name: nocopkName,
        title: nocopkName,   
        uidt: 'ID',
        dt: 'int8',          // a real DB type behind the scenes
        ai: true,
        pk: true,
        nn: true,
        description: 'Auto-generated Primary Key',
      };
      columnDefs.push(pkCol);
    }

    //
    // Secondary UUID column: auto-generated via gen_random_uuid()
    //
    if (IS_V3) {
      // v3 meta uses `type` + `options` (same pattern as Formula fields)
      const uuidCol = {
        column_name: nocoUUIDName,
        title: nocoUUIDName,
        type: 'SpecificDBType',
        options: {
          dbType: 'uuid',                 // Postgres uuid type
          defaultValue: 'gen_random_uuid()',
          nn: true,
          un: true,
        },
        description: 'Auto-generated UUID',
      };

      columnDefs.push(uuidCol);
    } else {
      // v2 meta style – use uidt/dt + default/nn/un flags
      const uuidCol = {
        column_name: nocoUUIDName,
        title: nocoUUIDName,
        uidt: 'SpecificDBType',
        dt: 'uuid',
        dtxp: JSON.stringify({ length: 36 }), // harmless metadata
        default: 'gen_random_uuid()',
        nn: true,     // not null
        un: true,     // unique
        description: 'Auto-generated UUID',
      };

      columnDefs.push(uuidCol);
    }

    // STEP 2: create concrete Airtable fields.
    //         The *first* Airtable field becomes the NocoDB "display value"
    //         (pv=true) instead of the PK. 
    if (primaryField.type === "formula") {
      // First field is a formula – translate it for NocoDB and use it as PK.
      const rawFormula =
        (primaryField.options && primaryField.options.formula) || "";
  
      // We only need basic translation (e.g., DATETIME_FORMAT -> DATESTR)
      // AirtableMaps isn't available here, but that's fine because your PK
      // formulas don't reference other fields.
      const translatedFormula = translateAirtableFormulaToNoco(
        rawFormula,
        airTable // airtableMaps omitted
      );
  
      if (IS_V3) {
        // For v3 API: use `type` + `options.formula`
        const pkCol = {
          column_name: primaryField.name,
          title: primaryField.name,
          type: "Formula",
          options: {
            formula: translatedFormula,
          },
          pv: true,
        };
        
        
        columnDefs.push(pkCol);
      } else {
        // For v2 API: uidt Formula, but underlying DB type must be real
        const pkCol = {
          column_name: primaryField.name,
          title: primaryField.name,
          uidt: "Formula",
          dt: "text",                 // <— was "formula"
          colOptions: {
            formula: translatedFormula,
          },
          formula: translatedFormula,
          formula_raw: translatedFormula,
          pv: true,
        };
        columnDefs.push(pkCol);
      }
      
    } else {
        // First field is a “normal” field – map it and mark it as PK.
        let mappedPkCol = mapFieldToNocoColumn_FirstPass(primaryField);
  
        // If the mapping returns null (e.g. unsupported type), we’ll fall back below.
        if (mappedPkCol) {
          mappedPkCol.pv = true;
          columnDefs.push(mappedPkCol);
        }    
    }
  }


  //
  // STEP 3: add the remaining Airtable fields (skipping the one we already used as PV).
  //
  for (const field of fields) {
    // Skip the first field if we already turned it into the PK
    if (primaryField && field.id === primaryField.id) continue;

    let col = mapFieldToNocoColumn_FirstPass(field);
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
    table_name: tableName,
    title: tableName,
    columns: columnDefs,
  };

  try {
    const url = `${META_PREFIX}/bases/${baseId}/tables`;
    console.log(
      `  [DEBUG] Payload for table "${tableName}":`,
      JSON.stringify(payload, null, 2)
    );
    const res = await ncClient.post(url, payload);
    console.log(
      `  [OK] Created table "${tableName}" (id: ${res.data?.id || "unknown"})`
    );
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

// --------------------------------------------
// NOCO: FETCH TABLES + FIELDS
// --------------------------------------------

/**
 * Shared implementation now lives in load_env.js
 */
async function fetchNocoTablesWithFields() {
  const tables = await fetchMetaTables({ includeFields: IS_V3 });
  if (IS_V2) {
    for (const table of tables) {
      await refreshNocoFieldsForTable(table);
    }
  }
  logInfo(
    IS_V2
      ? `Fetched ${tables.length} NocoDB tables (v2, columns hydrated).`
      : `Fetched ${tables.length} NocoDB tables (v3, inline fields).`
  );
  return tables;
}

// Find Noco table by Airtable table
function findNocoTableForAirtableTable(atTable, nocoTables) {
  const exact = nocoTables.find(
    (t) => (t.title || t.name || t.table_name) === atTable.name
  );
  if (exact) return exact;

  const lower = atTable.name.toLowerCase();
  return nocoTables.find(
    (t) =>
      (t.title && t.title.toLowerCase() === lower) ||
      (t.name && t.name.toLowerCase() === lower) ||
      (t.table_name && t.table_name.toLowerCase() === lower)
  );
}

// --------------------------------------------
// NOCO: FIELDS / COLUMNS HELPERS
// --------------------------------------------

/**
 * Refresh fields/columns for a NocoDB table in-place.
 *
 * v3:
 *   GET /api/v3/meta/bases/{baseId}/tables/{tableId}
 *   -> data.fields[]
 *
 * v2:
 *   GET /api/v2/meta/tables/{tableId}
 *   -> data.columns[]
 */
async function refreshNocoFieldsForTable(table) {
  const fields = await fetchMetaFieldsForTable(table.id);
  table.fields = fields;

  return fields;
}

// Helper: get logical type name from a field (v3 might use type or uidt)
function fieldType(field) {
  return field.type || field.uidt || null;
}

// --------------------------------------------
// NAME / SLUG HELPERS
// --------------------------------------------

function slugify(name) {
  return name
    .toString()
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '');
}

function normalizeLinkName(name) {
  if (!name) return '';
  let n = name.trim();

  // Strip older helper prefixes we might have used
  n = n.replace(/^From field:\s*/i, '');

  // NOTE:
  // We intentionally DO NOT strip numeric suffixes anymore (e.g. "lots 2", "products 2").
  // Airtable uses names like "lots 2", "lots 4", "products 2" as *distinct* link fields,
  // and we need those to exist in NocoDB for data migration. Collapsing them would cause
  // us to skip creating the additional links.

  // Basic lower-casing
  return n.toLowerCase();
}

/**
 * Choose a unique field (column) name for a table, based on a seed title.
 *
 * Returns:
 *   { title, column_name }
 */
function chooseUniqueFieldName(table, baseTitle, suffix) {
  const suggestedTitle = suffix
    ? `${baseTitle} ${suffix}`
    : baseTitle;

  const fields = table.fields || [];
  const existingNames = new Set(
    fields.map((f) => f.title || f.name || f.column_name).filter(Boolean)
  );

  let title = suggestedTitle;
  let i = 1;
  while (existingNames.has(title)) {
    i += 1;
    title = `${suggestedTitle} (${i})`;
  }

  const baseSlug = slugify(title);
  let column_name = baseSlug;
  const existingColNames = new Set(
    fields.map((f) => f.name || f.column_name || f.title).filter(Boolean)
  );
  let j = 1;
  while (existingColNames.has(column_name)) {
    j += 1;
    column_name = `${baseSlug}_${j}`;
  }

  return { title, column_name };
}

// -----------------------------------------------------------------------------
// MANUAL DESCRIPTION ACCUMULATORS
// -----------------------------------------------------------------------------

const manualLinkDescriptions = [];
const manualRollupDescriptions = [];
const manualLookupDescriptions = [];
const manualFormulaFallbacks = [];

// -----------------------------------------------------------------------------
// FORMULA TRANSLATION HELPERS
// -----------------------------------------------------------------------------

function translateAirtableFormulaToNoco(atFormula, atTable, airtableMaps) {
  if (!atFormula || typeof atFormula !== 'string') return atFormula;

  let f = atFormula;

  // Normalize newlines
  f = f.replace(/\r\n/g, '\n');

  // Normalize curly / smart quotes to straight quotes
  f = f.replace(/[“”]/g, '"');
  f = f.replace(/[‘’]/g, "'");

  // If we have Airtable metadata, rewrite {fieldId} -> {Field Name}
  if (atTable && airtableMaps && airtableMaps.fieldsByTableAndId) {
    const perTable = airtableMaps.fieldsByTableAndId[atTable.id] || {};
    f = f.replace(/\{([^}]+)\}/g, (m, inner) => {
      const fld = perTable[inner];
      if (!fld) return m;
      const safeName = fld.name || inner;
      return `{${safeName}}`;
    });
  }

  // DATETIME_FORMAT(date, pattern) -> date
  f = f.replace(
    /DATETIME_FORMAT\s*\(\s*CREATED_TIME\s*\(\s*\)\s*,\s*(['"])YYMMDD\1\s*\)\s*;?/gi,
    `RIGHT(CONCAT(YEAR({${nocoCreatedTime}}), ""), 2) + MONTH({${nocoCreatedTime}}) + DAY({${nocoCreatedTime}}) `
  );
  
  f = f.replace(
    /DATETIME_FORMAT\s*\(\s*([^,]+)\s*,\s*("[^"]*"|'[^']*')\s*\)/gi,
    'DATESTR($1)'
  );

  // DATEADD(date, n, 'unit') -> DATEADD(date, n, 'unit') with singular unit
  // Airtable uses plural: 'days','months','years','hours','minutes','seconds'
  // NocoDB expects singular: 'day','month','year','hour','minute','second'
  f = f.replace(
    /\bDATEADD\s*\(\s*([^,]+?)\s*,\s*([^,]+?)\s*,\s*(['"])\s*(years?|months?|days?|hours?|minutes?|seconds?)\s*\3\s*\)/gi,
    (m, dateExpr, nExpr, quote, unit) => {
      const u = unit.toLowerCase().trim();
      const singular =
        u.endsWith('s') && !u.endsWith('ss') ? u.slice(0, -1) : u; // safe enough here
      return `DATEADD(${dateExpr.trim()}, ${nExpr.trim()}, ${quote}${singular}${quote})`;
    }
  );

  // SET_TIMEZONE(date, "TZ") -> date
  f = f.replace(
    /SET_TIMEZONE\s*\(\s*([^,]+)\s*,\s*("[^"]*"|'[^']*')\s*\)/gi,
    '$1'
  );

  // CREATED_TIME() -> {CreatedAt}
  f = f.replace(/CREATED_TIME\s*\(\s*\)/gi, `{${nocoCreatedTime}}`);

  // LAST_MODIFIED_TIME() -> {UpdatedAt}
  f = f.replace(/LAST_MODIFIED_TIME\s*\(\s*\)/gi, `{${nocoModifiedTime}}`);

  // TRUE() / FALSE() -> TRUE / FALSE
  //f = f.replace(/\bTRUE\s*\(\s*\)/gi, 'TRUE');
  //f = f.replace(/\bFALSE\s*\(\s*\)/gi, 'FALSE');

  // BLANK() -> ""
  // IF({Field}, ...)
  f = f.replace(
    /\bIF\s*\(\s*(\{[^}]+\})\s*,/gi,
    'IF(ISNOTBLANK($1),'
  );
  
  // IF(NOT({Field}), ...)
  f = f.replace(
    /\bIF\s*\(\s*NOT\s*\(\s*(\{[^}]+\})\s*\)\s*,/gi,
    'IF(ISBLANK($1),'
  );
  // {Field} == BLANK() or ""
  f = f.replace(
    /\b(\{[^}]+\})\s*==?\s*(BLANK\s*\(\s*\)|""|'')/gi,
    'ISBLANK($1)'
  );
  // {Field} != BLANK() or ""
  f = f.replace(
    /\b(\{[^}]+\})\s*!=\s*(BLANK\s*\(\s*\)|""|'')/gi,
    'ISNOTBLANK($1)'
  );  
  // Final cleanup: BLANK() → ""
  f = f.replace(/\bBLANK\s*\(\s*\)/gi, '""');  

  // SUM replaced by ADD
  f = f.replace(
    /\bSUM\s*\(\s*([^,]+?)\s*,\s*((?:[^()]+|\([^()]*\))+)\s*\)/gi,
    'ADD($1, $2)'
  );

  // RECORD_ID() -> ""
  f = f.replace(/RECORD_ID\s*\(\s*\)/gi, `CONCAT({${nocoUUIDName}}, "")`);

  // <> -> !=
  f = f.replace(/<>/g, '!=');

  // Convert `{field} = value` to `{field} == value`
  f = f.replace(/(\{[^}]+\})\s*=\s*/g, '$1 == ');
  f = f.replace(/(\))\s*=\s*/g, '$1 == ');

  // Normalize TRUE/FALSE comparisons
  f = f.replace(/\s==\s*TRUE\b/gi, ' == TRUE');
  f = f.replace(/\s==\s*FALSE\b/gi, ' == FALSE');

  // Cleanup whitespace
  f = f.replace(/[ \t]+/g, ' ');
  f = f.replace(/\n\s+/g, '\n');
  f = f.trim();

  return f;
}

function escapeRegex(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function formulaReferencesLookupInUnsupportedWay(formula, atTable, airtableMaps) {
  if (!formula || !atTable || !airtableMaps) {
    return false;
  }

  const fields = atTable.fields || [];

  // Names of any lookup / rollup fields on this table
  const badNames = fields
    .filter((fld) =>
      fld &&
      (fld.type === 'multipleLookupValues' || fld.type === 'rollup')
    )
    .map((fld) => fld.name)
    .filter(Boolean);

  if (!badNames.length) return false;

  const f = String(formula);

  // If the formula references ANY of those fields by {Field Name}, treat as unsupported
  for (const name of badNames) {
    const re = new RegExp(`\\{${escapeRegex(name)}\\}`, 'i');
    if (re.test(f)) {
      return true;
    }
  }

  return false;
}

// --------------------------------------------
// CREATE / DELETE FIELD (COLUMN) WRAPPERS
// --------------------------------------------

async function createFieldOnTable(tableId, payload) {
  const url = META_TABLE_FIELDS(tableId);
  return await apiCall('post', url, payload);
}

// Separate helper for Link fields, allowing a different meta API version.
async function createFieldOnTableForLinks(tableId, payload) {
  const url = LINK_META_TABLE_FIELDS(tableId);
  return await apiCall('post', url, payload);
}

async function deleteFieldById(fieldId) {
  const url = META_FIELD(fieldId);
  return await apiCall('delete', url);
}

async function renameAutoInverseLinkField({
  parentNoco,
  childNoco,
  linkField,
  existingChildLinksToParent,
  newInverseTitle,
}) {
  // Ensure fields are up to date
  await refreshNocoFieldsForTable(childNoco);

  const isLinkToParent = (f) => {
    const t = fieldType(f);
    if (t !== "Links" && t !== "LinkToAnotherRecord") return false;

    const opt = f.options || f.colOptions || {};
    const relatedId =
      opt.related_table_id ||
      opt.fk_related_model_id ||
      opt.fk_relation_id;

    return String(relatedId) === String(parentNoco.id);
  };

  const linkFieldId = linkField && linkField.id;

  // Candidates: link fields that:
  //  - point to parentNoco
  //  - did NOT exist before we created linkField
  //  - are NOT the primary linkField itself
  const candidates = (childNoco.fields || []).filter((f) => {
    if (!isLinkToParent(f)) return false;

    // Skip any link that was already present before we created the primary link
    if (existingChildLinksToParent && existingChildLinksToParent.has(f.id)) {
      return false;
    }

    // Skip the primary field we just created; we never want to rename
    // the Airtable-named primary link, especially for self-links.
    if (linkFieldId && f.id === linkFieldId) {
      return false;
    }

    return true;
  });

  if (candidates.length !== 1) {
    if (candidates.length === 0) {
      logWarn(
        `  Could not find auto-inverse link on "${childNoco.title || childNoco.name}" to rename to "${newInverseTitle}".`
      );
    } else {
      logWarn(
        `  Multiple auto-inverse links found on "${childNoco.title || childNoco.name}" for parent "${parentNoco.title || parentNoco.name}" – not renaming.`
      );
    }
    return;
  }

  const autoField = candidates[0];
  const currentTitle =
    autoField.title || autoField.name || autoField.column_name;

  // Already has the desired name
  if (currentTitle === newInverseTitle) {
    return;
  }

  const payload = {
    title: newInverseTitle,
  };

  try {
    await apiCall("patch", META_FIELD(autoField.id), payload);
    autoField.title = newInverseTitle;
    autoField.column_name = newInverseTitle;

    logInfo(
      `  Renamed auto-inverse link "${currentTitle}" on "${childNoco.title || childNoco.name}" to Airtable field name "${newInverseTitle}".`
    );
  } catch (err) {
    logWarn(
      `  Failed to rename auto-inverse link "${currentTitle}" on "${childNoco.title || childNoco.name}" to "${newInverseTitle}": ${err.message}`
    );
  }
}

// -----------------------------------------------------------------------------
// FORMULA FIELD CREATION (with LongText fallback)
// -----------------------------------------------------------------------------

// LongText fallback for rejected formulas
async function createFormulaFallbackField({ parentTable, baseTitle, formula }) {
  const { title, column_name } = chooseUniqueFieldName(
    parentTable,
    `${baseTitle}_formula_src`,
    '(fallback)'
  );

  const body = {
    // v3-style
    type: 'LongText',
    title,
    column_name,
    // v2-style keys that v3 still understands (avoids "dt" undefined)
    dt: 'text',
    uidt: 'LongText',
  };

  try {
    const field = await createFieldOnTable(parentTable.id, body);
    parentTable.fields = parentTable.fields || [];
    parentTable.fields.push(field);

    const fieldTitle = body.title || field.title || field.name || field.column_name;
    const parentTitle =
      parentTable.title || parentTable.name || parentTable.table_name;

    logInfo(
      `  Created LongText "${fieldTitle}" on "${parentTitle}" to preserve original formula expression.`
    );

    // Track this so we can summarize all formula fallbacks at the end.
    manualFormulaFallbacks.push({
      table: parentTitle,
      column: baseTitle,
      fieldTitle,
      formula,
    });

    debugData.failed.formulas.push({
      table: parentTitle,
      field: baseTitle,
      reason: "Formula incompatible with NocoDB; stored as fallback LongText",
      formula: formula
    });

    return field;
  } catch (err) {
    logError(
      `  Failed to create fallback LongText for formula "${baseTitle}" on "${parentTable.title}": ${err.message}`
    );
    return null;
  }
}

// --------------------------------------------
// AIRTABLE HELPERS
// --------------------------------------------

/**
 * Get Airtable "multipleRecordLinks" fields for a table.
 */
function getAirtableLinkFields(atTable) {
  return (atTable.fields || []).filter(
    (f) => f.type === 'multipleRecordLinks'
  );
}

/**
 * Get Airtable formula fields (type === 'formula').
 */
function getAirtableFormulaFields(atTable) {
  return (atTable.fields || []).filter((f) => f.type === 'formula');
}

// --------------------------------------------
// CREATE FORMULA FIELD
// --------------------------------------------

async function createFormulaField({
  parentTable,
  baseTitle,
  formula,
  originalFormula,
  atTable,
  airtableMaps,
  atField,
  finalAttempt, // optional, boolean
  isDisplayValue, // optional, boolean
}) {
  if (!formula) {
    logWarn(
      `  Formula field "${baseTitle}" on "${parentTable.title}" has no options.formula; skipping.`
    );
    return null;
  }

  const translated = translateAirtableFormulaToNoco(formula, atTable, airtableMaps);
  const preserved = originalFormula || formula;

  // Pre-detect formulas that use lookup fields incompatibly.
  if (formulaReferencesLookupInUnsupportedWay(formula, atTable, airtableMaps)) {
    logWarn(
      `  Formula "${baseTitle}" on "${parentTable.title}" references lookup fields in a way NocoDB cannot evaluate; preserving as LongText instead.`
    );
    return await createFormulaFallbackField({
      parentTable,
      baseTitle,
      formula: preserved,
    });
  }

  const { title, column_name } = chooseUniqueFieldName(
    parentTable,
    baseTitle
  );

  let body;

  if (IS_V3) {
    // v3: clean Formula payload – Noco expects type + options.formula
    body = {
      type: 'Formula',
      title,
      column_name,
      options: {
        formula: translated,
      },
    };
  } else {
    // v2: uses uidt/dt/colOptions/formula_raw
    // IMPORTANT: underlying DB type must be something real (e.g. text), not "formula"
    body = {
      title,
      column_name,
      uidt: 'Formula',
      dt: 'text',            // <— was 'formula'
      colOptions: {
        formula: translated,
      },
      formula: translated,
      formula_raw: translated,
    };
  }
  
  // If this formula corresponds to the first Airtable field, mark it
  // as the Display Value in NocoDB.
  if (isDisplayValue) {
    body.pv = true;
  }

  try {
    const field = await createFieldOnTable(parentTable.id, body);
    parentTable.fields = parentTable.fields || [];
    parentTable.fields.push(field);

    const fieldTitle =
      body.title || field.title || field.name || field.column_name;
    logInfo(
      `  Created Formula "${fieldTitle}" on "${parentTable.title}" with expression: ${translated}`
    );

    debugData.created.formulas.push({
      table: parentTable.title || parentTable.name,
      field: baseTitle,
      translated
    });

    return field;
  } catch (err) {
    const parentTitle = parentTable.title || parentTable.name || parentTable.table_name;
    const reason = err && err.message ? err.message : String(err);

    if (finalAttempt) {
      // Final attempt: give up and create fallback
      logWarn(
        `  NocoDB rejected Formula "${baseTitle}" on "${parentTitle}" even on final attempt (expression "${translated}"): ${reason}`
      );
      logWarn(
        `  Creating a LongText "_formula_src" field instead so the Airtable expression is preserved.`
      );

      debugData.failed.formulas.push({
        table: parentTitle,
        field: baseTitle,
        reason: `Final attempt failed: ${reason}`,
        translated
      });

      return await createFormulaFallbackField({
        parentTable,
        baseTitle,
        formula: preserved,
      });
    }

    // First attempt: defer until after links/lookups/rollups exist
    logWarn(
      `  NocoDB rejected Formula "${baseTitle}" on "${parentTitle}" (expression "${translated}") on first attempt: ${reason}`
    );
    logWarn(
      `  Deferring formula "${baseTitle}" for retry after all link/lookup/rollup phases.`
    );

    deferredFormulaCreates.push({
      atTableId: atTable.id,
      atFieldId: atTable && atField ? atField.id : null, // kept for possible future use
      atFieldName: atField && atField.name ? atField.name : baseTitle,
      baseTitle,
    });

    // Also record in debug as deferred
    debugData.failed.formulas.push({
      table: parentTitle,
      field: baseTitle,
      reason: `Deferred for retry: ${reason}`,
      translated
    });

    return null;
  }

}

// --------------------------------------------
// DETERMINE RELATION TYPE FOR AIRTABLE LINK
// --------------------------------------------

function determineRelationTypeForAirtableLink(atField, airtableMaps) {
  if (!atField || !airtableMaps || !airtableMaps.fieldsById) {
    return 'mm';
  }

  const opts = atField.options || {};
  const fSingle = !!opts.prefersSingleRecordLink;

  let invSingle = null;
  if (opts.inverseLinkFieldId) {
    const inv = airtableMaps.fieldsById[opts.inverseLinkFieldId];
    if (inv && inv.options) {
      invSingle = !!inv.options.prefersSingleRecordLink;
    }
  }

  // If we don't know the inverse, pick something reasonable:
  if (invSingle === null) {
    // If this side is single but inverse is unknown, treat as hm;
    // otherwise default to mm.
    return fSingle ? 'hm' : 'mm';
  }

  // Both sides allow multiple -> many-to-many
  if (!fSingle && !invSingle) {
    return 'mm';
  }

  // Both sides prefer single -> one-to-one
  if (fSingle && invSingle) {
    return 'oo';
  }

  // Mixed single/multi -> one-to-many
  return 'hm';
}

// --------------------------------------------
// CREATE LINKTOANOTHERRECORD FIELD
// --------------------------------------------

async function createLinkField({
  parentTable,
  targetTable,
  baseTitle,
  relationType,
}) {
  const { title, column_name } = chooseUniqueFieldName(
    parentTable,
    baseTitle
  );
  const relType = relationType || 'mm';

  let body;

  if (LINKS_IS_V2) {
    // v2: Links / LinkToAnotherRecord are created as normal columns with
    //     uidt = 'Links' and colOptions specifying the relationship.
    // IMPORTANT: always use the *real PK* column (nocopk), never the display value,
    // otherwise the m2m join table ends up with varchar FKs and we get
    // "operator does not exist: character varying = integer" errors.
    const parentPk = (parentTable.fields || []).find(
      (c) => c.pk === 1 || c.pk === true
    );
    const childPk = (targetTable.fields || []).find(
      (c) => c.pk === 1 || c.pk === true
    );
  
    const parentTitle = parentTable.title || parentTable.name;
    const targetTitle = targetTable.title || targetTable.name;
  
    if (!parentPk || !childPk) {
      throw new Error(
        `Could not find *primary key* columns for link "${title}" on "${parentTitle}" -> "${targetTitle}". Make sure nocopk is created as PK.`
      );
    }
  
    const effectiveType =
      relType === 'hm' || relType === 'ho'
        ? 'hm'
        : relType === 'mm'
        ? 'mm'
        : 'hm';
  
    body = {
      title,
      column_name,
      uidt: 'Links',
      // v2 expects table IDs here, not column IDs
      parentId: parentTable.id,
      childId: targetTable.id,
      type: effectiveType,
      colOptions: {
        type: effectiveType,
        // These remain column IDs (PKs) for the relation wiring
        fk_parent_column_id: parentPk.id,
        fk_child_column_id: childPk.id,
      },
    };
  } else {
    // v3: more explicit 'LinkToAnotherRecord' type with options.targetTableId
    body = {
      type: 'LinkToAnotherRecord',
      title: title,
      id: column_name,
      options: {
        relation_type: relType,
        related_table_id: targetTable.id,
      },
    };
  }

  try {
    const field = await createFieldOnTableForLinks(parentTable.id, body);
    parentTable.fields = parentTable.fields || [];
    parentTable.fields.push(field);

    const fieldTitle =
      body.title || field.title || field.name || field.column_name;
    const parentTitle = parentTable.title || parentTable.name;
    const targetTitle = targetTable.title || targetTable.name;

    logInfo(
      `  Created Link field "${fieldTitle}" on "${parentTitle}" -> "${targetTitle}" (relation_type=${relType}).`
    );

    debugData.created.links.push({
      table: parentTitle,
      field: fieldTitle,
      relationType: relType,
      targetTable: targetTitle
    });

    return field;
  } catch (err) {
    const parentTitle = parentTable.title || parentTable.name;
    const targetTitle = targetTable.title || targetTable.name;
    logError(
      `  Failed to create Link field "${baseTitle}" on "${parentTitle}" -> "${targetTitle}": ${err.message}`
    );

    debugData.failed.links.push({
      table: parentTitle,
      field: baseTitle,
      reason: err.message,
      targetTable: targetTitle
    });

    return null;
  }
}

// Create inverse link (bidirectional) on target table
async function createInverseLinkField({
  parentTable,
  parentField,
  targetTable,
  relationType,
}) {
  // For v3, NocoDB automatically manages inverse relations.
  // Creating them manually causes duplicate alias columns like "lotss", "productss", etc.
  if (LINKS_IS_V3) {
    const parentTitle = parentTable.title || parentTable.name || parentTable.table_name;
    const targetTitle = targetTable.title || targetTable.name || targetTable.table_name;
    logInfo(
      `  (v3) Skipping explicit inverse link "${parentTitle}" -> "${targetTitle}" (NocoDB auto-creates inverse).`
    );
    return null;
  }

/*
  if (LINKS_IS_V2) {
    logInfo(
      `  (v2) Skipping explicit inverse link on "${targetTable.title}" – NocoDB creates inverse automatically.`
    );
    return null;
  }
*/

  const baseTitle = `${parentTable.title || parentTable.name}s`;

  const { title, column_name } = chooseUniqueFieldName(
    targetTable,
    baseTitle
  );

  const relType = relationType || 'mm';

  const body = {
    type: 'LinkToAnotherRecord',
    title,
    options: {
      relation_type: relType,
      related_table_id: parentTable.id,
    },
  };

  try {
    const field = await createFieldOnTable(targetTable.id, body);
    targetTable.fields = targetTable.fields || [];
    targetTable.fields.push(field);

    const fieldTitle =
      body.title || field.title || field.name || field.column_name;
    const parentTitle = parentTable.title || parentTable.name;
    const targetTitle = targetTable.title || targetTable.name;

    logInfo(
      `  Created inverse LinkToAnotherRecord "${fieldTitle}" on "${targetTitle}" -> "${parentTitle}".`
    );

    debugData.created.links.push({
      table: targetTitle,
      field: fieldTitle,
      relationType: relType,
      targetTable: parentTitle,
      inverse: true
    });

    return field;
  } catch (err) {
    const targetTitle = targetTable.title || targetTable.name;
    const parentTitle = parentTable.title || parentTable.name;

    logError(
      `  Failed to create inverse link on "${targetTitle}" for link back to "${parentTitle}": ${err.message}`
    );

    debugData.failed.links.push({
      table: targetTitle,
      field: `${baseTitle} (inverse)`,
      reason: err.message,
      targetTable: parentTitle
    });

    return null;
  }
}

// --------------------------------------------
// LINK PAIR PRIMARY-SIDE HEURISTICS
// --------------------------------------------

function isFromStyleLinkName(name) {
  if (!name) return false;
  const n = String(name).trim().toLowerCase();
  return n.startsWith('from ') || n.startsWith('from field:');
}

function isIdStyleLinkName(name) {
  if (!name) return false;
  const n = String(name).trim().toLowerCase();
  // Treat "*_id" or "id" suffix as more "data-bearing" (e.g. lot_id, product_id)
  if (/_id$/.test(n)) return true;
  if (/\sid$/.test(n)) return true;
  return false;
}

function hasNumericSuffix(name) {
  if (!name) return false;
  // Matches "lots 2", "products 4", etc.
  return /\s+\d+$/.test(String(name).trim());
}

/**
 * Decide which side of an Airtable link pair should be treated as "primary"
 * when creating the NocoDB LinkToAnotherRecord field.
 *
 * Returns the field.id that should be PRIMARY. The other side is secondary.
 */
function choosePrimaryFieldIdForLinkPair(atField, inverseField) {
  if (!inverseField) {
    return atField.id;
  }

  const thisName = atField.name || '';
  const otherName = inverseField.name || '';

  const thisFrom = isFromStyleLinkName(thisName);
  const otherFrom = isFromStyleLinkName(otherName);

  const thisIdStyle = isIdStyleLinkName(thisName);
  const otherIdStyle = isIdStyleLinkName(otherName);

  const thisNumeric = hasNumericSuffix(thisName);
  const otherNumeric = hasNumericSuffix(otherName);

  // 1) Prefer ID-style names (lot_id, product_id, strain_id, etc.)
  if (thisIdStyle && !otherIdStyle) return atField.id;
  if (!thisIdStyle && otherIdStyle) return inverseField.id;

  // 2) Prefer names with numeric suffix if the other side is the "base" name
  //    (e.g. "lots 2" vs "lots").
  if (thisNumeric && !otherNumeric) return atField.id;
  if (!thisNumeric && otherNumeric) return inverseField.id;

  // 3) Prefer non-"From" names over "From field: ..." / "From ..."
  if (!thisFrom && otherFrom) return atField.id;
  if (thisFrom && !otherFrom) return inverseField.id;

  // 4) Fallback: stable choice based on lexicographically smaller id
  const pairIds = [atField.id, inverseField.id].sort();
  return pairIds[0];
}

// --------------------------------------------
// LINK HANDLER
// --------------------------------------------

async function ensureLinkForAirtableField({
  atTable,
  atField,
  airtableMaps,
  nocoTables,
}) {
  const options = atField.options || {};
  const linkedTableId = options.linkedTableId;

  if (!linkedTableId) {
    logWarn(
      `  Linked-record field "${atField.name}" in "${atTable.name}" has no linkedTableId; skipping.`
    );
    return;
  }

  // Avoid reversed Airtable link definitions
  if (options.isReversed) {
    logInfo(
      `  Skipping reversed link field "${atField.name}" in "${atTable.name}".`
    );
    return;
  }
  
  // Avoid creating the same logical relation twice.
  // Airtable models each relation as two fields (one on each table),
  // connected via options.inverseLinkFieldId. NocoDB v3 automatically
  // creates the inverse LinkToAnotherRecord field, so if we create a link
  // from *both* sides, NocoDB ends up with duplicate fields like "lots1".
  const inverseId = options.inverseLinkFieldId;
  let inverseField = null;
  let isPrimarySide = true;
  let pairKey = null;

  if (inverseId) {
    const thisId = atField.id;
    inverseField =
      (airtableMaps &&
        airtableMaps.fieldsById &&
        airtableMaps.fieldsById[inverseId]) ||
      null;

    // Decide which side we *want* to treat as primary based on naming
    const primaryId = inverseField
      ? choosePrimaryFieldIdForLinkPair(atField, inverseField)
      : thisId;

    const secondaryId = primaryId === thisId ? inverseId : thisId;

    isPrimarySide = (thisId === primaryId);

    // Canonical pair key (order-independent) for tracking
    const pairIds = [primaryId, secondaryId].sort();
    pairKey = pairIds.join("::");

    if (!isPrimarySide) {
      // Secondary side: we won't create a second LinkToAnotherRecord here.
      // The primary side will create the relation and we'll rename the
      // auto-inverse on this table to match this Airtable field name.
      if (processedAirtableLinkPairs.has(pairKey)) {
        logInfo(
          `  Skipping secondary side of link pair "${atField.name}" in "${atTable.name}" (inverse of ${inverseId}) – relation already created and inverse will be renamed.`
        );
      } else {
        logInfo(
          `  Skipping secondary side of link pair "${atField.name}" in "${atTable.name}" in favor of primary "${inverseField ? inverseField.name : inverseId}".`
        );
      }
      return;
    }

    // We are on the chosen primary side; only create the relation once.
    if (processedAirtableLinkPairs.has(pairKey)) {
      logInfo(
        `  Link pair for "${atField.name}" in "${atTable.name}" already processed on its primary side; skipping.`
      );
      return;
    }

    processedAirtableLinkPairs.add(pairKey);
  }

  const targetAtTable = airtableMaps.tablesById[linkedTableId];
  if (!targetAtTable) {
    logWarn(
      `  Linked-record field "${atField.name}" in "${atTable.name}" references unknown tableId=${linkedTableId}.`
    );
    return;
  }

  const relationType = determineRelationTypeForAirtableLink(
    atField,
    airtableMaps
  );

  // If we are NOT recreating links, just record a manual description and return.
  if (!RECREATE_LINKS) {
    manualLinkDescriptions.push({
      table: atTable.name,
      column: atField.name,
      description: `Column "${atField.name}" on table "${atTable.name}" should be a link to table "${targetAtTable.name}".`
    });
    logInfo(
      `  Recorded manual link description for "${atField.name}" (NOCODB_RECREATE_LINKS not "true").`
    );
    return;
  }

  const parentNoco = findNocoTableForAirtableTable(atTable, nocoTables);
  const childNoco = findNocoTableForAirtableTable(targetAtTable, nocoTables);
  
  if (!parentNoco || !childNoco) {
    logWarn(
      `  Missing Noco table(s) for link field "${atField.name}" on "${atTable.name}".`
    );
    return;
  }
  
  // Refresh fields so we see anything created earlier in this run
  await refreshNocoFieldsForTable(parentNoco);
  await refreshNocoFieldsForTable(childNoco);
  
  const normalizedAtName = normalizeLinkName(atField.name);
  const existingLink = (parentNoco.fields || []).find((f) => {
    const t = fieldType(f);
    if (t !== 'Links' && t !== 'LinkToAnotherRecord') return false;
    const n = normalizeLinkName(f.title || f.name || f.column_name);
    return n === normalizedAtName;
  });
  
  if (existingLink) {
    const parentTitle = parentNoco.title || parentNoco.name || parentNoco.table_name;
    logInfo(
      `  Link field already exists (by normalized name) for "${atField.name}" on "${parentTitle}" as "${existingLink.title || existingLink.name || existingLink.column_name}". Skipping.`
    );
    return;
  }
  
  // Snapshot existing child-side links to this parent, so we can identify
  // which auto-inverse was created after we add the primary link.
  const existingChildLinksToParent = new Set(
    (childNoco.fields || [])
      .filter((f) => {
        const t = fieldType(f);
        if (t !== "Links" && t !== "LinkToAnotherRecord") return false;
        const opt = f.options || f.colOptions || {};
        const relatedId =
          opt.related_table_id ||
          opt.fk_related_model_id ||
          opt.fk_relation_id;
        return relatedId === parentNoco.id;
      })
      .map((f) => f.id)
  );
  
  const existing = (parentNoco.fields || []).find(
    (f) => (f.title || f.name) === atField.name
  );
  const existingType = existing ? fieldType(existing) : null;

  if (existing && (existingType === 'LinkToAnotherRecord' || existingType === 'Links')) {
    logInfo(
      `  Link field already exists for "${atField.name}" on "${parentNoco.title}".`
    );
    return;
  }

  if (existing && existingType === 'LongText') {
    try {
      await deleteFieldById(existing.id);
      parentNoco.fields = parentNoco.fields.filter((f) => f.id !== existing.id);
      logInfo(
        `  Removed LongText placeholder "${existing.title}" before creating LinkToAnotherRecord.`
      );
    } catch (err) {
      logWarn(
        `  Failed to delete LongText placeholder "${existing.title}": ${err.message}`
      );
    }
  }

  // Create the main link
  const linkField = await createLinkField({
    parentTable: parentNoco,
    targetTable: childNoco,
    baseTitle: atField.name,
    relationType,
  });
  
  // For v3: NocoDB automatically creates the inverse link on childNoco
  // when we create the link on parentNoco. If this Airtable link had an
  // inverse side, rename that auto-inverse on childNoco to match the
  // Airtable field name on the other table (Option B).
  if (LINKS_IS_V3 && inverseField && isPrimarySide && linkField) {
    await renameAutoInverseLinkField({
      parentNoco,
      childNoco,
      linkField,
      existingChildLinksToParent,
      newInverseTitle: inverseField.name,
    });
  }

  if (linkField) {
    await createInverseLinkField({
      parentTable: parentNoco,
      parentField: linkField,
      targetTable: childNoco,
      relationType,
    });
  }
}

// --------------------------------------------
// MANUAL DESCRIPTORS
// --------------------------------------------

function recordLinkDescription({
  atTable,
  atField,
  airtableMaps,
}) {
  const options = atField.options || {};
  const linkedTableId = options.linkedTableId;
  let linkedTableName = null;

  if (linkedTableId && airtableMaps.tablesById) {
    const t = airtableMaps.tablesById[linkedTableId];
    if (t) {
      linkedTableName = t.name;
    }
  }

  const parts = [];
  parts.push(
    `Column "${atField.name}" on table "${atTable.name}" should be a link to another record.`
  );
  if (linkedTableName) {
    parts.push(`It links to table "${linkedTableName}".`);
  }

  manualLinkDescriptions.push({
    table: atTable.name,
    column: atField.name,
    description: parts.join(' '),
  });
}

// --------------------------------------------
// MANUAL ROLLUP DESCRIPTION
// --------------------------------------------

function recordRollupDescription({
  atTable,
  atField,
  airtableMaps,
}) {
  const options = atField.options || {};
  const recordLinkFieldId = options.recordLinkFieldId;
  const fieldIdInLinkedTable = options.fieldIdInLinkedTable;

  let linkFieldName = null;
  let linkedTableName = null;
  let targetFieldName = null;
  let aggregation = null;

  // Resolve link field on same table
  if (recordLinkFieldId) {
    const linkField =
      (atTable.fields || []).find((f) => f.id === recordLinkFieldId) || null;
    if (linkField) {
      linkFieldName = linkField.name;

      const linkOpts = linkField.options || {};
      const linkedTableId = linkOpts.linkedTableId;
      if (linkedTableId) {
        const linkedAtTable = airtableMaps.tablesById[linkedTableId];
        if (linkedAtTable) {
          linkedTableName = linkedAtTable.name;

          if (fieldIdInLinkedTable) {
            const targetField =
              (linkedAtTable.fields || []).find(
                (f) => f.id === fieldIdInLinkedTable
              ) || null;
            if (targetField) {
              targetFieldName = targetField.name;
            }
          }
        }
      }
    }
  }

  // Aggregation hint, if present
  aggregation =
    options.aggregationFunction ||
    options.aggregation ||
    (options.result && options.result.type) ||
    null;

  const parts = [];
  parts.push(
    `Column "${atField.name}" on table "${atTable.name}" should be a rollup.`
  );
  if (linkFieldName) {
    parts.push(`It uses link field "${linkFieldName}".`);
  }
  if (linkedTableName) {
    parts.push(`The link points to table "${linkedTableName}".`);
  }
  if (targetFieldName) {
    parts.push(`It rolls up field "${targetFieldName}" in that table.`);
  }
  if (aggregation) {
    parts.push(`Airtable aggregation: ${JSON.stringify(aggregation)}.`);
  }

  manualRollupDescriptions.push({
    table: atTable.name,
    column: atField.name,
    description: parts.join(' '),
  });
}

// --------------------------------------------
// MANUAL LOOKUP DESCRIPTION (Airtable multipleLookupValues)
// --------------------------------------------

function recordLookupDescription({
  atTable,
  atField,
  airtableMaps,
}) {
  const options = atField.options || {};
  const recordLinkFieldId = options.recordLinkFieldId;
  const fieldIdInLinkedTable = options.fieldIdInLinkedTable;

  let linkFieldName = null;
  let linkedTableName = null;
  let targetFieldName = null;

  // Resolve link field on same table
  if (recordLinkFieldId) {
    const linkField =
      (atTable.fields || []).find((f) => f.id === recordLinkFieldId) || null;
    if (linkField) {
      linkFieldName = linkField.name;

      const linkOpts = linkField.options || {};
      const linkedTableId = linkOpts.linkedTableId;
      if (linkedTableId) {
        const linkedAtTable = airtableMaps.tablesById[linkedTableId];
        if (linkedAtTable) {
          linkedTableName = linkedAtTable.name;

          if (fieldIdInLinkedTable) {
            const targetField =
              (linkedAtTable.fields || []).find(
                (f) => f.id === fieldIdInLinkedTable
              ) || null;
            if (targetField) {
              targetFieldName = targetField.name;
            }
          }
        }
      }
    }
  }

  const parts = [];
  parts.push(
    `Column "${atField.name}" on table "${atTable.name}" should be a lookup.`
  );
  if (linkFieldName) {
    parts.push(`It uses link field "${linkFieldName}".`);
  }
  if (linkedTableName) {
    parts.push(`The link points to table "${linkedTableName}".`);
  }
  if (targetFieldName) {
    parts.push(`It looks up field "${targetFieldName}" in that table.`);
  }

  manualLookupDescriptions.push({
    table: atTable.name,
    column: atField.name,
    description: parts.join(' '),
  });
}

// -----------------------------------------------------------------------------
// ROLLUP / LOOKUP CREATION HELPERS
// -----------------------------------------------------------------------------
function mapAirtableRollupFunction(fn, targetType, rollupName) {
  const t = (targetType || '').toString().toLowerCase();
  const name = (rollupName || '').toString().toLowerCase();

  // NocoDB generates SQL aggregates like SUM(<expr>) for rollups.
  // In Postgres, SUM(text) fails with:
  //   "function sum(text) does not exist"
  // which can break *any* SELECT that includes that rollup.
  //
  // So: only allow sum/avg when the target field type is clearly numeric.
  function isNumericTargetType(typeName) {
    const x = (typeName || '').toString().toLowerCase();

    // Handle both Airtable-ish and Noco-ish names.
    // (Noco often uses "Number", "Decimal", etc; we lower-case above.)
    if (
      x === 'number' ||
      x === 'decimal' ||
      x === 'currency' ||
      x === 'percent' ||
      x === 'integer' ||
      x === 'int' ||
      x === 'float' ||
      x === 'rating'
    ) {
      return true;
    }

    // Some builds surface uidt/dt-ish strings; be permissive for numeric markers.
    if (x.includes('number') || x.includes('decimal') || x.includes('currency')) {
      return true;
    }
    if (x === 'int2' || x === 'int4' || x === 'int8' || x === 'numeric' || x === 'float4' || x === 'float8') {
      return true;
    }

    return false;
  }

  const isDateish = t === 'date' || t === 'datetime';
  const isNumeric = isNumericTargetType(t);

  // If Airtable didn't specify, guess based on target type + name.
  if (!fn) {
    if (isDateish) {
      if (name.startsWith('first_')) return 'min';
      if (name.startsWith('last_')) return 'max';
      return 'max';
    }
    // Safe default:
    // - numeric -> sum
    // - everything else -> count (never sum(text))
    return isNumeric ? 'sum' : 'count';
  }

  const s = String(fn).toLowerCase();

  // COUNT variants are always safe.
  if (s.includes('count') && (s.includes('distinct') || s.includes('unique'))) {
    return 'countDistinct';
  }
  if (s.startsWith('count')) return 'count';

  // SUM variants: only safe for numeric targets.
  if (s.startsWith('sum') && (s.includes('distinct') || s.includes('unique'))) {
    return isNumeric ? 'sumDistinct' : 'countDistinct';
  }
  if (s.startsWith('sum')) {
    return isNumeric ? 'sum' : 'count';
  }

  // AVG variants: only safe for numeric targets.
  if ((s.startsWith('avg') || s.startsWith('average')) && (s.includes('distinct') || s.includes('unique'))) {
    return isNumeric ? 'avgDistinct' : 'countDistinct';
  }
  if (s.startsWith('avg') || s.startsWith('average')) {
    return isNumeric ? 'avg' : 'count';
  }

  // MIN/MAX are safe on many types (including text/date).
  if (s.startsWith('min')) return 'min';
  if (s.startsWith('max')) return 'max';

  // Unknown aggregation string: fall back safely.
  if (isDateish) {
    if (name.startsWith('first_')) return 'min';
    if (name.startsWith('last_')) return 'max';
    return 'max';
  }
  
  return isNumeric ? 'sum' : 'count';
}

// --------------------------------------------
// CREATE ROLLUP FIELD
// --------------------------------------------
async function createRollupField({
  atTable,
  atField,
  airtableMaps,
  nocoTables,
}) {
  const options = atField.options || {};
  const recordLinkFieldId = options.recordLinkFieldId;
  const fieldIdInLinkedTable = options.fieldIdInLinkedTable;

  if (!recordLinkFieldId || !fieldIdInLinkedTable) {
    logWarn(
      `  Rollup "${atField.name}" on "${atTable.name}" missing recordLinkFieldId or fieldIdInLinkedTable.`
    );
    return false;
  }

  const linkField =
    (atTable.fields || []).find((f) => f.id === recordLinkFieldId) || null;
  if (!linkField) {
    logWarn(
      `  Rollup "${atField.name}" on "${atTable.name}" references unknown link field id="${recordLinkFieldId}".`
    );
    return false;
  }

  const linkOpts = linkField.options || {};
  const linkedTableId = linkOpts.linkedTableId;
  if (!linkedTableId) {
    logWarn(
      `  Rollup "${atField.name}" link field "${linkField.name}" has no linkedTableId.`
    );
    return false;
  }

  const linkedAtTable = airtableMaps.tablesById[linkedTableId];
  if (!linkedAtTable) {
    logWarn(
      `  Rollup "${atField.name}" references unknown Airtable table id="${linkedTableId}".`
    );
    return false;
  }

  const targetAtField =
    (linkedAtTable.fields || []).find((f) => f.id === fieldIdInLinkedTable) ||
    null;
  if (!targetAtField) {
    logWarn(
      `  Rollup "${atField.name}" references missing fieldIdInLinkedTable="${fieldIdInLinkedTable}".`
    );
    return false;
  }
  
  // Detect Airtable chains that NocoDB cannot represent:
  //   - rollup over a lookup field on another table
  //   - rollup over another rollup field on another table
  // NocoDB rollups must aggregate primitive fields (number/date/etc.), not
  // other computed fields like lookups or rollups.
  if (
    targetAtField.type === 'multipleLookupValues' ||
    targetAtField.type === 'rollup'
  ) {
    const msg =
      `  Rollup "${atField.name}" on "${atTable.name}" aggregates ` +
      `"${targetAtField.name}" on "${linkedAtTable.name}", which is a ` +
      `${targetAtField.type} field (lookup/rollup). ` +
      `NocoDB does not support rollups over lookup/rollup fields on another table. ` +
      `Consider rolling up a primitive field instead (or materializing this value).`;

    logError(msg);

    // Record in manual rollup descriptions so it shows up in the summary.
    manualRollupDescriptions.push({
      table: atTable.name,
      field: atField.name,
      reason:
        'Unsupported chained rollup: target field is lookup/rollup on another table',
      details: msg,
    });

    // And in the debug JSON.
    debugData.failed.rollups.push({
      table: atTable.name,
      field: atField.name,
      reason:
        'unsupported_chained_rollup_target_is_lookup_or_rollup',
      linkField: linkField.name,
      targetField: targetAtField.name,
    });

    // Skip creating this rollup; NocoDB cannot represent it.
    return false;
  }  

  const parentNoco = findNocoTableForAirtableTable(atTable, nocoTables);
  const linkedNoco = findNocoTableForAirtableTable(linkedAtTable, nocoTables);

  if (!parentNoco || !linkedNoco) {
    logWarn(
      `  Cannot find Noco parent/linked table for rollup "${atField.name}".`
    );
    return false;
  }

  await refreshNocoFieldsForTable(parentNoco);
  await refreshNocoFieldsForTable(linkedNoco);

  const relationNocoField = (parentNoco.fields || []).find(
    (f) => (f.title || f.name) === linkField.name
  );
  if (!relationNocoField) {
    logWarn(
      `  Rollup "${atField.name}" missing Noco relation column "${linkField.name}".`
    );
    return false;
  }

  const relationTypeName = fieldType(relationNocoField);
  if (
    relationTypeName !== 'Links' &&
    relationTypeName !== 'LinkToAnotherRecord'
  ) {
    logWarn(
      `  "${relationNocoField.title}" is not a link column; required for rollup "${atField.name}".`
    );
    return false;
  }

  const targetNocoField = (linkedNoco.fields || []).find(
    (f) => (f.title || f.name) === targetAtField.name
  );
  if (!targetNocoField) {
    logWarn(
      `  Rollup target column "${targetAtField.name}" missing in Noco table "${linkedNoco.title}".`
    );
    return false;
  }

  const existing = (parentNoco.fields || []).find(
    (f) => (f.title || f.name) === atField.name
  );
  const existingType = existing ? fieldType(existing) : null;

  if (existing && (existingType === 'Rollup' || existingType === 'RollupField')) {
    logInfo(
      `  Rollup "${atField.name}" already exists on "${parentNoco.title}".`
    );
    return true;
  }

  if (existing && existingType === 'LongText') {
    try {
      await deleteFieldById(existing.id);
      parentNoco.fields = parentNoco.fields.filter((f) => f.id !== existing.id);
      logInfo(
        `  Removed LongText placeholder "${existing.title}" to create Rollup.`
      );
    } catch (err) {
      logWarn(
        `  Failed to delete LongText placeholder "${existing.title}": ${err.message}`
      );
    }
  }
  
  const targetTypeName = fieldType(targetNocoField);

  const aggFn = mapAirtableRollupFunction(
    options.aggregationFunction ||
      options.aggregation ||
      (options.result && options.result.type),
    targetTypeName,
    atField.name
  );

  const { title, column_name } = chooseUniqueFieldName(
    parentNoco,
    atField.name
  );

  let body;

  if (IS_V3) {
    body = {
      title,
      type: 'Rollup',
      options: {
        related_field_id: relationNocoField.id,
        related_table_rollup_field_id: targetNocoField.id,
        rollup_function: aggFn,
      },
    };
  } else {
    body = {
      title,
      uidt: 'Rollup',
      fk_relation_column_id: relationNocoField.id,
      fk_rollup_column_id: targetNocoField.id,
      rollup_function: aggFn,
      colOptions: {
        fk_relation_column_id: relationNocoField.id,
        fk_rollup_column_id: targetNocoField.id,
        rollup_function: aggFn,
      },
    };
  }

  try {
    const field = await createFieldOnTable(parentNoco.id, body);
    parentNoco.fields = parentNoco.fields || [];
    parentNoco.fields.push(field);

    logInfo(
      `  Created Rollup "${title}" on "${parentNoco.title}" via relation "${linkField.name}" -> "${linkedAtTable.name}.${targetAtField.name}".`
    );

    debugData.created.rollups.push({
      table: parentNoco.title || parentNoco.name,
      field: atField.name,
      linkField: linkField.name,
      targetField: targetAtField.name,
      aggFn
    });

    return true;
  } catch (err) {
    logWarn(
      `  Failed to create Rollup "${atField.name}" on "${parentNoco.title}": ${err.message}`
    );

    debugData.failed.rollups.push({
      table: parentNoco.title || parentNoco.name,
      field: atField.name,
      reason: err.message,
      linkField: linkField.name,
      targetField: targetAtField.name
    });

    return false;
  }
}

// --------------------------------------------
// CREATE LOOKUP FIELD
// --------------------------------------------

async function createLookupField({
  atTable,
  atField,
  airtableMaps,
  nocoTables,
}) {
  const options = atField.options || {};
  const recordLinkFieldId = options.recordLinkFieldId;
  const fieldIdInLinkedTable = options.fieldIdInLinkedTable;

  if (!recordLinkFieldId || !fieldIdInLinkedTable) {
    logWarn(
      `  Lookup "${atField.name}" missing recordLinkFieldId or fieldIdInLinkedTable.`
    );
    return false;
  }

  const linkField =
    (atTable.fields || []).find((f) => f.id === recordLinkFieldId) || null;
  if (!linkField) {
    logWarn(
      `  Lookup "${atField.name}" references unknown link field id="${recordLinkFieldId}".`
    );
    return false;
  }

  const linkOpts = linkField.options || {};
  const linkedTableId = linkOpts.linkedTableId;
  if (!linkedTableId) {
    logWarn(
      `  Lookup "${atField.name}" link field "${linkField.name}" has no linkedTableId.`
    );
    return false;
  }

  const linkedAtTable = airtableMaps.tablesById[linkedTableId];
  if (!linkedAtTable) {
    logWarn(
      `  Lookup "${atField.name}" references missing table id="${linkedTableId}".`
    );
    return false;
  }

  const targetAtField =
    (linkedAtTable.fields || []).find((f) => f.id === fieldIdInLinkedTable) ||
    null;
  if (!targetAtField) {
    logWarn(
      `  Lookup "${atField.name}" references missing fieldIdInLinkedTable="${fieldIdInLinkedTable}".`
    );
    return false;
  }

  // Detect Airtable chains that NocoDB cannot represent:
  //   - lookup of a rollup field on another table
  // NocoDB lookups can dereference primitive/link fields but not rollups.
  if (targetAtField.type === 'rollup') {
    const msg =
      `  Lookup "${atField.name}" on "${atTable.name}" targets rollup field ` +
      `"${targetAtField.name}" on "${linkedAtTable.name}". ` +
      `NocoDB does not support lookups of rollup fields on another table. ` +
      `Consider materializing this rollup into a normal field in Airtable, ` +
      `or flattening the dependency.`;

    logError(msg);

    // Record in manual lookup descriptions so you can see it in the summary.
    manualLookupDescriptions.push({
      table: atTable.name,
      field: atField.name,
      reason:
        'Unsupported chained lookup: target field is rollup on another table',
      details: msg,
    });

    // Also track in debugData.failed.lookups for the JSON debug output.
    debugData.failed.lookups.push({
      table: atTable.name,
      field: atField.name,
      reason: 'unsupported_chained_lookup_target_is_rollup',
      linkField: linkField.name,
      targetField: targetAtField.name,
    });

    // Skip creating this lookup; NocoDB cannot represent it.
    return false;
  }

  const parentNoco = findNocoTableForAirtableTable(atTable, nocoTables);
  const linkedNoco = findNocoTableForAirtableTable(linkedAtTable, nocoTables);

  if (!parentNoco || !linkedNoco) {
    logWarn(
      `  Lookup "${atField.name}" cannot map to Noco tables.`
    );
    return false;
  }

  await refreshNocoFieldsForTable(parentNoco);
  await refreshNocoFieldsForTable(linkedNoco);

  const relationNocoField = (parentNoco.fields || []).find(
    (f) => (f.title || f.name) === linkField.name
  );
  if (!relationNocoField) {
    logWarn(
      `  Lookup "${atField.name}" missing relation column "${linkField.name}".`
    );
    return false;
  }

  const relationTypeName = fieldType(relationNocoField);
  if (
    relationTypeName !== 'Links' &&
    relationTypeName !== 'LinkToAnotherRecord'
  ) {
    logWarn(
      `  Relation column "${relationNocoField.title}" is not a link (needed for lookup "${atField.name}").`
    );
    return false;
  }

  const targetNocoField = (linkedNoco.fields || []).find(
    (f) => (f.title || f.name) === targetAtField.name
  );
  if (!targetNocoField) {
    logWarn(
      `  Lookup "${atField.name}" missing target column "${targetAtField.name}" in "${linkedNoco.title}".`
    );
    return false;
  }

  const existing = (parentNoco.fields || []).find(
    (f) => (f.title || f.name) === atField.name
  );
  const existingType = existing ? fieldType(existing) : null;

  if (existing && (existingType === 'Lookup' || existingType === 'LookupField')) {
    logInfo(
      `  Lookup "${atField.name}" already exists on "${parentNoco.title}".`
    );
    return true;
  }

  if (existing && existingType === 'LongText') {
    try {
      await deleteFieldById(existing.id);
      parentNoco.fields = parentNoco.fields.filter((f) => f.id !== existing.id);
      logInfo(
        `  Removed LongText placeholder "${existing.title}" before creating Lookup.`
      );
    } catch (err) {
      logWarn(
        `  Failed to delete LongText placeholder "${existing.title}": ${err.message}`
      );
    }
  }

  const { title, column_name } = chooseUniqueFieldName(
    parentNoco,
    atField.name
  );

  let body;

  if (IS_V3) {
    body = {
      title,
      type: 'Lookup',
      options: {
        related_field_id: relationNocoField.id,
        related_table_lookup_field_id: targetNocoField.id,
      },
    };
  } else {
    body = {
      title,
      uidt: 'Lookup',
      fk_relation_column_id: relationNocoField.id,
      fk_lookup_column_id: targetNocoField.id,
      colOptions: {
        fk_relation_column_id: relationNocoField.id,
        fk_lookup_column_id: targetNocoField.id,
      },
    };
  }

  try {
    const field = await createFieldOnTable(parentNoco.id, body);
    parentNoco.fields = parentNoco.fields || [];
    parentNoco.fields.push(field);

    logInfo(
      `  Created Lookup "${title}" on "${parentNoco.title}".`
    );

    debugData.created.lookups.push({
      table: parentNoco.title || parentNoco.name,
      field: atField.name,
      linkField: linkField.name,
      targetField: targetAtField.name
    });

    return true;
  } catch (err) {
    logWarn(
      `  Failed to create Lookup "${atField.name}" on "${parentNoco.title}": ${err.message}`
    );

    debugData.failed.lookups.push({
      table: parentNoco.title || parentNoco.name,
      field: atField.name,
      reason: err.message,
      linkField: linkField.name,
      targetField: targetAtField.name
    });

    return false;
  }
}

// --------------------------------------------
// DEPENDENCY GRAPH FOR MULTI-PASS PROCESSING
// --------------------------------------------

/**
 * Build dependency graph for:
 *   - links
 *   - simple lookups
 *   - simple rollups
 *   - chained lookups (lookup of lookup)
 *   - chained rollups (rollup of lookup/rollup)
 */
function buildDependencyGraph(schema, airtableMaps) {
  const graph = {
    links: [],
    simpleLookups: [],
    simpleRollups: [],
    chainedLookups: [],
    chainedRollups: []
  };

  for (const atTable of schema.tables || []) {
    for (const atField of atTable.fields || []) {
      const type = atField.type;

      if (type === 'multipleRecordLinks') {
        graph.links.push({ atTable, atField });
        debugData.phases.links.push({
          table: atTable.name,
          field: atField.name
        });
        continue;
      }

      if (type === 'multipleLookupValues') {
        const linkFieldId = atField.options?.recordLinkFieldId;
        const targetFieldId = atField.options?.fieldIdInLinkedTable;

        if (!linkFieldId || !targetFieldId) {
          graph.simpleLookups.push({ atTable, atField });
          debugData.phases.simpleLookups.push({
            table: atTable.name,
            field: atField.name,
            reason: 'missing link or target'
          });
          continue;
        }

        const linkField = atTable.fields.find(f => f.id === linkFieldId);
        const linkedTableId = linkField?.options?.linkedTableId;
        const linkedAtTable = airtableMaps.tablesById[linkedTableId];

        const targetAtField = linkedAtTable?.fields?.find(f => f.id === targetFieldId);
        const nestedType = targetAtField?.type;

        if (nestedType === 'multipleLookupValues') {
          graph.chainedLookups.push({ atTable, atField });
          debugData.phases.chainedLookups.push({
            table: atTable.name,
            field: atField.name,
            dependsOn: targetAtField?.name
          });
        } else {
          graph.simpleLookups.push({ atTable, atField });
          debugData.phases.simpleLookups.push({
            table: atTable.name,
            field: atField.name
          });
        }

        continue;
      }

      if (type === 'rollup') {
        const linkFieldId = atField.options?.recordLinkFieldId;
        const targetFieldId = atField.options?.fieldIdInLinkedTable;

        if (!linkFieldId || !targetFieldId) {
          graph.simpleRollups.push({ atTable, atField });
          debugData.phases.simpleRollups.push({
            table: atTable.name,
            field: atField.name,
            reason: 'missing link or target'
          });
          continue;
        }

        const linkField = atTable.fields.find(f => f.id === linkFieldId);
        const linkedTableId = linkField?.options?.linkedTableId;
        const linkedAtTable = airtableMaps.tablesById[linkedTableId];

        const targetAtField = linkedAtTable?.fields?.find(f => f.id === targetFieldId);
        const nestedType = targetAtField?.type;

        if (nestedType === 'multipleLookupValues' || nestedType === 'rollup') {
          graph.chainedRollups.push({ atTable, atField });
          debugData.phases.chainedRollups.push({
            table: atTable.name,
            field: atField.name,
            dependsOn: targetAtField?.name
          });
        } else {
          graph.simpleRollups.push({ atTable, atField });
          debugData.phases.simpleRollups.push({
            table: atTable.name,
            field: atField.name
          });
        }

        continue;
      }
    }
  }

  return graph;
}

// --------------------------------------------
// STABILIZATION WAIT
// --------------------------------------------

async function stabilize(label) {
  logInfo(`  Stabilizing after ${label} ...`);
  await new Promise(r => setTimeout(r, 250));
}

// --------------------------------------------
// RETRY FAILED PHASE ITEMS
// --------------------------------------------

async function retryFailedPhaseItems(graph, airtableMaps, nocoTables) {
  logInfo(`Retrying chained and failed items ...`);

  const retrySets = [
    ...graph.chainedLookups,
    ...graph.chainedRollups
  ];

  for (const { atTable, atField } of retrySets) {
    const type = atField.type;

    if (type === 'multipleLookupValues') {
      const ok = await createLookupField({
        atTable,
        atField,
        airtableMaps,
        nocoTables
      });
      if (!ok) {
        debugData.failed.lookups.push({
          table: atTable.name,
          field: atField.name,
          reason: 'Retry failed'
        });
      }
      continue;
    }

    if (type === 'rollup') {
      const ok = await createRollupField({
        atTable,
        atField,
        airtableMaps,
        nocoTables
      });
      if (!ok) {
        debugData.failed.rollups.push({
          table: atTable.name,
          field: atField.name,
          reason: 'Retry failed'
        });
      }
      continue;
    }
  }
}

// --------------------------------------------
// MAIN FIELD PROCESSOR (used for table-by-table iteration)
// --------------------------------------------

async function processAirtableField({
  atTable,
  atField,
  airtableMaps,
  nocoTables,
}) {
  const parentNoco = findNocoTableForAirtableTable(atTable, nocoTables);
  if (!parentNoco) {
    logWarn(
      `  No matching Noco table for Airtable table "${atTable.name}".`
    );
    return;
  }

  // Multiple record links -> LinkToAnotherRecord (or manual instructions)
  if (atField.type === 'multipleRecordLinks') {
    await ensureLinkForAirtableField({
      atTable,
      atField,
      airtableMaps,
      nocoTables,
    });
    return;
  }

  // Formula fields -> Formula (with fallback LongText)
  if (atField.type === 'formula') {
    const options = atField.options || {};
    const formula = options.formula;
    await refreshNocoFieldsForTable(parentNoco);

    const existing = (parentNoco.fields || []).find(
      (f) => (f.title || f.name) === atField.name
    );

    if (existing && fieldType(existing) === 'Formula') {
      logInfo(
        `  Formula "${atField.name}" already exists on "${parentNoco.title}".`
      );
      return;
    }

    if (existing && fieldType(existing) === 'LongText') {
      try {
        await deleteFieldById(existing.id);
        parentNoco.fields = parentNoco.fields.filter((f) => f.id !== existing.id);
        logInfo(
          `  Removed LongText placeholder "${existing.title}" before creating Formula.`
        );
      } catch (err) {
        logWarn(
          `  Failed to delete LongText placeholder "${existing.title}": ${err.message}`
        );
      }
    }

    const isDisplayValue =
      atTable.fields &&
      atTable.fields.length > 0 &&
      atTable.fields[0].id === atField.id;

    await createFormulaField({
      parentTable: parentNoco,
      baseTitle: atField.name,
      formula,
      originalFormula: formula,
      atTable,
      airtableMaps,
      atField,
      finalAttempt: false,
      isDisplayValue,
    });

    return;
  }

  // Rollup
  if (atField.type === 'rollup') {
    if (!RECREATE_ROLLUPS) {
      recordRollupDescription({ atTable, atField, airtableMaps });
      logInfo(
        `  Recorded manual rollup "${atField.name}" on "${atTable.name}".`
      );
      return;
    }

    const ok = await createRollupField({
      atTable,
      atField,
      airtableMaps,
      nocoTables,
    });

    if (!ok) {
      recordRollupDescription({ atTable, atField, airtableMaps });
      logInfo(
        `  Rollup "${atField.name}" could not be auto-created; recorded manual instructions.`
      );
    }

    return;
  }

  // Lookup (Airtable "multipleLookupValues")
  if (atField.type === 'multipleLookupValues') {
    if (!RECREATE_LOOKUPS) {
      recordLookupDescription({ atTable, atField, airtableMaps });
      logInfo(
        `  Recorded manual lookup "${atField.name}" on "${atTable.name}".`
      );
      return;
    }

    const ok = await createLookupField({
      atTable,
      atField,
      airtableMaps,
      nocoTables,
    });

    if (!ok) {
      recordLookupDescription({ atTable, atField, airtableMaps });
      logInfo(
        `  Lookup "${atField.name}" could not be auto-created; recorded manual instructions.`
      );
    }

    return;
  }
}

// --------------------------------------------
// WRITE DEBUG JSON
// --------------------------------------------

function writeNocoSchemaExport(tables) {
  try {
    const normalized = (tables || []).map((t) => ({
      id: t.id,
      name: t.title || t.name || t.table_name,
      fields: (t.fields || []).map((f) => ({
        id: f.id,
        name: f.title || f.name || f.column_name,
        type: fieldType(f),
        // keep raw options metadata so you can inspect relations/lookups/rollups if needed
        options: f.options || f.colOptions || undefined,
      })),
    }));

    const dir = path.dirname(NOCO_SCHEMA_EXPORT_PATH);
    fs.mkdirSync(dir, { recursive: true });

    fs.writeFileSync(
      NOCO_SCHEMA_EXPORT_PATH,
      JSON.stringify({ tables: normalized }, null, 2),
      'utf8'
    );
    logInfo(`NocoDB schema export written to: ${NOCO_SCHEMA_EXPORT_PATH}`);
  } catch (err) {
    logError(`Failed to write NocoDB schema export: ${err.message}`);
  }
}

function writeDebugJson() {
  try {
    fs.writeFileSync(DEBUG_OUTPUT_PATH, JSON.stringify(debugData, null, 2), 'utf8');
    logInfo(`Debug JSON written to: ${DEBUG_OUTPUT_PATH}`);
  } catch (err) {
    logError(`Failed to write debug JSON: ${err.message}`);
  }
}

// --------------------------------------------
// MAIN
// --------------------------------------------

async function main() {
  try {
    const schema = loadAirtableSchema(SCHEMA_PATH);
    const airtableMaps = buildAirtableMaps(schema);

    // First-pass: create tables
    const ncClient = axios.create({
      baseURL: NOCODB_URL.replace(/\/+$/, ""),
      headers: {
        "xc-token": NOCODB_API_TOKEN,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
    });

    logInfo(`Creating ${schema.tables.length} table(s) in NocoDB (first pass)...`);
    for (const t of schema.tables) {
      await createNocoTableFromAirtableTable_FirstPass(ncClient, NOCODB_BASE_ID, t);
    }

    // Refresh Noco table structures
    let nocoTables = await fetchNocoTablesWithFields();

    // After first-pass table creation, before buildDependencyGraph(...)
    logInfo("PHASE 0.5: Creating formula fields...");
    for (const atTable of schema.tables || []) {
     const parentNoco = findNocoTableForAirtableTable(atTable, nocoTables);
     if (!parentNoco) continue;
     for (const atField of atTable.fields || []) {
       if (atField.type === 'formula') {
         await processAirtableField({
           atTable,
           atField,
           airtableMaps,
           nocoTables,
         });
       }
     }
    }
    await stabilize("formulas");
    nocoTables = await fetchNocoTablesWithFields();
   
    // Dependency graph
    const graph = buildDependencyGraph(schema, airtableMaps);

    // Phase 1: links
    logInfo("PHASE 1: Creating links...");
    for (const item of graph.links) {
      await ensureLinkForAirtableField({
        atTable: item.atTable,
        atField: item.atField,
        airtableMaps,
        nocoTables,
      });
    }
    await stabilize("links");
    nocoTables = await fetchNocoTablesWithFields();

    // Phase 2: simple lookups
    logInfo("PHASE 2: Creating simple lookups...");
    for (const item of graph.simpleLookups) {
      await createLookupField({
        atTable: item.atTable,
        atField: item.atField,
        airtableMaps,
        nocoTables,
      });
    }
    await stabilize("simple lookups");
    nocoTables = await fetchNocoTablesWithFields();

    // Phase 3: simple rollups
    logInfo("PHASE 3: Creating simple rollups...");
    for (const item of graph.simpleRollups) {
      await createRollupField({
        atTable: item.atTable,
        atField: item.atField,
        airtableMaps,
        nocoTables,
      });
    }
    await stabilize("simple rollups");
    nocoTables = await fetchNocoTablesWithFields();

    // Phase 4: chained lookups
    logInfo("PHASE 4: Creating chained lookups...");
    for (const item of graph.chainedLookups) {
      await createLookupField({
        atTable: item.atTable,
        atField: item.atField,
        airtableMaps,
        nocoTables,
      });
    }
    await stabilize("chained lookups");
    nocoTables = await fetchNocoTablesWithFields();

    // Phase 5: chained rollups
    logInfo("PHASE 5: Creating chained rollups...");
    for (const item of graph.chainedRollups) {
      await createRollupField({
        atTable: item.atTable,
        atField: item.atField,
        airtableMaps,
        nocoTables,
      });
    }
    await stabilize("chained rollups");
    nocoTables = await fetchNocoTablesWithFields();

    // Retry pass
    await retryFailedPhaseItems(graph, airtableMaps, nocoTables);

    // Final phase: retry deferred formulas now that all links/lookups/rollups exist
    if (deferredFormulaCreates.length) {
      logInfo("FINAL PHASE: Retrying deferred formulas after all relations/rollups/lookups are created...");

      // Refresh Noco tables once before we start
      nocoTables = await fetchNocoTablesWithFields();

      for (const item of deferredFormulaCreates) {
        const atTable = airtableMaps.tablesById[item.atTableId];
        if (!atTable) continue;

        const atField = (atTable.fields || []).find(f => f.name === item.atFieldName);
        if (!atField || atField.type !== 'formula') continue;

        const parentNoco = findNocoTableForAirtableTable(atTable, nocoTables);
        if (!parentNoco) continue;

        await refreshNocoFieldsForTable(parentNoco);

        const options = atField.options || {};
        const formula = options.formula;
        if (!formula) continue;

        const isDisplayValue =
          atTable.fields &&
          atTable.fields.length > 0 &&
          atTable.fields[0].id === atField.id;

        await createFormulaField({
          parentTable: parentNoco,
          baseTitle: atField.name,
          formula,
          originalFormula: formula,
          atTable,
          airtableMaps,
          atField,
          finalAttempt: true,
          isDisplayValue,
        });
      }

      await stabilize("final formulas");
      nocoTables = await fetchNocoTablesWithFields();
      
      // Ensure fields are hydrated before exporting schema
      for (const t of nocoTables) {
        await refreshNocoFieldsForTable(t);
      }
    }

    // Final lookup fixup: ensure any Airtable lookups whose target columns
    // were created in the final formula phase now exist in NocoDB.
    logInfo("FINAL PHASE: Ensuring all remaining Airtable lookups exist in NocoDB.");
    nocoTables = await fetchNocoTablesWithFields();

    for (const atTable of schema.tables || []) {
      const parentNoco = findNocoTableForAirtableTable(atTable, nocoTables);
      if (!parentNoco) continue;

      await refreshNocoFieldsForTable(parentNoco);

      for (const atField of atTable.fields || []) {
        if (atField.type !== 'multipleLookupValues') {
          continue;
        }

        const existing = (parentNoco.fields || []).find(
          (f) => (f.title || f.name) === atField.name
        );
        const existingType = existing ? fieldType(existing) : null;

        // If the lookup already exists, skip it.
        if (existing && (existingType === 'Lookup' || existingType === 'LookupField')) {
          continue;
        }

        // Try to create the lookup now that all formulas/relations exist.
        await createLookupField({
          atTable,
          atField,
          airtableMaps,
          nocoTables,
        });

        // Refresh in case we just added a field.
        await refreshNocoFieldsForTable(parentNoco);
      }
    }

    await stabilize("final lookup fixup");
    nocoTables = await fetchNocoTablesWithFields();

    // Export final NocoDB schema snapshot for comparison with Airtable _schema.json
    writeNocoSchemaExport(nocoTables);
    
    // Manual instructions
    if (manualLinkDescriptions.length > 0) {
      logInfo('Manual link instructions:');
      manualLinkDescriptions.forEach(d => {
        console.log(
          `MANUAL_LINK\tTable="${d.table}"\tColumn="${d.column}"\t${d.description}`
        );
      });
    }

    if (manualRollupDescriptions.length > 0) {
      logInfo('Manual rollup instructions:');
      manualRollupDescriptions.forEach(d => {
        console.log(
          `MANUAL_ROLLUP\tTable="${d.table}"\tColumn="${d.column}"\t${d.description}`
        );
      });
    }

    if (manualLookupDescriptions.length > 0) {
      logInfo('Manual lookup instructions:');
      manualLookupDescriptions.forEach(d => {
        console.log(
          `MANUAL_LOOKUP\tTable="${d.table}"\tColumn="${d.column}"\t${d.description}`
        );
      });
    }

    if (manualFormulaFallbacks.length) {
      logInfo('Manual formulas preserved as LongText:');
      manualFormulaFallbacks.forEach((item, idx) => {
        const prefix = `${idx + 1}. [${item.table}] ${item.column}`;
        logInfo(`  ${prefix}`);
        logInfo(
          `     Review LongText field "${item.fieldTitle}" to recreate Formula manually.`
        );
        logInfo(`     Original expression: ${item.formula}`);
      });
    }

    // Write debug JSON
    writeDebugJson();

  } catch (err) {
    logError(`Fatal error in create_nocodb_schema_full: ${err.message}`);
    writeDebugJson();
    process.exitCode = 1;
  }
}

if (require.main === module) {
  main();
}
