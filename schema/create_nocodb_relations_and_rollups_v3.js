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
    '[FATAL] NOCODB_API_TOKEN (or NOCODB_AUTH_TOKEN / NOCODB_TOKEN / NC_TOKEN) must be set.'
  );
  process.exit(1);
}

console.log(`[INFO] Base URL : ${NOCODB_URL}`);
console.log(`[INFO] Base ID  : ${NOCODB_BASE_ID}`);
console.log(`[INFO] Schema   : ${SCHEMA_PATH}`);

const META_BASE = `/api/v3/meta/bases/${NOCODB_BASE_ID}`;
const META_TABLES = `${META_BASE}/tables`;
const META_TABLE_FIELDS = (tableId) => `${META_BASE}/tables/${tableId}/fields`;
const META_FIELD = (fieldId) => `${META_BASE}/fields/${fieldId}`;

// -----------------------------------------------------------------------------
// HTTP CLIENT (v3 meta)
// -----------------------------------------------------------------------------

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

// -----------------------------------------------------------------------------
// LOG HELPERS
// -----------------------------------------------------------------------------

function logInfo(msg) {
  console.log(`[INFO] ${msg}`);
}
function logWarn(msg) {
  console.warn(`[WARN] ${msg}`);
}
function logError(msg) {
  console.error(`[ERROR] ${msg}`);
}

// -----------------------------------------------------------------------------
// LOAD AIRTABLE SCHEMA
// -----------------------------------------------------------------------------

function loadAirtableSchema(schemaPath) {
  const full = path.resolve(schemaPath);
  if (!fs.existsSync(full)) {
    throw new Error(`Schema file not found: ${full}`);
  }
  const raw = fs.readFileSync(full, 'utf8');
  return JSON.parse(raw);
}

function buildAirtableMaps(schema) {
  const tablesById = {};
  const tablesByName = {};

  for (const table of schema.tables || []) {
    tablesById[table.id] = table;
    tablesByName[table.name] = table;
  }

  return { tablesById, tablesByName };
}

// -----------------------------------------------------------------------------
// FETCH NOCO TABLE + FIELD METADATA (v3)
// -----------------------------------------------------------------------------

async function fetchNocoTablesWithFields() {
  logInfo(`Fetching NocoDB tables for base ${NOCODB_BASE_ID} ...`);

  const url = `${META_TABLES}?include_fields=true`;
  const data = await apiCall('get', url);

  // v3 meta may return an array of tables or { list: [...] }
  let tables = data;
  if (data && Array.isArray(data.list)) {
    tables = data.list;
  }
  if (!Array.isArray(tables)) {
    throw new Error(
      `Unexpected response for tables: ${JSON.stringify(data).slice(0, 500)}`
    );
  }

  logInfo(`Fetched ${tables.length} tables from NocoDB base.`);
  return tables;
}

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

  const fields = Array.isArray(data.fields) ? data.fields : [];
  table.fields = fields;

  logInfo(
    `  Refreshed fields for table "${table.title || table.name}": ${fields.length} field(s).`
  );

  return fields;
}

// -----------------------------------------------------------------------------
// NAME HELPERS
// -----------------------------------------------------------------------------

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

// -----------------------------------------------------------------------------
// FORMULA TRANSLATION (Airtable -> Noco-ish, best-effort)
// -----------------------------------------------------------------------------

function translateAirtableFormulaToNoco(atFormula) {
  if (!atFormula || typeof atFormula !== 'string') return atFormula;

  let f = atFormula;

  f = f.replace(/\r\n/g, '\n');

  // DATETIME_FORMAT(date, 'pattern') -> date
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

  // RECORD_ID() -> "" to avoid PK complaints
  f = f.replace(/RECORD_ID\s*\(\s*\)/gi, '""');

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

async function createFormulaFallbackField({ parentTable, baseTitle, formula }) {
  const { title, column_name } = chooseUniqueFieldName(
    parentTable,
    `${baseTitle}_formula_src`,
    '(fallback)'
  );

  const payload = {
    type: 'LongText',
    title,
    column_name,
  };

  try {
    const created = await createFieldOnTable(parentTable.id, payload);
    parentTable.fields = parentTable.fields || [];
    parentTable.fields.push(created);

    logInfo(
      `  Created LongText fallback "${created.title}" on "${parentTable.title}" to preserve formula "${baseTitle}".`
    );
    return created;
  } catch (err) {
    logError(
      `  Failed to create LongText fallback for formula "${baseTitle}" on "${parentTable.title}": ${err.message}`
    );
    return null;
  }
}

async function createFormulaField({
  parentTable,
  baseTitle,
  formula,
  originalFormula,
}) {
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

  const payload = {
    type: 'Formula',
    title,
    column_name,
    options: {
      formula: translated,
    },
  };

  try {
    const created = await createFieldOnTable(parentTable.id, payload);
    parentTable.fields = parentTable.fields || [];
    parentTable.fields.push(created);

    logInfo(
      `  Created Formula "${created.title}" on "${parentTable.title}" with expression: ${translated}`
    );
    return created;
  } catch (err) {
    logWarn(
      `  NocoDB rejected Formula "${baseTitle}" on "${parentTable.title}" (expression "${translated}"): ${err.message}`
    );
    logWarn(
      '  Creating LongText "_formula_src" fallback column instead to preserve Airtable expression.'
    );
    return await createFormulaFallbackField({
      parentTable,
      baseTitle,
      formula: preserved,
    });
  }
}

// -----------------------------------------------------------------------------
// LINK (LTAR) FIELD CREATION (bidirectional mm)
// -----------------------------------------------------------------------------

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

  const payload = {
    type: 'LinkToAnotherRecord',
    title,
    column_name,
    options: {
      relation_type: 'mm',           // LTAR mode: all multi
      related_table_id: targetTable.id,
    },
  };

  try {
    const created = await createFieldOnTable(parentTable.id, payload);
    parentTable.fields = parentTable.fields || [];
    parentTable.fields.push(created);

    logInfo(
      `  Created LinkToAnotherRecord "${created.title}" on "${parentTable.title}" -> "${targetTable.title}".`
    );
    return created;
  } catch (err) {
    logError(
      `  Failed to create LinkToAnotherRecord "${baseTitle}" on "${parentTable.title}" -> "${targetTable.title}": ${err.message}`
    );
    return null;
  }
}

