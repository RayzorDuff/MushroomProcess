#!/usr/bin/env node
/**
 * create_nocodb_relations_and_rollups.js (v3 meta)
 *
 * Reads Airtable export schema (export/_schema.json) and creates:
 *   - LinkToAnotherRecord fields for multipleRecordLinks
 *   - Lookup fields for multipleLookupValues / lookup
 *   - Rollup fields for rollup
 *   - Formula fields for formula (Airtable -> Noco-ish translation)
 *
 * Behavior:
 *   - For each Airtable link field, this script will:
 *       1) Look for an existing Noco field with the same title.
 *       2) If that field exists and is NOT LinkToAnotherRecord, DELETE it.
 *       3) Create a new LinkToAnotherRecord field with that title (or a
 *          suffixed one if delete fails).
 *   - Formulas are simplified to avoid Airtable-only functions and URLs,
 *     then stored in a v3 Formula field (options.formula).
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

// v3 meta prefix
const META_PREFIX = '/api/v3/meta';
const META_BASE = `${META_PREFIX}/bases/${NOCO_BASE_ID}`;
const META_TABLES = `${META_BASE}/tables`;

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

// ---------- NOCO META HELPERS (v3) ----------

async function fetchNocoTables() {
  const url = `${META_BASE}/tables`;

  try {
    const res = await http.get(url, {
      params: {
        include_fields: true,
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
      // Normalize so we always have t.fields
      t.fields = t.fields || t.columns || [];
      tablesById[t.id] = t;
      tablesByTitle[t.title] = t;
      if (t.table_name) {
        tablesByPhysicalName[t.table_name] = t;
      }
    }

    return { list, tablesById, tablesByTitle, tablesByPhysicalName };
  } catch (err) {
    logError(
      `  Could not GET tables from ${url} ${
        err.response ? JSON.stringify(err.response.data) : err.stack || err.message
      }`
    );
    throw err;
  }
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

  // Fallback: physical table_name containing the title-ish
  for (const t of nocoMeta.list) {
    if (t.table_name && normalizeName(t.table_name).includes(normTitle)) {
      return t;
    }
  }

  return null;
}

// Find a Noco field by title
function findNocoFieldByTitle(nocoTable, fieldTitle) {
  if (!nocoTable || !nocoTable.fields) return null;
  const norm = normalizeName(fieldTitle);
  for (const f of nocoTable.fields) {
    if (normalizeName(f.title) === norm) return f;
  }
  return null;
}

// Find a Noco field by column_name
function findNocoFieldByName(nocoTable, colName) {
  if (!nocoTable || !nocoTable.fields) return null;
  const norm = normalizeName(colName);
  for (const f of nocoTable.fields) {
    if (normalizeName(f.column_name) === norm) return f;
  }
  return null;
}

function isLinkToAnotherRecord(field) {
  return (
    field &&
    (field.type === 'LinkToAnotherRecord' ||
      field.uidt === 'LinkToAnotherRecord')
  );
}

// Try to find an existing link field on parentTable that already points to childId
function findExistingLinkField(parentTable, childId) {
  if (!parentTable || !parentTable.fields) return null;
  for (const field of parentTable.fields) {
    if (
      field.type === 'LinkToAnotherRecord' ||
      field.uidt === 'LinkToAnotherRecord'
    ) {
      const opt = field.options || field.colOptions || {};
      if (
        opt.related_table_id === childId ||
        opt.fk_related_model_id === childId
      ) {
        return field;
      }
    }
  }
  return null;
}

// ---------- FIELD CREATION / DELETE HELPERS ----------

function chooseUniqueFieldName(nocoTable, baseTitle, suffixHint) {
  const existingTitles = new Set(
    (nocoTable.fields || []).map((f) => f.title)
  );
  const existingNames = new Set(
    (nocoTable.fields || []).map((f) => f.column_name)
  );

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

async function deleteField(field, parentTable) {
  try {
    // v3 meta: DELETE /api/v3/meta/bases/{baseId}/fields/{fieldId}
    const url = `${META_BASE}/fields/${field.id}`;
    await http.delete(url);
    if (parentTable && parentTable.fields) {
      parentTable.fields = parentTable.fields.filter((f) => f.id !== field.id);
    }
    logInfo(`  Deleted placeholder field "${field.title}" (id=${field.id}).`);
    return true;
  } catch (err) {
    logWarn(
      `  Could not delete field "${field.title}" (id=${field.id}): ${
        err.response ? JSON.stringify(err.response.data) : err.message
      }`
    );
    return false;
  }
}

// Create a LinkToAnotherRecord field on parentTable → childTable
async function createLinkField({ parentTable, childTable, baseTitle }) {
  // If a relation already exists from this table to child, reuse it
  const already = findExistingLinkField(parentTable, childTable.id);
  if (already) {
    logInfo(
      `  Existing link field "${already.title}" on "${parentTable.title}" -> "${childTable.title}" found; reusing.`
    );
    return already;
  }

  // We prefer to use the Airtable field name as the relation title.
  const { title, column_name } = chooseUniqueFieldName(
    parentTable,
    baseTitle,
    '(link)'
  );

  /**
   * v3 meta relation creation:
   *   POST /api/v3/meta/bases/{baseId}/tables/{tableId}/fields
   * body:
   *   {
   *     type: 'LinkToAnotherRecord',
   *     title,
   *     column_name,
   *     options: {
   *       relation_type: 'mm',       // mm/hm/mh/11
   *       related_table_id: childTable.id
   *     }
   *   }
   */
  const body = {
    type: 'LinkToAnotherRecord',
    title,
    column_name,
    options: {
      relation_type: 'mm', // many-to-many by default; you can tune to hm/mh/11 if desired
      related_table_id: childTable.id,
    },
  };

  try {
    const url = `${META_BASE}/tables/${parentTable.id}/fields`;
    const res = await http.post(url, body);
    const field = res.data;
    parentTable.fields = parentTable.fields || [];
    parentTable.fields.push(field);

    logInfo(
      `  Created LinkToAnotherRecord field "${field.title}" on "${parentTable.title}" -> "${childTable.title}".`
    );
    return field;
  } catch (err) {
    logError(
      `  Failed to create LinkToAnotherRecord "${baseTitle}" on "${parentTable.title}" -> "${childTable.title}": ${
        err.response ? JSON.stringify(err.response.data) : err.message
      }`
    );
    return null;
  }
}

