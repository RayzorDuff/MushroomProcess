#!/usr/bin/env node

/**
 * create_nocodb_schema_full.js
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

// --------------------------------------------
// ENV + CONFIG
// --------------------------------------------

const NOCODB_URL =
  process.env.NOCODB_URL ||
  process.env.NC_URL ||
  'http://localhost:8080';

const NOCODB_BASE_ID = process.env.NOCODB_BASE_ID;

const NOCODB_API_TOKEN =
  process.env.NOCODB_API_TOKEN ||
  process.env.NOCODB_AUTH_TOKEN ||
  process.env.NOCODB_TOKEN ||
  process.env.NC_TOKEN ||
  '';

const SCHEMA_PATH =
  process.env.SCHEMA_PATH ||
  path.join(process.cwd(), 'export', '_schema.json');

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

const NOCODB_API_VERSION =
  (process.env.NOCODB_API_VERSION || 'v2').toString().toLowerCase();

const IS_V3 =
  NOCODB_API_VERSION === '3' ||
  NOCODB_API_VERSION === 'v3' ||
  NOCODB_API_VERSION === 'api_v3';

const IS_V2 = !IS_V3;

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

console.log(`[INFO] Base URL : ${NOCODB_URL}`);
console.log(`[INFO] Base ID  : ${NOCODB_BASE_ID}`);
console.log(`[INFO] Schema   : ${SCHEMA_PATH}`);
console.log(
  `[INFO] Meta API : ${IS_V2 ? 'v2 (/api/v2/meta)' : 'v3 (/api/v3/meta)'}`
);
console.log(`[INFO] Recreate links  : ${RECREATE_LINKS}`);
console.log(`[INFO] Recreate rollups: ${RECREATE_ROLLUPS}`);
console.log(`[INFO] Recreate lookups: ${RECREATE_LOOKUPS}`);
console.log(`[INFO] Debug JSON path : ${DEBUG_OUTPUT_PATH}`);

const META_PREFIX = IS_V2 ? '/api/v2/meta' : '/api/v3/meta';

// Base-level tables listing endpoint is the same shape in v2 & v3
const META_TABLES = `${META_PREFIX}/bases/${NOCODB_BASE_ID}/tables`;

// Field creation endpoint differs between v2 & v3.
const META_TABLE_FIELDS = (tableId) =>
  IS_V2
    ? `${META_PREFIX}/tables/${tableId}/columns`
    : `${META_PREFIX}/bases/${NOCODB_BASE_ID}/tables/${tableId}/fields`;

// Field (column) delete endpoint.
const META_FIELD = (fieldId) =>
  IS_V2
    ? `${META_PREFIX}/columns/${fieldId}`
    : `${META_PREFIX}/bases/${NOCODB_BASE_ID}/fields/${fieldId}`;

// --------------------------------------------
// BASIC LOGGING HELPERS
// --------------------------------------------

function logInfo(msg) {
  console.log(`[INFO] ${msg}`);
}

function logWarn(msg) {
  console.warn(`[WARN] ${msg}`);
}

function logError(msg) {
  console.error(`[ERROR] ${msg}`);
}

// --------------------------------------------
// AXIOS INSTANCE
// --------------------------------------------

const api = axios.create({
  baseURL: NOCODB_URL.replace(/\/+$/, ''),
  headers: {
    'xc-token': NOCODB_API_TOKEN,
    'Content-Type': 'application/json',
  },
  timeout: 60000,
  validateStatus: () => true,
});

async function apiCall(method, url, data) {
  try {
    const res = await api.request({
      method,
      url,
      data,
    });
    if (res.status >= 200 && res.status < 300) {
      return res.data;
    }
    const payload = res.data ? JSON.stringify(res.data) : res.statusText;
    throw new Error(`${method.toUpperCase()} ${url} -> ${res.status} ${payload}`);
  } catch (err) {
    const status = err.response && err.response.status;
    const body =
      err.response && err.response.data
        ? JSON.stringify(err.response.data).slice(0, 500)
        : String(err);
    throw new Error(
      `API ${method.toUpperCase()} ${url} failed (status=${status}): ${body}`
    );
  }
}

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

  // --- Numbers & decimals ---
  if (type === 'number' || type === 'percent') {
    col.uidt = 'Number';
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

async function createNocoTableFromAirtableTable_FirstPass(ncClient, baseId, airTable) {
  const tableName = airTable.name;
  console.log(`\n[INFO] Creating NocoDB table for Airtable table: "${tableName}"`);

  const columnDefs = [];

  // Special PK for NocoDB
  const name = "nocopk";
  const pkCol = {
    column_name: name,
    title: name,
    uidt: "Number",
    pk: true
  };
  columnDefs.push(pkCol);

  for (const field of airTable.fields || []) {
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

// --------------------------------------------
// NOCO: FETCH TABLES + FIELDS
// --------------------------------------------

/**
 * Fetch all NocoDB tables for the base, including field/column metadata.
 *
 * v3:
 *   GET /api/v3/meta/bases/{baseId}/tables?include_fields=true
 *
 * v2:
 *   GET /api/v2/meta/bases/{baseId}/tables         (list only)
 *   GET /api/v2/meta/tables/{tableId}             (per-table columns[])
 */
