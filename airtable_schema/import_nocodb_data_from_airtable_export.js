#!/usr/bin/env node
/* eslint-disable no-console */
/**
 * Script: import_nocodb_data_from_airtable_export.js
 * Version: 2025-12-18.1
 * =============================================================================
 * Imports Airtable table data exported by `airtable-export` (JSON arrays) into an
 * existing NocoDB base where the schema has already been created.
 *
 * Design goals:
 *  - Idempotent: upserts rows using `airtable_id` as the natural key.
 *  - Two-pass import:
 *      Pass A: create/update primitive columns (non-link fields)
 *      Pass B: create/update link fields (LTAR/Links) after rowId maps exist
 *
 * Required env:
 *   NOCODB_URL       e.g. http://localhost:8080
 *   NOCODB_BASE_ID   e.g. p_xxxxxxxx  (from NocoDB UI)
 *   NOCODB_API_TOKEN personal access token (xc-token)
 *
 * Optional env:
 *   AIRTABLE_EXPORT_DIR   default: ./export
 *   NOCODB_BATCH_SIZE     default: 100
 *   NOCODB_DEBUG          default: 0  (set to 1 for verbose logging)
 *   TABLES                comma-separated list of table names to import
 *
 * Notes:
 *  - This script expects each table file to be `${AIRTABLE_EXPORT_DIR}/{table}.json`
 *    and to contain an array of records (the default airtable-export output).
 *  - Link fields in export are typically arrays of Airtable record ids (e.g. ["rec..."]).
 *    We translate those to NocoDB row ids by looking up the target table's rows by
 *    `airtable_id`, then PATCHing the link column with an array of row ids.
 */

const fs = require('fs');
const path = require('path');
const axios = require('axios');

const NOCODB_URL = (process.env.NOCODB_URL || '').toString();
const NOCODB_BASE_ID = (process.env.NOCODB_BASE_ID || '').toString();
const NOCODB_API_TOKEN =
  (process.env.NOCODB_API_TOKEN || process.env.NOCODB_TOKEN || '').toString();

const AIRTABLE_EXPORT_DIR = (process.env.AIRTABLE_EXPORT_DIR || './export').toString();
const NOCODB_BATCH_SIZE = Math.max(
  1,
  parseInt(process.env.NOCODB_BATCH_SIZE || '100', 10) || 100
);
const NOCODB_DEBUG = (process.env.NOCODB_DEBUG || '0').toString() === '1';

if (!NOCODB_URL || !NOCODB_BASE_ID || !NOCODB_API_TOKEN) {
  console.error(
    'ERROR: Missing required env vars. Need NOCODB_URL, NOCODB_BASE_ID, NOCODB_API_TOKEN.'
  );
  process.exit(1);
}

function log(...args) {
  console.log(...args);
}
function debug(...args) {
  if (NOCODB_DEBUG) console.log('[DEBUG]', ...args);
}

const api = axios.create({
  baseURL: NOCODB_URL.replace(/\/$/, ''),
  headers: {
    'xc-token': NOCODB_API_TOKEN,
    'Content-Type': 'application/json',
    accept: 'application/json',
  },
  timeout: 120000,
  validateStatus: () => true,
});

async function apiCall(method, url, data) {
  const res = await api.request({ method, url, data });
  if (res.status >= 200 && res.status < 300) return res.data;
  const payload = res.data ? JSON.stringify(res.data) : res.statusText;
  throw new Error(`${method.toUpperCase()} ${url} -> ${res.status} ${payload}`);
}

// ------------------------------
// Meta write helpers (v2)
// ------------------------------

async function createColumnV2(tableId, columnPayload) {
  // v2: POST /api/v2/meta/tables/{tableId}/columns
  return apiCall('post', `/api/v2/meta/tables/${tableId}/columns`, columnPayload);
}

function normalizeColName(c) {
  return (c?.column_name || c?.name || c?.title || '').toString().trim();
}

