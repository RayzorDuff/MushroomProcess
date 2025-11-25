#!/usr/bin/env node
/**
 * create_nocodb_relations_and_rollups.js
 *
 * Reads Airtable export schema (export/_schema.json) and creates:
 *   - LinkToAnotherRecord columns for multipleRecordLinks
 *   - Lookup columns for multipleLookupValues / lookup
 *   - Rollup columns for rollup
 *   - Formula columns for formula (with Airtable→Noco-ish translation)
 *
 * IMPORTANT:
 *   - This script will try to delete placeholder LongText columns created
 *     in the first pass if they share the same title as an Airtable
 *     linked-record field, so that the new relation can take the original name.
 *
 * Env vars:
 *   NOCODB_URL        base URL to NocoDB (e.g. http://localhost:8080)
 *   NOCODB_BASE_ID    base ID in NocoDB
 *   NOCODB_API_TOKEN  API token with meta permissions
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
  process.env.SCHEMA_PATH ||
  path.join(__dirname, 'export', '_schema.json');

if (!NOCO_BASE_URL || !NOCO_BASE_ID || !NOCO_API_TOKEN) {
  console.error(
    '[ERROR] NOCODB_URL, NOCODB_BASE_ID, and NOCODB_API_TOKEN must be set as environment variables.'
  );
  process.exit(1);
}

console.log(`[INFO] Base URL : ${NOCO_BASE_URL}`);
console.log(`[INFO] Base ID  : ${NOCO_BASE_ID}`);
console.log(`[INFO] Schema   : ${SCHEMA_PATH}`);

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
  const schema = JSON.parse(raw);
  return schema;
}

function buildAirtableMaps(schema) {
  const tablesById = {};
  const tablesByName = {};
  const fieldsById = {};

  for (const table of schema.tables || []) {
    tablesById[table.id] = table;
    tablesByName[table.name] = table;

    for (const field of table.fields || []) {
      fieldsById[field.id] = field;
    }
  }

  return { tablesById, tablesByName, fieldsById };
}

// ---------- NOCO META HELPERS ----------

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
    if (t.table_name && normalizeName(t.table_name).includes(normTitle)) {
      return t;
    }
  }

  return null;
}

// Find a Noco column by title
function findNocoColumnByTitle(nocoTable, colTitle) {
  if (!nocoTable || !nocoTable.columns) return null;
  const norm = normalizeName(colTitle);
  for (const c of nocoTable.columns) {
    if (normalizeName(c.title) === norm) return c;
  }
  return null;
}

// Find a Noco column by column_name
function findNocoColumnByName(nocoTable, colName) {
  if (!nocoTable || !nocoTable.columns) return null;
  const norm = normalizeName(colName);
  for (const c of nocoTable.columns) {
    if (normalizeName(c.column_name) === norm) return c;
  }
  return null;
}

function isLinkToAnotherRecord(col) {
  return col && col.uidt === 'LinkToAnotherRecord';
}

// Try to find an existing link column on parentTable that already points to childId
function findExistingLinkColumn(parentTable, childId) {
  if (!parentTable || !parentTable.columns) return null;
  for (const col of parentTable.columns) {
    if (col.uidt === 'LinkToAnotherRecord') {
      try {
        const opt = col.colOptions || {};
        if (opt.fk_related_model_id === childId || opt.related_table_id === childId) {
          return col;
        }
      } catch {
        // ignore parse errors
      }
    }
  }
  return null;
}

// ---------- COLUMN CREATION HELPERS ----------

// Choose a unique title / column_name for new column
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
  let nameCandidate = name;

  let i = 1;
  while (existingTitles.has(titleCandidate) || existingNames.has(nameCandidate)) {
    titleCandidate = `${baseTitleWithHint} ${++i}`;
    nameCandidate = `${name}_${i}`;
  }

  return { title: titleCandidate, column_name: nameCandidate };
}

/**
 * Best-effort Airtable → Noco-ish formula transformation.
 *
 * Goal: avoid hard Noco errors like "Function DATETIME_FORMAT is not available"
 * and "Primary key not found" while keeping something logically similar.
 *
 * We do NOT try to be perfectly faithful to Airtable; this is a migration.
 */