async function fetchNocoTablesWithFields() {
  logInfo(
    `Fetching NocoDB tables for base ${NOCODB_BASE_ID} using ${
      IS_V2 ? 'v2' : 'v3'
    } meta API ...`
  );

  if (!IS_V2) {
    const url = `${META_TABLES}?include_fields=true`;
    const data = await apiCall('get', url);

    let tables = data;
    if (data && Array.isArray(data.list)) {
      tables = data.list;
    }
    if (!Array.isArray(tables)) {
      throw new Error(
        `Unexpected tables response: ${JSON.stringify(data).slice(0, 500)}`
      );
    }

    logInfo(`Fetched ${tables.length} NocoDB tables (v3, inline fields).`);
    return tables;
  }

  // v2: fetch tables first, then hydrate their columns via /meta/tables/{tableId}
  const data = await apiCall('get', META_TABLES);
  let tables = data;
  if (data && Array.isArray(data.list)) {
    tables = data.list;
  }
  if (!Array.isArray(tables)) {
    throw new Error(
      `Unexpected tables response (v2): ${JSON.stringify(data).slice(0, 500)}`
    );
  }

  for (const table of tables) {
    await refreshNocoFieldsForTable(table);
  }

  logInfo(`Fetched ${tables.length} NocoDB tables (v2, columns hydrated).`);
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
  const url = IS_V2
    ? `/api/v2/meta/tables/${table.id}`
    : `${META_TABLES}/${table.id}`;

  const data = await apiCall('get', url);

  let fields;
  if (IS_V2) {
    // v2 table meta exposes columns[]
    const columns = Array.isArray(data.columns) ? data.columns : [];
    fields = columns;
  } else {
    // v3 table meta exposes fields[]
    fields = Array.isArray(data.fields) ? data.fields : [];
  }

  table.fields = fields;

  logInfo(
    `  Refreshed fields for table "${
      table.title || table.name || table.table_name
    }": ${fields.length} field(s).`
  );

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
    /DATETIME_FORMAT\s*\(\s*([^,]+)\s*,\s*("[^"]*"|'[^']*')\s*\)/gi,
    '$1'
  );

  // DATEADD(date, n, 'unit') -> date
  f = f.replace(
    /DATEADD\s*\(\s*([^,]+)\s*,\s*[^,]+,\s*'[^']*'\s*\)/gi,
    '$1'
  );

  // SET_TIMEZONE(date, "TZ") -> date
  f = f.replace(
    /SET_TIMEZONE\s*\(\s*([^,]+)\s*,\s*("[^"]*"|'[^']*')\s*\)/gi,
    '$1'
  );

  // CREATED_TIME() -> NOW()
  f = f.replace(/CREATED_TIME\s*\(\s*\)/gi, 'NOW()');

  // TRUE() / FALSE() -> TRUE / FALSE
  f = f.replace(/\bTRUE\s*\(\s*\)/gi, 'TRUE');
  f = f.replace(/\bFALSE\s*\(\s*\)/gi, 'FALSE');

  // BLANK() -> ""
  f = f.replace(/\bBLANK\s*\(\s*\)/gi, '""');

  // RECORD_ID() -> ""
  f = f.replace(/RECORD_ID\s*\(\s*\)/gi, '""');

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
  if (!formula || !atTable || !airtableMaps || !airtableMaps.fieldsByTableAndId) {
    return false;
  }

  const perTable = airtableMaps.fieldsByTableAndId[atTable.id] || {};
  const lookupIds = Object.keys(perTable).filter((fid) => {
    const fld = perTable[fid];
    return fld && fld.type === 'multipleLookupValues';
  });

  if (!lookupIds.length) return false;

  const f = String(formula);

  for (const fid of lookupIds) {
    const token = `{${fid}}`;
    const tokenEsc = escapeRegex(token);

    // Numeric aggregates of lookup arrays (unsupported)
    const aggRe = new RegExp(
      `\\b(SUM|MAX|MIN|AVG|COUNT)\\s*\\(\\s*${tokenEsc}\\s*\\)`,
      'i'
    );
    if (aggRe.test(f)) {
      return true;
    }

    // IF({lookup}, ...) / SWITCH({lookup}, ...) style conditions on arrays (unsupported)
    const ifRe = new RegExp(`\\bIF\\s*\\(\\s*${tokenEsc}`, 'i');
    if (ifRe.test(f)) {
      return true;
    }

    const switchRe = new RegExp(`\\bSWITCH\\s*\\(\\s*${tokenEsc}`, 'i');
    if (switchRe.test(f)) {
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

async function deleteFieldById(fieldId) {
  const url = META_FIELD(fieldId);
  return await apiCall('delete', url);
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
    body = {
      title,
      column_name,
      uidt: 'Formula',
      dt: 'formula',
      colOptions: {
        formula: translated,
      },
      formula: translated,
      formula_raw: translated,
    };
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
    logWarn(
      `  NocoDB rejected Formula "${baseTitle}" on "${parentTable.title}" (expression "${translated}"): ${err.message}`
    );
    logWarn(
      `  Creating a LongText "_formula_src" field instead so the Airtable expression is preserved.`
    );

    debugData.failed.formulas.push({
      table: parentTable.title || parentTable.name,
      field: baseTitle,
      reason: "NocoDB rejected formula",
      translated
    });

    return await createFormulaFallbackField({
      parentTable,
      baseTitle,
      formula: preserved,
    });
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

  if (IS_V2) {
    // v2: Links / LinkToAnotherRecord are created as normal columns with
    //     uidt = 'Links' or 'LinkToAnotherRecord' and colOptions specifying
    //     the relationship. colOptions uses fk_parent_column_id and
    //     fk_child_column_id, which must be valid column IDs (typically the
    //     primary-key columns of the two tables).
    const parentPk =
      (parentTable.fields || []).find((c) => c.pk === 1 || c.pk === true) ||
      (parentTable.fields || []).find((c) => c.pv === 1 || c.pv === true);
    const childPk =
      (targetTable.fields || []).find((c) => c.pk === 1 || c.pk === true) ||
      (targetTable.fields || []).find((c) => c.pv === 1 || c.pv === true);

    if (!parentPk || !childPk) {
      const parentTitle = parentTable.title || parentTable.name;
      const targetTitle = targetTable.title || targetTable.name;
      throw new Error(
        `Could not find primary keys for link "${title}" on "${parentTitle}" -> "${targetTitle}".`
      );
    }

    const effectiveType = relType === 'oo' ? 'hm' : relType;

    body = {
      title,
      column_name,
      uidt: 'Links',
      parentId: parentPk.id,
      childId: childPk.id,
      type: effectiveType,
      colOptions: {
        type: effectiveType,
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
    const field = await createFieldOnTable(parentTable.id, body);
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
  if (IS_V2) {
    logInfo(
      `  (v2) Skipping explicit inverse link on "${targetTable.title}" – NocoDB creates inverse automatically.`
    );
    return null;
  }

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
function mapAirtableRollupFunction(fn) {
  if (!fn) return 'sum';
  const s = String(fn).toLowerCase();

  if (s.includes('count') && s.includes('distinct')) return 'countDistinct';
  if (s.includes('count') && s.includes('unique')) return 'countDistinct';
  if (s.startsWith('count')) return 'count';

  if (s.startsWith('sum') && s.includes('distinct')) return 'sumDistinct';
  if (s.startsWith('sum')) return 'sum';

  if ((s.startsWith('avg') || s.startsWith('average')) && s.includes('distinct')) {
    return 'avgDistinct';
  }
  if (s.startsWith('avg') || s.startsWith('average')) return 'avg';

  if (s.startsWith('min')) return 'min';
  if (s.startsWith('max')) return 'max';

  return 'sum';
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

  const aggFn = mapAirtableRollupFunction(
    options.aggregationFunction ||
      options.aggregation ||
      (options.result && options.result.type)
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

    await createFormulaField({
      parentTable: parentNoco,
      baseTitle: atField.name,
      formula,
      originalFormula: formula,
      atTable,
      airtableMaps,
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
