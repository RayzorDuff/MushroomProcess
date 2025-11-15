#!/usr/bin/env node
/**
 * create_nocodb_relations_and_rollups.js
 *
 * Purpose
 * -------
 * Migration helper for MushroomProcess → NocoDB.
 *
 * This script:
 *  1) Compares Airtable schema (_schema.json) with NocoDB base:
 *       - Tables missing / extra
 *       - Columns missing / extra
 *  2) For Airtable relational / virtual fields:
 *       - Linked-record fields (multipleRecordLinks / LinkToAnotherRecord)
 *       - Lookup fields
 *       - Rollup fields
 *     It will CREATE missing NocoDB columns with appropriate uidt + meta:
 *       - LinkToAnotherRecord
 *       - Lookup
 *       - Rollup
 *  3) Leaves existing columns untouched if types differ (warn only).
 *  4) Reports Formula fields and type mismatches so you can fix manually.
 *
 * Safety notes
 * ------------
 * - This script only adds new columns; it does NOT drop or modify existing
 *   columns that have mismatched types. Those generate warnings only.
 * - It does NOT attempt to convert Airtable formulas into NocoDB Formula
 *   expressions; formulas are reported, not created.
 *
 * Environment
 * -----------
 *   NOCODB_BASE_URL   - e.g. http://localhost:8080
 *   NOCODB_BASE_ID    - NocoDB base ID (project ID)
 *   NOCODB_API_TOKEN  - NocoDB API token
 *   SCHEMA_PATH     - path to Airtable _schema.json
 *                     (defaults to ./export/_schema.json)
 */

const fs = require('fs');
const path = require('path');
const axios = require('axios');

// ---------- Environment & basic helpers ----------

const NOCO_BASE_URL = process.env.NOCODB_BASE_URL || process.env.NOCODB_URL;
const NOCO_BASE_ID = process.env.NOCODB_BASE_ID;
const NOCO_API_TOKEN = process.env.NOCODB_API_TOKEN;
const SCHEMA_PATH =
  process.env.SCHEMA_PATH ||
  path.join(__dirname, 'export', '_schema.json');

if (!NOCO_BASE_URL || !NOCO_BASE_ID || !NOCO_API_TOKEN) {
  console.error('[FATAL] NOCO_BASE_URL, NOCO_BASE_ID, NOCO_API_TOKEN must be set in the environment.');
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

// ---------- Load Airtable schema ----------

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

  // Build lookup maps by tableId and by name
  const tablesById = {};
  const tablesByName = {};
  for (const t of tables) {
    if (!t || !t.name) continue;
    const table = {
      ...t,
      fieldsById: {},
      fieldsByName: {},
    };

    const fields = t.fields || [];
    for (const f of fields) {
      if (!f || !f.name) continue;
      table.fieldsById[f.id] = f;
      table.fieldsByName[f.name] = f;
    }

    tablesById[t.id] = table;
    tablesByName[t.name] = table;
  }

  return { tables, tablesById, tablesByName };
}

// Rough classification of Airtable field types
function classifyFieldType(field) {
  const t = (field.type || '').toLowerCase();
  if (!t) return 'simple';

  if (t.includes('multiple') && t.includes('record') && t.includes('link')) {
    return 'link';
  }
  if (t === 'foreignkey' || t === 'linktoanotherrecord') {
    return 'link';
  }
  if (t === 'rollup') return 'rollup';
  if (t === 'lookup') return 'lookup';
  if (t === 'formula') return 'formula';
  if (t.includes('lookup')) return 'lookup';

  return 'simple';
}

// Map Airtable rollup function into something NocoDB can accept
function mapRollupFunction(func) {
  if (!func) return 'sum';
  const f = String(func).toLowerCase();

  if (['sum', 'avg', 'average', 'min', 'max', 'count'].includes(f)) {
    if (f === 'average') return 'avg';
    return f;
  }
  // Fallback to sum for anything else (ARRAY_JOIN, etc. not supported here)
  return 'sum';
}

// ---------- NocoDB meta helpers ----------

async function fetchNocoTables() {
  const url = `/api/v2/meta/bases/${NOCO_BASE_ID}/tables`;
  const resp = await http.get(url);
  const list = resp.data && resp.data.list ? resp.data.list : [];

  const byTitle = new Map();
  for (const tbl of list) {
    if (tbl.title) byTitle.set(tbl.title, tbl);
  }
  return { list, byTitle };
}

