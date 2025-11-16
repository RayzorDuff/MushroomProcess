#!/usr/bin/env node
/* eslint-disable no-console */

/**
 * create_nocodb_relations_and_rollups.js
 *
 * For MushroomProcess → NocoDB 0.265.1.
 *
 * This script:
 *  - Reads Airtable export/_schema.json
 *  - Connects to a NocoDB base via Meta API v2
 *  - Assumes all tables & "raw" columns already exist
 *  - For Airtable relational / virtual fields:
 *      - multipleRecordLinks / singleRecordLink / foreignKey → LinkToAnotherRecord
 *      - lookup / multipleLookupValues                     → Lookup
 *      - rollup                                           → Rollup
 *      - formula                                          → Formula
 *
 * Behavior for link fields:
 *  - If an existing column shares the Airtable field name:
 *      - Try to PATCH it into a relation (uidt=LinkToAnotherRecord).
 *      - If PATCH fails, RENAME that column to "<name>_legacy" (title & column_name),
 *        then CREATE a new relation column with the original name.
 *  - If no column exists, CREATE the relation column with that name.
 *
 * Environment variables:
 *  - NOCODB_BASE_URL or NOCO_BASE_URL or NOCODB_URL or NOCO_URL
 *      (e.g. http://localhost:8080)
 *  - NOCODB_BASE_ID  or NOCO_BASE_ID  (base id, e.g. p0pcjn52qivlawb)
 *  - NOCODB_API_TOKEN or NOCO_API_TOKEN or NC_TOKEN (API token)
 *  - SCHEMA_PATH (optional, default: ./export/_schema.json)
 */

const fs = require('fs');
const path = require('path');
const axios = require('axios');

// -------------------------------------------------------------
// Config / env
// -------------------------------------------------------------

const BASE_URL =
  process.env.NOCODB_BASE_URL ||
  process.env.NOCO_BASE_URL ||
  process.env.NOCODB_URL ||
  process.env.NOCO_URL ||
  'http://localhost:8080';

const BASE_ID =
  process.env.NOCODB_BASE_ID ||
  process.env.NOCO_BASE_ID;

const API_TOKEN =
  process.env.NOCODB_API_TOKEN ||
  process.env.NOCO_API_TOKEN ||
  process.env.NC_TOKEN;

const SCHEMA_PATH =
  process.env.SCHEMA_PATH ||
  path.join(__dirname, 'export', '_schema.json');

if (!API_TOKEN) {
  console.error(
    'ERROR: NOCODB_API_TOKEN (or NOCO_API_TOKEN or NC_TOKEN) is required in environment.'
  );
  process.exit(1);
}
if (!BASE_ID) {
  console.error('ERROR: NOCODB_BASE_ID (or NOCO_BASE_ID) is required in environment.');
  process.exit(1);
}

const http = axios.create({
  baseURL: BASE_URL.replace(/\/+$/, ''),
  headers: {
    'xc-token': API_TOKEN,
    'Content-Type': 'application/json',
  },
});

// -------------------------------------------------------------
// Logging
// -------------------------------------------------------------

function logInfo(msg) {
  console.log(`[INFO] ${msg}`);
}
function logWarn(msg) {
  console.warn(`[WARN] ${msg}`);
}
function logError(msg) {
  console.error(`[ERROR] ${msg}`);
}

// -------------------------------------------------------------
// Airtable schema loader / helpers
// -------------------------------------------------------------

function loadAirtableSchema(schemaPath) {
  const abs = path.resolve(schemaPath);
  if (!fs.existsSync(abs)) {
    throw new Error(`Schema file not found: ${abs}`);
  }
  const raw = fs.readFileSync(abs, 'utf8');
  const json = JSON.parse(raw);

  const tables = Array.isArray(json) ? json : json.tables || [];
  if (!Array.isArray(tables) || tables.length === 0) {
    throw new Error('Schema JSON does not contain a non-empty "tables" array.');
  }

  const tablesById = {};
  const tablesByName = {};

  for (const t of tables) {
    const table = {
      id: t.id,
      name: t.name,
      primaryFieldId: t.primaryFieldId,
      fields: t.fields || [],
      fieldsById: {},
      fieldsByName: {},
    };

    for (const f of table.fields) {
      table.fieldsById[f.id] = f;
      table.fieldsByName[f.name] = f;
    }

    tablesById[table.id] = table;
    tablesByName[table.name] = table;
  }

  return { tables, tablesById, tablesByName };
}