function transformAirtableFormulaToNoco(original) {
  if (!original) return original;

  let f = String(original);

  // Flatten newlines & extra indentation – Noco formula parser is picky.
  f = f.replace(/\r?\n\s*/g, ' ');

  // If the formula is just an Airtable view/public link with RECORD_ID(),
  // it is meaningless in Noco. Replace with a simple constant string.
  if (/airtable\.com/i.test(f) && /RECORD_ID\s*\(\s*\)/i.test(f)) {
    return '"Migrated from Airtable (link not preserved)"';
  }

  // SET_TIMEZONE(expr, "America/Denver") → expr
  f = f.replace(
    /SET_TIMEZONE\s*\(\s*([^,]+)\s*,\s*("[^"]*"|'[^']*')\s*\)/gi,
    '$1'
  );

  // DATETIME_FORMAT(expr, "pattern") or DATETIME_FORMAT(expr, 'pattern') → expr
  f = f.replace(
    /DATETIME_FORMAT\s*\(\s*([^,]+)\s*,\s*("[^"]*"|'[^']*')\s*\)/gi,
    '$1'
  );

  // CREATED_TIME() → NOW()
  f = f.replace(/CREATED_TIME\s*\(\s*\)/gi, 'NOW()');

  // TRUE() / FALSE() → TRUE / FALSE (simplify)
  f = f.replace(/\bTRUE\s*\(\s*\)/gi, 'TRUE');
  f = f.replace(/\bFALSE\s*\(\s*\)/gi, 'FALSE');

  // RECORD_ID() is Airtable-specific; remove it so Noco doesn't throw
  // "Primary key not found".
  f = f.replace(/RECORD_ID\s*\(\s*\)/gi, '""');

  // Small cleanup: multiple spaces → single
  f = f.replace(/\s+/g, ' ').trim();

  return f;
}

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
   * For NocoDB v2 meta API (0.263.x), relation creation via /meta/tables/{tableId}/columns
   * works if we send:
   *   - parentId: parent table id
   *   - childId:  related (target) table id
   *   - type:    'relation'
   *   - uidt:    'LinkToAnotherRecord'
   *   - meta:    JSON-encoded relation_type + related_table_id
   */
  const relationMeta = {
    relation_type: 'mm', // many-to-many by default
    related_table_id: childTable.id,
  };

  const body = {
    parentId: parentTable.id,
    childId: childTable.id,
    type: 'relation',
    title,
    column_name,
    uidt: 'LinkToAnotherRecord',
    meta: JSON.stringify(relationMeta),
  };

  try {
    const url = `/api/v2/meta/tables/${parentTable.id}/columns`;
    const res = await http.post(url, body);
    const col = res.data;
    // add into in-memory meta so later lookups see it
    parentTable.columns = parentTable.columns || [];
    parentTable.columns.push(col);

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
    parentTable.columns = parentTable.columns || [];
    parentTable.columns.push(col);

    logInfo(
      `  Created Lookup "${col.title}" on "${parentTable.title}" from relation "${relationColumn.title}" -> "${targetColumn.title}".`
    );
    return col;
  } catch (err) {
    logError(
      `  Failed to create Lookup "${baseTitle}" on "${parentTable.title}" from relation "${relationColumn.title}" -> "${targetColumn.title}": ${
        err.response ? JSON.stringify(err.response.data) : err.message
      }`
    );
    return null;
  }
}

// Create a Rollup column on parentTable
async function createRollupColumn({
  parentTable,
  baseTitle,
  relationColumn,
  targetColumn,
  aggFunction,
}) {
  const { title, column_name } = chooseUniqueColumnName(
    parentTable,
    baseTitle,
    '(rollup)'
  );

  const body = {
    title,
    column_name,
    uidt: 'Rollup',
    parentId: parentTable.id,
    colOptions: {
      fk_relation_column_id: relationColumn.id,
      fk_rollup_column_id: targetColumn.id,
      rollup_function: aggFunction || 'sum',
    },
  };

  try {
    const url = `/api/v2/meta/tables/${parentTable.id}/columns`;
    const res = await http.post(url, body);
    const col = res.data;
    parentTable.columns = parentTable.columns || [];
    parentTable.columns.push(col);

    logInfo(
      `  Created Rollup "${col.title}" on "${parentTable.title}" using "${aggFunction}" from "${targetColumn.title}".`
    );
    return col;
  } catch (err) {
    logError(
      `  Failed to create Rollup "${baseTitle}" on "${parentTable.title}" from relation "${relationColumn.title}" -> "${targetColumn.title}": ${
        err.response ? JSON.stringify(err.response.data) : err.message
      }`
    );
    return null;
  }
}

// Create a Formula column (with fallback LongText preservation)
async function createFormulaColumn({
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

  const finalFormula = formula;
  const preserved = originalFormula || formula;

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
    formula: finalFormula,
  };

  const url = `/api/v2/meta/tables/${parentTable.id}/columns`;

  try {
    const res = await http.post(url, body);
    const col = res.data;
    parentTable.columns = parentTable.columns || [];
    parentTable.columns.push(col);

    logInfo(
      `  Created Formula "${col.title}" on "${parentTable.title}" with expression: ${finalFormula}`
    );
    return col;
  } catch (err) {
    const msg = err.response ? JSON.stringify(err.response.data) : err.message;
    logWarn(
      `  NocoDB rejected Formula "${baseTitle}" on "${parentTable.title}" (expression "${finalFormula}"): ${msg}`
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
      colOptions: {
        default: preserved,
      },
    };

    try {
      const fbRes = await http.post(url, fbBody);
      const fbCol = fbRes.data;
      parentTable.columns = parentTable.columns || [];
      parentTable.columns.push(fbCol);

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

// Ensure link column exists for a given Airtable multipleRecordLinks field,
// and try to remove the LongText placeholder created in pass 1.
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
      `  No matching Noco table for Airtable table "${targetAtTable.name}" (for link field "${atField.name}"); skipping.`
    );
    return null;
  }

  // If a placeholder column with the same title exists and is NOT a link,
  // try to delete it so the new LinkToAnotherRecord can take its place.
  const existingSameTitle = findNocoColumnByTitle(parentNoco, atField.name);
  if (existingSameTitle && !isLinkToAnotherRecord(existingSameTitle)) {
    try {
      const delUrl = `/api/v2/meta/tables/${parentNoco.id}/columns/${existingSameTitle.id}`;
      await http.delete(delUrl);
      // remove from in-memory meta
      parentNoco.columns = (parentNoco.columns || []).filter(
        (c) => c.id !== existingSameTitle.id
      );
      logInfo(
        `  Deleted placeholder column "${existingSameTitle.title}" on "${parentNoco.title}" before creating relation.`
      );
    } catch (err) {
      logWarn(
        `  Could not delete placeholder column "${existingSameTitle.title}" on "${parentNoco.title}"; relation column will be created with a suffix. Reason: ${
          err.response ? JSON.stringify(err.response.data) : err.message
        }`
      );
    }
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
  const relationship = options.relationship;
  const targetFieldId = options.fieldIdInLinkedTable || options.recordLinkFieldId;
  const lookupFieldId = options.fieldIdInPrimaryTable || options.fieldId;

  if (!relationship || !targetFieldId || !lookupFieldId) {
    logWarn(
      `  Lookup field "${atField.name}" in "${atTable.name}" missing relationship/fieldId; skipping.`
    );
    return;
  }

  const linkField = airtableMaps.fieldsById[relationship];
  if (!linkField) {
    logWarn(
      `  Lookup field "${atField.name}" in "${atTable.name}" references missing link fieldId=${relationship}; skipping.`
    );
    return;
  }

  const linkCol = await ensureLinkForAirtableField({
    atTable,
    atField: linkField,
    airtableMaps,
    nocoMeta,
  });

  if (!linkCol) {
    logWarn(
      `  Could not create relation column for lookup "${atField.name}" in "${atTable.name}"; skipping lookup creation.`
    );
    return;
  }

  const parentNoco = findNocoTableForAirtableTable(atTable, nocoMeta);
  const targetAtTable = airtableMaps.tablesById[linkField.options.linkedTableId];
  const targetNoco = findNocoTableForAirtableTable(targetAtTable, nocoMeta);

  if (!targetNoco) {
    logWarn(
      `  Could not find target Noco table for lookup "${atField.name}" in "${atTable.name}"; skipping.`
    );
    return;
  }

  const targetAtField = airtableMaps.fieldsById[lookupFieldId];
  if (!targetAtField) {
    logWarn(
      `  Lookup field "${atField.name}" in "${atTable.name}" references missing lookup fieldId=${lookupFieldId}; skipping.`
    );
    return;
  }

  const targetCol =
    findNocoColumnByTitle(targetNoco, targetAtField.name) ||
    findNocoColumnByName(targetNoco, targetAtField.name);

  if (!targetCol) {
    logWarn(
      `  Could not map lookup target field "${targetAtField.name}" in "${targetAtTable.name}" to a Noco column; skipping.`
    );
    return;
  }

  await createLookupColumn({
    parentTable: parentNoco,
    baseTitle: atField.name,
    relationColumn: linkCol,
    targetColumn: targetCol,
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
  const relationship = options.relationship;
  const targetFieldId = options.fieldId;
  const aggFunction = options.function || 'sum';

  if (!relationship || !targetFieldId) {
    logWarn(
      `  Rollup field "${atField.name}" in "${atTable.name}" missing relationship/fieldId; skipping.`
    );
    return;
  }

  const linkField = airtableMaps.fieldsById[relationship];
  if (!linkField) {
    logWarn(
      `  Rollup field "${atField.name}" in "${atTable.name}" references missing link fieldId=${relationship}; skipping.`
    );
    return;
  }

  const linkCol = await ensureLinkForAirtableField({
    atTable,
    atField: linkField,
    airtableMaps,
    nocoMeta,
  });

  if (!linkCol) {
    logWarn(
      `  Could not create relation column for rollup "${atField.name}" in "${atTable.name}"; skipping rollup creation.`
    );
    return;
  }

  const parentNoco = findNocoTableForAirtableTable(atTable, nocoMeta);
  const targetAtTable = airtableMaps.tablesById[linkField.options.linkedTableId];
  const targetNoco = findNocoTableForAirtableTable(targetAtTable, nocoMeta);

  if (!targetNoco) {
    logWarn(
      `  Could not find target Noco table for rollup "${atField.name}" in "${atTable.name}"; skipping.`
    );
    return;
  }

  const targetAtField = airtableMaps.fieldsById[targetFieldId];
  if (!targetAtField) {
    logWarn(
      `  Rollup field "${atField.name}" in "${atTable.name}" references missing target fieldId=${targetFieldId}; skipping.`
    );
    return;
  }

  const targetCol =
    findNocoColumnByTitle(targetNoco, targetAtField.name) ||
    findNocoColumnByName(targetNoco, targetAtField.name);

  if (!targetCol) {
    logWarn(
      `  Could not map rollup target field "${targetAtField.name}" in "${targetAtTable.name}" to a Noco column; skipping.`
    );
    return;
  }

  await createRollupColumn({
    parentTable: parentNoco,
    baseTitle: atField.name,
    relationColumn: linkCol,
    targetColumn: targetCol,
    aggFunction,
  });
}

// Handle formula (with transform)
async function handleFormulaField({
  atTable,
  atField,
  airtableMaps,
  nocoMeta,
}) {
  const options = atField.options || {};
  const rawFormula = options.formula;

  const parentNoco = findNocoTableForAirtableTable(atTable, nocoMeta);
  if (!parentNoco) {
    logWarn(
      `  No matching Noco table for Airtable table "${atTable.name}" (for formula field "${atField.name}"); skipping.`
    );
    return;
  }

  const transformed = transformAirtableFormulaToNoco(rawFormula);

  await createFormulaColumn({
    parentTable: parentNoco,
    baseTitle: atField.name,
    formula: transformed,
    originalFormula: rawFormula,
  });
}

// ---------- MAIN PER-TABLE LOOP ----------

async function processTable(atTable, airtableMaps, nocoMeta) {
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
    } else if (
      type === 'multipleLookupValues' ||
      type === 'lookup'
    ) {
      await handleLookupField({
        atTable,
        atField,
        airtableMaps,
        nocoMeta,
      });
    } else if (type === 'rollup') {
      await handleRollupField({
        atTable,
        atField,
        airtableMaps,
        nocoMeta,
      });
    } else if (type === 'formula') {
      await handleFormulaField({
        atTable,
        atField,
        airtableMaps,
        nocoMeta,
      });
    }
  }
}

// ---------- MAIN ----------

async function main() {
  try {
    const schema = loadAirtableSchema();
    const airtableMaps = buildAirtableMaps(schema);

    const nocoMeta = await fetchNocoTables();
    logInfo(
      `NocoDB tables in base: ${nocoMeta.list
        .map((t) => t.title)
        .join(', ')}`
    );

    for (const atTable of schema.tables || []) {
      await processTable(atTable, airtableMaps, nocoMeta);
    }

    logInfo('Done creating relations, lookups, rollups, and formulas.');
  } catch (err) {
    logError(
      `Fatal error in create_nocodb_relations_and_rollups: ${
        err.stack || err.message
      }`
    );
    process.exit(1);
  }
}

main().catch((err) => {
  logError(
    `Unhandled error in create_nocodb_relations_and_rollups: ${
      err.stack || err.message
    }`
  );
  process.exit(1);
});