async function fetchNocoTableMeta(tableId) {
  const url = `/api/v2/meta/tables/${tableId}`;
  const resp = await http.get(url);
  return resp.data;
}

async function createNocoColumn(tableId, payload) {
  const url = `/api/v2/meta/tables/${tableId}/columns`;
  const resp = await http.post(url, payload);
  return resp.data;
}

// ---------- Relation & virtual field creators ----------

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

  const { list: nocoTables, byTitle } = nocoMeta;
  const targetNocoTable = byTitle.get(targetAtTable.name);
  if (!targetNocoTable) {
    logWarn(
      `Linked-record field "${atField.name}" in "${atTable.name}" references table "${targetAtTable.name}" which does not exist in NocoDB; skipping.`
    );
    return;
  }

  const currentMeta = await fetchNocoTableMeta(nocoTable.id);
  const columns = currentMeta.columns || [];
  const existing = columns.find(
    (c) => (c.title || c.column_name) === atField.name
  );

  if (existing) {
    const uidt = existing.uidt;
    if (uidt !== 'LinkToAnotherRecord' && uidt !== 'Links') {
      logWarn(
        `Field "${atField.name}" in NocoDB table "${atTable.name}" exists with uidt="${uidt}" (expected LinkToAnotherRecord/Links). Not modifying.`
      );
    } else {
      logInfo(
        `✓ Linked-record already configured for "${atTable.name}.${atField.name}" (uidt=${uidt}).`
      );
    }
    return;
  }

  const payload = {
    column_name: atField.name,
    title: atField.name,
    uidt: 'LinkToAnotherRecord',
    meta: JSON.stringify({
      relation_type: 'mm', // many-to-many; adjust if you later want one-to-many
      related_table_id: targetNocoTable.id,
    }),
  };

  const created = await createNocoColumn(nocoTable.id, payload);
  logInfo(
    `+ Created LinkToAnotherRecord field "${atField.name}" on "${atTable.name}" → linked to "${targetAtTable.name}" (relation_type=mm).`
  );
  return created;
}

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
      `Lookup field "${atField.name}" in "${atTable.name}" references unknown link field id "${recordLinkFieldId}"; skipping.`
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
      `Lookup field "${atField.name}" in "${atTable.name}" references linkedTableId "${linkedTableId}" not found in schema; skipping.`
    );
    return;
  }

  const targetField = targetAtTable.fieldsById[fieldIdInLinkedTable];
  if (!targetField) {
    logWarn(
      `Lookup field "${atField.name}" in "${atTable.name}" references target field id "${fieldIdInLinkedTable}" not found in table "${targetAtTable.name}"; skipping.`
    );
    return;
  }

  const { byTitle } = nocoMeta;
  const targetNocoTable = byTitle.get(targetAtTable.name);
  if (!targetNocoTable) {
    logWarn(
      `Lookup field "${atField.name}" in "${atTable.name}" references target table "${targetAtTable.name}" not in NocoDB; skipping.`
    );
    return;
  }

  // Fetch Noco table meta + target table meta
  const tableMeta = await fetchNocoTableMeta(nocoTable.id);
  const tableCols = tableMeta.columns || [];
  const targetMeta = await fetchNocoTableMeta(targetNocoTable.id);
  const targetCols = targetMeta.columns || [];

  const existing = tableCols.find(
    (c) => (c.title || c.column_name) === atField.name
  );
  if (existing) {
    if (existing.uidt !== 'Lookup') {
      logWarn(
        `Lookup field "${atField.name}" in "${atTable.name}" exists in NocoDB with uidt="${existing.uidt}" (expected "Lookup"). Not modifying.`
      );
    } else {
      logInfo(
        `✓ Lookup already configured for "${atTable.name}.${atField.name}" (uidt=${existing.uidt}).`
      );
    }
    return;
  }

  // Find link column in Noco
  const linkCol = tableCols.find(
    (c) => (c.title || c.column_name) === linkField.name
  );
  if (!linkCol || (linkCol.uidt !== 'LinkToAnotherRecord' && linkCol.uidt !== 'Links')) {
    logWarn(
      `Lookup field "${atField.name}" in "${atTable.name}" expects link column "${linkField.name}" as LinkToAnotherRecord/Links in NocoDB, found uidt="${linkCol?.uidt}". Skipping creation.`
    );
    return;
  }

  // Find target field column in Noco
  const targetCol = targetCols.find(
    (c) => (c.title || c.column_name) === targetField.name
  );
  if (!targetCol) {
    logWarn(
      `Lookup field "${atField.name}" in "${atTable.name}" expects target column "${targetField.name}" on table "${targetAtTable.name}" in NocoDB; not found. Skipping creation.`
    );
    return;
  }

  const payload = {
    column_name: atField.name,
    title: atField.name,
    uidt: 'Lookup',
    meta: JSON.stringify({
      related_field_id: linkCol.id,
      related_table_lookup_field_id: targetCol.id,
    }),
  };

  const created = await createNocoColumn(nocoTable.id, payload);
  logInfo(
    `+ Created Lookup field "${atField.name}" on "${atTable.name}" referencing "${linkField.name}" → "${targetAtTable.name}.${targetField.name}".`
  );
  return created;
}

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
      `Rollup field "${atField.name}" in "${atTable.name}" references unknown link field id "${recordLinkFieldId}"; skipping.`
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
      `Rollup field "${atField.name}" in "${atTable.name}" references linkedTableId "${linkedTableId}" not found in schema; skipping.`
    );
    return;
  }

  const targetField = targetAtTable.fieldsById[fieldIdInLinkedTable];
  if (!targetField) {
    logWarn(
      `Rollup field "${atField.name}" in "${atTable.name}" references target field id "${fieldIdInLinkedTable}" not found in table "${targetAtTable.name}"; skipping.`
    );
    return;
  }

  const { byTitle } = nocoMeta;
  const targetNocoTable = byTitle.get(targetAtTable.name);
  if (!targetNocoTable) {
    logWarn(
      `Rollup field "${atField.name}" in "${atTable.name}" references target table "${targetAtTable.name}" not in NocoDB; skipping.`
    );
    return;
  }

  const tableMeta = await fetchNocoTableMeta(nocoTable.id);
  const tableCols = tableMeta.columns || [];
  const targetMeta = await fetchNocoTableMeta(targetNocoTable.id);
  const targetCols = targetMeta.columns || [];

  const existing = tableCols.find(
    (c) => (c.title || c.column_name) === atField.name
  );
  if (existing) {
    if (existing.uidt !== 'Rollup') {
      logWarn(
        `Rollup field "${atField.name}" in "${atTable.name}" exists in NocoDB with uidt="${existing.uidt}" (expected "Rollup"). Not modifying.`
      );
    } else {
      logInfo(
        `✓ Rollup already configured for "${atTable.name}.${atField.name}" (uidt=${existing.uidt}).`
      );
    }
    return;
  }

  const linkCol = tableCols.find(
    (c) => (c.title || c.column_name) === linkField.name
  );
  if (!linkCol || (linkCol.uidt !== 'LinkToAnotherRecord' && linkCol.uidt !== 'Links')) {
    logWarn(
      `Rollup field "${atField.name}" in "${atTable.name}" expects link column "${linkField.name}" as LinkToAnotherRecord/Links in NocoDB; found uidt="${linkCol?.uidt}". Skipping creation.`
    );
    return;
  }

  const targetCol = targetCols.find(
    (c) => (c.title || c.column_name) === targetField.name
  );
  if (!targetCol) {
    logWarn(
      `Rollup field "${atField.name}" in "${atTable.name}" expects target column "${targetField.name}" on table "${targetAtTable.name}" in NocoDB; not found. Skipping creation.`
    );
    return;
  }

  const payload = {
    column_name: atField.name,
    title: atField.name,
    uidt: 'Rollup',
    meta: JSON.stringify({
      related_field_id: linkCol.id,
      related_table_rollup_field_id: targetCol.id,
      rollup_function: func,
    }),
  };

  const created = await createNocoColumn(nocoTable.id, payload);
  logInfo(
    `+ Created Rollup field "${atField.name}" on "${atTable.name}" via link "${linkField.name}" → "${targetAtTable.name}.${targetField.name}", function=${func}.`
  );
  return created;
}