// Create a Lookup field on parentTable
async function createLookupField({
  parentTable,
  baseTitle,
  relationField,
  targetField,
}) {
  const { title, column_name } = chooseUniqueFieldName(
    parentTable,
    baseTitle,
    '(lookup)'
  );

  /**
   * v3 meta lookup creation:
   * type: 'Lookup'
   * options: {
   *   related_field_id: relationField.id,
   *   related_table_lookup_field_id: targetField.id
   * }
   */
  const body = {
    type: 'Lookup',
    title,
    column_name,
    options: {
      related_field_id: relationField.id,
      related_table_lookup_field_id: targetField.id,
    },
  };

  try {
    const url = `${META_BASE}/tables/${parentTable.id}/fields`;
    const res = await http.post(url, body);
    const field = res.data;
    parentTable.fields = parentTable.fields || [];
    parentTable.fields.push(field);

    logInfo(
      `  Created Lookup "${field.title}" on "${parentTable.title}" from relation "${relationField.title}" -> "${targetField.title}".`
    );
    return field;
  } catch (err) {
    logError(
      `  Failed to create Lookup "${baseTitle}" on "${parentTable.title}" from relation "${relationField.title}" -> "${targetField.title}": ${
        err.response ? JSON.stringify(err.response.data) : err.message
      }`
    );
    return null;
  }
}

