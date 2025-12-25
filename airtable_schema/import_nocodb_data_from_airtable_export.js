#!/usr/bin/env node
require('./load_env');
/* eslint-disable no-console */
/**
 * Script: import_nocodb_data_from_airtable_export.js
 * Version: 2025-12-24.6
 * =============================================================================
 *  Copyright © 2025 Dank Mushrooms, LLC
 *  Licensed under the GNU General Public License v3 (GPL-3.0-only)
 *
 *  This program is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation, either version 3 of the License.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program. If not, see <https://www.gnu.org/licenses/>.
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
 *   NOCODB_API_VERSION       ("v2" or "v3"; default: "v2")
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

// Shared API client + caller (already configured w/ NOCODB_URL + xc-token)
const apiCall = ENV.apiCall;

// Local log alias (kept separate from load_env.js helpers for backwards compatibility)
const log = (...args) => console.log(...args);

// ------------------------------
// Meta write helpers
// ------------------------------

async function createColumn(tableId, columnPayload, { useLinksApi = false } = {}) {
  // Backwards-compatible wrapper name.
  // Uses the shared helper so request bodies and endpoints match NOCODB_API_VERSION.
  return ENV.createMetaField(tableId, columnPayload, { useLinksApi });
}

function isLinkColumn(c) {
  return ENV.isLinkColumn(c);
}

function isWritableColumn(c) {
  return ENV.isWritableColumn(c);
}

function normalizeColName(c) {
  return ENV.normalizeColName(c);
}

async function ensureAirtableIdColumn(tableMeta, columns) {
  return ENV.ensureAirtableIdColumn(tableMeta, columns);
}

// ------------------------------
// Meta helpers
// ------------------------------

async function fetchTables() {
  const data = await apiCall('get', ENV.META_TABLES);
  const tables = Array.isArray(data?.list) ? data.list : data;
  if (!Array.isArray(tables)) {
    throw new Error(`Unexpected tables response: ${JSON.stringify(data).slice(0, 500)}`);
  }
  return tables;
}

async function fetchTableColumns(tableId) {
  return ENV.fetchTableFields(tableId);
}

async function patchColumn(columnId, payload) {
  // Backwards-compatible wrapper name.
  // Uses the shared helper so endpoints match NOCODB_API_VERSION.
  return ENV.patchMetaField(columnId, payload);
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

// Some NocoDB builds return records as:
//   { id: 1, fields: { colA: ..., airtable_id: ... } }
// Others return flattened:
//   { id: 1, colA: ..., airtable_id: ... }
// Normalize to flattened to keep the rest of the importer consistent.
function flattenNocoRecord(rec) {
  if (!rec || typeof rec !== 'object') return rec;

  // Different builds/endpoints nest row values differently.
  // Prefer the first object-like payload found among common keys.
  const payload =
    (rec.fields && typeof rec.fields === 'object' && rec.fields) ||
    (rec.data && typeof rec.data === 'object' && rec.data) ||
    (rec.row && typeof rec.row === 'object' && rec.row) ||
    (rec.record && typeof rec.record === 'object' && rec.record) ||
    (rec.values && typeof rec.values === 'object' && rec.values) ||
    null;

  if (!payload) return rec;

  // Preserve identifiers on the top-level record, but merge payload into root.
  const out = { ...payload, ...rec };

  // Some builds return the pk under nested payload but not on top-level.
  // After merge, ensure common pk aliases exist at top-level when present.
  if (out.id == null && out.ID != null) out.id = out.ID;
  if (out.id == null && out.Id != null) out.id = out.Id;
  if (out.id == null && out.pk != null) out.id = out.pk;
  if (out.id == null && out.nocopk != null) out.id = out.nocopk;
  
  // Remove nesting keys so later code sees a flat object.
  delete out.fields;
  delete out.data;
  delete out.row;
  delete out.record;
  delete out.values;
  return out;
}

function flattenNocoList(list) {
  if (!Array.isArray(list)) return list;
  return list.map(flattenNocoRecord);
}

function safeStringify(x, maxLen = 800) {
  try {
    const s = typeof x === 'string' ? x : JSON.stringify(x);
    return s.length > maxLen ? s.slice(0, maxLen) + '…' : s;
  } catch {
    const s = String(x);
    return s.length > maxLen ? s.slice(0, maxLen) + '…' : s;
  }
}

function parseVirtualColumnFromError(err) {
  // Observed message patterns include:
  //   Column "foo" is virtual and cannot be updated.
  // Sometimes the JSON body is embedded/escaped inside the thrown Error string.
  const msg = (err && err.message) ? err.message : String(err);
  if (!msg) return null;

  // Try raw match first
  let m = msg.match(/Column\s+"([^"]+)"\s+is\s+virtual\s+and\s+cannot\s+be\s+updated/i);
  if (m && m[1]) return m[1];

  // Try unescaped quotes variant (e.g. Column \"foo\" is virtual...)
  const unescaped = msg.replace(/\\"/g, '"');
  m = unescaped.match(/Column\s+"([^"]+)"\s+is\s+virtual\s+and\s+cannot\s+be\s+updated/i);
  if (m && m[1]) return m[1];

  return null;
}

function stripField(obj, fieldName) {
  if (!obj || typeof obj !== 'object') return obj;
  if (!Object.prototype.hasOwnProperty.call(obj, fieldName)) return obj;
  const copy = { ...obj };
  delete copy[fieldName];
  return copy;
}

// ------------------------------
// Data helpers
// ------------------------------

async function listAllRows(tableId, limit = 1000, fields = []) {
  // v2: { list: [...] } with offset/limit
  // v3: { records: [...], next: "https://...page=2" } with page/pageSize
  if (ENV.IS_V3) {
    let page = 1;
    const out = [];
    while (true) {
      const qs = new URLSearchParams();
      qs.set('page', String(page));
      qs.set('pageSize', String(limit));
      if (Array.isArray(fields) && fields.length) {
        for (const f of fields) {
          if (f && String(f).trim()) qs.append('fields', String(f).trim());
        }
      }
      const data = await apiCall('get', tableRecordsUrl(tableId, qs.toString(), false));
      const rawList = Array.isArray(data?.records) ? data.records : data?.list;
      const list = flattenNocoList(rawList);
      if (!Array.isArray(list)) {
        throw new Error(`Unexpected v3 records response for table ${tableId}: ${safeStringify(data)}`);
      }
      out.push(...list);
      if (!data?.next) break;
      page += 1;
    }
    return out;
  }

  // v2 path (existing behavior)
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
    const data = await apiCall('get', tableRecordsUrl(tableId, qs.toString(), false));
    const rawList = Array.isArray(data?.list) ? data.list : data;
    const list = flattenNocoList(rawList);
    if (!Array.isArray(list)) {
      throw new Error(`Unexpected v2 records response for table ${tableId}: ${safeStringify(data)}`);
    }
    out = out.concat(list);
    if (list.length < limit) break;
    offset += limit;
  }
  return out;
}

async function createOneRow(tableId, rowObj, verifyKey = null) {
  // Different NocoDB builds accept different shapes.
  // Also: some schemas expose virtual/computed columns that appear writable in meta,
  // but fail at insert-time with:
  //   Column "<x>" is virtual and cannot be updated.
  //
  // We auto-strip offending fields and retry.

  const url = tableRecordsUrl(tableId, false, false);
  
  const wantsKey =
    !!verifyKey &&
    rowObj &&
    typeof rowObj === 'object' &&
    Object.prototype.hasOwnProperty.call(rowObj, verifyKey) &&
    rowObj[verifyKey] != null;
  
  const shapes = ENV.IS_V2
    ? [(o) => o, (o) => ({ data: o }), (o) => ({ fields: o })]
    : [(o) => ({ fields: o }), (o) => o, (o) => ({ data: o })];

  let working = rowObj;
  const stripped = new Set();

  for (let attempt = 0; attempt < 10; attempt++) {
    let lastErr = null;

    for (const shapeFn of shapes) {
      try {
        const created = await apiCall('post', url, shapeFn(working));
        
        // Guard against silent "empty row" inserts (seen in some v2 builds).
        if (wantsKey) {
          const flat = flattenNocoRecord(created);
          const echoed = flat ? flat[verifyKey] : null;
          
          // Some builds do NOT echo the inserted fields in the POST response.
          // If we at least have a created row id, verify by GET.
          const createdId = getRowId(flat);
          if (!echoed || String(echoed).trim() !== String(rowObj[verifyKey]).trim()) {
            if (createdId != null) {
              try {
                const after = await getRow(tableId, createdId, [verifyKey]);
                const persisted = after ? after[verifyKey] : null;
                if (persisted && String(persisted).trim() === String(rowObj[verifyKey]).trim()) {
                  return created;
                }
              } catch (_) {
                // ignore readback error; fall through to try next shape
              }
            }
            continue; // try next payload shape
          }
        }
        return created;
     } catch (e) {
       lastErr = e;
     }
    }

    // If we get a virtual column error, strip that field and try again.
    const bad = parseVirtualColumnFromError(lastErr);
    if (bad && !stripped.has(bad) && working && typeof working === 'object') {
      stripped.add(bad);
      working = stripField(working, bad);
      continue;
    }

    // No virtual field found (or already stripped) — bubble the error with context.
    const msg = (lastErr && lastErr.message) ? lastErr.message : String(lastErr);
    throw new Error(
      `createOneRow failed for table ${tableId}. ` +
      `Stripped=[${Array.from(stripped).join(', ')}]. ` +
      `LastError=${msg}`
    );
  }

  throw new Error(`createOneRow exceeded retry budget for table ${tableId}.`);
}

async function createRows(tableId, rows, verifyKey = null) {
  if (!rows.length) return [];

  // IMPORTANT:
  // Bulk insert (POST {data:[...]}) has been observed to create the correct number of rows
  // but with empty field values in some NocoDB builds. To keep imports reliable,
  // we always insert rows one-by-one using createOneRow().
  //const data = await apiCall('post', tableRecordsUrl(tableId, null, false), { data: rows });
  //const list = Array.isArray(data?.list) ? data.list : data;
  //return Array.isArray(list) ? list : [];  
  if (process.env.NOCODB_DEBUG === '1') {
    console.warn('[DEBUG] createRows(): bulk disabled; inserting one-by-one for reliability.');
    console.warn('[DEBUG] First row payload keys:', Object.keys(rows[0] || {}));
  }

  const created = [];
  for (let i = 0; i < rows.length; i++) {
    const r = rows[i];
    try {
      const one = await createOneRow(tableId, r, verifyKey);
      if (one && typeof one === 'object') created.push(one);
    } catch (e) {
      // IMPORTANT: createRows already iterates row-by-row; add row context here.
      // This helps diagnose “why didn’t error handling work?” when createOneRow bubbles.
      const airtableId =
        (r && typeof r === 'object' && (r.airtable_id || r.id || r.Id)) ? (r.airtable_id || r.id || r.Id) : null;
      const msg = (e && e.message) ? e.message : String(e);
      throw new Error(
        `createRows failed for table ${tableId} at row ${i + 1}/${rows.length}` +
        (airtableId ? ` (airtable_id=${airtableId})` : '') +
        `: ${msg}`
      );
    }
  }
  return created;
}

function parseVirtualColumnFromError(err) {
  const msg = (err && err.message) ? String(err.message) : String(err || '');
  // Seen in your logs:
  //   Column "available_from_products" is virtual and cannot be updated.
  const m = msg.match(/Column\s+"([^"]+)"\s+is\s+virtual\s+and\s+cannot\s+be\s+updated/i);
  if (m && m[1]) return m[1];
  return null;
}

function stripColumn(obj, colName) {
  if (!obj || typeof obj !== 'object') return obj;
  if (!Object.prototype.hasOwnProperty.call(obj, colName)) return obj;
  const out = { ...obj };
  delete out[colName];
  return out;
}

async function patchRow(tableId, rowId, fields, useLinksApi = false) {
  // PATCH usually accepts a plain object body, but some builds used { data: {...} }.
  try {
    return await apiCall('patch', tableRecordUrl(tableId, rowId, null, useLinksApi), fields);
  } catch (e) {
    // If NocoDB complains a column is virtual, strip and retry once.
    const badCol = parseVirtualColumnFromError(e);
    if (badCol && fields && typeof fields === 'object' && Object.keys(fields).length) {
      const reduced = stripColumn(fields, badCol);
      if (reduced && Object.keys(reduced).length !== Object.keys(fields).length) {
        log(`  [WARN] patchRow(): stripping virtual/non-writable column "${badCol}" and retrying.`);
        try {
          return await apiCall('patch', tableRecordUrl(tableId, rowId, null, useLinksApi), reduced);
        } catch (_) {
          // fall through to existing fallback shape retry
          fields = reduced;
        }
      }
    }    
    const msg = (e && e.message) ? e.message : String(e);
    debug(`patchRow(plain body) failed, retrying with {data:{...}}: ${msg}`);
    return apiCall('patch', tableRecordUrl(tableId, rowId, null, useLinksApi), { data: fields });
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

// IMPORTANT: This file previously redefined apiFieldName() later and preferred `title`.
// That breaks airtable-export JSON (snake_case keys) and causes empty rows in NocoDB.
// Always use the real API key: column_name (snake_case).
function apiFieldName(col) {
  return (col && (col.column_name || col.name || col.title)) || null;
}

function getField(rec, key) {
  if (!rec || !key) return undefined;
  if (Object.prototype.hasOwnProperty.call(rec, key)) return rec[key];
  // Common nested shapes: fields/data/row/record/values
  for (const nestKey of ['fields', 'data', 'row', 'record', 'values']) {
    const obj = rec[nestKey];
    if (obj && typeof obj === 'object' && Object.prototype.hasOwnProperty.call(obj, key)) {
      return obj[key];
    }
  }
  // Normalized search
  const want = normalizeKey(key);
  for (const [rk, rv] of Object.entries(rec)) {
    if (normalizeKey(rk) === want) return rv;
  }
  for (const nestKey of ['fields', 'data', 'row', 'record', 'values']) {
    const obj = rec[nestKey];
    if (!obj || typeof obj !== 'object') continue;
    for (const [rk, rv] of Object.entries(obj)) {
      if (normalizeKey(rk) === want) return rv;
    }
  }
  return undefined;
}

function getRowId(rec) {
  if (!rec || typeof rec !== 'object') return null;
  // NocoDB row pk can show up under different keys depending on version/build/endpoint:
  //   id / Id / ID / pk / nocopk  (and sometimes only nested)
  return (
    rec.id ??
    rec.Id ??
    rec.ID ??
    rec.pk ??
    rec.nocopk ??
    getField(rec, 'id') ??
    getField(rec, 'Id') ??
    getField(rec, 'ID') ??
    getField(rec, 'pk') ??
    getField(rec, 'nocopk') ??
    null
  );
}

function normalizeKey(s) {
  // normalize to match "Item ID" vs "item_id" vs "item id"
  return String(s || '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '');
}

function findColumnByNormalizedKey(columns, wantNorm) {
  const cols = columns || [];
  for (const c of cols) {
    const cand = [c?.column_name, c?.name, c?.title].filter(Boolean);
    for (const k of cand) {
      if (normalizeKey(k) === wantNorm) return c;
    }
  }
  return null;
}

function getAirtableIdFieldKey(columns) {
  // Prefer the actual API key (column_name/name/title) for the Airtable id column.
  // This avoids silently writing to the wrong key and ending up with NULL airtable_id values,
  // which makes Pass B impossible.
  const col = findColumnByNormalizedKey(columns, 'airtableid');
  if (!col) return 'airtable_id';
  return apiFieldName(col) || 'airtable_id';
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
  
  // Normalized-key fallback: matches "Item ID" vs "item_id" vs "item id"
  const want = new Set(candidates.map(normalizeKey));
  for (const rk of Object.keys(record)) {
    if (want.has(normalizeKey(rk))) return record[rk];
  }
  
  // Case-insensitive fallback (Airtable-export keys are often lowercased)
  const lowerMap = new Map();
  for (const rk of Object.keys(record)) lowerMap.set(rk.toLowerCase(), rk);
  for (const k of candidates) {
    const hit = lowerMap.get(String(k).toLowerCase());
    if (hit && Object.prototype.hasOwnProperty.call(record, hit)) return record[hit];
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


function getDisplayValueColumn(columns) {
  // In v2 meta, the "primary value" column usually carries `pv: true`.
  return (columns || []).find((c) => c?.pv === true) || null;
}

async function getRow(tableId, rowId, fields = []) {
  const qs = new URLSearchParams();
  if (Array.isArray(fields) && fields.length) {
    for (const f of fields) {
      if (f && String(f).trim()) qs.append('fields', String(f).trim());
    }
  }
  const url = tableRecordUrl(tableId, rowId, qs.toString(), false);
  const rec = await apiCall('get', url);
  return flattenNocoRecord(rec);
}

async function patchLinkFieldWithRetry(tableId, rowId, fieldKey, resolvedIds) {
  // Try array-of-ids first; if Noco ignores it, fall back to array-of-{id}.
  await patchRow(tableId, rowId, { [fieldKey]: resolvedIds });
  try {
    const after = await getRow(tableId, rowId, [fieldKey]);
    const v = after?.[fieldKey];
    if (Array.isArray(v) && v.length) return;
  } catch (_) {
    // ignore readback errors; just try fallback
  }
  await patchRow(tableId, rowId, { [fieldKey]: resolvedIds.map((id) => ({ id })) });
}

function pickFieldsForPassA(record, colIndex) {
  // Keep only columns present in NocoDB AND not LinkToAnotherRecord/Links.
  const out = {};
  for (const [k, v] of Object.entries(record || {})) {
    const col = colIndex.byName.get(k) || colIndex.byTitle.get(k);
    if (!col) continue;
    // Critical: do not attempt to write computed/virtual/read-only fields in Pass A
    // (lookups, rollups, formulas, system fields, etc).
    if (!isWritableColumn(col)) continue;
    if (isLinkColumn(col)) continue;

    // Skip null/undefined to avoid overwriting with null unless explicit
    if (typeof v === 'undefined') continue;

    const apiKey = apiFieldName(col);
    if (!apiKey) continue;
    out[apiKey] = v;
  }
  return out;
}

function coerceLinkIds(v) {
  if (!v) return [];
  // ["rec..."]
  if (Array.isArray(v) && v.every((x) => typeof x === 'string' || x == null)) {
    return v.map((x) => String(x || '').trim()).filter(Boolean);
  }
  // [{id:"rec..."}]
  if (Array.isArray(v) && v.length && typeof v[0] === 'object' && v[0] !== null) {
    return v
      .map((o) => (o && (o.id || o.airtable_id || o.record_id)) ? String(o.id || o.airtable_id || o.record_id) : '')
      .map((s) => s.trim())
      .filter(Boolean);
  }
  return [];
}

function extractLinkPayloads(record, linkCols, linkColMap) {
  // Return { fieldName: [airtable_id, ...], ... } for link columns
  const out = {};

  // 1) Direct (old behavior): look up values by column meta
  for (const c of linkCols) {
    const apiKey = apiFieldName(c);
    if (!apiKey) continue;
    const v = readFieldValue(record, c);
    const ids = coerceLinkIds(v);
    if (ids.length) out[apiKey] = ids;
  }
  if (Object.keys(out).length) return out;

  // 2) Heuristic fallback: scan record keys for link-like arrays and match by normalized key
  if (!record || typeof record !== 'object' || !linkColMap) return out;
  for (const [rk, rv] of Object.entries(record)) {
    const ids = coerceLinkIds(rv);
    if (!ids.length) continue;
    const nk = normalizeKey(rk);
    const fieldKey = linkColMap.get(nk);
    if (!fieldKey) continue;
    out[fieldKey] = ids;
  }
  return out;
}

async function buildAirtableIdToRowMaps(tableId, columns) {
  const AIRTABLE_ID_KEY = getAirtableIdFieldKey(columns);
  // IMPORTANT: only fetch minimal fields to avoid NocoDB rollup/lookups exploding on select
  // (e.g. Postgres error "function sum(text) does not exist")
  // NOTE (NocoDB 0.265.1): `fields` can only include *real columns*. `id` is not a column.
  // Ask only for airtable_id; the row identifier still comes back as `id` / `Id` / `nocopk` depending on setup.
  const pvCol = getDisplayValueColumn(columns || []);
  const pvName = pvCol?.column_name || pvCol?.title || pvCol?.name;
  const fieldList = [AIRTABLE_ID_KEY];
  if (pvName && pvName !== 'airtable_id') fieldList.push(pvName);

  let rows = await listAllRows(tableId, 1000, fieldList);

  // Some NocoDB builds accept the fields= filter but do NOT actually return the requested
  // column values (they come back undefined), which makes byAirtableId empty and breaks Pass B.
  // Detect and retry without fields filtering if that happens.
  if (Array.isArray(rows) && rows.length) {
    const anyAirtableId = rows.some((r) => {
      const v = getField(r, AIRTABLE_ID_KEY);
      return v != null && String(v).trim();
    });
    if (!anyAirtableId) {
      debug(`[DEBUG] buildAirtableIdToRowMaps(${tableId}): rows returned but airtable_id missing with fields filter; retrying without fields=...`);
      rows = await listAllRows(tableId, 1000, []);
      if (NOCODB_DEBUG && Array.isArray(rows) && rows.length) {
        // Print a shallow sample so we can see what shape Noco is returning
        const sample = rows[0];
        debug(`[DEBUG] buildAirtableIdToRowMaps(${tableId}): sample keys:`, Object.keys(sample || {}));
        for (const nestKey of ['fields', 'data', 'row', 'record', 'values']) {
          if (sample && sample[nestKey] && typeof sample[nestKey] === 'object') {
            debug(`[DEBUG] buildAirtableIdToRowMaps(${tableId}): sample.${nestKey} keys:`, Object.keys(sample[nestKey]));
          }
        }
      }      
    }

    // IMPORTANT: Some builds omit the row identifier when fields= is present.
    // If we can't resolve ANY row ids, Pass B will always report "no links to update"
    // (because missingRowId=N causes every record to be skipped).
    const anyRowId = rows.some((r) => getRowId(r) != null);
    if (!anyRowId) {
      debug(
        `[DEBUG] buildAirtableIdToRowMaps(${tableId}): rows returned but row id missing with fields filter; retrying without fields=.`
      );
      rows = await listAllRows(tableId, 1000, []);
      if (NOCODB_DEBUG && Array.isArray(rows) && rows.length) {
        const sample = rows[0];
        debug(`[DEBUG] buildAirtableIdToRowMaps(${tableId}): retry(no fields) sample keys:`, Object.keys(sample || {}));
      }
    }    
  }

  const byAirtableId = new Map();
  const byDisplayValue = new Map();
  for (const r of rows) {
    const at = getField(r, AIRTABLE_ID_KEY);
    // NocoDB row identifier varies by endpoint/config:
    // - v2 commonly: `id`
    // - some setups: `Id`
    // - your Postgres schema shows `nocopk` as pk in SQL logs
    const id = getRowId(r);
    if (at && id) byAirtableId.set(String(at), id);
    if (pvName && id) {
      const pv = getField(r, pvName);
      if (pv !== null && typeof pv !== 'undefined' && String(pv).trim()) {
        byDisplayValue.set(String(pv), id);
      }
    }
  }
  return { byAirtableId, byDisplayValue, pvName };
}

/**
 * When running NOCODB_API_VERSION=v2 with NOCODB_API_VERSION_LINKS=v3,
 * the v2 meta endpoint can omit/misclassify LTAR (link) columns in some installs.
 *
 * That leads to:
 *   - linkCols = []
 *   - extractLinkPayloads() always returns {}
 *   - "Pass B: no link fields to update."
 *
 * Fix: merge v2 meta fields with v3(meta-for-links) fields, then detect links.
 */
