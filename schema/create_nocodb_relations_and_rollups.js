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
 *     It will:
 *       - CREATE missing NocoDB columns with appropriate uidt + meta
 *       - PATCH existing columns whose uidt is wrong to the correct uidt + meta
 *  3) Leaves Formula fields as “report only” (no automatic creation)
 *
 * Notes
 * -----
 * - This script **mutates** your NocoDB schema.
 * - For links/lookups/rollups, if the column already exists but has the
 *   wrong uidt (e.g. LongText), it PATCHes that column to the correct type.
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

function mapRollupFunction(func) {
  if (!func) return 'sum';
  const f = String(func).toLowerCase();

  if (['sum', 'avg', 'average', 'min', 'max', 'count'].includes(f)) {
    if (f === 'average') return 'avg';
    return f;
  }
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

async function createNocoColumn(tableOrId, payload) {
  // Accept either a table object or a raw ID
  const tableId =
    typeof tableOrId === 'string' ? tableOrId : tableOrId.id;

  if (!tableId) {
    throw new Error(
      `createNocoColumn called without a valid table id (got: ${JSON.stringify(
        tableOrId
      )})`
    );
  }

  const url = `/api/v2/meta/tables/${tableId}/columns`;

  // NocoDB expects parentId in the body
  const body = {
    parentId: tableId,
    ...payload,
  };

  const resp = await http.post(url, body);
  return resp.data;
}

async function patchNocoColumn(tableId, columnId, payload) {
  const url = `/api/v2/meta/tables/${tableId}/columns/${columnId}`;
  const resp = await http.patch(url, payload);
  return resp.data;
}

// ---------- Relation & virtual field creators / updaters ----------
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
      `Linked-record field "${atField.name}" in "${atTable.name}" references table "${targetAtTable.name}" which does not exist in NocoDB; skipping.`
    );
    return;
  }

  // Get current columns for this Noco table
  const currentMeta = await fetchNocoTableMeta(nocoTable.id);
  const columns = currentMeta.columns || [];
  const existing = columns.find(
    (c) => (c.title || c.column_name) === atField.name
  );

  const relationMeta = {
    relation_type: 'mm', // many-to-many; adjust later if you decide to model differently
    related_table_id: targetNocoTable.id,
  };

  // --- Case 1: column already exists ---
  if (existing) {
    const uidt = existing.uidt;

    // 1a. Already a link field → just ensure meta is correct
    if (uidt === 'LinkToAnotherRecord' || uidt === 'Links') {
      let existingMeta = {};
      try {
        existingMeta = existing.meta ? JSON.parse(existing.meta) : {};
      } catch {
        existingMeta = {};
      }

      const needsPatch =
        existingMeta.related_table_id !== targetNocoTable.id ||
        !existingMeta.relation_type;

      if (needsPatch) {
        try {
          await patchNocoColumn(nocoTable.id, existing.id, {
            uidt: 'LinkToAnotherRecord',
            meta: JSON.stringify(relationMeta),
          });
          logInfo(
            `± Patched link meta on "${atTable.name}.${atField.name}" to LinkToAnotherRecord → "${targetAtTable.name}".`
          );
        } catch (err) {
          logError(
            `Error patching link meta on "${atTable.name}.${atField.name}": ${
              err.response?.data
                ? JSON.stringify(err.response.data)
                : err.message
            }`
          );
        }
      } else {
        logInfo(
          `✓ Linked-record already configured for "${atTable.name}.${atField.name}" (uidt=${uidt}).`
        );
      }

      return;
    }

    // 1b. Existing column, but wrong uidt → try to PATCH to LinkToAnotherRecord
    try {
      await patchNocoColumn(nocoTable.id, existing.id, {
        uidt: 'LinkToAnotherRecord',
        meta: JSON.stringify(relationMeta),
      });
      logInfo(
        `± Converted existing column "${atTable.name}.${atField.name}" from uidt="${uidt}" to LinkToAnotherRecord linked to "${targetAtTable.name}".`
      );
      return;
    } catch (err) {
      const msgData = err.response?.data;
      const msgStr = msgData && msgData.msg ? String(msgData.msg) : '';

      // If NocoDB refuses to PATCH this column, fall back to creating a *new* link field
      if (msgStr.includes('Cannot PATCH')) {
        logWarn(
          `Cannot PATCH existing column "${atTable.name}.${atField.name}" (uidt="${uidt}") in NocoDB: ${msgStr}. ` +
            `Creating a new link column with a suffix instead.`
        );

        // Find a unique name like lots_rel, lots_rel1, lots_rel2, ...
        let newNameBase = `${atField.name}_rel`;
        let newName = newNameBase;
        let counter = 1;
        while (
          columns.find(
            (c) => (c.title || c.column_name) === newName
          )
        ) {
          newName = `${newNameBase}${counter++}`;
        }

        const payload = {
          childId: targetNocoTable.id,
          column_name: newName,
          title: newName,
          uidt: 'LinkToAnotherRecord',
          meta: JSON.stringify(relationMeta),
        };

        try {
          await createNocoColumn(nocoTable, {
            // NocoDB wants BOTH parentId and childId for link columns:
            // - parentId is injected by createNocoColumn(...) (source table)
            // - childId is the related table id (targetNocoTable.id)
            childId: targetNocoTable.id,

            column_name: ${newName},
            title: ${newName},
            uidt: 'LinkToAnotherRecord',

            // meta still has relation details
            meta: JSON.stringify({
              relation_type: 'mm',
              related_table_id: targetNocoTable.id,
            }),
          });

          console.log(
            `[INFO] Created fallback link column "${atTable}.${newName}" (LinkToAnotherRecord).`
          );
        } catch (createErr) {
          console.error(
            `[ERROR] Error creating fallback link column "${atTable}.${newName}" after PATCH failure: ${
              createErr.response?.data
                ? JSON.stringify(createErr.response.data)
                : createErr.message
            }`
          );
        }

        return;
      }

      // Any other error → log and bubble up to summary
      throw err;
    }
  }

  // --- Case 2: column does not exist at all → create it normally ---
  const payload = {
    column_name: atField.name,
    title: atField.name,
    uidt: 'LinkToAnotherRecord',
    meta: JSON.stringify(relationMeta),
  };

  try {
    await createNocoColumn(nocoTable.id, payload);
    logInfo(
      `+ Created LinkToAnotherRecord field "${atField.name}" on "${atTable.name}" → "${targetAtTable.name}".`
    );
  } catch (err) {
    logError(
      `Error creating new link column "${atTable.name}.${atField.name}": ${
        err.response?.data ? JSON.stringify(err.response.data) : err.message
      }`
    );
    throw err;
  }
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

  const tableMeta = await fetchNocoTableMeta(nocoTable.id);
  const tableCols = tableMeta.columns || [];
  const targetMeta = await fetchNocoTableMeta(targetNocoTable.id);
  const targetCols = targetMeta.columns || [];

  const linkCol = tableCols.find(
    (c) => (c.title || c.column_name) === linkField.name
  );
  if (!linkCol || (linkCol.uidt !== 'LinkToAnotherRecord' && linkCol.uidt !== 'Links')) {
    logWarn(
      `Lookup field "${atField.name}" in "${atTable.name}" expects link column "${linkField.name}" as LinkToAnotherRecord/Links in NocoDB; found uidt="${linkCol?.uidt}". Skipping creation.`
    );
    return;
  }

  const targetCol = targetCols.find(
    (c) => (c.title || c.column_name) === targetField.name
  );
  if (!targetCol) {
    logWarn(
      `Lookup field "${atField.name}" in "${atTable.name}" expects target column "${targetField.name}" on table "${targetAtTable.name}" in NocoDB; not found. Skipping creation.`
    );
    return;
  }

  const metaPayload = {
    related_field_id: linkCol.id,
    related_table_lookup_field_id: targetCol.id,
  };

  const existing = tableCols.find(
    (c) => (c.title || c.column_name) === atField.name
  );

  if (existing) {
    if (existing.uidt === 'Lookup') {
      // Maybe just patch meta if needed
      let existingMeta = {};
      try {
        existingMeta = existing.meta ? JSON.parse(existing.meta) : {};
      } catch {
        existingMeta = {};
      }
      const needsPatch =
        existingMeta.related_field_id !== linkCol.id ||
        existingMeta.related_table_lookup_field_id !== targetCol.id;

      if (needsPatch) {
        await patchNocoColumn(nocoTable.id, existing.id, {
          uidt: 'Lookup',
          meta: JSON.stringify(metaPayload),
        });
        logInfo(
          `± Patched Lookup meta on "${atTable.name}.${atField.name}" to use link="${linkField.name}" and target="${targetAtTable.name}.${targetField.name}".`
        );
      } else {
        logInfo(
          `✓ Lookup already configured for "${atTable.name}.${atField.name}".`
        );
      }
    } else {
      await patchNocoColumn(nocoTable.id, existing.id, {
        uidt: 'Lookup',
        meta: JSON.stringify(metaPayload),
      });
      logInfo(
        `± Converted existing column "${atTable.name}.${atField.name}" from uidt="${existing.uidt}" to Lookup (via "${linkField.name}" → "${targetAtTable.name}.${targetField.name}").`
      );
    }
    return;
  }

  const payload = {
    column_name: atField.name,
    title: atField.name,
    uidt: 'Lookup',
    meta: JSON.stringify(metaPayload),
  };

  await createNocoColumn(nocoTable.id, payload);
  logInfo(
    `+ Created Lookup field "${atField.name}" on "${atTable.name}" referencing "${linkField.name}" → "${targetAtTable.name}.${targetField.name}".`
  );
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
      `Rollup field "${atField.name}" in "${atTable.name}" references target field id "${fieldIdInLinkedTable}" not found in "${targetAtTable.name}"; skipping.`
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

  const metaPayload = {
    related_field_id: linkCol.id,
    related_table_rollup_field_id: targetCol.id,
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
      } catch {
        existingMeta = {};
      }
      const needsPatch =
        existingMeta.related_field_id !== linkCol.id ||
        existingMeta.related_table_rollup_field_id !== targetCol.id ||
        existingMeta.rollup_function !== func;

      if (needsPatch) {
        await patchNocoColumn(nocoTable.id, existing.id, {
          uidt: 'Rollup',
          meta: JSON.stringify(metaPayload),
        });
        logInfo(
          `± Patched Rollup meta on "${atTable.name}.${atField.name}" to use link="${linkField.name}", target="${targetAtTable.name}.${targetField.name}", func=${func}.`
        );
      } else {
        logInfo(
          `✓ Rollup already configured for "${atTable.name}.${atField.name}".`
        );
      }
    } else {
      await patchNocoColumn(nocoTable.id, existing.id, {
        uidt: 'Rollup',
        meta: JSON.stringify(metaPayload),
      });
      logInfo(
        `± Converted existing column "${atTable.name}.${atField.name}" from uidt="${existing.uidt}" to Rollup (via "${linkField.name}" → "${targetAtTable.name}.${targetField.name}", func=${func}).`
      );
    }
    return;
  }

  const payload = {
    column_name: atField.name,
    title: atField.name,
    uidt: 'Rollup',
    meta: JSON.stringify(metaPayload),
  };

  await createNocoColumn(nocoTable.id, payload);
  logInfo(
    `+ Created Rollup field "${atField.name}" on "${atTable.name}" via link="${linkField.name}" → "${targetAtTable.name}.${targetField.name}", func=${func}.`
  );
}