// Create a Rollup field on parentTable
async function createRollupField({
  parentTable,
  baseTitle,
  relationField,
  targetField,
  aggFunction,
}) {
  const { title, column_name } = chooseUniqueFieldName(
    parentTable,
    baseTitle,
    '(rollup)'
  );

  /**
   * v3 meta rollup creation:
   * type: 'Rollup'
   * options: {
   *   related_field_id: relationField.id,
   *   related_table_rollup_field_id: targetField.id,
   *   rollup_function: 'sum' | 'max' | 'min' | 'count' | 'avg' | ...
   * }
   */
  const body = {
    type: 'Rollup',
    title,
    column_name,
    options: {
      related_field_id: relationField.id,
      related_table_rollup_field_id: targetField.id,
      rollup_function: aggFunction || 'sum',
    },
  };

  try {
    const url = `${META_BASE}/tables/${parentTable.id}/fields`;
    const res = await http.post(url, body);
    const field = res.data;
    parentTable.fields = parentTable.fields || [];
    parentTable.fields.push(field);

    logInfo(
      `  Created Rollup "${field.title}" on "${parentTable.title}" using "${aggFunction}" from "${targetField.title}".`
    );
    return field;
  } catch (err) {
    logError(
      `  Failed to create Rollup "${baseTitle}" on "${parentTable.title}" from relation "${relationField.title}" -> "${targetField.title}": ${
        err.response ? JSON.stringify(err.response.data) : err.message
      }`
    );
    return null;
  }
}

// Shared helper: create a LongText field that stores the original formula
async function createFormulaFallbackField({ parentTable, baseTitle, formula }) {
  const url = `${META_BASE}/tables/${parentTable.id}/fields`;

  const fallbackNameBase = `${baseTitle}_formula_src`;
  const { title: fbTitle, column_name: fbColName } = chooseUniqueFieldName(
    parentTable,
    fallbackNameBase,
    ''
  );

  const fbBody = {
    type: 'LongText',
    title: fbTitle,
    column_name: fbColName,
    options: {
      default_value: formula,
    },
  };

  try {
    const fbRes = await http.post(url, fbBody);
    const fbField = fbRes.data;
    parentTable.fields = parentTable.fields || [];
    parentTable.fields.push(fbField);

    logInfo(
      `  Created LongText field "${fbField.title}" on "${parentTable.title}" holding original formula expression.`
    );
    return fbField;
  } catch (fbErr) {
    logError(
      `  Failed to create fallback "_formula_src" field for "${baseTitle}" on "${parentTable.title}": ${
        fbErr.response ? JSON.stringify(fbErr.response.data) : fbErr.message
      }`
    );
    return null;
  }
}

