#!/usr/bin/env node
/**
 * create_nocodb_relations_and_rollups.js
 *
 * Reads Airtable export schema (export/_schema.json) and creates:
 *   - LinkToAnotherRecord columns for multipleRecordLinks
 *   - Lookup columns for multipleLookupValues / lookup
 *   - Rollup columns for rollup
 *   - Formula columns for formula
 *
 * IMPORTANT:
 *   - This script does NOT try to PATCH or DELETE existing columns.
 *   - Existing LongText columns created by create_nocodb_from_schema.js remain as legacy.
 *   - New, correctly-typed columns are created with unique names where needed.
 *
 * Env vars:
 *   NOCODB_URL        e.g. http://localhost:8080
 *   NOCODB_BASE_ID    e.g. p0pcjn52qivlawb
 *   NOCODB_API_TOKEN  xc-token with schema-edit permissions
 *
 * Optional:
 *   SCHEMA_PATH       override path to Airtable _schema.json
 */

const fs = require('fs');
const path = require('path');
const axios = require('axios');

// ---------- ENV & CLIENT ----------

const NOCO_BASE_URL = process.env.NOCODB_URL || process.env.NOCO_BASE_URL;
const NOCO_BASE_ID = process.env.NOCODB_BASE_ID || process.env.NOCO_BASE_ID;
const NOCO_API_TOKEN = process.env.NOCODB_API_TOKEN || process.env.NOCO_API_TOKEN;

const SCHEMA_PATH =
  process.env.SCHEMA_PATH || path.join(__dirname, 'export', '_schema.json');

if (!NOCO_BASE_URL || !NOCO_BASE_ID || !NOCO_API_TOKEN) {
  console.error(
    '[FATAL] NOCODB_URL, NOCODB_BASE_ID, NOCODB_API_TOKEN (or NOCO_*) must be set in env.'
  );
  process.exit(1);
}

function logInfo(msg) {
  console.log(`[INFO] ${msg}`);
}
function logWarn(msg) {
  console.warn(`[WARN] ${msg}`);
}
function logError(msg) {
  console.error(`[ERROR] ${msg}`);
}

const http = axios.create({
  baseURL: NOCO_BASE_URL.replace(/\/+$/, ''),
  headers: {
    'xc-token': NOCO_API_TOKEN,
    'Content-Type': 'application/json',
  },
});

// ---------- LOAD AIRTABLE SCHEMA ----------

function loadAirtableSchema() {
  logInfo(`Loading Airtable schema from ${SCHEMA_PATH}`);
  const raw = fs.readFileSync(SCHEMA_PATH, 'utf8');
  const json = JSON.parse(raw);

  if (!json.tables || !Array.isArray(json.tables)) {
    throw new Error('Unexpected _schema.json format: missing tables[]');
  }
  return json.tables;
}

// Build lookup maps
function buildAirtableMaps(tables) {
  const tablesById = {};
  const tablesByName = {};
  const fieldsById = {};

  for (const t of tables) {
    tablesById[t.id] = t;
    tablesByName[t.name] = t;
    for (const f of t.fields || []) {
      fieldsById[f.id] = { table: t, field: f };
    }
  }

  return { tablesById, tablesByName, fieldsById };
}

// ---------- FETCH NOCO TABLE META ----------

async function fetchNocoTables() {
  // v2 meta API: /api/v2/meta/bases/{baseId}/tables?include_columns=true
  const url = `/api/v2/meta/bases/${NOCO_BASE_ID}/tables`;
  const res = await http.get(url, {
    params: {
      include_columns: true,
      limit: 1000,
    },
  });

  const list = res.data && (res.data.list || res.data);
  if (!Array.isArray(list)) {
    throw new Error('Unexpected NocoDB meta tables response shape');
  }

  const tablesById = {};
  const tablesByTitle = {};
  const tablesByPhysicalName = {};

  for (const t of list) {
    tablesById[t.id] = t;
    tablesByTitle[t.title] = t;
    if (t.table_name) {
      tablesByPhysicalName[t.table_name] = t;
    }
  }

  return { list, tablesById, tablesByTitle, tablesByPhysicalName };
}

