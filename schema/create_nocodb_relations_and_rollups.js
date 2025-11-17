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
 * MODE: Aggressive
 *   - If an existing non-link column has the same name as an Airtable link field:
 *       1) Rename it to "<name>_legacy"
 *       2) Create a new, correct LinkToAnotherRecord column with the original name
 *   - If rename fails, create the relation with a suffixed name (e.g. "lots (link) 2").
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
const NOCO_API_TOKEN =
  process.env.NOCODB_API_TOKEN || process.env.NOCO_API_TOKEN;

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

// ---------- NocoDB META HELPERS ----------

async function fetchNocoTables() {
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
  for (const t of list) {
    tablesById[t.id] = t;
    if (t.title) tablesByTitle[t.title] = t;
  }

  return { list, tablesById, tablesByTitle };
}

async function fetchNocoTableMeta(tableId) {
  const url = `/api/v2/meta/tables/${tableId}`;
  const res = await http.get(url);
  return res.data;
}

async function patchNocoColumn(tableId, columnId, body) {
  const url = `/api/v2/meta/tables/${tableId}/columns/${columnId}`;
  const res = await http.patch(url, body);
  return res.data;
}

async function createNocoColumn(tableId, body) {
  const url = `/api/v2/meta/tables/${tableId}/columns`;
  const res = await http.post(url, body);
  return res.data;
}

// ---------- UTILS ----------

function normalizeName(s) {
  return (s || '').trim().toLowerCase();
}

function sanitizeColumnName(s) {
  return (
    (s || '')
      .normalize('NFKD')
      .replace(/[^\w]+/g, '_')
      .replace(/^_+|_+$/g, '')
      .toLowerCase() || 'col'
  );
}

function chooseUniqueColumnName(nocoTableColumns, baseTitle) {
  const existingTitles = new Set((nocoTableColumns || []).map((c) => c.title));
  const existingNames = new Set(
    (nocoTableColumns || []).map((c) => c.column_name)
  );

  let title = baseTitle;
  let name = sanitizeColumnName(baseTitle);

  let t = title;
  let n = name;
  let i = 1;
  while (existingTitles.has(t) || existingNames.has(n)) {
    t = `${title} ${i + 1}`;
    n = `${name}_${i}`;
    i++;
  }

  return { title: t, column_name: n };
}

function findNocoTableForAirtableTable(atTable, nocoMeta) {
  const normTitle = normalizeName(atTable.name);

  for (const [k, t] of Object.entries(nocoMeta.tablesByTitle)) {
    if (normalizeName(k) === normTitle) return t;
  }

  for (const t of nocoMeta.list) {
    if (normalizeName(t.title) === normTitle) return t;
  }

  return null;
}

function findNocoColumnByNameLike(nocoTableMeta, fieldName) {
  const norm = normalizeName(fieldName);
  const cols = nocoTableMeta.columns || [];
  for (const c of cols) {
    const t = normalizeName(c.title);
    const n = normalizeName(c.column_name || '');
    if (t === norm || n === norm) return c;
  }
  return null;
}

// find existing link column between parent & child (already relation)
function findExistingLinkColumn(nocoTableMeta, childTableId) {
  const cols = nocoTableMeta.columns || [];
  for (const c of cols) {
    if (c.uidt !== 'LinkToAnotherRecord' && c.uidt !== 'Links') continue;
    let meta = {};
    if (typeof c.meta === 'string') {
      try {
        meta = JSON.parse(c.meta);
      } catch (_) {}
    } else if (c.meta && typeof c.meta === 'object') {
      meta = c.meta;
    }

    if (meta.related_table_id === childTableId) return c;
    if (c.childId && c.childId === childTableId) return c;
    const colOptions = c.colOptions || {};
    if (colOptions.fk_related_model_id === childTableId) return c;
  }
  return null;
}

// ---------- ROLLUP UTILS ----------

