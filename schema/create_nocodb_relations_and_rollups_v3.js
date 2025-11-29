#!/usr/bin/env node

/**
 * create_nocodb_relations_and_rollups_v3.js
 *
 * Second-pass migration script:
 *   - Creates LinkToAnotherRecord relations for Airtable multipleRecordLinks
 *   - Creates Formula fields for Airtable formula fields
 *   - Deletes LongText placeholders created by first-pass schema import
 *   - Uses NocoDB v3 META API:
 *
 *     GET    /api/v3/meta/bases/{baseId}/tables?include_fields=true
 *     GET    /api/v3/meta/bases/{baseId}/tables/{tableId}        (table schema incl. fields[])
 *     POST   /api/v3/meta/bases/{baseId}/tables/{tableId}/fields (create field)
 *     DELETE /api/v3/meta/bases/{baseId}/fields/{fieldId}        (delete field)
 *     PATCH  /api/v3/meta/bases/{baseId}/fields/{fieldId}        (not used yet)
 *
 * Environment variables:
 *   NOCODB_URL        (e.g. http://localhost:8080)
 *   NOCODB_BASE_ID    (required)
 *   NOCODB_API_TOKEN  (or NOCODB_AUTH_TOKEN / NOCODB_TOKEN / NC_TOKEN)
 *   SCHEMA_PATH       (defaults to ./export/_schema.json)
 */

const fs = require('fs');
const path = require('path');
const axios = require('axios');

// -----------------------------------------------------------------------------
// ENV & CONFIG
// -----------------------------------------------------------------------------

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
  path.join(__dirname, 'export', '_schema.json');

if (!NOCODB_BASE_ID) {
  console.error('[FATAL] NOCODB_BASE_ID must be set in the environment.');
  process.exit(1);
}

if (!NOCODB_API_TOKEN) {
  console.error(
    '[FATAL] NOCODB_API_TOKEN (or NOCODB_API_TOKEN / NOCODB_TOKEN / NC_TOKEN) must be set.'
  );
  process.exit(1);
}

console.log(`[INFO] Base URL : ${NOCODB_URL}`);
console.log(`[INFO] Base ID  : ${NOCODB_BASE_ID}`);
// console.log(`[INFO] Auth Token  : ${NOCODB_API_TOKEN}`);
console.log(`[INFO] Schema   : ${SCHEMA_PATH}`);

const META_BASE = `/api/v3/meta/bases/${NOCODB_BASE_ID}`;
const META_TABLES = `${META_BASE}/tables`;
const META_TABLE_FIELDS = (tableId) => `${META_BASE}/tables/${tableId}/fields`;
const META_FIELD = (fieldId) => `${META_BASE}/fields/${fieldId}`;

// ---------- BASIC LOGGING HELPERS ----------

function logInfo(msg) {
  console.log(`[INFO] ${msg}`);
}
function logWarn(msg) {
  console.warn(`[WARN] ${msg}`);
}
function logError(msg) {
  console.error(`[ERROR] ${msg}`);
}

// ---------- HTTP CLIENT (v3) ----------

const http = axios.create({
  baseURL: NOCODB_URL.replace(/\/+$/, ''),
  headers: {
    'Content-Type': 'application/json',
    'xc-token': NOCODB_API_TOKEN,
  },
  validateStatus: () => true,
});

async function apiCall(method, url, body) {
  const res = await http.request({ method, url, data: body });
  if (res.status >= 200 && res.status < 300) {
    return res.data;
  }
  const payload = res.data ? JSON.stringify(res.data) : res.statusText;
  throw new Error(`${method.toUpperCase()} ${url} -> ${res.status} ${payload}`);
}

// ---------- LOAD AIRTABLE SCHEMA ----------

function loadAirtableSchema(schemaPath) {
  const full = path.resolve(schemaPath);
  if (!fs.existsSync(full)) {
    throw new Error(`Schema file not found: ${full}`);
  }
  const raw = fs.readFileSync(full, 'utf8');
  return JSON.parse(raw);
}

// Build convenient maps: tablesById, tablesByName
function buildAirtableMaps(schema) {
  const tablesById = {};
  const tablesByName = {};

  for (const table of schema.tables || []) {
    tablesById[table.id] = table;
    tablesByName[table.name] = table;
  }

  return {
    tablesById,
    tablesByName,
  };
}