// Bucket Airtable types into link / lookup / rollup / formula / simple
function classifyFieldType(field) {
  const t = (field.type || '').toLowerCase();
  if (!t) return 'simple';

  if (
    t === 'multiplerecordlinks' ||
    t === 'singlerecordlink' ||
    t === 'foreignkey' ||
    (t.includes('multiple') && t.includes('record') && t.includes('link'))
  ) {
    return 'link';
  }

  if (t === 'lookup' || t === 'multiplelookupvalues' || t.includes('lookup')) {
    return 'lookup';
  }

  if (t === 'rollup') {
    return 'rollup';
  }

  if (t === 'formula') {
    return 'formula';
  }

  return 'simple';
}

// Map Airtable rollup "function" string to something usable
function mapRollupFunction(func) {
  if (!func) return 'sum';
  const f = String(func).toLowerCase();

  if (['sum', 'avg', 'average', 'min', 'max', 'count'].includes(f)) {
    if (f === 'average') return 'avg';
    return f;
  }
  return 'sum';
}

// -------------------------------------------------------------
// NocoDB Meta API helpers
// -------------------------------------------------------------

async function fetchNocoTables() {
  const url = `/api/v2/meta/bases/${encodeURIComponent(BASE_ID)}/tables`;
  const res = await http.get(url);
  const raw = res.data;
  const list = Array.isArray(raw) ? raw : raw.list || [];

  const byId = new Map();
  const byTitle = new Map();

  for (const t of list) {
    byId.set(t.id, t);
    if (t.title) byTitle.set(t.title, t);
    if (t.table_name && !byTitle.has(t.table_name)) {
      byTitle.set(t.table_name, t);
    }
  }

  return { list, byId, byTitle };
}

async function fetchNocoTableMeta(tableId) {
  const url = `/api/v2/meta/tables/${encodeURIComponent(tableId)}`;
  const res = await http.get(url);
  return res.data;
}

async function createNocoColumn(tableOrId, payload) {
  const tableId = typeof tableOrId === 'string' ? tableOrId : tableOrId.id;
  if (!tableId) {
    throw new Error(
      `createNocoColumn called without a valid table id (got: ${JSON.stringify(
        tableOrId
      )})`
    );
  }

  const url = `/api/v2/meta/tables/${encodeURIComponent(tableId)}/columns`;

  const body = {
    parentId: tableId,
    ...payload,
  };

  const resp = await http.post(url, body);
  return resp.data;
}

async function patchNocoColumn(tableId, columnId, payload) {
  const url = `/api/v2/meta/tables/${encodeURIComponent(
    tableId
  )}/columns/${encodeURIComponent(columnId)}`;
  const resp = await http.patch(url, payload);
  return resp.data;
}

// -------------------------------------------------------------
// Relation / virtual field helpers
// -------------------------------------------------------------

/**
 * Ensure a LinkToAnotherRecord / relation column with the SAME name
 * as the Airtable field exists.
 *
 * Algorithm:
 *  - If a column with this name exists:
 *      - Try to PATCH it into a relation (uidt=LinkToAnotherRecord, type=relation, childId, meta).
 *      - If PATCH fails:
 *          - PATCH again just to rename it to "<name>_legacy" (title + column_name).
 *          - Then CREATE a new relation column "<name>" with correct meta.
 *  - If no column exists:
 *      - CREATE the relation column "<name>".
 */