function inferRollupFunctionFromResult(atRollupField) {
  const result = atRollupField.options && atRollupField.options.result;
  const resultType = result && result.type;
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

// ---------- RELATION CREATION (AGGRESSIVE) ----------

// Create a LinkToAnotherRecord relation column on parentTableMeta → childTable
// Aggressive behavior:
//   - If existing non-link column with same name exists, rename to "<name>_legacy"
//   - Then create relation with original name
//   - If rename fails, create relation with unique suffixed name
async function ensureRelationColumn({
  parentAtTable,
  linkAtField,
  parentNoco,
  childNoco,
}) {
  const parentTableId = parentNoco.id;
  const parentMeta = await fetchNocoTableMeta(parentTableId);
  const cols = parentMeta.columns || [];
  const baseName = linkAtField.name;

  // 1) If a relation already exists between parent & child, reuse it
  const existingRelation = findExistingLinkColumn(parentMeta, childNoco.id);
  if (existingRelation) {
    logInfo(
      `  Reusing existing relation column "${existingRelation.title}" on "${parentNoco.title}" -> "${childNoco.title}".`
    );
    return existingRelation;
  }

  // 2) See if a column already exists with the same name (likely LongText)
  const sameNameCol = cols.find((c) => {
    const t = normalizeName(c.title);
    const n = normalizeName(c.column_name || '');
    const target = normalizeName(baseName);
    return t === target || n === target;
  });

  let newTitle = baseName;
  let newName = sanitizeColumnName(baseName);
  let columnsForNaming = cols;

  // If a non-link column with that name exists, try to rename it to *_legacy
  if (sameNameCol && sameNameCol.uidt !== 'LinkToAnotherRecord') {
    const legacyTitle = `${baseName}_legacy`;
    const legacyName = sanitizeColumnName(legacyTitle);

    try {
      await patchNocoColumn(parentTableId, sameNameCol.id, {
        title: legacyTitle,
        column_name: legacyName,
      });
      logInfo(
        `  Renamed existing column "${baseName}" on "${parentNoco.title}" to "${legacyTitle}" (aggressive mode).`
      );
      // Refresh meta to reflect rename so name is free
      const refreshed = await fetchNocoTableMeta(parentTableId);
      columnsForNaming = refreshed.columns || [];
    } catch (err) {
      logWarn(
        `  Could not rename existing column "${baseName}" to "${legacyName}" on "${parentNoco.title}": ${
          err.response ? JSON.stringify(err.response.data) : err.message
        }. Will create relation with a suffixed name.`
      );
      // We cannot free the name; pick a unique suffixed one
      const { title, column_name } = chooseUniqueColumnName(
        columnsForNaming,
        `${baseName} (link)`
      );
      newTitle = title;
      newName = column_name;
    }
  } else if (sameNameCol && sameNameCol.uidt === 'LinkToAnotherRecord') {
    // It is already a link, just reuse
    logInfo(
      `  Column "${baseName}" on "${parentNoco.title}" is already LinkToAnotherRecord; reusing.`
    );
    return sameNameCol;
  }

  // 3) Create the relation column with the decided name
  const relationMeta = {
    relation_type: 'mm', // treat as many-to-many for now
    related_table_id: childNoco.id,
  };

  const body = {
    parentId: parentTableId,
    childId: childNoco.id,
    type: 'relation',
    title: newTitle,
    column_name: newName,
    uidt: 'LinkToAnotherRecord',
    meta: JSON.stringify(relationMeta),
  };

  try {
    const created = await createNocoColumn(parentTableId, body);
    logInfo(
      `  Created LinkToAnotherRecord column "${created.title}" on "${parentNoco.title}" -> "${childNoco.title}".`
    );
    return created;
  } catch (err) {
    logError(
      `  Failed to create LinkToAnotherRecord "${newTitle}" on "${parentNoco.title}" -> "${childNoco.title}": ${
        err.response ? JSON.stringify(err.response.data) : err.message
      }`
    );
    return null;
  }
}

// ---------- LOOKUP / ROLLUP / FORMULA CREATION ----------

async function createLookupColumn({
  parentNoco,
  baseTitle,
  relationColumn,
  targetColumn,
}) {
  const parentMeta = await fetchNocoTableMeta(parentNoco.id);
  const cols = parentMeta.columns || [];

  const { title, column_name } = chooseUniqueColumnName(
    cols,
    baseTitle + ' (lookup)'
  );

  const body = {
    parentId: parentNoco.id,
    title,
    column_name,
    uidt: 'Lookup',
    colOptions: {
      fk_relation_column_id: relationColumn.id,
      fk_lookup_column_id: targetColumn.id,
    },
  };

  try {
    const created = await createNocoColumn(parentNoco.id, body);
    logInfo(
      `  Created Lookup "${created.title}" on "${parentNoco.title}" from relation "${relationColumn.title}" -> "${targetColumn.title}".`
    );
    return created;
  } catch (err) {
    logError(
      `  Failed to create Lookup "${baseTitle}" on "${parentNoco.title}": ${
        err.response ? JSON.stringify(err.response.data) : err.message
      }`
    );
    return null;
  }
}

async function createRollupColumn({
  parentNoco,
  baseTitle,
  relationColumn,
  targetColumn,
  rollupFunction,
}) {
  const parentMeta = await fetchNocoTableMeta(parentNoco.id);
  const cols = parentMeta.columns || [];

  const { title, column_name } = chooseUniqueColumnName(
    cols,
    baseTitle + ' (rollup)'
  );

  const func = rollupFunction || 'count';

  const body = {
    parentId: parentNoco.id,
    title,
    column_name,
    uidt: 'Rollup',
    colOptions: {
      fk_relation_column_id: relationColumn.id,
      fk_rollup_column_id: targetColumn.id,
      rollup_function: func,
    },
  };

  try {
    const created = await createNocoColumn(parentNoco.id, body);
    logInfo(
      `  Created Rollup "${created.title}" on "${parentNoco.title}" using "${func}" from "${targetColumn.title}".`
    );
    return created;
  } catch (err) {
    logError(
      `  Failed to create Rollup "${baseTitle}" on "${parentNoco.title}": ${
        err.response ? JSON.stringify(err.response.data) : err.message
      }`
    );
    return null;
  }
}

// Formula with fallback if NocoDB rejects Airtable syntax
async function createFormulaColumn({ parentNoco, baseTitle, formula }) {
  if (!formula) {
    logWarn(
      `  Formula field "${baseTitle}" on "${parentNoco.title}" has no options.formula; skipping.`
    );
    return null;
  }

  const parentMeta = await fetchNocoTableMeta(parentNoco.id);
  const cols = parentMeta.columns || [];

  const { title, column_name } = chooseUniqueColumnName(
    cols,
    baseTitle + ' (formula)'
  );

  const url = `/api/v2/meta/tables/${parentNoco.id}/columns`;
  const body = {
    parentId: parentNoco.id,
    title,
    column_name,
    uidt: 'Formula',
    formula,
  };

  try {
    const res = await http.post(url, body);
    const col = res.data;
    logInfo(
      `  Created Formula "${col.title}" on "${parentNoco.title}" with expression: ${formula}`
    );
    return col;
  } catch (err) {
    const msg = err.response ? JSON.stringify(err.response.data) : err.message;
    logWarn(
      `  NocoDB rejected Formula "${baseTitle}" on "${parentNoco.title}" (expression "${formula}"): ${msg}`
    );
    logWarn(
      `  Creating a LongText "_formula_src" column instead so the Airtable expression is preserved.`
    );

    const fbBase = `${baseTitle}_formula_src`;
    const { title: fbTitle, column_name: fbColName } = chooseUniqueColumnName(
      cols,
      fbBase
    );

    const fbBody = {
      parentId: parentNoco.id,
      title: fbTitle,
      column_name: fbColName,
      uidt: 'LongText',
      colOptions: {
        default: formula,
      },
    };

    try {
      const fbRes = await http.post(url, fbBody);
      const fbCol = fbRes.data;
      logInfo(
        `  Created LongText column "${fbCol.title}" on "${parentNoco.title}" holding original formula expression.`
      );
      return fbCol;
    } catch (fbErr) {
      logError(
        `  Failed to create fallback "_formula_src" column for "${baseTitle}" on "${parentNoco.title}": ${
          fbErr.response ? JSON.stringify(fbErr.response.data) : fbErr.message
        }`
      );
      return null;
    }
  }
}

// ---------- PER-FIELD HANDLERS ----------

async function handleLinkField({
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

  // Don't create duplicate links from reversed fields
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
      `  No matching Noco table for Airtable table "${atTable.name}" (for field "${atField.name}"); skipping link.`
    );
    return null;
  }
  if (!childNoco) {
    logWarn(
      `  No matching Noco table for linked Airtable table "${targetAtTable.name}" (for field "${atField.name}"); skipping link.`
    );
    return null;
  }

  return await ensureRelationColumn({
    parentAtTable: atTable,
    linkAtField: atField,
    parentNoco,
    childNoco,
  });
}

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

  // Ensure relation column exists (aggressive mode)
  const relationCol = await handleLinkField({
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
  const targetMeta = await fetchNocoTableMeta(targetNoco.id);
  const targetNocoCol = findNocoColumnByNameLike(targetMeta, targetFieldName);

  if (!targetNocoCol) {
    logWarn(
      `  Could not find Noco column for target lookup field "${targetFieldName}" in "${targetNoco.title}" (for lookup "${atField.name}" in "${atTable.name}").`
    );
    return;
  }

  await createLookupColumn({
    parentNoco,
    baseTitle: atField.name,
    relationColumn: relationCol,
    targetColumn: targetNocoCol,
  });
}

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

  const relationCol = await handleLinkField({
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
  const targetMeta = await fetchNocoTableMeta(targetNoco.id);
  const targetNocoCol = findNocoColumnByNameLike(targetMeta, targetFieldName);

  if (!targetNocoCol) {
    logWarn(
      `  Could not find Noco column for target rollup field "${targetFieldName}" in "${targetNoco.title}" (for rollup "${atField.name}" in "${atTable.name}").`
    );
    return;
  }

  const rollupFn = inferRollupFunctionFromResult(atField);

  await createRollupColumn({
    parentNoco,
    baseTitle: atField.name,
    relationColumn: relationCol,
    targetColumn: targetNocoCol,
    rollupFunction: rollupFn,
  });
}

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
    parentNoco,
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
          await handleLinkField({
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