function normalizeName(name) {
  return (name || '').trim().toLowerCase();
}

function findNocoTableForAirtableTable(airTable, nocoMeta) {
  const title = airTable.name;
  const normTitle = normalizeName(title);

  // Prefer title match
  for (const [k, t] of Object.entries(nocoMeta.tablesByTitle)) {
    if (normalizeName(k) === normTitle) return t;
  }

  // Fallback: try physical table_name containing the title-ish
  for (const t of nocoMeta.list) {
    if (normalizeName(t.title) === normTitle) return t;
  }

  return null;
}

function findNocoColumnByNameLike(nocoTable, fieldName) {
  const norm = normalizeName(fieldName);
  if (!nocoTable || !Array.isArray(nocoTable.columns)) return null;

  let candidate = null;

  for (const c of nocoTable.columns) {
    const titleNorm = normalizeName(c.title);
    const colNameNorm = normalizeName(c.column_name || '');
    if (titleNorm === norm || colNameNorm === norm) {
      candidate = c;
      break;
    }
  }

  return candidate;
}

// Find existing link column between parent & child (if already created)
function findExistingLinkColumn(parentTable, childTableId) {
  if (!parentTable || !Array.isArray(parentTable.columns)) return null;

  return parentTable.columns.find((c) => {
    if (!c.uidt) return false;
    const uidt = c.uidt;
    if (uidt !== 'LinkToAnotherRecord' && uidt !== 'Links') return false;

    const colOptions = c.colOptions || {};
    // For links, colOptions.type is "mm" / "bt" / "hm" / "oo"
    // and fk_related_model_id indicates target table.
    if (colOptions.fk_related_model_id === childTableId) {
      return true;
    }

    // Some versions store relation metadata differently;
    // also check childId on column.
    if (c.childId && c.childId === childTableId) return true;

    return false;
  });
}

// Generate a safe, unique column name & title on a Noco table
function chooseUniqueColumnName(nocoTable, baseTitle, suffixHint) {
  const existingTitles = new Set(
    (nocoTable.columns || []).map((c) => c.title)
  );
  const existingNames = new Set(
    (nocoTable.columns || []).map((c) => c.column_name)
  );

  let title = baseTitle;
  let name =
    baseTitle
      .normalize('NFKD')
      .replace(/[^\w]+/g, '_')
      .replace(/^_+|_+$/g, '')
      .toLowerCase() || 'col';

  if (!suffixHint) suffixHint = '';

  const baseTitleWithHint = suffixHint ? `${baseTitle} ${suffixHint}` : baseTitle;
  let titleCandidate = baseTitleWithHint;
  let nameCandidate =
    (baseTitleWithHint
      .normalize('NFKD')
      .replace(/[^\w]+/g, '_')
      .replace(/^_+|_+$/g, '')
      .toLowerCase()) || 'col';

  let i = 1;
  while (existingTitles.has(titleCandidate) || existingNames.has(nameCandidate)) {
    titleCandidate = `${baseTitleWithHint} ${i + 1}`;
    nameCandidate = `${nameCandidate}_${i}`;
    i++;
  }

  return { title: titleCandidate, column_name: nameCandidate };
}