async function ensureLinkField({
  atTable,
  atField,
  tablesById,
  nocoTable,
  nocoMeta,
}) {
  const options = atField.options || {};
  const linkedTableId = options.linkedTableId;
  if (!linkedTableId) {
    logWarn(
      `Linked-record field "${atField.name}" in table "${atTable.name}" has no options.linkedTableId; skipping.`
    );
    return;
  }

  const targetAtTable = tablesById[linkedTableId];
  if (!targetAtTable) {
    logWarn(
      `Linked-record field "${atField.name}" in "${atTable.name}" references unknown linkedTableId "${linkedTableId}"; skipping.`
    );
    return;
  }

  const { byTitle } = nocoMeta;
  const targetNocoTable = byTitle.get(targetAtTable.name);
  if (!targetNocoTable) {
    logWarn(
      `Linked-record field "${atField.name}" in "${atTable.name}" refers to "${targetAtTable.name}" not found in NocoDB; skipping.`
    );
    return;
  }

  const currentMeta = await fetchNocoTableMeta(nocoTable.id);
  const columns = currentMeta.columns || [];
  const existing = columns.find(
    (c) => (c.title || c.column_name) === atField.name
  );

  const relationMeta = {
    relation_type: 'mm',
    related_table_id: targetNocoTable.id,
  };

  // ------------- Helper: create new relation col with a given name -------------
  async function createRelationWithName(name) {
    const payload = {
      // parentId injected by createNocoColumn
      childId: targetNocoTable.id,
      type: 'relation',
      column_name: name,
      title: name,
      uidt: 'LinkToAnotherRecord',
      meta: JSON.stringify(relationMeta),
    };
    const created = await createNocoColumn(nocoTable, payload);
    logInfo(
      `+ Created relation column "${atTable.name}.${name}" (LinkToAnotherRecord → "${targetAtTable.name}").`
    );
    return created;
  }

  // ------------- Case 1: existing column with the same name -------------
  if (existing) {
    const uidt = existing.uidt;

    // 1a. Already link-ish, try just patching meta if needed
    if (uidt === 'LinkToAnotherRecord' || uidt === 'Links') {
      let existingMeta = {};
      try {
        existingMeta = existing.meta ? JSON.parse(existing.meta) : {};
      } catch (_) {
        existingMeta = {};
      }

      const needsPatch =
        existingMeta.related_table_id !== targetNocoTable.id ||
        !existingMeta.relation_type;

      if (!needsPatch) {
        logInfo(
          `✓ Linked-record already configured for "${atTable.name}.${atField.name}" (uidt=${uidt}).`
        );
        return;
      }

      try {
        await patchNocoColumn(nocoTable.id, existing.id, {
          uidt: 'LinkToAnotherRecord',
          type: 'relation',
          childId: targetNocoTable.id,
          meta: JSON.stringify(relationMeta),
        });
        logInfo(
          `± Patched link meta for "${atTable.name}.${atField.name}" → "${targetAtTable.name}".`
        );
        return;
      } catch (err) {
        logWarn(
          `Cannot PATCH link meta for "${atTable.name}.${atField.name}" (uidt="${uidt}"): ${
            err.response?.data
              ? JSON.stringify(err.response.data)
              : err.message
          }. Will rename old column and create a new relation.`
        );
      }
    } else {
      // 1b. Not a link yet → try to PATCH fully into a relation
      try {
        await patchNocoColumn(nocoTable.id, existing.id, {
          uidt: 'LinkToAnotherRecord',
          type: 'relation',
          childId: targetNocoTable.id,
          meta: JSON.stringify(relationMeta),
        });
        logInfo(
          `± Converted "${atTable.name}.${atField.name}" from uidt="${uidt}" to LinkToAnotherRecord → "${targetAtTable.name}".`
        );
        return;
      } catch (err) {
        const msgData = err.response?.data;
        const msgStr = msgData && msgData.msg ? String(msgData.msg) : '';
        logWarn(
          `Cannot PATCH existing column "${atTable.name}.${atField.name}" (uidt="${uidt}") to relation: ${
            msgStr || err.message
          }. Will rename old column and create a new relation.`
        );
      }
    }

    // 1c. PATCH failed: rename old column to "<name>_legacy", then create new relation with original name
    const legacyName = `${atField.name}_legacy`;

    try {
      await patchNocoColumn(nocoTable.id, existing.id, {
        column_name: legacyName,
        title: legacyName,
      });
      logInfo(
        `- Renamed previous column "${atTable.name}.${atField.name}" to "${legacyName}" to free up name for relation.`
      );
    } catch (renameErr) {
      logWarn(
        `Could not rename existing column "${atTable.name}.${atField.name}" to "${legacyName}": ${
          renameErr.response?.data
            ? JSON.stringify(renameErr.response.data)
            : renameErr.message
        }. Will still attempt to create a relation column with a different name.`
      );
      // In worst case, we'll create relation with a suffix
      let suffix = 1;
      let newName = `${atField.name}_rel`;
      const refreshedMeta = await fetchNocoTableMeta(nocoTable.id);
      const refreshedCols = refreshedMeta.columns || [];
      while (
        refreshedCols.find((c) => (c.title || c.column_name) === newName)
      ) {
        newName = `${atField.name}_rel${suffix++}`;
      }
      await createRelationWithName(newName);
      return;
    }

    // After rename, create relation with the original field name
    await createRelationWithName(atField.name);
    return;
  }

  // ------------- Case 2: no existing column with this name -------------
  await createRelationWithName(atField.name);
}