async function ensureAirtableIdColumn(tableMeta, columns) {
  const tableId = tableMeta?.id;
  const tableName = tableMeta?.title || tableMeta?.table_name || tableMeta?.name;
  if (!tableId) return columns;

  const has = (columns || []).some((c) => normalizeColName(c) === 'airtable_id');
  if (has) return columns;

  log(`  [INFO] Creating missing column "airtable_id" on table "${tableName}" ...`);
  await createColumnV2(tableId, {
    column_name: 'airtable_id',
    title: 'airtable_id',
    uidt: 'LongText',
    // Keep it simple/portable: not all builds accept 'un' (unique) here.
    // If you want uniqueness enforced at DB level, add a unique index manually later.
  });

  // Re-fetch columns so subsequent logic sees it.
  return fetchTableColumns(tableId);
}

// ------------------------------
// Meta helpers
// ------------------------------

async function fetchTables() {
  // v2 meta list
  const data = await apiCall('get', `/api/v2/meta/bases/${NOCODB_BASE_ID}/tables`);
  const tables = Array.isArray(data?.list) ? data.list : data;
  if (!Array.isArray(tables)) {
    throw new Error(`Unexpected tables response: ${JSON.stringify(data).slice(0, 500)}`);
  }
  return tables;
}

async function fetchTableColumns(tableId) {
  const data = await apiCall('get', `/api/v2/meta/tables/${tableId}`);
  // v2 returns { id, table_name, columns: [...] }
  const cols = data?.columns || data?.fields || data?.list || [];
  if (!Array.isArray(cols)) {
    throw new Error(
      `Unexpected columns response for ${tableId}: ${JSON.stringify(data).slice(0, 500)}`
    );
  }
  return cols;
}

async function patchColumn(columnId, payload) {
  // v2 meta update
  return apiCall('patch', `/api/v2/meta/columns/${columnId}`, payload);
}

async function fixBrokenSumRollupsForTable(tableMeta) {
  const tableName = tableMeta?.title || tableMeta?.table_name || tableMeta?.name;
  const tableId = tableMeta?.id;
  if (!tableId) return { patched: 0, restored: 0, originals: [] };

  const columns = await fetchTableColumns(tableId);
  let patched = 0;
  const originals = [];

  for (const col of columns) {
    const uidt = (col?.uidt || col?.type || '').toString();
    if (uidt !== 'Rollup') continue;
    const fn = (col?.rollup_function || col?.options?.rollup_function || '').toString().toLowerCase();
    if (fn !== 'sum') continue;

    // NocoDB generates SQL like sum(<expression>) for Rollups.
    // If the rollup target column is text/formula, Postgres throws:
    //   "function sum(text) does not exist"
    // This breaks *any* SELECT that includes that rollup, and NocoDB tends to
    // SELECT after inserts/updates, causing imports to fail.
    //
    // Workaround: temporarily change rollup_function to 'count' (works for any type).
    const payload = {
      uidt: 'Rollup',
      title: col.title,
      column_name: col.column_name || col.name || col.title,
      fk_relation_column_id: col.fk_relation_column_id || col.options?.fk_relation_column_id,
      fk_rollup_column_id: col.fk_rollup_column_id || col.options?.fk_rollup_column_id,
      rollup_function: 'count',
    };

    originals.push({
      columnId: col.id,
      rollup_function: fn,
      payload,
      tableName,
    });

    log(`  [INFO] Patching Rollup "${payload.column_name}" on "${tableName}" from sum -> count (temporary) ...`);
    await patchColumn(col.id, payload);
    patched += 1;
  }

  return { patched, originals };
}

async function restoreSumRollups(originals) {
  let restored = 0;
  for (const o of originals) {
    const payload = { ...o.payload, rollup_function: o.rollup_function };
    log(`  [INFO] Restoring Rollup "${payload.column_name}" on "${o.tableName}" back to "${o.rollup_function}" ...`);
    await patchColumn(o.columnId, payload);
    restored += 1;
  }
  return restored;
}

// ------------------------------
// Data helpers
// ------------------------------