// ---------- CREATE COLUMNS ----------
// Create a LinkToAnotherRecord column on parentTable → childTable
async function createLinkColumn({ parentTable, childTable, baseTitle }) {
  // If a relation already exists from this table to child, reuse it
  const already = findExistingLinkColumn(parentTable, childTable.id);
  if (already) {
    logInfo(
      `  Existing link column "${already.title}" on "${parentTable.title}" -> "${childTable.title}" found; reusing.`
    );
    return already;
  }

  // Choose a unique title/column_name for the new relation
  const { title, column_name } = chooseUniqueColumnName(
    parentTable,
    baseTitle,
    '(link)'
  );

  /**
   * NocoDB 0.26x’s Meta v2 usually expects relation config in colOptions:
   *   - uidt: 'LinkToAnotherRecord'
   *   - colOptions: {
   *       type: 'mm' | 'bt' | 'hm' | 'oo',
   *       fk_related_model_id: <child table id>
   *     }
   *
   * We *don’t* send dt or low-level DB details; Noco will infer them.
   */
  const body = {
    parentId: parentTable.id,
    title,
    column_name,
    uidt: 'LinkToAnotherRecord',
    colOptions: {
      type: 'mm', // treat as many-to-many by default
      fk_related_model_id: childTable.id,
      // Noco will fill in fk_relation_column_id / fk_related_column_id
    },
  };

  try {
    const url = `/api/v2/meta/tables/${parentTable.id}/columns`;
    const res = await http.post(url, body);
    const col = res.data;
    logInfo(
      `  Created LinkToAnotherRecord column "${col.title}" on "${parentTable.title}" -> "${childTable.title}".`
    );
    return col;
  } catch (err) {
    logError(
      `  Failed to create LinkToAnotherRecord "${baseTitle}" on "${parentTable.title}" -> "${childTable.title}": ${
        err.response ? JSON.stringify(err.response.data) : err.message
      }`
    );
    return null;
  }
}


// Create a Lookup column on parentTable
async function createLookupColumn({
  parentTable,
  baseTitle,
  relationColumn,
  targetColumn,
}) {
  const { title, column_name } = chooseUniqueColumnName(
    parentTable,
    baseTitle,
    '(lookup)'
  );

  const body = {
    title,
    column_name,
    uidt: 'Lookup',
    parentId: parentTable.id,
    colOptions: {
      fk_relation_column_id: relationColumn.id,
      fk_lookup_column_id: targetColumn.id,
    },
  };

  try {
    const url = `/api/v2/meta/tables/${parentTable.id}/columns`;
    const res = await http.post(url, body);
    const col = res.data;
    logInfo(
      `  Created Lookup "${col.title}" on "${parentTable.title}" from relation "${relationColumn.title}" -> "${targetColumn.title}".`
    );
    return col;
  } catch (err) {
    logError(
      `  Failed to create Lookup "${baseTitle}" on "${parentTable.title}": ${
        err.response && JSON.stringify(err.response.data)
      }`
    );
    return null;
  }
}

// Infer a reasonable rollup function from Airtable result.type
function inferRollupFunctionFromResult(atRollupField) {
  const result = atRollupField.options && atRollupField.options.result;
  const resultType = result && result.type;

  // Heuristic:
  //   - date / dateTime: max (latest)
  //   - numeric-ish: sum
  //   - everything else: count
  if (!resultType) return 'count';

  const t = resultType.toLowerCase();
  if (t === 'date' || t === 'datetime') return 'max';
  if (
    t === 'number' ||
    t === 'currency' ||
    t === 'percent' ||
    t === 'duration' ||
    t === 'decimal'
  ) {
    return 'sum';
  }

  return 'count';
}

// Create a Rollup column on parentTable
async function createRollupColumn({
  parentTable,
  baseTitle,
  relationColumn,
  targetColumn,
  rollupFunction,
}) {
  const { title, column_name } = chooseUniqueColumnName(
    parentTable,
    baseTitle,
    '(rollup)'
  );

  const func = rollupFunction || 'count';

  const body = {
    title,
    column_name,
    uidt: 'Rollup',
    parentId: parentTable.id,
    colOptions: {
      fk_relation_column_id: relationColumn.id,
      fk_rollup_column_id: targetColumn.id,
      rollup_function: func,
    },
  };

  try {
    const url = `/api/v2/meta/tables/${parentTable.id}/columns`;
    const res = await http.post(url, body);
    const col = res.data;
    logInfo(
      `  Created Rollup "${col.title}" on "${parentTable.title}" using "${func}" from "${targetColumn.title}".`
    );
    return col;
  } catch (err) {
    logError(
      `  Failed to create Rollup "${baseTitle}" on "${parentTable.title}": ${
        err.response && JSON.stringify(err.response.data)
      }`
    );
    return null;
  }
}