/**
 * Ensure Lookup column exists.
 */
async function ensureLookupField({
  atTable,
  atField,
  tablesById,
  nocoTable,
  nocoMeta,
}) {
  const options = atField.options || {};
  const recordLinkFieldId = options.recordLinkFieldId;
  const fieldIdInLinkedTable = options.fieldIdInLinkedTable;

  if (!recordLinkFieldId || !fieldIdInLinkedTable) {
    logWarn(
      `Lookup field "${atField.name}" in "${atTable.name}" missing recordLinkFieldId or fieldIdInLinkedTable; skipping.`
    );
    return;
  }

  const linkField = atTable.fieldsById[recordLinkFieldId];
  if (!linkField) {
    logWarn(
      `Lookup field "${atField.name}" in "${atTable.name}" refers to missing link field id="${recordLinkFieldId}"; skipping.`
    );
    return;
  }

  const linkOptions = linkField.options || {};
  const linkedTableId = linkOptions.linkedTableId;
  if (!linkedTableId) {
    logWarn(
      `Lookup field "${atField.name}" in "${atTable.name}" has link field "${linkField.name}" without options.linkedTableId; skipping.`
    );
    return;
  }

  const targetAtTable = tablesById[linkedTableId];
  if (!targetAtTable) {
    logWarn(
      `Lookup field "${atField.name}" in "${atTable.name}" refers to linkedTableId "${linkedTableId}" not found in schema; skipping.`
    );
    return;
  }

  const targetField = targetAtTable.fieldsById[fieldIdInLinkedTable];
  if (!targetField) {
    logWarn(
      `Lookup field "${atField.name}" in "${atTable.name}" refers to fieldIdInLinkedTable "${fieldIdInLinkedTable}" not found in "${targetAtTable.name}"; skipping.`
    );
    return;
  }

  const { byTitle } = nocoMeta;
  const targetNocoTable = byTitle.get(targetAtTable.name);
  if (!targetNocoTable) {
    logWarn(
      `Lookup field "${atField.name}" in "${atTable.name}" refers to target table "${targetAtTable.name}" not in NocoDB; skipping.`
    );
    return;
  }

  // Ensure relation exists
  await ensureLinkField({
    atTable,
    atField: linkField,
    tablesById,
    nocoTable,
    nocoMeta,
  });

  // Now find relation column & target column
  const tableMeta = await fetchNocoTableMeta(nocoTable.id);
  const tableCols = tableMeta.columns || [];
  const targetMeta = await fetchNocoTableMeta(targetNocoTable.id);
  const targetCols = targetMeta.columns || [];

  const relationColumn = tableCols.find((c) => {
    if (c.uidt !== 'LinkToAnotherRecord' && c.uidt !== 'Links') return false;
    let m = {};
    try {
      m = c.meta ? JSON.parse(c.meta) : {};
    } catch (_) {
      m = {};
    }
    return m.related_table_id === targetNocoTable.id;
  });

  if (!relationColumn) {
    logWarn(
      `Lookup field "${atField.name}" in "${atTable.name}": no LinkToAnotherRecord column pointing to "${targetAtTable.name}" found; skipping.`
    );
    return;
  }

  const lookupTargetCol = targetCols.find(
    (c) => (c.title || c.column_name) === targetField.name
  );
  if (!lookupTargetCol) {
    logWarn(
      `Lookup field "${atField.name}" in "${atTable.name}": target column "${targetField.name}" not found in Noco table "${targetAtTable.name}"; skipping.`
    );
    return;
  }

  const metaPayload = {
    fk_relation_column_id: relationColumn.id,
    fk_lookup_column_id: lookupTargetCol.id,
  };

  const existing = tableCols.find(
    (c) => (c.title || c.column_name) === atField.name
  );

  if (existing) {
    if (existing.uidt === 'Lookup') {
      let existingMeta = {};
      try {
        existingMeta = existing.meta ? JSON.parse(existing.meta) : {};
      } catch (_) {
        existingMeta = {};
      }
      const needsPatch =
        existingMeta.fk_relation_column_id !== relationColumn.id ||
        existingMeta.fk_lookup_column_id !== lookupTargetCol.id;

      if (!needsPatch) {
        logInfo(
          `✓ Lookup column "${atTable.name}.${atField.name}" already correctly configured.`
        );
        return;
      }

      await patchNocoColumn(nocoTable.id, existing.id, {
        uidt: 'Lookup',
        meta: JSON.stringify(metaPayload),
      });
      logInfo(
        `± Patched Lookup "${atTable.name}.${atField.name}" via "${relationColumn.title}" → "${targetAtTable.name}.${targetField.name}".`
      );
    } else {
      await patchNocoColumn(nocoTable.id, existing.id, {
        uidt: 'Lookup',
        meta: JSON.stringify(metaPayload),
      });
      logInfo(
        `± Converted "${atTable.name}.${atField.name}" (uidt="${existing.uidt}") to Lookup via "${relationColumn.title}" → "${targetAtTable.name}.${targetField.name}".`
      );
    }
  } else {
    const payload = {
      column_name: atField.name,
      title: atField.name,
      uidt: 'Lookup',
      meta: JSON.stringify(metaPayload),
    };

    await createNocoColumn(nocoTable.id, payload);
    logInfo(
      `+ Created Lookup "${atTable.name}.${atField.name}" via "${relationColumn.title}" → "${targetAtTable.name}.${targetField.name}".`
    );
  }
}

