#!/usr/bin/env node

/**
 * create_nocodb_relations_and_rollups.js
 *
 * Second-pass migration script:
 *   - Creates LinkToAnotherRecord relations for Airtable multipleRecordLinks
 *   - Creates Formula fields for Airtable formula fields
 *   - Creates Rollup and Lookup fields (when enabled via env flags)
 *   - Deletes LongText placeholders created by first-pass schema import
 *   - Supports NocoDB v2 and v3 META APIs:
 *
 *     v3:
 *       GET    /api/v3/meta/bases/{baseId}/tables?include_fields=true
 *       GET    /api/v3/meta/bases/{baseId}/tables/{tableId}        (fields[])
 *       POST   /api/v3/meta/bases/{baseId}/tables/{tableId}/fields (create field)
 *       DELETE /api/v3/meta/bases/{baseId}/fields/{fieldId}        (delete field)
 *
 *     v2:
 *       GET    /api/v2/meta/bases/{baseId}/tables                  (table list)
 *       GET    /api/v2/meta/tables/{tableId}                       (columns[])
 *       POST   /api/v2/meta/tables/{tableId}/columns               (create column)
 *       DELETE /api/v2/meta/columns/{columnId}                     (delete column)
 *
 * Usage:
 *   node create_nocodb_relations_and_rollups.js
 *
 * Env:
 *   NOCODB_URL             (default: http://localhost:8080)
 *   NOCODB_BASE_ID         (required)
 *   NOCODB_API_TOKEN       (or NC_TOKEN, etc.)
 *   NOCODB_API_VERSION     (optional: "v2" or "v3"; default "v2")
 *   SCHEMA_PATH            (default: ./export/_schema.json)
 *   NOCODB_RECREATE_LINKS   ("true" to actually delete/recreate link columns)
 *   NOCODB_RECREATE_ROLLUPS ("true" to actually create rollup columns)
 *   NOCODB_RECREATE_LOOKUPS ("true" to actually create lookup columns)
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

console.log(`[INFO] Base URL : ${NOCODB_URL}`);
console.log(`[INFO] Base ID  : ${NOCODB_BASE_ID}`);
// console.log(`[INFO] Auth Token  : ${NOCODB_API_TOKEN}`);
console.log(`[INFO] Schema   : ${SCHEMA_PATH}`);

const NOCODB_API_VERSION =
  (process.env.NOCODB_API_VERSION || 'v2').toString().toLowerCase();

const IS_V3 =
  NOCODB_API_VERSION === '3' ||
  NOCODB_API_VERSION === 'v3' ||
  NOCODB_API_VERSION === 'api_v3';

const IS_V2 = !IS_V3;

console.log(
  `[INFO] Meta API : ${IS_V2 ? 'v2 (/api/v2/meta)' : 'v3 (/api/v3/meta)'}`
);

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

console.log(`[INFO] Recreate links  : ${RECREATE_LINKS}`);
console.log(`[INFO] Recreate rollups: ${RECREATE_ROLLUPS}`);
console.log(`[INFO] Recreate lookups: ${RECREATE_LOOKUPS}`);

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
// LOAD AIRTABLE _schema.json
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
    // v3 can include fields inline
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
// FORMULA TRANSLATION (Airtable -> Noco-ish, best-effort)
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
// CREATE FORMULA FIELD ON A NOCO TABLE
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

  // Pre-detect formulas that use lookup (multipleLookupValues) fields in ways
  // NocoDB cannot evaluate (numeric aggregates or IF/SWITCH on arrays).
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
    baseTitle,
//    '(formula)'
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
    return field;
  } catch (err) {
    logWarn(
      `  NocoDB rejected Formula "${baseTitle}" on "${parentTable.title}" (expression "${translated}"): ${err.message}`
    );
    logWarn(
      `  Creating a LongText "_formula_src" field instead so the Airtable expression is preserved.`
    );

    return await createFormulaFallbackField({
      parentTable,
      baseTitle,
      formula: preserved,
    });
  }
}

// --------------------------------------------
// CREATE LINKTOANOTHERRECORD FIELD
// --------------------------------------------

async function createLinkField({
  parentTable,
  targetTable,
  baseTitle,
}) {
  const { title, column_name } = chooseUniqueFieldName(
    parentTable,
    baseTitle,
//    '(link)'
  );

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
        `Could not find primary key columns for link "${title}" on "${parentTitle}" -> "${targetTitle}".`
      );
    }

    body = {
      title,
      column_name,
      uidt: 'Links',
      parentId: parentPk.id,
      childId: childPk.id,
      type: 'mm',
      colOptions: {
        type: 'mm',
        fk_parent_column_id: parentPk.id,
        fk_child_column_id: childPk.id,
      },
    };
  } else {
    // v3: more explicit 'LinkToAnotherRecord' type with options.targetTableId
    body = {
      "type": "LinkToAnotherRecord",
      "title": title,
      "id": column_name,
      options: {
        "relation_type": "mm",  
        "related_table_id": targetTable.id
      }
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
      `  Created Link field "${fieldTitle}" on "${parentTitle}" -> "${targetTitle}".`
    );
    return field;
  } catch (err) {
    const parentTitle = parentTable.title || parentTable.name;
    const targetTitle = targetTable.title || targetTable.name;
    logError(
      `  Failed to create Link field "${baseTitle}" on "${parentTitle}" (${parentTable.id}) -> "${targetTitle}" (${targetTable.id}): ${err.message}`
    );
    return null;
  }
}

// Create inverse link (bidirectional) on target table
async function createInverseLinkField({
  parentTable,
  parentField,
  targetTable,
}) {
  if (IS_V2) {
    // v2: server auto-creates the inverse side when you create a Links column.
    const parentTitle = parentTable.title || parentTable.name;
    const targetTitle = targetTable.title || targetTable.name;
    logInfo(
      `  (v2) Skipping explicit inverse link on "${targetTitle}" – NocoDB will create the inverse for "${parentTitle}" automatically.`
    );
    return null;
  }

  const baseTitle = `${parentTable.title || parentTable.name}s`;

  const { title, column_name } = chooseUniqueFieldName(
    targetTable,
    baseTitle,
//    '(inverse)'
  );

  const body = {
    type: 'LinkToAnotherRecord',
    title,
    options: {
      relation_type: 'mm',
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
    return field;
  } catch (err) {
    const targetTitle = targetTable.title || targetTable.name;
    const parentTitle = parentTable.title || parentTable.name;
    logError(
      `  Failed to create inverse link on "${targetTitle}" (${targetTable.id}) for link back to "${parentTitle}" (${parentTable.id}): ${err.message}`
    );
    return null;
  }
}

// -----------------------------------------------------------------------------
// HANDLERS FOR SPECIFIC AIRTABLE FIELD TYPES
// -----------------------------------------------------------------------------

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
      `  Linked-record field "${atField.name}" in "${atTable.name}" has no options.linkedTableId; skipping.`
    );
    return;
  }

  // Avoid reversed Airtable link definitions
  if (options.isReversed) {
    logInfo(
      `  Skipping reversed link field "${atField.name}" in "${atTable.name}" (options.isReversed=true).`
    );
    return;
  }

  const targetAtTable = airtableMaps.tablesById[linkedTableId];
  if (!targetAtTable) {
    logWarn(
      `  Linked-record field "${atField.name}" in "${atTable.name}" references unknown tableId=${linkedTableId}; skipping.`
    );
    return;
  }

  // If we are NOT recreating links, just record a manual description and return.
  if (!RECREATE_LINKS) {
    const descParts = [];
    descParts.push(
      `Column "${atField.name}" on table "${atTable.name}" should be a link to table "${targetAtTable.name}".`
    );
    descParts.push(
      `Airtable: type "multipleRecordLinks", fieldId="${atField.id}", linkedTableId="${linkedTableId}".`
    );

    manualLinkDescriptions.push({
      table: atTable.name,
      column: atField.name,
      description: descParts.join(' '),
    });

    logInfo(
      `  Recorded manual link description for "${atField.name}" on "${atTable.name}" (no automatic link creation because NOCODB_RECREATE_LINKS is not "true").`
    );
    return;
  }

  const parentNoco = findNocoTableForAirtableTable(atTable, nocoTables);
  const childNoco = findNocoTableForAirtableTable(targetAtTable, nocoTables);

  if (!parentNoco) {
    logWarn(
      `  No matching Noco table for Airtable table "${atTable.name}" (for link field "${atField.name}"); skipping.`
    );
    return;
  }
  if (!childNoco) {
    logWarn(
      `  No matching Noco table for Airtable table "${targetAtTable.name}" (for link field "${atField.name}"); skipping.`
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
      `  Link field already exists for "${atField.name}" on "${parentNoco.title}"; skipping creation.`
    );
    return;
  }

  if (existing && existingType === 'LongText') {
    try {
      await deleteFieldById(existing.id);
      parentNoco.fields = parentNoco.fields.filter((f) => f.id !== existing.id);
      logInfo(
        `  Removed LongText placeholder "${existing.title}" on "${parentNoco.title}" before creating LinkToAnotherRecord.`
      );
    } catch (err) {
      logWarn(
        `  Failed to delete LongText placeholder "${existing.title}" on "${parentNoco.title}": ${err.message}`
      );
    }
  }

  // Create the main link
  const linkField = await createLinkField({
    parentTable: parentNoco,
    targetTable: childNoco,
    baseTitle: atField.name,
  });

  if (!linkField) return;

  // Create inverse link on the child (bidirectional by default)
  await createInverseLinkField({
    parentTable: parentNoco,
    parentField: linkField,
    targetTable: childNoco,
  });
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
      `  Rollup "${atField.name}" on "${atTable.name}" is missing recordLinkFieldId or fieldIdInLinkedTable; cannot auto-create.`
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
      `  Rollup "${atField.name}" on "${atTable.name}" link field "${linkField.name}" has no linkedTableId.`
    );
    return false;
  }

  const linkedAtTable = airtableMaps.tablesById[linkedTableId];
  if (!linkedAtTable) {
    logWarn(
      `  Rollup "${atField.name}" on "${atTable.name}" references unknown Airtable linked table id="${linkedTableId}".`
    );
    return false;
  }

  const targetAtField =
    (linkedAtTable.fields || []).find((f) => f.id === fieldIdInLinkedTable) ||
    null;
  if (!targetAtField) {
    logWarn(
      `  Rollup "${atField.name}" on "${atTable.name}" references unknown fieldIdInLinkedTable="${fieldIdInLinkedTable}" on table "${linkedAtTable.name}".`
    );
    return false;
  }

  const parentNoco = findNocoTableForAirtableTable(atTable, nocoTables);
  const linkedNoco = findNocoTableForAirtableTable(linkedAtTable, nocoTables);

  if (!parentNoco) {
    logWarn(
      `  Cannot find Noco parent table for rollup "${atField.name}" on "${atTable.name}".`
    );
    return false;
  }
  if (!linkedNoco) {
    logWarn(
      `  Cannot find Noco linked table for rollup "${atField.name}" on "${atTable.name}" -> "${linkedAtTable.name}".`
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
      `  Cannot find Noco relation column "${linkField.name}" on table "${parentNoco.title || parentNoco.name}" required for rollup "${atField.name}".`
    );
    return false;
  }

  // NEW: verify that the "relation" column is actually a link column
  const relationType = fieldType(relationNocoField);
  if (
    relationType !== 'Links' &&
    relationType !== 'LinkToAnotherRecord'
  ) {
    logWarn(
      `  Column "${relationNocoField.title || relationNocoField.name}" on "${parentNoco.title || parentNoco.name}" is not a link-type column (uidt=${relationType ||
        'unknown'}); cannot auto-create rollup "${atField.name}". ` +
        `Ensure the link is migrated (NOCODB_RECREATE_LINKS="true" or created manually) before rollups.`
    );
    return false;
  }

  const targetNocoField = (linkedNoco.fields || []).find(
    (f) => (f.title || f.name) === targetAtField.name
  );
  if (!targetNocoField) {
    logWarn(
      `  Cannot find Noco target column "${targetAtField.name}" on table "${linkedNoco.title || linkedNoco.name}" required for rollup "${atField.name}".`
    );
    return false;
  }

  const existing = (parentNoco.fields || []).find(
    (f) => (f.title || f.name) === atField.name
  );
  const existingType = existing ? fieldType(existing) : null;

  if (existing && (existingType === 'Rollup' || existingType === 'RollupField')) {
    logInfo(
      `  Rollup field "${atField.name}" already exists on "${parentNoco.title || parentNoco.name}"; skipping.`
    );
    return true;
  }

  if (existing && existingType === 'LongText') {
    try {
      await deleteFieldById(existing.id);
      parentNoco.fields = parentNoco.fields.filter((f) => f.id !== existing.id);
      logInfo(
        `  Removed LongText placeholder "${existing.title}" on "${parentNoco.title || parentNoco.name}" before creating Rollup.`
      );
    } catch (err) {
      logWarn(
        `  Failed to delete LongText placeholder "${existing.title}" on "${parentNoco.title || parentNoco.name}": ${err.message}`
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
    atField.name,
//    '(rollup)'
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

    const fieldTitle =
      body.title || field.title || field.name || field.column_name;
    logInfo(
      `  Created Rollup "${fieldTitle}" on "${parentNoco.title || parentNoco.name}" via relation "${linkField.name}" -> "${linkedAtTable.name}.${targetAtField.name}" (fn=${aggFn}).`
    );
    return true;
  } catch (err) {
    logWarn(
      `  Failed to create Rollup "${atField.name}" on "${parentNoco.title || parentNoco.name}": ${err.message}`
    );
    return false;
  }
}

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
      `  Lookup "${atField.name}" on "${atTable.name}" is missing recordLinkFieldId or fieldIdInLinkedTable; cannot auto-create.`
    );
    return false;
  }

  const linkField =
    (atTable.fields || []).find((f) => f.id === recordLinkFieldId) || null;
  if (!linkField) {
    logWarn(
      `  Lookup "${atField.name}" on "${atTable.name}" references unknown link field id="${recordLinkFieldId}".`
    );
    return false;
  }

  const linkOpts = linkField.options || {};
  const linkedTableId = linkOpts.linkedTableId;
  if (!linkedTableId) {
    logWarn(
      `  Lookup "${atField.name}" on "${atTable.name}" link field "${linkField.name}" has no linkedTableId.`
    );
    return false;
  }

  const linkedAtTable = airtableMaps.tablesById[linkedTableId];
  if (!linkedAtTable) {
    logWarn(
      `  Lookup "${atField.name}" on "${atTable.name}" references unknown Airtable linked table id="${linkedTableId}".`
    );
    return false;
  }

  const targetAtField =
    (linkedAtTable.fields || []).find((f) => f.id === fieldIdInLinkedTable) ||
    null;
  if (!targetAtField) {
    logWarn(
      `  Lookup "${atField.name}" on "${atTable.name}" references unknown fieldIdInLinkedTable="${fieldIdInLinkedTable}" on table "${linkedAtTable.name}".`
    );
    return false;
  }

  const parentNoco = findNocoTableForAirtableTable(atTable, nocoTables);
  const linkedNoco = findNocoTableForAirtableTable(linkedAtTable, nocoTables);

  if (!parentNoco) {
    logWarn(
      `  Cannot find Noco parent table for lookup "${atField.name}" on "${atTable.name}".`
    );
    return false;
  }
  if (!linkedNoco) {
    logWarn(
      `  Cannot find Noco linked table for lookup "${atField.name}" on "${atTable.name}" -> "${linkedAtTable.name}".`
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
      `  Cannot find Noco relation column "${linkField.name}" on table "${parentNoco.title || parentNoco.name}" required for lookup "${atField.name}".`
    );
    return false;
  }

  // NEW: verify that the "relation" column is actually a link column
  const relationType = fieldType(relationNocoField);
  if (
    relationType !== 'Links' &&
    relationType !== 'LinkToAnotherRecord'
  ) {
    logWarn(
      `  Column "${relationNocoField.title || relationNocoField.name}" on "${parentNoco.title || parentNoco.name}" is not a link-type column (uidt=${relationType ||
        'unknown'}); cannot auto-create lookup "${atField.name}". ` +
        `Ensure the link is migrated (NOCODB_RECREATE_LINKS="true" or created manually) before lookups.`
    );
    return false;
  }

  const targetNocoField = (linkedNoco.fields || []).find(
    (f) => (f.title || f.name) === targetAtField.name
  );
  if (!targetNocoField) {
    logWarn(
      `  Cannot find Noco target column "${targetAtField.name}" on table "${linkedNoco.title || linkedNoco.name}" required for lookup "${atField.name}".`
    );
    return false;
  }

  const existing = (parentNoco.fields || []).find(
    (f) => (f.title || f.name) === atField.name
  );
  const existingType = existing ? fieldType(existing) : null;

  if (existing && (existingType === 'Lookup' || existingType === 'LookupField')) {
    logInfo(
      `  Lookup field "${atField.name}" already exists on "${parentNoco.title || parentNoco.name}"; skipping.`
    );
    return true;
  }

  if (existing && existingType === 'LongText') {
    try {
      await deleteFieldById(existing.id);
      parentNoco.fields = parentNoco.fields.filter((f) => f.id !== existing.id);
      logInfo(
        `  Removed LongText placeholder "${existing.title}" on "${parentNoco.title || parentNoco.name}" before creating Lookup.`
      );
    } catch (err) {
      logWarn(
        `  Failed to delete LongText placeholder "${existing.title}" on "${parentNoco.title || parentNoco.name}": ${err.message}`
      );
    }
  }

  const { title, column_name } = chooseUniqueFieldName(
    parentNoco,
    atField.name,
//    '(lookup)'
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

    const fieldTitle =
      body.title || field.title || field.name || field.column_name;
    logInfo(
      `  Created Lookup "${fieldTitle}" on "${parentNoco.title || parentNoco.name}" via relation "${linkField.name}" -> "${linkedAtTable.name}.${targetAtField.name}".`
    );
    return true;
  } catch (err) {
    logWarn(
      `  Failed to create Lookup "${atField.name}" on "${parentNoco.title || parentNoco.name}": ${err.message}`
    );
    return false;
  }
}

// --------------------------------------------
// MAIN FIELD PROCESSOR
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
      `  No matching Noco table for Airtable table "${atTable.name}"; skipping field "${atField.name}".`
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
    const existingType = existing ? fieldType(existing) : null;
  
    if (existing && existingType === 'Formula') {
      logInfo(
        `  Formula field "${atField.name}" already exists on "${parentNoco.title}"; skipping.`
      );
      return;
    }
  
    if (existing && existingType === 'LongText') {
      try {
        await deleteFieldById(existing.id);
        parentNoco.fields = parentNoco.fields.filter((f) => f.id !== existing.id);
        logInfo(
          `  Removed LongText placeholder "${existing.title}" on "${parentNoco.title}" before creating Formula.`
        );
      } catch (err) {
        logWarn(
          `  Failed to delete LongText placeholder "${existing.title}" on "${parentNoco.title}": ${err.message}`
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
        `  Recorded manual rollup description for "${atField.name}" on "${atTable.name}" (no automatic rollup creation because NOCODB_RECREATE_ROLLUPS is not "true").`
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
        `  Rollup "${atField.name}" on "${atTable.name}" could not be auto-created; recorded manual rollup description instead.`
      );
    }

    return;
  }

  // Lookup (Airtable "multipleLookupValues")
  if (atField.type === 'multipleLookupValues') {
    if (!RECREATE_LOOKUPS) {
      recordLookupDescription({ atTable, atField, airtableMaps });
      logInfo(
        `  Recorded manual lookup description for "${atField.name}" on "${atTable.name}" (no automatic lookup creation because NOCODB_RECREATE_LOOKUPS is not "true").`
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
        `  Lookup "${atField.name}" on "${atTable.name}" could not be auto-created; recorded manual lookup description instead.`
      );
    }

    return;
  }

  // other types can be added later once relations are stable
}

// --------------------------------------------
// MAIN
// --------------------------------------------

async function main() {
  try {
    const schema = loadAirtableSchema(SCHEMA_PATH);
    const airtableMaps = buildAirtableMaps(schema);
    const nocoTables = await fetchNocoTablesWithFields();

    for (const atTable of schema.tables || []) {
      logInfo(`Processing table "${atTable.name}" (${atTable.id}) ...`);

      for (const atField of atTable.fields || []) {
        await processAirtableField({
          atTable,
          atField,
          airtableMaps,
          nocoTables,
        });
      }
    }

    if (manualLinkDescriptions.length > 0) {
      logInfo(
        'Manual link creation instructions (either because NOCODB_RECREATE_LINKS is not "true" or link creation failed):'
      );
      manualLinkDescriptions.forEach((d) => {
        console.log(
          `MANUAL_LINK\tTable="${d.table}"\tColumn="${d.column}"\t${d.description}`
        );
      });
    }

    if (manualRollupDescriptions.length > 0) {
      logInfo(
        'Manual rollup creation instructions (either because NOCODB_RECREATE_ROLLUPS is not "true" or rollup creation failed):'
      );
      manualRollupDescriptions.forEach((d) => {
        console.log(
          `MANUAL_ROLLUP\tTable="${d.table}"\tColumn="${d.column}"\t${d.description}`
        );
      });
    }

    if (manualLookupDescriptions.length > 0) {
      logInfo(
        'Manual lookup creation instructions (either because NOCODB_RECREATE_LOOKUPS is not "true" or lookup creation failed):'
      );
      manualLookupDescriptions.forEach((d) => {
        console.log(
          `MANUAL_LOOKUP\tTable="${d.table}"\tColumn="${d.column}"\t${d.description}`
        );
      });
    }
    
    // Manual formula fallbacks: Airtable formulas that could not be auto-created
    // and were preserved in LongText "_formula_src" columns.
    if (manualFormulaFallbacks.length) {
      logInfo('----------------------------------------------');
      logInfo(
        'Manual formulas (Airtable expressions preserved in LongText "_formula_src" columns):'
      );
    
      manualFormulaFallbacks.forEach((item, idx) => {
        const prefix = `${idx + 1}. [${item.table}] ${item.column}`;
        logInfo(`  ${prefix}`);
        logInfo(
          `     Review LongText field "${item.fieldTitle}" and recreate a NocoDB Formula field manually if desired.`
        );
        logInfo(`     Original expression: ${item.formula}`);
      });
    }
  } catch (err) {
    logError(
      `Fatal error in create_nocodb_relations_and_rollups: ${err.message}`
    );
    process.exitCode = 1;
  }
}

if (require.main === module) {
  main();
}