// Aggressive Airtable -> Noco-ish formula transformation
function transformAirtableFormulaToNoco(original) {
  if (!original) return original;

  let f = String(original);

  // Flatten newlines & indentation
  f = f.replace(/\r?\n\s*/g, ' ');

  // If the formula is just an Airtable public link with RECORD_ID(), it's meaningless in Noco.
  if (/airtable\.com/i.test(f) && /RECORD_ID\s*\(\s*\)/i.test(f)) {
    return '"Migrated from Airtable (link not preserved)"';
  }

  // SET_TIMEZONE(expr, "Zone") -> expr
  f = f.replace(
    /SET_TIMEZONE\s*\(\s*([^,]+)\s*,\s*("[^"]*"|'[^']*')\s*\)/gi,
    '$1'
  );

  // DATETIME_FORMAT(expr, "pattern") or DATETIME_FORMAT(expr, 'pattern') -> expr
  f = f.replace(
    /DATETIME_FORMAT\s*\(\s*([^,]+)\s*,\s*("[^"]*"|'[^']*')\s*\)/gi,
    '$1'
  );

  // DATEADD(date, n, 'unit') -> date (drop offset, keep validity)
  f = f.replace(
    /DATEADD\s*\(\s*([^,]+)\s*,\s*[^,]+,\s*'[^']*'\s*\)/gi,
    '$1'
  );

  // CREATED_TIME() -> NOW()
  f = f.replace(/CREATED_TIME\s*\(\s*\)/gi, 'NOW()');

  // TRUE() / FALSE() -> TRUE / FALSE
  f = f.replace(/\bTRUE\s*\(\s*\)/gi, 'TRUE');
  f = f.replace(/\bFALSE\s*\(\s*\)/gi, 'FALSE');

  // RECORD_ID() -> "" (prevent "Primary key not found")
  f = f.replace(/RECORD_ID\s*\(\s*\)/gi, '""');

  // BLANK() -> ""
  f = f.replace(/\bBLANK\s*\(\s*\)/gi, '""');

  // Cleanup whitespace
  f = f.replace(/\s+/g, ' ').trim();

  return f;
}

// Create a Formula field (with fallback LongText preservation)
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

  const finalFormula = formula;
  const preserved = originalFormula || formula;

  const { title, column_name } = chooseUniqueFieldName(
    parentTable,
    baseTitle,
    '(formula)'
  );

  const body = {
    type: 'Formula',
    title,
    column_name,
    options: {
      formula: finalFormula,
    },
  };

  const url = `${META_BASE}/tables/${parentTable.id}/fields`;

  try {
    const res = await http.post(url, body);
    const field = res.data;
    parentTable.fields = parentTable.fields || [];
    parentTable.fields.push(field);

    logInfo(
      `  Created Formula "${field.title}" on "${parentTable.title}" with expression: ${finalFormula}`
    );
    return field;
  } catch (err) {
    const msg = err.response ? JSON.stringify(err.response.data) : err.message;
    logWarn(
      `  NocoDB rejected Formula "${baseTitle}" on "${parentTable.title}" (expression "${finalFormula}"): ${msg}`
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

// ---------- PER-FIELD HANDLERS ----------

// Ensure link field exists for a given Airtable multipleRecordLinks field,
// and remove LongText placeholders created in the first pass.
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

  // If a placeholder field with the same title exists and is NOT a link,
  // try to delete it so the new LinkToAnotherRecord can take its place.
  const existingSameTitle = findNocoFieldByTitle(parentNoco, atField.name);
  if (existingSameTitle && !isLinkToAnotherRecord(existingSameTitle)) {
    await deleteField(existingSameTitle, parentNoco);
  }

  return await createLinkField({
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
  const targetFieldId =
    options.fieldIdInLinkedTable || options.recordLinkFieldId;
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

  const relationField = await ensureLinkForAirtableField({
    atTable,
    atField: linkField,
    airtableMaps,
    nocoMeta,
  });

  if (!relationField) {
    logWarn(
      `  Could not create relation field for lookup "${atField.name}" in "${atTable.name}"; skipping lookup creation.`
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

  const targetField =
    findNocoFieldByTitle(targetNoco, targetAtField.name) ||
    findNocoFieldByName(targetNoco, targetAtField.name);

  if (!targetField) {
    logWarn(
      `  Could not map lookup target field "${targetAtField.name}" in "${targetAtTable.name}" to a Noco field; skipping.`
    );
    return;
  }

  await createLookupField({
    parentTable: parentNoco,
    baseTitle: atField.name,
    relationField,
    targetField,
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

  const relationField = await ensureLinkForAirtableField({
    atTable,
    atField: linkField,
    airtableMaps,
    nocoMeta,
  });

  if (!relationField) {
    logWarn(
      `  Could not create relation field for rollup "${atField.name}" in "${atTable.name}"; skipping rollup creation.`
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

  const targetField =
    findNocoFieldByTitle(targetNoco, targetAtField.name) ||
    findNocoFieldByName(targetNoco, targetAtField.name);

  if (!targetField) {
    logWarn(
      `  Could not map rollup target field "${targetAtField.name}" in "${targetAtTable.name}" to a Noco field; skipping.`
    );
    return;
  }

  await createRollupField({
    parentTable: parentNoco,
    baseTitle: atField.name,
    relationField,
    targetField,
    aggFunction,
  });
}

// Handle formula
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

  await createFormulaField({
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
    } else if (type === 'multipleLookupValues' || type === 'lookup') {
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