// Create a Formula column on parentTable, with a safe fallback when NocoDB rejects the expression
async function createFormulaColumn({ parentTable, baseTitle, formula }) {
  if (!formula) {
    logWarn(
      `  Formula field "${baseTitle}" on "${parentTable.title}" has no options.formula; skipping.`
    );
    return null;
  }

  // First attempt: real Formula column
  const { title, column_name } = chooseUniqueColumnName(
    parentTable,
    baseTitle,
    '(formula)'
  );

  const body = {
    parentId: parentTable.id,
    title,
    column_name,
    uidt: 'Formula',
    formula, // NocoDB will try to parse this
  };

  const url = `/api/v2/meta/tables/${parentTable.id}/columns`;

  try {
    const res = await http.post(url, body);
    const col = res.data;
    logInfo(
      `  Created Formula "${col.title}" on "${parentTable.title}" with expression: ${formula}`
    );
    return col;
  } catch (err) {
    const msg = err.response ? JSON.stringify(err.response.data) : err.message;
    logWarn(
      `  NocoDB rejected Formula "${baseTitle}" on "${parentTable.title}" (expression "${formula}"): ${msg}`
    );
    logWarn(
      `  Creating a LongText "_formula_src" column instead so the Airtable expression is preserved.`
    );

    // Fallback: create a LongText column that just stores the expression string
    const fallbackNameBase = `${baseTitle}_formula_src`;
    const { title: fbTitle, column_name: fbColName } = chooseUniqueColumnName(
      parentTable,
      fallbackNameBase,
      ''
    );

    const fbBody = {
      parentId: parentTable.id,
      title: fbTitle,
      column_name: fbColName,
      uidt: 'LongText',
      // there is no "defaultExpression" concept here,
      // but we can set a default value if we want to hint the expression
      colOptions: {
        default: formula,
      },
    };

    try {
      const fbRes = await http.post(url, fbBody);
      const fbCol = fbRes.data;
      logInfo(
        `  Created LongText column "${fbCol.title}" on "${parentTable.title}" holding original formula expression.`
      );
      return fbCol;
    } catch (fbErr) {
      logError(
        `  Failed to create fallback "_formula_src" column for "${baseTitle}" on "${parentTable.title}": ${
          fbErr.response ? JSON.stringify(fbErr.response.data) : fbErr.message
        }`
      );
      return null;
    }
  }
}


// ---------- PER-FIELD HANDLERS ----------

// Ensure link column exists for a given Airtable multipleRecordLinks field
async function ensureLinkForAirtableField({
  atTable,
  atField,
  airtableMaps,
  nocoMeta,
}) {
  const options = atField.options || {};
  const linkedTableId = options.linkedTableId;

  if (!linkedTableId) {
    logWarn(
      `  Linked-record field "${atField.name}" in "${atTable.name}" has no options.linkedTableId; skipping.`
    );
    return null;
  }

  // Avoid creating duplicate links for reversed fields.
  if (options.isReversed) {
    logInfo(
      `  Skipping reversed link field "${atField.name}" in "${atTable.name}" (options.isReversed=true).`
    );
    return null;
  }

  const targetAtTable = airtableMaps.tablesById[linkedTableId];
  if (!targetAtTable) {
    logWarn(
      `  Linked-record field "${atField.name}" in "${atTable.name}" references unknown tableId=${linkedTableId}; skipping.`
    );
    return null;
  }

  const parentNoco = findNocoTableForAirtableTable(atTable, nocoMeta);
  const childNoco = findNocoTableForAirtableTable(targetAtTable, nocoMeta);

  if (!parentNoco) {
    logWarn(
      `  No matching Noco table for Airtable table "${atTable.name}" (for link field "${atField.name}"); skipping.`
    );
    return null;
  }
  if (!childNoco) {
    logWarn(
      `  No matching Noco table for linked Airtable table "${targetAtTable.name}" (for field "${atField.name}"); skipping.`
    );
    return null;
  }

  return await createLinkColumn({
    parentTable: parentNoco,
    childTable: childNoco,
    baseTitle: atField.name,
  });
}