async function createInverseLinkField({
  parentTable,
  parentField,
  targetTable,
}) {
  const baseTitle = `${parentTable.title || parentTable.name || 'parent'}s`;

  const { title, column_name } = chooseUniqueFieldName(
    targetTable,
    baseTitle,
    '(inverse)'
  );

  const payload = {
    type: 'LinkToAnotherRecord',
    title,
    column_name,
    options: {
      relation_type: 'mm',
      related_table_id: parentTable.id,
    },
  };

  try {
    const created = await createFieldOnTable(targetTable.id, payload);
    targetTable.fields = targetTable.fields || [];
    targetTable.fields.push(created);

    logInfo(
      `  Created inverse LinkToAnotherRecord "${created.title}" on "${targetTable.title}" -> "${parentTable.title}".`
    );
    return created;
  } catch (err) {
    logError(
      `  Failed to create inverse link on "${targetTable.title}" for "${parentField.title}": ${err.message}`
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
      `  No matching Noco table for linked Airtable table "${targetAtTable.name}" (for link field "${atField.name}"); skipping.`
    );
    return;
  }

  await refreshNocoFieldsForTable(parentNoco);
  await refreshNocoFieldsForTable(childNoco);

  const existing = (parentNoco.fields || []).find(
    (f) => (f.title || f.name) === atField.name
  );

  if (existing && existing.type === 'LinkToAnotherRecord') {
    logInfo(
      `  LinkToAnotherRecord already exists for "${atField.name}" on "${parentNoco.title}"; skipping creation.`
    );
    return;
  }

  if (existing && existing.type === 'LongText') {
    try {
      await deleteFieldById(existing.id);
      parentNoco.fields = parentNoco.fields.filter((f) => f.id !== existing.id);
      logInfo(
        `  Removed LongText placeholder "${existing.title}" on "${parentNoco.title}" before creating link.`
      );
    } catch (err) {
      logWarn(
        `  Failed to delete LongText placeholder "${existing.title}" on "${parentNoco.title}": ${err.message}`
      );
    }
  }

  const linkField = await createLinkField({
    parentTable: parentNoco,
    targetTable: childNoco,
    baseTitle: atField.name,
  });

  if (!linkField) return;

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
    logWarn(
      `  No matching Noco table for Airtable table "${atTable.name}"; skipping field "${atField.name}".`
    );
    return;
  }

  // Link fields
  if (atField.type === 'multipleRecordLinks') {
    await ensureLinkForAirtableField({
      atTable,
      atField,
      airtableMaps,
      nocoTables,
    });
    return;
  }

  // Formula fields
  if (atField.type === 'formula') {
    const options = atField.options || {};
    const formula = options.formula;
    await refreshNocoFieldsForTable(parentNoco);

    const existing = (parentNoco.fields || []).find(
      (f) => (f.title || f.name) === atField.name
    );

    if (existing && existing.type === 'Formula') {
      logInfo(
        `  Formula field "${atField.name}" already exists on "${parentNoco.title}"; skipping.`
      );
      return;
    }

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

// -----------------------------------------------------------------------------
// MAIN
// -----------------------------------------------------------------------------

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

    logInfo('Done creating relations and formulas for v3.');
  } catch (err) {
    logError(
      `Fatal error in create_nocodb_relations_and_rollups_v3: ${err.message}`
    );
    process.exitCode = 1;
  }
}

if (require.main === module) {
  main();
}