async function listAllRows(tableId, limit = 1000, fields = []) {
  // GET /api/v2/tables/{tableId}/records?limit=...&offset=...
  let offset = 0;
  let out = [];
  while (true) {
    const qs = new URLSearchParams();
    qs.set('limit', String(limit));
    qs.set('offset', String(offset));
    // IMPORTANT: NocoDB v2 expects repeated fields params in some builds:
    //   &fields=id&fields=airtable_id
    // Not a single CSV string: &fields=id,airtable_id
    if (Array.isArray(fields) && fields.length) {
      for (const f of fields) {
        if (f && String(f).trim()) qs.append('fields', String(f).trim());
      }
    }

    const data = await apiCall('get', `/api/v2/tables/${tableId}/records?${qs.toString()}`);
    const list = Array.isArray(data?.list) ? data.list : data;
    if (!Array.isArray(list)) {
      throw new Error(
        `Unexpected records response for table ${tableId}: ${JSON.stringify(data).slice(
          0,
          500
        )}`
      );
    }
    out = out.concat(list);
    if (list.length < limit) break;
    offset = limit;
  }
  return out;
}

async function createRows(tableId, rows) {
  if (!rows.length) return [];
  const data = await apiCall('post', `/api/v2/tables/${tableId}/records`, { data: rows });
  const list = Array.isArray(data?.list) ? data.list : data;
  return Array.isArray(list) ? list : [];
}

async function patchRow(tableId, rowId, fields) {
  return apiCall('patch', `/api/v2/tables/${tableId}/records/${rowId}`, { data: fields });
}

// ------------------------------
// Import logic
// ------------------------------

function readExportJson(tableName) {
  const file = path.join(AIRTABLE_EXPORT_DIR, `${tableName}.json`);
  if (!fs.existsSync(file)) {
    throw new Error(`Export file not found: ${file}`);
  }
  const raw = fs.readFileSync(file, 'utf-8');
  const data = JSON.parse(raw);
  if (!Array.isArray(data)) {
    throw new Error(`Expected array JSON in ${file}`);
  }
  return data;
}

function chunk(arr, n) {
  const out = [];
  for (let i = 0; i < arr.length; i = n) out.push(arr.slice(i, i + n));
  return out;
}

function buildColumnIndex(columns) {
  const byTitle = new Map();
  const byName = new Map();
  for (const c of columns) {
    if (c?.title) byTitle.set(c.title, c);
    if (c?.column_name) byName.set(c.column_name, c);
    if (c?.name) byName.set(c.name, c);
  }
  return { byTitle, byName };
}

function pickFieldsForPassA(record, colIndex) {
  // Keep only columns present in NocoDB AND not Links uidt.
  const out = {};
  for (const [k, v] of Object.entries(record || {})) {
    const col = colIndex.byName.get(k) || colIndex.byTitle.get(k);
    if (!col) continue;
    if ((col.uidt || '').toString() === 'Links') continue;

    // Skip null/undefined to avoid overwriting with null unless explicit
    if (typeof v === 'undefined') continue;

    out[k] = v;
  }
  return out;
}

function extractLinkPayloads(record, linkCols) {
  // Return { fieldName: [airtable_id, ...], ... } limited to link columns
  const out = {};
  for (const c of linkCols) {
    const k = c.column_name || c.title || c.name;
    if (!k) continue;
    const v = record?.[k];
    if (!v) continue;

    // airtable-export emits link fields as arrays of Airtable record ids
    if (Array.isArray(v)) {
      out[k] = v.filter((x) => typeof x === 'string' && x.trim());
    }
  }
  return out;
}