// Handle multipleLookupValues / lookup
async function handleLookupField({
  atTable,
  atField,
  airtableMaps,
  nocoMeta,
}) {
  const options = atField.options || {};
  const recordLinkFieldId = options.recordLinkFieldId;
  const fieldIdInLinkedTable = options.fieldIdInLinkedTable;

  if (!recordLinkFieldId || !fieldIdInLinkedTable) {
    logWarn(
      `  Lookup field "${atField.name}" in "${atTable.name}" missing recordLinkFieldId or fieldIdInLinkedTable; skipping.`
    );
    return;
  }

  const linkInfo = airtableMaps.fieldsById[recordLinkFieldId];
  if (!linkInfo) {
    logWarn(
      `  Lookup field "${atField.name}" in "${atTable.name}" refers to unknown link fieldId=${recordLinkFieldId}; skipping.`
    );
    return;
  }

  const linkField = linkInfo.field;
  const linkOptions = linkField.options || {};
  const linkedTableId = linkOptions.linkedTableId;
  if (!linkedTableId) {
    logWarn(
      `  Lookup field "${atField.name}" in "${atTable.name}" refers to link field without linkedTableId; skipping.`
    );
    return;
  }

  const targetAtTable = airtableMaps.tablesById[linkedTableId];
  if (!targetAtTable) {
    logWarn(
      `  Lookup field "${atField.name}" in "${atTable.name}" references unknown tableId=${linkedTableId}; skipping.`
    );
    return;
  }

  // Ensure link column exists first
  const relationCol = await ensureLinkForAirtableField({
    atTable,
    atField: linkField,
    airtableMaps,
    nocoMeta,
  });
  if (!relationCol) {
    logWarn(
      `  Could not create relation column for lookup "${atField.name}" in "${atTable.name}"; skipping lookup creation.`
    );
    return;
  }

  const parentNoco = findNocoTableForAirtableTable(atTable, nocoMeta);
  const targetNoco = findNocoTableForAirtableTable(targetAtTable, nocoMeta);

  if (!parentNoco || !targetNoco) return;

  const targetAtFieldInfo = airtableMaps.fieldsById[fieldIdInLinkedTable];
  if (!targetAtFieldInfo) {
    logWarn(
      `  Lookup field "${atField.name}" in "${atTable.name}" refers to unknown target fieldId=${fieldIdInLinkedTable}; skipping.`
    );
    return;
  }

  const targetFieldName = targetAtFieldInfo.field.name;
  const targetNocoCol = findNocoColumnByNameLike(targetNoco, targetFieldName);
  if (!targetNocoCol) {
    logWarn(
      `  Could not find Noco column for target lookup field "${targetFieldName}" in "${targetNoco.title}" (for lookup "${atField.name}" in "${atTable.name}").`
    );
    return;
  }

  await createLookupColumn({
    parentTable: parentNoco,
    baseTitle: atField.name,
    relationColumn: relationCol,
    targetColumn: targetNocoCol,
  });
}