async function fetchMergedTableFields(tableId, baseColumns = []) {
  // Normalize to array
  let colsV2 = Array.isArray(baseColumns) ? baseColumns : [];

  // If caller gave us nothing, fetch via default meta API (ENV.IS_V3 decides)
  if (!colsV2.length) {
    try {
      colsV2 = await fetchTableFields(tableId);
    } catch (e) {
      colsV2 = [];
    }
  }

  // Always attempt to fetch link-aware meta via LINKS API when available.
  // This is especially important when NOCODB_API_VERSION=v2 and LINKS=v3.
  let colsLinks = [];
  try {
    colsLinks = await fetchTableFields(tableId, { useLinksApi: true });
  } catch (e) {
    colsLinks = [];
    if (NOCODB_DEBUG) {
      debug(`[DEBUG] fetchMergedTableFields(${tableId}): could not fetch link-meta fields via useLinksApi=true: ${e?.message || e}`);
    }
  }

  // Merge by best-effort stable key
  const byKey = new Map();
  const push = (c) => {
    if (!c) return;
    const key =
      (c.id != null ? `id:${String(c.id)}` : null) ||
      (c.column_name ? `col:${String(c.column_name)}` : null) ||
      (c.name ? `name:${String(c.name)}` : null) ||
      (c.title ? `title:${String(c.title)}` : null);
    if (!key) return;
    // Prefer link-meta version if it contains relation options
    const prev = byKey.get(key);
    if (!prev) return void byKey.set(key, c);
    const prevOpt = prev?.colOptions || prev?.options || prev?.column_options;
    const nextOpt = c?.colOptions || c?.options || c?.column_options;
    const prevHasRel = !!(prevOpt?.fk_related_model_id || prevOpt?.fk_mm_model_id);
    const nextHasRel = !!(nextOpt?.fk_related_model_id || nextOpt?.fk_mm_model_id);
    if (!prevHasRel && nextHasRel) byKey.set(key, c);
  };

  for (const c of colsV2) push(c);
  for (const c of colsLinks) push(c);

  const merged = Array.from(byKey.values());
  if (NOCODB_DEBUG) {
    debug(`[DEBUG] fetchMergedTableFields(${tableId}): v2=${colsV2.length}, linkMeta=${colsLinks.length}, merged=${merged.length}`);
  }
  return merged;
}