/**
 * Ensure Rollup column exists.
 */
async function ensureRollupField({
  atTable,
  atField,
  tablesById,
  nocoTable,
  nocoMeta,
}) {
  const options = atField.options || {};
  const recordLinkFieldId = options.recordLinkFieldId;
  const fieldIdInLinkedTable = options.fieldIdInLinkedTable;
  const func = mapRollupFunction(options.function);

  if (!recordLinkFieldId || !fieldIdInLinkedTable) {
    logWarn(
      `Rollup field "${atField.name}" in "${atTable.name}" missing recordLinkFieldId or fieldIdInLinkedTable; skipping.`
    );
    return;
  }

  const linkField = atTable.fieldsById[recordLinkFieldId];
  if (!linkField) {
    logWarn(
      `Rollup field "${atField.name}" in "${atTable.name}" refers to missing link field id="${recordLinkFieldId}"; skipping.`
    );
    return;
  }

  const linkOptions = linkField.options || {};
  const linkedTableId = linkOptions.linkedTableId;
  if (!linkedTableId) {
    logWarn(
      `Rollup field "${atField.name}" in "${atTable.name}" has link field "${linkField.name}" without options.linkedTableId; skipping.`
    );
    return;
  }

  const targetAtTable = tablesById[linkedTableId];
  if (!targetAtTable) {
    logWarn(
      `Rollup field "${atField.name}" in "${atTable.name}" refers to linkedTableId "${linkedTableId}" not found in schema; skipping.`
    );
    return;
  }

  const targetField = targetAtTable.fieldsById[fieldIdInLinkedTable];
  if (!targetField) {
    logWarn(
      `Rollup field "${atField.name}" in "${atTable.name}" refers to fieldIdInLinkedTable "${fieldIdInLinkedTable}" not found in "${targetAtTable.name}"; skipping.`
    );
    return;
  }

  const { byTitle } = nocoMeta;
  const targetNocoTable = byTitle.get(targetAtTable.name);
  if (!targetNocoTable) {
    logWarn(
      `Rollup field "${atField.name}" in "${atTable.name}" refers to target table "${targetAtTable.name}" not in NocoDB; skipping.`
    );
    return;
  }

  await ensureLinkField({
    atTable,
    atField: linkField,
    tablesById,
    nocoTable,
    nocoMeta,
  });

  const tableMeta = await fetchNocoTableMeta(nocoTable.id);
  const tableCols = tableMeta.columns || [];
  const targetMeta = await fetchNocoTableMeta(targetNocoTable.id);
  const targetCols = targetMeta.columns || [];

  const relationColumn = tableCols.find((c) => {
    if (c.uidt !== 'LinkToAnotherRecord' && c.uidt !== 'Links') return false;
    let m = {};
    try {
      m = c.meta ? JSON.parse(c.meta) : {};
    } catch (_) {
      m = {};
    }
    return m.related_table_id === targetNocoTable.id;
  });

  if (!relationColumn) {
    logWarn(
      `Rollup field "${atField.name}" in "${atTable.name}": no LinkToAnotherRecord column pointing to "${targetAtTable.name}" found; skipping.`
    );
    return;
  }

  const rollupTargetCol = targetCols.find(
    (c) => (c.title || c.column_name) === targetField.name
  );
  if (!rollupTargetCol) {
    logWarn(
      `Rollup field "${atField.name}" in "${atTable.name}": target column "${targetField.name}" not found in Noco table "${targetAtTable.name}"; skipping.`
    );
    return;
  }

  const metaPayload = {
    fk_relation_column_id: relationColumn.id,
    fk_rollup_column_id: rollupTargetCol.id,
    rollup_function: func,
  };

  const existing = tableCols.find(
    (c) => (c.title || c.column_name) === atField.name
  );

  if (existing) {
    if (existing.uidt === 'Rollup') {
      let existingMeta = {};
      try {
        existingMeta = existing.meta ? JSON.parse(existing.meta) : {};
      } catch (_) {
        existingMeta = {};
      }
      const needsPatch =
        existingMeta.fk_relation_column_id !== relationColumn.id ||
        existingMeta.fk_rollup_column_id !== rollupTargetCol.id ||
        existingMeta.rollup_function !== func;

      if (!needsPatch) {
        logInfo(
          `✓ Rollup column "${atTable.name}.${atField.name}" already correctly configured.`
        );
        return;
      }

      await patchNocoColumn(nocoTable.id, existing.id, {
        uidt: 'Rollup',
        meta: JSON.stringify(metaPayload),
      });
      logInfo(
        `± Patched Rollup "${atTable.name}.${atField.name}" via "${relationColumn.title}" → "${targetAtTable.name}.${targetField.name}" [${func}].`
      );
    } else {
      await patchNocoColumn(nocoTable.id, existing.id, {
        uidt: 'Rollup',
        meta: JSON.stringify(metaPayload),
      });
      logInfo(
        `± Converted "${atTable.name}.${atField.name}" (uidt="${existing.uidt}") to Rollup via "${relationColumn.title}" → "${targetAtTable.name}.${targetField.name}" [${func}].`
      );
    }
  } else {
    const payload = {
      column_name: atField.name,
      title: atField.name,
      uidt: 'Rollup',
      meta: JSON.stringify(metaPayload),
    };

    await createNocoColumn(nocoTable.id, payload);
    logInfo(
      `+ Created Rollup "${atTable.name}.${atField.name}" via "${relationColumn.title}" → "${targetAtTable.name}.${targetField.name}" [${func}].`
    );
  }
}