// Handle rollup
async function handleRollupField({
  atTable,
  atField,
  airtableMaps,
  nocoMeta,
}) {
  const options = atField.options || {};
  const recordLinkFieldId = options.recordLinkFieldId;
  const fieldIdInLinkedTable = options.fieldIdInLinkedTable;

  if (!recordLinkFieldId || !fieldIdInLinkedTable) {
    logWarn(
      `  Rollup field "${atField.name}" in "${atTable.name}" missing recordLinkFieldId or fieldIdInLinkedTable; skipping.`
    );
    return;
  }

  const linkInfo = airtableMaps.fieldsById[recordLinkFieldId];
  if (!linkInfo) {
    logWarn(
      `  Rollup field "${atField.name}" in "${atTable.name}" refers to unknown link fieldId=${recordLinkFieldId}; skipping.`
    );
    return;
  }

  const linkField = linkInfo.field;
  const linkOptions = linkField.options || {};
  const linkedTableId = linkOptions.linkedTableId;
  if (!linkedTableId) {
    logWarn(
      `  Rollup field "${atField.name}" in "${atTable.name}" refers to link field without linkedTableId; skipping.`
    );
    return;
  }

  const targetAtTable = airtableMaps.tablesById[linkedTableId];
  if (!targetAtTable) {
    logWarn(
      `  Rollup field "${atField.name}" in "${atTable.name}" references unknown tableId=${linkedTableId}; skipping.`
    );
    return;
  }

  // Ensure link column exists
  const relationCol = await ensureLinkForAirtableField({
    atTable,
    atField: linkField,
    airtableMaps,
    nocoMeta,
  });
  if (!relationCol) {
    logWarn(
      `  Could not create relation column for rollup "${atField.name}" in "${atTable.name}"; skipping rollup creation.`
    );
    return;
  }

  const parentNoco = findNocoTableForAirtableTable(atTable, nocoMeta);
  const targetNoco = findNocoTableForAirtableTable(targetAtTable, nocoMeta);

  if (!parentNoco || !targetNoco) return;

  const targetAtFieldInfo = airtableMaps.fieldsById[fieldIdInLinkedTable];
  if (!targetAtFieldInfo) {
    logWarn(
      `  Rollup field "${atField.name}" in "${atTable.name}" refers to unknown target fieldId=${fieldIdInLinkedTable}; skipping.`
    );
    return;
  }

  const targetFieldName = targetAtFieldInfo.field.name;
  const targetNocoCol = findNocoColumnByNameLike(targetNoco, targetFieldName);
  if (!targetNocoCol) {
    logWarn(
      `  Could not find Noco column for target rollup field "${targetFieldName}" in "${targetNoco.title}" (for rollup "${atField.name}" in "${atTable.name}").`
    );
    return;
  }

  const rollupFn = inferRollupFunctionFromResult(atField);
  await createRollupColumn({
    parentTable: parentNoco,
    baseTitle: atField.name,
    relationColumn: relationCol,
    targetColumn: targetNocoCol,
    rollupFunction: rollupFn,
  });
}

// Handle formula
async function handleFormulaField({ atTable, atField, nocoMeta }) {
  const options = atField.options || {};
  const formula = options.formula;

  const parentNoco = findNocoTableForAirtableTable(atTable, nocoMeta);
  if (!parentNoco) {
    logWarn(
      `  No matching Noco table for Airtable table "${atTable.name}" (for formula field "${atField.name}"); skipping.`
    );
    return;
  }

  await createFormulaColumn({
    parentTable: parentNoco,
    baseTitle: atField.name,
    formula,
  });
}

// ---------- MAIN ----------

async function main() {
  try {
    logInfo(`Base URL : ${NOCO_BASE_URL}`);
    logInfo(`Base ID  : ${NOCO_BASE_ID}`);
    logInfo(`Schema   : ${SCHEMA_PATH}`);

    const airTables = loadAirtableSchema();
    const airtableMaps = buildAirtableMaps(airTables);

    const nocoMeta = await fetchNocoTables();
    logInfo(
      `NocoDB tables in base: ${nocoMeta.list
        .map((t) => t.title)
        .join(', ')}`
    );

    for (const atTable of airTables) {
      logInfo(`Processing table "${atTable.name}" (${atTable.id})...`);

      for (const atField of atTable.fields || []) {
        const type = atField.type;

        if (type === 'multipleRecordLinks') {
          await ensureLinkForAirtableField({
            atTable,
            atField,
            airtableMaps,
            nocoMeta,
          });
          continue;
        }

        if (type === 'multipleLookupValues' || type === 'lookup') {
          await handleLookupField({
            atTable,
            atField,
            airtableMaps,
            nocoMeta,
          });
          continue;
        }

        if (type === 'rollup') {
          await handleRollupField({
            atTable,
            atField,
            airtableMaps,
            nocoMeta,
          });
          continue;
        }

        if (type === 'formula') {
          await handleFormulaField({ atTable, atField, nocoMeta });
          continue;
        }
      }
    }

    logInfo('Done creating relations, lookups, rollups, and formulas.');
  } catch (err) {
    logError(
      `Fatal error in create_nocodb_relations_and_rollups: ${
        err.stack || err.message || err
      }`
    );
    process.exit(1);
  }
}

main();
