#!/usr/bin/env node
require('./load_env');
/* eslint-disable no-console */
/**
 * Script: import_nocodb_data_from_airtable_export.js
 * Version: 2025-12-22.1
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
    offset += limit;
  }
  return out;
}

async function createOneRow(tableId, rowObj) {
  // Different NocoDB builds accept different shapes.
  // Try the plain object first (most common for single row), then fallbacks.
  const url = `/api/v2/tables/${tableId}/records`;
  try {
    return await apiCall('post', url, rowObj);
  } catch (e1) {
    try {
      return await apiCall('post', url, { data: rowObj });
    } catch (e2) {
      return apiCall('post', url, { fields: rowObj });
    }
  }
}

async function createRows(tableId, rows) {
  if (!rows.length) return [];

  // Try bulk first (fast path). In some NocoDB builds, bulk POST may "succeed"
  // but only create 1 empty row (or return a non-bulk payload). Detect and fallback.
  const data = await apiCall('post', `/api/v2/tables/${tableId}/records`, { data: rows });
  const list = Array.isArray(data?.list) ? data.list : (Array.isArray(data) ? data : null);

  if (Array.isArray(list) && list.length === rows.length) {
    return list;
  }

  // Suspicious response: bulk didn't create what we asked for.
  // Fall back to reliable single-row inserts.
  const got = Array.isArray(list) ? list.length : 0;
  console.warn(
    `[WARN] Bulk insert response for table ${tableId} did not match request: requested=${rows.length} got=${got}. Falling back to single inserts.`
  );
  // Optional debug: show first 1-2 rows we attempted
  if (process.env.NOCODB_DEBUG === '1') {
    console.warn('[DEBUG] First row payload keys:', Object.keys(rows[0] || {}));
  }

  const created = [];
  for (const r of rows) {
    const one = await createOneRow(tableId, r);
    if (one && typeof one === 'object') created.push(one);
  }
  return created;
}

async function patchRow(tableId, rowId, fields) {
  // PATCH usually accepts a plain object body, but some builds used { data: {...} }.
  try {
    return await apiCall('patch', `/api/v2/tables/${tableId}/records/${rowId}`, fields);
  } catch (e) {
    const msg = (e && e.message) ? e.message : String(e);
    debug(`patchRow(plain body) failed, retrying with {data:{...}}: ${msg}`);
    return apiCall('patch', `/api/v2/tables/${tableId}/records/${rowId}`, { data: fields });
  }
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
  for (let i = 0; i < arr.length; i += n) out.push(arr.slice(i, i + n));
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

function apiFieldName(col) {
  // For v2 record create/patch payloads, NocoDB expects the *column title*.
  // Using column_name works for some schemas, but silently drops fields for others.
  return (col && (col.title || col.column_name || col.name)) || null;
}

function readFieldValue(record, col) {
  // airtable-export may output field keys in a few forms:
  //  - exact Airtable field name (often matches Noco title)
  //  - snake_case (our generated column_name)
  //  - already-normalized
  // Try a few candidates without being too clever.
  if (!record || !col) return undefined;
  const candidates = [col.title, col.column_name, col.name].filter(Boolean);
  for (const k of candidates) {
    if (Object.prototype.hasOwnProperty.call(record, k)) return record[k];
  }
  return undefined;
}

// Normalize airtable-export record shapes:
//  - Flattened: { airtable_id: "rec..", fieldA: ..., fieldB: ... }
//  - Airtable-like: { id: "rec..", fields: { fieldA: ..., fieldB: ... } }
function normalizeExportRecord(rec) {
  if (!rec || typeof rec !== 'object') {
    return { airtableId: null, fields: {} };
  }

  // Airtable API-style
  if (rec.fields && typeof rec.fields === 'object') {
    const airtableId = typeof rec.id === 'string' && rec.id.startsWith('rec') ? rec.id : null;
    return { airtableId, fields: rec.fields };
  }

  // Flattened style
  const airtableId =
    rec.airtable_id ||
    rec.airtableId ||
    rec.record_id ||
    (typeof rec.id === 'string' && rec.id.startsWith('rec') ? rec.id : null);

  return { airtableId: airtableId || null, fields: rec };
}

function isLinkLikeColumn(col) {
  const t = (col?.uidt || col?.type || '').toString();
  // NocoDB uses 'Links' for LTAR, but other builds/paths sometimes surface related types.
  return (
    t === 'Links' ||
    t === 'LinkToAnotherRecord' ||
    t === 'LinkToAnotherRecords' ||
    t === 'Relation' ||
    t === 'Lookup' ||
    t === 'Rollup'
  );
}

function getDisplayValueColumn(columns) {
  // In v2 meta, the "primary value" column usually carries `pv: true`.
  return (columns || []).find((c) => c?.pv === true) || null;
}

function pickFieldsForPassA(record, colIndex) {
  // Keep only columns present in NocoDB AND not Links uidt.
  const out = {};
  for (const [k, v] of Object.entries(record || {})) {
    const col = colIndex.byName.get(k) || colIndex.byTitle.get(k);
    if (!col) continue;
    if (isLinkLikeColumn(col)) continue;

    // Skip null/undefined to avoid overwriting with null unless explicit
    if (typeof v === 'undefined') continue;

    const apiKey = apiFieldName(col);
    if (!apiKey) continue;
    out[apiKey] = v;
  }
  return out;
}

function extractLinkPayloads(record, linkCols) {
  // Return { fieldName: [airtable_id, ...], ... } limited to link columns
  const out = {};
  for (const c of linkCols) {
    const apiKey = apiFieldName(c);
    if (!apiKey) continue;
    const v = readFieldValue(record, c);
    if (!v) continue;

    // airtable-export emits link fields as arrays of Airtable record ids
    if (Array.isArray(v)) {
      out[apiKey] = v.filter((x) => typeof x === 'string' && x.trim());
    }
  }
  return out;
}

async function buildAirtableIdToRowMaps(tableId, columns) {
  // IMPORTANT: only fetch minimal fields to avoid NocoDB rollup/lookups exploding on select
  // (e.g. Postgres error "function sum(text) does not exist")
  // NOTE (NocoDB 0.265.1): `fields` can only include *real columns*. `id` is not a column.
  // Ask only for airtable_id; the row identifier still comes back as `id` / `Id` / `nocopk` depending on setup.
  const pvCol = getDisplayValueColumn(columns || []);
  const pvName = pvCol?.column_name || pvCol?.title || pvCol?.name;
  const fieldList = ['airtable_id'];
  if (pvName && pvName !== 'airtable_id') fieldList.push(pvName);

  const rows = await listAllRows(tableId, 1000, fieldList);
  const byAirtableId = new Map();
  const byDisplayValue = new Map();
  for (const r of rows) {
    const at = r?.airtable_id;
    // NocoDB row identifier varies by endpoint/config:
    // - v2 commonly: `id`
    // - some setups: `Id`
    // - your Postgres schema shows `nocopk` as pk in SQL logs
    const id = r?.id ?? r?.Id ?? r?.nocopk;
    if (at && id) byAirtableId.set(String(at), id);
    if (pvName && id) {
      const pv = r?.[pvName];
      if (pv !== null && typeof pv !== 'undefined' && String(pv).trim()) {
        byDisplayValue.set(String(pv), id);
      }
    }
  }
  return { byAirtableId, byDisplayValue, pvName };
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
  const linkCols = (columns || []).filter((c) => (c?.uidt || c?.type || '').toString() === 'Links');

  // Existing map for upsert routing
  const existingMapObj = await buildAirtableIdToRowMaps(tableId, columns);
  const existingMap = existingMapObj.byAirtableId;  
  debug(`Existing rows with airtable_id: ${existingMap.size}`);

  const passA_create = [];
  const passA_update = []; // { rowId, fields, linkPayloads }
  const passB_links = [];  // { rowId, links }

  for (const rawRec of exportRecs) {
    const { airtableId, fields: rec } = normalizeExportRecord(rawRec);
    if (!airtableId) {
      debug('Skipping record without Airtable record id', rawRec);
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
  const mapAfterObj = await buildAirtableIdToRowMaps(tableId, columns);
  const mapAfter = mapAfterObj.byAirtableId;

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
  for (const rawRec of exportRecs) {
    const { airtableId, fields: rec } = normalizeExportRecord(rawRec);
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
    // Keys in `item.links` are API field names (prefer title).
    const field = apiFieldName(c);
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
  async function getTargetMaps(relatedTableId) {
    if (allTableIdMaps.has(relatedTableId)) return allTableIdMaps.get(relatedTableId);
    const targetCols = await fetchTableColumns(relatedTableId);
    const m = await buildAirtableIdToRowMaps(relatedTableId, targetCols);
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
      const targetMaps = await getTargetMaps(relatedTableId);
      const byAirtableId = targetMaps.byAirtableId;
      const byDisplayValue = targetMaps.byDisplayValue;

      const resolved = [];
      for (const v of vals || []) {
        const s = String(v || '').trim();
        if (!s) continue;
        let rid = null;
        if (s.startsWith('rec')) {
          rid = byAirtableId.get(s);
        } else {
          rid = byDisplayValue.get(s) || byAirtableId.get(s);
        }
        if (rid) resolved.push(rid);
      }

      // If Airtable had links but target doesn't exist, we still set empty array
      patch[field] = resolved;
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