// ---------- Main ----------

async function main() {
  try {
    logInfo('Starting relations & rollups import for NocoDB (mutating mode)...');
    logInfo(`Base URL : ${NOCO_BASE_URL}`);
    logInfo(`Base ID  : ${NOCO_BASE_ID}`);
    logInfo(`Schema   : ${SCHEMA_PATH}`);

    const { tables, tablesById, tablesByName } = loadAirtableSchema(SCHEMA_PATH);
    const noco = await fetchNocoTables();

    logInfo(
      `NocoDB tables in base: ${noco.list
        .map((t) => `${t.table_name || t.id} [${t.id}] title="${t.title}"`)
        .join(', ')}`
    );

    const summary = {
      missingTablesInNoco: [],
      extraTablesInNoco: [],
      perTable: {}, // tableName -> { missingColumns, extraColumns, relationIssues, virtualIssues }
    };

    const airtableTableNames = new Set(Object.keys(tablesByName));

    // ---------- Structural comparison (tables & columns) ----------

    console.log('-----------------------------------------------------');
    logInfo('First comparison: Airtable vs NocoDB (structural)');
    console.log('-----------------------------------------------------');

    for (const [tName, atTable] of Object.entries(tablesByName)) {
      const nocoTable = noco.byTitle.get(tName);
      if (!nocoTable) {
        logWarn(
          `Table "${tName}" exists in Airtable schema but not in NocoDB base "${NOCO_BASE_ID}".`
        );
        summary.missingTablesInNoco.push(tName);
        continue;
      }

      const meta = await fetchNocoTableMeta(nocoTable.id);
      const nocoColumns = meta.columns || [];

      const nocoColNames = new Set(
        nocoColumns.map((c) => c.title || c.column_name)
      );
      const airtableFieldNames = new Set(
        (atTable.fields || []).map((f) => f.name)
      );

      const missingColumns = [];
      const extraColumns = [];

      for (const fName of airtableFieldNames) {
        if (!nocoColNames.has(fName)) missingColumns.push(fName);
      }
      for (const col of nocoColumns) {
        const cName = col.title || col.column_name;
        if (!airtableFieldNames.has(cName)) extraColumns.push(cName);
      }

      if (missingColumns.length || extraColumns.length) {
        logInfo(
          `Table "${tName}" structural differences: missingColumns=${JSON.stringify(
            missingColumns
          )}, extraColumns=${JSON.stringify(extraColumns)}`
        );
      }

      summary.perTable[tName] = {
        missingColumns,
        extraColumns,
        relationIssues: [],
        virtualIssues: [],
      };
    }

    for (const t of noco.list) {
      const title = t.title;
      if (!airtableTableNames.has(title)) {
        logWarn(
          `NocoDB table "${title}" (id=${t.id}) not found in Airtable schema.`
        );
        summary.extraTablesInNoco.push(title);
      }
    }

    // ---------- Create missing relations & virtual fields ----------

    console.log('');
    console.log('-----------------------------------------------------');
    logInfo(
      'Creating LinkToAnotherRecord, Lookup, Rollup fields where missing'
    );
    console.log('-----------------------------------------------------');

    for (const [tName, atTable] of Object.entries(tablesByName)) {
      const nocoTable = noco.byTitle.get(tName);
      if (!nocoTable) continue; // already recorded as missing

      const perTable = summary.perTable[tName] || {
        missingColumns: [],
        extraColumns: [],
        relationIssues: [],
        virtualIssues: [],
      };

      const fields = atTable.fields || [];
      const linkFields = [];
      const rollupFields = [];
      const lookupFields = [];
      const formulaFields = [];

      for (const f of fields) {
        const cls = classifyFieldType(f);
        if (cls === 'link') linkFields.push(f);
        else if (cls === 'rollup') rollupFields.push(f);
        else if (cls === 'lookup') lookupFields.push(f);
        else if (cls === 'formula') formulaFields.push(f);
      }

      if (
        !linkFields.length &&
        !rollupFields.length &&
        !lookupFields.length &&
        !formulaFields.length
      ) {
        summary.perTable[tName] = perTable;
        continue;
      }

      console.log('');
      logInfo(
        `Table "${tName}": linkFields=${linkFields.length}, rollupFields=${rollupFields.length}, lookupFields=${lookupFields.length}, formulaFields=${formulaFields.length}`
      );

      // 1st pass: ensure all link fields exist
      for (const lf of linkFields) {
        try {
          await ensureLinkField({
            atTable,
            atField: lf,
            tablesById,
            nocoTable,
            nocoMeta: noco,
          });
        } catch (err) {
          const msg = `Error creating / checking link field "${lf.name}" on "${tName}": ${
            err.response?.data ? JSON.stringify(err.response.data) : err.message
          }`;
          logError(msg);
          perTable.relationIssues.push(msg);
        }
      }

      // 2nd pass: ensure lookups and rollups (now that links should exist)
      for (const lf of lookupFields) {
        try {
          await ensureLookupField({
            atTable,
            atField: lf,
            tablesById,
            nocoTable,
            nocoMeta: noco,
          });
        } catch (err) {
          const msg = `Error creating / checking lookup field "${lf.name}" on "${tName}": ${
            err.response?.data ? JSON.stringify(err.response.data) : err.message
          }`;
          logError(msg);
          perTable.virtualIssues.push(msg);
        }
      }

      for (const rf of rollupFields) {
        try {
          await ensureRollupField({
            atTable,
            atField: rf,
            tablesById,
            nocoTable,
            nocoMeta: noco,
          });
        } catch (err) {
          const msg = `Error creating / checking rollup field "${rf.name}" on "${tName}": ${
            err.response?.data ? JSON.stringify(err.response.data) : err.message
          }`;
          logError(msg);
          perTable.virtualIssues.push(msg);
        }
      }

      // Formula fields: report only (no automatic creation)
      for (const ff of formulaFields) {
        const msg = `Formula field "${ff.name}" in "${tName}" is not auto-created in NocoDB. You may want to create a Formula column manually with an equivalent expression.`;
        logWarn(msg);
        perTable.virtualIssues.push(msg);
      }

      summary.perTable[tName] = perTable;
    }

    // ---------- Post-analysis summary ----------

    console.log('');
    console.log('-----------------------------------------------------');
    logInfo('Post-analysis summary (differences & remaining items)');
    console.log('-----------------------------------------------------');

    if (summary.missingTablesInNoco.length) {
      logWarn(
        `Tables missing in NocoDB: ${summary.missingTablesInNoco.join(', ')}`
      );
    } else {
      logInfo('No Airtable tables are missing in NocoDB.');
    }

    if (summary.extraTablesInNoco.length) {
      logWarn(
        `Extra tables in NocoDB (not in Airtable schema): ${summary.extraTablesInNoco.join(
          ', '
        )}`
      );
    } else {
      logInfo('No extra NocoDB tables relative to Airtable schema.');
    }

    for (const [tableName, detail] of Object.entries(summary.perTable)) {
      const {
        missingColumns = [],
        extraColumns = [],
        relationIssues = [],
        virtualIssues = [],
      } = detail;

      if (
        !missingColumns.length &&
        !extraColumns.length &&
        !relationIssues.length &&
        !virtualIssues.length
      ) {
        logInfo(`Table "${tableName}" appears aligned (post-creation).`);
        continue;
      }

      console.log('');
      logInfo(`Table "${tableName}" details:`);

      if (missingColumns.length) {
        logWarn(
          `  Remaining missing columns in NocoDB: ${missingColumns.join(', ')}`
        );
      }
      if (extraColumns.length) {
        logWarn(`  Extra columns in NocoDB: ${extraColumns.join(', ')}`);
      }
      if (relationIssues.length) {
        logWarn('  Relation / link issues:');
        for (const msg of relationIssues) {
          console.log(`    - ${msg}`);
        }
      }
      if (virtualIssues.length) {
        logWarn('  Rollup / lookup / formula issues:');
        for (const msg of virtualIssues) {
          console.log(`    - ${msg}`);
        }
      }
    }

    console.log('');
    logInfo(
      'Relations & rollups migration complete. New columns were created where needed; existing mismatched columns were left unchanged.'
    );
  } catch (err) {
    logError(
      `Unhandled error in relations/rollups import: ${
        err && err.message ? err.message : err
      }`
    );
    if (err && err.response) {
      console.error('  Status:', err.response.status);
      console.error('  Data  :', JSON.stringify(err.response.data, null, 2));
    } else {
      console.error(err);
    }
    process.exit(1);
  }
}

main();