async function buildAirtableIdToRowIdMap(tableId) {
  // IMPORTANT: only fetch minimal fields to avoid NocoDB rollup/lookups exploding on select
  // (e.g. Postgres error "function sum(text) does not exist")
  // NOTE (NocoDB 0.265.1): `fields` can only include *real columns*. `id` is not a column.
  // Ask only for airtable_id; the row identifier still comes back as `id` / `Id` / `nocopk` depending on setup.
  const rows = await listAllRows(tableId, 1000, ['airtable_id']);
  const map = new Map();
  for (const r of rows) {
    const at = r?.airtable_id;
    // NocoDB row identifier varies by endpoint/config:
    // - v2 commonly: `id`
    // - some setups: `Id`
    // - your Postgres schema shows `nocopk` as pk in SQL logs
    const id = r?.id ?? r?.Id ?? r?.nocopk;
    if (at && id) map.set(at, id);
  }
  return map;
}

async function importTable(tableMeta, columns, allTableIdMaps) {
  const tableName = tableMeta?.title || tableMeta?.table_name;
  const tableId = tableMeta?.id;
  if (!tableName || !tableId) return;
  
  // Ensure our natural key exists before we attempt reads with fields=airtable_id
  columns = await ensureAirtableIdColumn(tableMeta, columns);  

  const exportRecs = readExportJson(tableName);
  log(`\n== Importing table: ${tableName}  (export records: ${exportRecs.length})`);

  if (!exportRecs.length) {
    log('  [SKIP] No records in export.');
    return;
  }

  const colIndex = buildColumnIndex(columns);
  const linkCols = columns.filter((c) => (c.uidt || '').toString() === 'Links');

  // Existing map for upsert routing
  const existingMap = await buildAirtableIdToRowIdMap(tableId);
  debug(`Existing rows with airtable_id: ${existingMap.size}`);

  const passA_create = [];
  const passA_update = []; // { rowId, fields, linkPayloads }
  const passB_links = [];  // { rowId, links }

  for (const rec of exportRecs) {
    const airtableId = rec?.airtable_id;
    if (!airtableId) {
      debug('Skipping record without airtable_id', rec);
      continue;
    }

    const fieldsA = pickFieldsForPassA(rec, colIndex);
    // Ensure natural key survives
    fieldsA.airtable_id = airtableId;

    const links = extractLinkPayloads(rec, linkCols);

    const rowId = existingMap.get(airtableId);
    if (!rowId) {
      passA_create.push({ fieldsA, links, airtableId });
    } else {
      passA_update.push({ rowId, fieldsA, links, airtableId });
    }
  }

  // Pass A - creates
  if (passA_create.length) {
    log(`  Pass A: creating ${passA_create.length} row(s) in batches of ${NOCODB_BATCH_SIZE} ...`);
    for (const batch of chunk(passA_create, NOCODB_BATCH_SIZE)) {
      const rows = batch.map((x) => x.fieldsA);
      await createRows(tableId, rows);
    }
  } else {
    log('  Pass A: no creates needed.');
  }

  // Refresh map after creates
  const mapAfter = await buildAirtableIdToRowIdMap(tableId);

  // Pass A - updates
  if (passA_update.length) {
    log(`  Pass A: updating ${passA_update.length} row(s) ...`);
    for (const u of passA_update) {
      await patchRow(tableId, u.rowId, u.fieldsA);
    }
  } else {
    log('  Pass A: no updates needed.');
  }

  // Prepare Pass B link updates (using current row ids)
  for (const rec of exportRecs) {
    const airtableId = rec?.airtable_id;
    if (!airtableId) continue;
    const rowId = mapAfter.get(airtableId);
    if (!rowId) continue;

    const links = extractLinkPayloads(rec, linkCols);
    if (!Object.keys(links).length) continue;

    passB_links.push({ rowId, links });
  }

  if (!passB_links.length) {
    log('  Pass B: no link fields to update.');
    return;
  }

  log(`  Pass B: updating link fields for ${passB_links.length} row(s) ...`);

  // For each link field, we need to know the target table to resolve airtable_id -> rowId.
  // In NocoDB meta, Links columns typically include `colOptions` / `options` / `fk_related_model_id`.
  // We'll attempt multiple keys to locate the related table id.
  const linkTargetByField = new Map();
  for (const c of linkCols) {
    const field = c.column_name || c.title || c.name;
    if (!field) continue;

    const opt = c?.colOptions || c?.options || c?.column_options || {};
    const relatedTableId =
      opt?.fk_related_model_id ||
      opt?.relatedTableId ||
      opt?.related_table_id ||
      opt?.fk_mm_model_id ||
      c?.fk_related_model_id ||
      c?.related_table_id;

    if (relatedTableId) linkTargetByField.set(field, relatedTableId);
  }

  // Build missing target maps lazily
  async function getTargetMap(relatedTableId) {
    if (allTableIdMaps.has(relatedTableId)) return allTableIdMaps.get(relatedTableId);
    const m = await buildAirtableIdToRowIdMap(relatedTableId);
    allTableIdMaps.set(relatedTableId, m);
    return m;
  }

  for (const item of passB_links) {
    const patch = {};
    for (const [field, airtableIds] of Object.entries(item.links)) {
      const relatedTableId = linkTargetByField.get(field);
      if (!relatedTableId) {
        debug(`  [WARN] Could not determine related table id for link field ${tableName}.${field}`);
        continue;
      }
      const targetMap = await getTargetMap(relatedTableId);
      const rowIds = airtableIds
        .map((atId) => targetMap.get(atId))
        .filter(Boolean);

      // If Airtable had links but target doesn't exist, we still set empty array
      patch[field] = rowIds;
    }

    if (Object.keys(patch).length) {
      await patchRow(tableId, item.rowId, patch);
    }
  }

  log('  [OK] Done.');
}