// ---------- FETCH NOCO TABLE + FIELD METADATA (v3) ----------

async function fetchNocoTablesWithFields() {
  logInfo(`Fetching NocoDB tables for base ${NOCODB_BASE_ID} ...`);

  const url = `${META_TABLES}?include_fields=true`;
  const data = await apiCall('get', url);

  // v3 meta sometimes returns { list: [...] } or an array
  let tables = data;
  if (data && Array.isArray(data.list)) {
    tables = data.list;
  }
  if (!Array.isArray(tables)) {
    throw new Error(`Unexpected tables response: ${JSON.stringify(data).slice(0, 500)}`);
  }

  logInfo(`Fetched ${tables.length} NocoDB tables.`);
  return tables;
}

// Find Noco table by Airtable table name (case-sensitive)
function findNocoTableForAirtableTable(atTable, nocoTables) {
  return (
    nocoTables.find((t) => t.title === atTable.name) ||
    nocoTables.find((t) => t.name === atTable.name) ||
    null
  );
}

/**
 * Refresh fields for a given Noco table using v3 "get table schema":
 *   GET /api/v3/meta/bases/{baseId}/tables/{tableId}
 * The response contains `fields: [...]`.
 */
async function refreshNocoFieldsForTable(table) {
  const url = `${META_TABLES}/${table.id}`; // GET table schema
  const data = await apiCall('get', url);

  let fields = data && data.fields ? data.fields : [];
  if (!Array.isArray(fields)) {
    throw new Error(
      `Unexpected fields response for table ${table.title}: ${JSON.stringify(data).slice(0, 500)}`
    );
  }
  table.fields = fields;
  logInfo(
    `  Refreshed fields for table "${table.title || table.name}": ${fields.length} field(s).`
  );
  return fields;
}

// Helper: get logical type name from a field (v3 might use type or uidt)
function fieldType(field) {
  return field.type || field.uidt || null;
}

// ---------- NAME HELPERS ----------

function chooseUniqueFieldName(table, baseTitle, suffix) {
  const existingTitles = new Set(
    (table.fields || []).map((f) => f.title || f.name).filter(Boolean)
  );
  const existingColumnNames = new Set(
    (table.fields || []).map((f) => f.column_name).filter(Boolean)
  );

  let title = baseTitle;
  if (existingTitles.has(title)) {
    title = suffix ? `${baseTitle} ${suffix}` : baseTitle;
  }

  let column_name = (title || 'field')
    .toLowerCase()
    .replace(/\s+/g, '_')
    .replace(/[^a-z0-9_]/g, '');

  if (!column_name) {
    column_name = `field_${Date.now()}`;
  }

  let finalTitle = title;
  let finalColumnName = column_name;
  let i = 2;
  while (
    existingTitles.has(finalTitle) ||
    existingColumnNames.has(finalColumnName)
  ) {
    finalTitle = `${title} (${i})`;
    finalColumnName = `${column_name}_${i}`;
    i++;
  }

  return { title: finalTitle, column_name: finalColumnName };
}

// ---------- FORMULA TRANSLATION ----------