/**
 * Ensure Formula column exists and carries Airtable expression.
 */
async function ensureFormulaField({ atTable, atField, nocoTable }) {
  const options = atField.options || {};
  const formula = options.formula;
  if (!formula) {
    logWarn(
      `Formula field "${atField.name}" in "${atTable.name}" has no options.formula; skipping.`
    );
    return;
  }

  const tableMeta = await fetchNocoTableMeta(nocoTable.id);
  const tableCols = tableMeta.columns || [];

  const existing = tableCols.find(
    (c) => (c.title || c.column_name) === atField.name
  );

  const payloadPatch = {
    uidt: 'Formula',
    formula_raw: formula,
    formula: formula,
  };

  if (existing) {
    await patchNocoColumn(nocoTable.id, existing.id, payloadPatch);
    if (existing.uidt === 'Formula') {
      logInfo(
        `± Updated formula expression for "${atTable.name}.${atField.name}".`
      );
    } else {
      logInfo(
        `± Converted "${atTable.name}.${atField.name}" (uidt="${existing.uidt}") to Formula.`
      );
    }
  } else {
    const payloadCreate = {
      column_name: atField.name,
      title: atField.name,
      uidt: 'Formula',
      formula_raw: formula,
      formula: formula,
    };
    await createNocoColumn(nocoTable.id, payloadCreate);
    logInfo(
      `+ Created Formula field "${atTable.name}.${atField.name}" with Airtable expression.`
    );
  }
}