async function importTable(tableMeta, columns, allTableIdMaps) {
  const tableName = tableMeta?.title || tableMeta?.table_name;
  const tableId = tableMeta?.id;
  if (!tableName || !tableId) return;
  
  // Ensure our natural key exists before we attempt reads with fields=airtable_id
  // (ensureAirtableIdColumn() uses the default meta API)
  columns = await ensureAirtableIdColumn(tableMeta, columns);

  // IMPORTANT: merge in link-aware meta fields (v3 meta) so LTAR/link columns are visible,
  // even when the primary import path is running on v2.
  columns = await fetchMergedTableFields(tableId, columns);

  const AIRTABLE_ID_KEY = getAirtableIdFieldKey(columns);
  debug(`Using Airtable ID field key for ${tableName}: ${AIRTABLE_ID_KEY}`);
 
  const exportRecs = readExportJson(tableName);
  log(`\n== Importing table: ${tableName}  (export records: ${exportRecs.length})`);

  if (!exportRecs.length) {
    log('  [SKIP] No records in export.');
    return;
  }

  const colIndex = buildColumnIndex(columns);
  const linkCols = (columns || []).filter((c) => isLinkColumn(c));

  // If we still didn't detect link columns, emit a very explicit diagnostic
  // because this is the #1 reason links never get applied in Pass B.
  if (!linkCols.length && NOCODB_DEBUG) {
    const sample = (columns || []).slice(0, 15).map((c) => ({
      id: c?.id,
      title: c?.title,
      name: c?.name,
      column_name: c?.column_name,
      uidt: c?.uidt,
      type: c?.type,
    }));
    debug(`[DEBUG] ${tableName}: linkCols=0 after merge. Sample columns:`, sample);
  }
  
  if (NOCODB_DEBUG) {
    const names = linkCols.map((c) => apiFieldName(c)).filter(Boolean);
    debug(`Detected ${linkCols.length} link column(s) on ${tableName}:`, names);
  }

  // Build a normalized lookup map for link columns so "Item ID" matches "item_id"
  const linkColMap = new Map(); // normalized -> apiFieldName
  for (const c of linkCols) {
    const k = apiFieldName(c);
    if (!k) continue;
    linkColMap.set(normalizeKey(k), k);
    if (c?.title) linkColMap.set(normalizeKey(c.title), k);
    if (c?.name) linkColMap.set(normalizeKey(c.name), k);
    if (c?.column_name) linkColMap.set(normalizeKey(c.column_name), k);
  }  

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
    delete fieldsA.airtable_id;
    fieldsA[AIRTABLE_ID_KEY] = airtableId;
    
    debug(`[DEBUG] ${tableName}: PassA payload keys:`, Object.keys(fieldsA));

    const links = extractLinkPayloads(rec, linkCols, linkColMap);

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
      await createRows(tableId, rows, AIRTABLE_ID_KEY);
    }
  } else {
    log('  Pass A: no creates needed.');
  }

  // Refresh map after creates
  const mapAfterObj = await buildAirtableIdToRowMaps(tableId, columns);
  const mapAfter = mapAfterObj.byAirtableId;
  if (NOCODB_DEBUG) debug(`Map after creates (airtable_id -> rowId) size for ${tableName}: ${mapAfter.size}`); 

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
  let passB_missingRowId = 0;
  let passB_linkExtracted = 0;
  for (const rawRec of exportRecs) {
    const { airtableId, fields: rec } = normalizeExportRecord(rawRec);
    if (!airtableId) continue;
    const rowId = mapAfter.get(airtableId);
    if (!rowId) {
      passB_missingRowId += 1;
      continue;
    }

    const links = extractLinkPayloads(rec, linkCols, linkColMap);
    if (!Object.keys(links).length) continue;
    passB_linkExtracted += 1;

    passB_links.push({ rowId, links });
  }

  if (!passB_links.length) {
    log('  Pass B: no link fields to update.');
    if (NOCODB_DEBUG) {
      debug(`Pass B diagnostics for ${tableName}: missingRowId=${passB_missingRowId} linkExtracted=${passB_linkExtracted} linkCols=${linkCols.length}`);
    }    
    return;
  }

  log(`  Pass B: updating link fields for ${passB_links.length} row(s) ...`);

  // For each link field, we need to know the target table to resolve airtable_id -> rowId.
  // In NocoDB meta, Links columns typically include `colOptions` / `options` / `fk_related_model_id`.
  // We'll attempt multiple keys to locate the related table id.
  // Map: fieldName -> { relatedTableId, linkFieldId }
  const linkTargetByField = new Map();

  // IMPORTANT (mixed API versions):
  // When NOCODB_API_VERSION="v2" but NOCODB_API_VERSION_LINKS="v3", we fetch
  // column metadata through v2 meta endpoints, but we *write links* through the
  // v3 links endpoints:
  //   /api/v3/data/{baseId}/{tableId}/links/{linkFieldId}/{recordId}
  //
  // In that v3 URL, {linkFieldId} is NOT the v2 column UUID. It is the v3 field
  // identifier, which (in practice) matches the field API name (column_name).
  // If we pass c.id (v2 UUID) into the v3 path segment, link updates are no-ops.
  //
  // Therefore:
  //   - For v2 links API: use c.id
  //   - For v3 links API: use c.column_name (fallback to name/title)
  
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

    // For v2 link endpoints, we also need the link *field id* (column id).
    // For mixed deployments, c.id may be v2-style while LINKS v3 may require a v3 field id.
    // Pass the strongest identifier we have; load_env.setLinksExact() will resolve refs for v3.
    const linkFieldId = c?.id || c?.column_name || c?.name || c?.title;

    if (relatedTableId && linkFieldId) {
      linkTargetByField.set(field, { relatedTableId, linkFieldId: String(linkFieldId) });
    }
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
    for (const [field, airtableIds] of Object.entries(item.links)) {
      const meta = linkTargetByField.get(field);
      if (!meta?.relatedTableId || !meta?.linkFieldId) {
        debug(`  [WARN] Could not determine related table id for link field ${tableName}.${field}`);
        continue;
      }
      const targetMaps = await getTargetMaps(meta.relatedTableId);
      const byAirtableId = targetMaps.byAirtableId;
      const byDisplayValue = targetMaps.byDisplayValue;

      const resolved = [];
      for (const v of airtableIds || []) {
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

      if (!resolved.length) continue;

      // IMPORTANT: Use the NocoDB v2 links API (record PATCH often doesn't set LTAR reliably).
      // This links each target record id to the source record for that link field.
      if (process.env.NOCODB_DEBUG === '1') {
        const u = ENV.linkRecordsUrl(tableId, meta.linkFieldId, item.rowId);
        console.warn('[DEBUG] setLinksExact url:', u, 'resolved:', resolved.length);
      }      
      await setLinksExact(tableId, meta.linkFieldId, item.rowId, resolved);
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