// ---------- Main ----------

async function main() {
  try {
    logInfo('Starting relations & rollups import for NocoDB (mutating – will patch mismatched columns)...');
    logInfo(`Base URL : ${NOCO_BASE_URL}`);
    logInfo(`Base ID  : ${NOCO_BASE_ID}`);
    logInfo(`Schema   : ${SCHEMA_PATH}`);

    const { tablesByName, tablesById } = loadAirtableSchema(SCHEMA_PATH);
    const noco = await fetchNocoTables();

    logInfo(
      `NocoDB tables in base: ${noco.list
        .map((t) => `${t.table_name || t.id} [${t.id}] title="${t.title}"`)
        .join(', ')}`
    );

    const summary = {
      missingTablesInNoco: [],
      extraTablesInNoco: [],
      perTable: {},
    };

    const airtableTableNames = new Set(Object.keys(tablesByName));

    // --- Structural comparison ---

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

    // --- Create / patch relations & virtual fields ---

    console.log('');
    console.log('-----------------------------------------------------');
    logInfo(
      'Creating & patching LinkToAnotherRecord, Lookup, Rollup fields'
    );
    console.log('-----------------------------------------------------');

    for (const [tName, atTable] of Object.entries(tablesByName)) {
      const nocoTable = noco.byTitle.get(tName);
      if (!nocoTable) continue;

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
          const msg = `Error creating / patching link field "${lf.name}" on "${tName}": ${
            err.response?.data ? JSON.stringify(err.response.data) : err.message
          }`;
          logError(msg);
          perTable.relationIssues.push(msg);
        }
      }

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
          const msg = `Error creating / patching lookup field "${lf.name}" on "${tName}": ${
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
          const msg = `Error creating / patching rollup field "${rf.name}" on "${tName}": ${
            err.response?.data ? JSON.stringify(err.response.data) : err.message
          }`;
          logError(msg);
          perTable.virtualIssues.push(msg);
        }
      }

      for (const ff of formulaFields) {
        const msg = `Formula field "${ff.name}" in "${tName}" is not auto-converted. Create a Formula column manually in NocoDB with an equivalent expression if needed.`;
        logWarn(msg);
        perTable.virtualIssues.push(msg);
      }

      summary.perTable[tName] = perTable;
    }

    // --- Summary ---

    console.log('');
    console.log('-----------------------------------------------------');
    logInfo('Post-analysis summary (after create/patch)');
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
        logInfo(`Table "${tableName}" appears aligned (post-creation/patch).`);
        continue;
      }

      console.log('');
      logInfo(`Table "${tableName}" remaining notes:`);

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
        for (const msg of relationIssues) console.log(`    - ${msg}`);
      }
      if (virtualIssues.length) {
        logWarn('  Rollup / lookup / formula issues:');
        for (const msg of virtualIssues) console.log(`    - ${msg}`);
      }
    }

    console.log('');
    logInfo(
      'Relations & rollups migration complete. Mismatched columns were patched to relation/virtual types where possible.'
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