// -------------------------------------------------------------
// Main
// -------------------------------------------------------------

async function main() {
  try {
    logInfo(
      'Starting relations & virtual fields import for NocoDB (PATCH + rename+create for links)...'
    );
    logInfo(`Base URL : ${BASE_URL}`);
    logInfo(`Base ID  : ${BASE_ID}`);
    logInfo(`Schema   : ${SCHEMA_PATH}`);

    const { tablesByName, tablesById } = loadAirtableSchema(SCHEMA_PATH);
    const noco = await fetchNocoTables();

    logInfo(
      `NocoDB tables: ${noco.list
        .map((t) => `${t.table_name || t.id} [${t.id}] title="${t.title}"`)
        .join(', ')}`
    );

    const nocoMeta = {
      list: noco.list,
      byId: noco.byId,
      byTitle: noco.byTitle,
    };

    console.log('-----------------------------------------------------');
    logInfo('Creating / patching Links, Lookups, Rollups, Formulas');
    console.log('-----------------------------------------------------');

    const tableNames = Object.keys(tablesByName).sort();

    for (const tName of tableNames) {
      const atTable = tablesByName[tName];
      const nocoTable = noco.byTitle.get(tName);
      if (!nocoTable) {
        logWarn(
          `Skipping table "${tName}" (present in Airtable but NOT in NocoDB for this base).`
        );
        continue;
      }

      logInfo(`Processing table "${tName}" (${atTable.id})...`);

      const linkFields = atTable.fields.filter(
        (f) => classifyFieldType(f) === 'link'
      );
      const lookupFields = atTable.fields.filter(
        (f) => classifyFieldType(f) === 'lookup'
      );
      const rollupFields = atTable.fields.filter(
        (f) => classifyFieldType(f) === 'rollup'
      );
      const formulaFields = atTable.fields.filter(
        (f) => classifyFieldType(f) === 'formula'
      );

      for (const f of linkFields) {
        try {
          await ensureLinkField({
            atTable,
            atField: f,
            tablesById,
            nocoTable,
            nocoMeta,
          });
        } catch (err) {
          logError(
            `Error configuring link field "${tName}.${f.name}": ${
              err && err.message ? err.message : err
            }`
          );
        }
      }

      for (const f of lookupFields) {
        try {
          await ensureLookupField({
            atTable,
            atField: f,
            tablesById,
            nocoTable,
            nocoMeta,
          });
        } catch (err) {
          logError(
            `Error configuring lookup field "${tName}.${f.name}": ${
              err && err.message ? err.message : err
            }`
          );
        }
      }

      for (const f of rollupFields) {
        try {
          await ensureRollupField({
            atTable,
            atField: f,
            tablesById,
            nocoTable,
            nocoMeta,
          });
        } catch (err) {
          logError(
            `Error configuring rollup field "${tName}.${f.name}": ${
              err && err.message ? err.message : err
            }`
          );
        }
      }

      for (const f of formulaFields) {
        try {
          await ensureFormulaField({
            atTable,
            atField: f,
            nocoTable,
          });
        } catch (err) {
          logError(
            `Error configuring formula field "${tName}.${f.name}": ${
              err && err.message ? err.message : err
            }`
          );
        }
      }
    }

    logInfo('Done.');
  } catch (err) {
    logError(
      `Fatal error in create_nocodb_relations_and_rollups: ${
        err.stack || err.message || err
      }`
    );
    process.exit(1);
  }
}

if (require.main === module) {
  main();
}