function translateAirtableFormulaToNoco(atFormula) {
  if (!atFormula || typeof atFormula !== 'string') return atFormula;

  let f = atFormula;

  // Normalize newlines
  f = f.replace(/\r\n/g, '\n');

  // DATETIME_FORMAT(date, 'pattern') or DATETIME_FORMAT(expr, "pattern") -> expr
  // (Noco's formula engine in v3 does not support DATETIME_FORMAT, and this is
  // used primarily for label text here.)
  f = f.replace(
    /DATETIME_FORMAT\s*\(\s*([^,]+)\s*,\s*("[^"]*"|'[^']*')\s*\)/gi,
    '$1'
  );

  // DATEADD(date, n, 'unit') -> date (drop offset, keep validity)
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

  // RECORD_ID() -> "" (avoid Noco complaining about PK)
  f = f.replace(/RECORD_ID\s*\(\s*\)/gi, '""');

  // Cleanup whitespace for readability
  f = f.replace(/[ \t]+/g, ' ');
  f = f.replace(/\n\s+/g, '\n');
  f = f.trim();

  return f;
}

// -----------------------------------------------------------------------------
// FIELD CRUD HELPERS (v3 meta)
// -----------------------------------------------------------------------------

async function createFieldOnTable(tableId, payload) {
  const url = META_TABLE_FIELDS(tableId); // POST /tables/{tableId}/fields
  const res = await http.post(url, payload);
  if (res.status >= 200 && res.status < 300) return res.data;
  const msg = res.data ? JSON.stringify(res.data) : res.statusText;
  throw new Error(`POST ${url} -> ${res.status} ${msg}`);
}

async function deleteFieldById(fieldId) {
  const url = META_FIELD(fieldId); // DELETE /fields/{fieldId}
  const res = await http.delete(url);
  if (res.status >= 200 && res.status < 300) return;
  const msg = res.data ? JSON.stringify(res.data) : res.statusText;
  throw new Error(`DELETE ${url} -> ${res.status} ${msg}`);
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

  const url = `${META_BASE}/tables/${parentTable.id}/fields`;

  try {
    const res = await http.post(url, body);
    const field = res.data;
    parentTable.fields = parentTable.fields || [];
    parentTable.fields.push(field);

    logInfo(
      `  Created LongText "${field.title}" on "${parentTable.title}" to preserve original formula expression.`
    );
    return field;
  } catch (err) {
    const msg = err.response ? JSON.stringify(err.response.data) : err.message;
    logError(
      `  Failed to create fallback LongText for formula "${baseTitle}" on "${parentTable.title}": ${msg}`
    );
    return null;
  }
}

// Create Formula field
async function createFormulaField({ parentTable, baseTitle, formula, originalFormula }) {
  if (!formula) {
    logWarn(
      `  Formula field "${baseTitle}" on "${parentTable.title}" has no options.formula; skipping.`
    );
    return null;
  }

  const translated = translateAirtableFormulaToNoco(formula);
  const preserved = originalFormula || formula;

  const { title, column_name } = chooseUniqueFieldName(
    parentTable,
    baseTitle,
    '(formula)'
  );

  const body = {
    // v3-style
    type: 'Formula',
    title,
    column_name,
    options: {
      formula: translated,
    },
    // v2-style keys that v3 still understands
    dt: 'formula',
    uidt: 'Formula',
    colOptions: {
      formula: translated,
    },
  };

  const url = `${META_BASE}/tables/${parentTable.id}/fields`;

  try {
    const res = await http.post(url, body);
    const field = res.data;
    parentTable.fields = parentTable.fields || [];
    parentTable.fields.push(field);

    logInfo(
      `  Created Formula "${field.title}" on "${parentTable.title}" with expression: ${translated}`
    );
    return field;
  } catch (err) {
    const msg = err.response ? JSON.stringify(err.response.data) : err.message;
    logWarn(
      `  NocoDB rejected Formula "${baseTitle}" on "${parentTable.title}" (expression "${translated}"): ${msg}`
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

// Create LinkToAnotherRecord field (parent side)
async function createLinkField({
  parentTable,
  targetTable,
  baseTitle,
}) {
  const { title, column_name } = chooseUniqueFieldName(
    parentTable,
    baseTitle,
    '(link)'
  );

  const body = {
    // v3-style
    type: 'LinkToAnotherRecord',
    title,
    column_name,
    options: {
      relation_type: 'mm', // LTAR mode: all multi
      related_table_id: targetTable.id,
    },
    // v2-style keys that v3 still understands (avoids dt undefined)
    dt: 'mm',
    uidt: 'LinkToAnotherRecord',
    colOptions: {
      type: 'mm',
      fk_related_model_id: targetTable.id,
    },
  };

  const url = `${META_BASE}/tables/${parentTable.id}/fields`;

  try {
    const res = await http.post(url, body);
    const field = res.data;
    parentTable.fields = parentTable.fields || [];
    parentTable.fields.push(field);

    logInfo(
      `  Created LinkToAnotherRecord "${field.title}" on "${parentTable.title}" -> "${targetTable.title}".`
    );
    return field;
  } catch (err) {
    const msg = err.response ? JSON.stringify(err.response.data) : err.message;
    logError(
      `  Failed to create LinkToAnotherRecord "${baseTitle}" on "${parentTable.title}" -> "${targetTable.title}": ${msg}`
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
  // Inverse field name = plural table name (per your spec).
  const baseTitle = `${parentTable.title}s`; // simple pluralization

  const { title, column_name } = chooseUniqueFieldName(
    targetTable,
    baseTitle,
    '(inverse)'
  );

  const body = {
    // v3-style
    type: 'LinkToAnotherRecord',
    title,
    column_name,
    options: {
      relation_type: 'mm',
      related_table_id: parentTable.id,
    },
    // v2-style keys
    dt: 'mm',
    uidt: 'LinkToAnotherRecord',
    colOptions: {
      type: 'mm',
      fk_related_model_id: parentTable.id,
    },
  };

  const url = `${META_BASE}/tables/${targetTable.id}/fields`;

  try {
    const res = await http.post(url, body);
    const field = res.data;
    targetTable.fields = targetTable.fields || [];
    targetTable.fields.push(field);

    logInfo(
      `  Created inverse LinkToAnotherRecord "${field.title}" on "${targetTable.title}" -> "${parentTable.title}".`
    );
    return field;
  } catch (err) {
    const msg = err.response ? JSON.stringify(err.response.data) : err.message;
    logError(
      `  Failed to create inverse link on "${targetTable.title}" for "${parentField.title}": ${msg}`
    );
    return null;
  }
}

// ---------- PER-FIELD HANDLER ----------

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

  // If a field with the same title already exists on parent, and it's already a LinkToAnotherRecord, do nothing.
  const existing = (parentNoco.fields || []).find((f) => f.title === atField.name);
  const existingType = existing ? fieldType(existing) : null;
  if (existing && existingType === 'LinkToAnotherRecord') {
    logInfo(
      `  LinkToAnotherRecord already exists for "${atField.name}" on "${parentNoco.title}"; skipping creation.`
    );
    return;
  }

  // If a LongText placeholder with same title exists, delete it before creating link
  if (existing && existing.type === 'LongText') {
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

async function processAirtableField({
  atTable,
  atField,
  airtableMaps,
  nocoTables,
}) {
  const parentNoco = findNocoTableForAirtableTable(atTable, nocoTables);
  if (!parentNoco) {
    logWarn(`  No matching Noco table for Airtable table "${atTable.name}"; skipping.`);
    return;
  }

  // Multiple record links -> LinkToAnotherRecord
  if (atField.type === 'multipleRecordLinks') {
    await ensureLinkForAirtableField({
      atTable,
      atField,
      airtableMaps,
      nocoTables,
    });
    return;
  }

  // Formula field -> Formula
  if (atField.type === 'formula') {
    const options = atField.options || {};
    const formula = options.formula;
    await refreshNocoFieldsForTable(parentNoco);

    // If a field with same title already exists and is Formula, skip
    const existing = (parentNoco.fields || []).find((f) => f.title === atField.name);
    const existingType = existing ? fieldType(existing) : null;
    if (existing && existingType === 'Formula') {
      logInfo(
        `  Formula field "${atField.name}" already exists on "${parentNoco.title}"; skipping.`
      );
      return;
    }

    // If there's a LongText placeholder with same title, delete it
    if (existing && existing.type === 'LongText') {
      try {
        await deleteFieldById(existing.id);
        parentNoco.fields = parentNoco.fields.filter((f) => f.id !== existing.id);
        logInfo(
          `  Removed LongText placeholder "${existing.title}" on "${parentNoco.title}" before creating Formula.`
        );
      } catch (err) {
        const msg = err.response ? JSON.stringify(err.response.data) : err.message;
        logWarn(
          `  Failed to delete LongText placeholder "${existing.title}" on "${parentNoco.title}": ${msg}`
        );
      }
    }

    await createFormulaField({
      parentTable: parentNoco,
      baseTitle: atField.name,
      formula,
      originalFormula: formula,
    });

    return;
  }

  // lookup / rollup will be added later once relations are stable
}

// ---------- MAIN ----------

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

    logInfo('Done.');
  } catch (err) {
    logError(`Fatal error in create_nocodb_relations_and_rollups_v3: ${err.message}`);
    process.exitCode = 1;
  }
}

if (require.main === module) {
  main();
}