async function main() {
  const tables = await fetchTables();
  const tablesByName = new Map();
  for (const t of tables) {
    const name = t?.title || t?.table_name;
    if (name) tablesByName.set(name, t);
  }

  const requested = (process.env.TABLES || '')
    .split(',')
    .map((x) => x.trim())
    .filter(Boolean);

  const tableNames = requested.length ? requested : Array.from(tablesByName.keys()).sort();

  log('Import order:', tableNames.join(', '));
  log(`Export dir: ${AIRTABLE_EXPORT_DIR}`);
  log(`Batch size: ${NOCODB_BATCH_SIZE}`);

  const FIX_SUM_ROLLUPS = (process.env.NOCODB_FIX_SUM_ROLLUPS || '1').toString() !== '0';
  const RESTORE_ROLLUPS = (process.env.NOCODB_RESTORE_ROLLUPS || '0').toString() === '1';
  let rollupOriginals = [];
  
  if (FIX_SUM_ROLLUPS) {
    log('\n[INFO] Pre-flight: scanning for Rollup fields using rollup_function=sum (can break Postgres) ...');
    for (const t of tables) {
      const r = await fixBrokenSumRollupsForTable(t);
      if (r?.originals?.length) rollupOriginals = rollupOriginals.concat(r.originals);
    }
    if (rollupOriginals.length) {
      log(`[INFO] Patched ${rollupOriginals.length} Rollup field(s) from sum -> count to prevent Postgres errors during import.`);
    } else {
      log('[INFO] No sum-based Rollup fields found. Continuing.');
    }
  } else {
    log('[INFO] Pre-flight Rollup fix disabled (NOCODB_FIX_SUM_ROLLUPS=0).');
  }

  const allTableIdMaps = new Map(); // relatedTableId -> Map(airtable_id -> rowId)

  for (const name of tableNames) {
    const t = tablesByName.get(name);
    if (!t) {
      log(`[WARN] Table not found in NocoDB base: ${name} (skipping)`);
      continue;
    }
    const cols = await fetchTableColumns(t.id);
    await importTable(t, cols, allTableIdMaps);
  }

  log('\nAll done.');

  if (RESTORE_ROLLUPS && rollupOriginals.length) {
    log('\n[INFO] Restoring Rollup fields to original rollup_function values ...');
    await restoreSumRollups(rollupOriginals);
    log('[INFO] Rollup restore complete.');
  }

}

main().catch((err) => {
  console.error('FATAL:', err && err.stack ? err.stack : err);
  process.exit(1);
});
