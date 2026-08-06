#!/usr/bin/env node
require('./load_env');
/* eslint-disable no-console */
/**
 * Script: import_nocodb_data_from_airtable_export.js
 * Version: 2026-01-24.3
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
 *   NOCODB_SOURCE_ID         (optional NocoDB data source) 
 *   NOCODB_API_TOKEN personal access token (xc-token) 
 *   NOCODB_API_VERSION       ("v2" or "v3"; default: "v2")
 *
 * OPTIONAL: Postgres SQL export mode (no NocoDB API calls)
 *   If POSTGRES_DATA_SQL_PATH is set, this script will generate INSERT statements
 *   (and, optionally, junction-table inserts for multipleRecordLinks) suitable for
 *   loading into an external Postgres database created by POSTGRES_SQL_PATH from
 *   create_nocodb_schema_full.js.
 *
 *   POSTGRES_DATA_SQL_PATH   e.g. ./postgres/data.sql
 *   POSTGRES_SCHEMA          Optional schema name (default: public)
 *   POSTGRES_INCLUDE_LINK_TABLES  true/false (default: true)
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

// --------------------------------------------
// Postgres SQL export mode
// --------------------------------------------

const POSTGRES_DATA_SQL_PATH = (process.env.POSTGRES_DATA_SQL_PATH || '').toString().trim();
const POSTGRES_SCHEMA = (process.env.POSTGRES_SCHEMA || 'public').toString().trim() || 'public';
const POSTGRES_INCLUDE_LINK_TABLES = ENV.envBool('POSTGRES_INCLUDE_LINK_TABLES', true);
const POSTGRES_MODE = !!POSTGRES_DATA_SQL_PATH;

// CSV mode: generates a psql load script (POSTGRES_DATA_SQL_PATH) plus CSV files.
// Use POSTGRES_DATA_FORMAT=insert to keep the old INSERT-based output.
const POSTGRES_DATA_FORMAT = (process.env.POSTGRES_DATA_FORMAT || 'csv').toString().trim().toLowerCase();
const POSTGRES_CSV_DIR = (process.env.POSTGRES_CSV_DIR || '').toString().trim();

function csvCell(val) {
  // Use \N for NULL to preserve empty-string vs NULL.
  if (val == null) return '\\N';
  if (typeof val === 'number') {
    if (!Number.isFinite(val)) return '\\N';
    return String(val);
  }
  if (typeof val === 'boolean') return val ? 'true' : 'false';
  let s = '';
  if (typeof val === 'string') s = val;
  else s = JSON.stringify(val);
  if (s.includes('"')) s = s.replace(/"/g, '""');
  if (s.includes(',') || s.includes('\n') || s.includes('\r') || s.includes('"')) {
    return '"' + s + '"';
  }
  return s;
}

function writeCsvFile(filePath, headerCols, rowsObjArray) {
  const out = [];
  out.push(headerCols.map(csvCell).join(','));
  for (const row of rowsObjArray) {
    out.push(headerCols.map((c) => csvCell(row[c])).join(','));
  }
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, out.join('\n') + '\n', 'utf8');
}

function pgQuoteIdent(name) {
  return '"' + String(name).replace(/"/g, '""') + '"';
}

function pgQuoteLiteral(val) {
  if (val == null) return 'NULL';
  const s = String(val);
  return "'" + s.replace(/'/g, "''") + "'";
}

function pgValue(val) {
  if (val == null) return 'NULL';
  if (typeof val === 'number') {
    if (!Number.isFinite(val)) return 'NULL';
    return String(val);
  }
  if (typeof val === 'boolean') return val ? 'TRUE' : 'FALSE';
  // Date-ish strings should remain quoted.
  if (typeof val === 'string') return pgQuoteLiteral(val);
  // Arrays/objects -> jsonb
  return pgQuoteLiteral(JSON.stringify(val)) + '::jsonb';
}

function extractAirtableId(rec) {
  return rec?.airtable_id || rec?.id || rec?.AirtableId || null;
}

function extractAirtableFields(rec) {
  // airtable-export JSON is usually either:
  //  A) { id: 'rec...', fields: { ... } }
  //  B) { id: 'rec...', ...fieldValues }
  if (rec && typeof rec === 'object' && rec.fields && typeof rec.fields === 'object') {
    return rec.fields;
  }
  const out = { ...rec };
  delete out.id;
  delete out.createdTime;
  delete out.created_time;
  delete out.lastModifiedTime;
  delete out.last_modified_time;
  delete out.airtable_id;
  return out;
}

function pgColumnsForTable(atTable) {
  const cols = [];
  // Always insert airtable_id so we can attach relations later.
  cols.push('airtable_id');
  for (const atField of atTable.fields || []) {
    const type = (atField?.type || '').toString();
    if (type === 'multipleRecordLinks') continue; // handled via junction tables
    const cn = ENV.normalizeColName(atField?.name || atField?.id);
    if (!cn) continue;
    if (cn === 'airtable_id' || cn === 'nocopk' || cn === 'nocouuid') continue;
    cols.push(cn);
  }
  return cols;
}

function buildAirtableMapsForSchema(schema) {
  const tableIdToTable = {};
  for (const t of schema?.tables || []) {
    if (t && t.id) tableIdToTable[t.id] = t;
  }
  return { tableIdToTable };
}

function generatePostgresInserts(schema, airtableMaps, exportDir, onlyTables = null) {
  const lines = [];
  lines.push('BEGIN;');
  lines.push('');

  const wanted = onlyTables && onlyTables.length
    ? new Set(onlyTables.map((s) => String(s).trim()).filter(Boolean))
    : null;

  // Base table inserts
  for (const atTable of schema.tables || []) {
    const tNameRaw = atTable?.name || atTable?.title || atTable?.id;
    if (wanted && !wanted.has(String(tNameRaw))) continue;
    const tName = ENV.normalizeColName(tNameRaw);
    const qTable = `${pgQuoteIdent(POSTGRES_SCHEMA)}.${pgQuoteIdent(tName)}`;

    const tablePath = path.join(exportDir, `${tNameRaw}.json`);
    if (!fs.existsSync(tablePath)) {
      // Also try normalized name file.
      const alt = path.join(exportDir, `${tName}.json`);
      if (!fs.existsSync(alt)) {
        lines.push(`-- [WARN] Missing export file for table ${tNameRaw}: ${tablePath}`);
        continue;
      }
    }
    const jsonPath = fs.existsSync(tablePath) ? tablePath : path.join(exportDir, `${tName}.json`);
    const raw = fs.readFileSync(jsonPath, 'utf8');
    let records = [];
    try {
      records = JSON.parse(raw);
    } catch (e) {
      lines.push(`-- [WARN] Failed to parse ${jsonPath}: ${e?.message || e}`);
      continue;
    }
    if (!Array.isArray(records) || records.length === 0) continue;

    const cols = pgColumnsForTable(atTable);
    const qCols = cols.map(pgQuoteIdent).join(', ');

    lines.push(`-- Data: ${tNameRaw}`);

    const BATCH = 250;
    for (let i = 0; i < records.length; i += BATCH) {
      const batch = records.slice(i, i + BATCH);
      const valuesSql = [];
      for (const rec of batch) {
        const id = extractAirtableId(rec);
        const fields = extractAirtableFields(rec);
        const rowVals = [];
        for (const c of cols) {
          if (c === 'airtable_id') {
            rowVals.push(pgValue(id));
            continue;
          }
          rowVals.push(pgValue(fields?.[c]));
        }
        valuesSql.push('(' + rowVals.join(', ') + ')');
      }
      lines.push(`INSERT INTO ${qTable} (${qCols}) VALUES\n  ${valuesSql.join(',\n  ')}\nON CONFLICT (airtable_id) DO UPDATE SET ${cols
        .filter((c) => c !== 'airtable_id')
        .map((c) => `${pgQuoteIdent(c)} = EXCLUDED.${pgQuoteIdent(c)}`)
        .join(', ')};`);
      lines.push('');
    }
  }

  // Link/junction table inserts (by airtable_id)
  if (POSTGRES_INCLUDE_LINK_TABLES) {
    for (const atTable of schema.tables || []) {
      const fromNameRaw = atTable?.name || atTable?.title || atTable?.id;
      if (wanted && !wanted.has(String(fromNameRaw))) continue;

      const fromName = ENV.normalizeColName(fromNameRaw);

      const tablePath = path.join(exportDir, `${fromNameRaw}.json`);
      const alt = path.join(exportDir, `${fromName}.json`);
      const jsonPath = fs.existsSync(tablePath) ? tablePath : (fs.existsSync(alt) ? alt : null);
      if (!jsonPath) continue;

      let records = [];
      try {
        records = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
      } catch {
        continue;
      }
      if (!Array.isArray(records) || records.length === 0) continue;

      for (const atField of atTable.fields || []) {
        if ((atField?.type || '').toString() !== 'multipleRecordLinks') continue;

        const linkedTableId =
          atField?.options?.linkedTableId ||
          atField?.options?.linkedTable ||
          atField?.options?.foreignTableId ||
          atField?.options?.foreignTable ||
          null;

        const linked = linkedTableId ? (airtableMaps?.tableIdToTable?.[linkedTableId] || null) : null;
        const toName = ENV.normalizeColName(linked?.name || linked?.title || linked?.id || linkedTableId);
        if (!toName) continue;

        const fieldName = ENV.normalizeColName(atField?.name || atField?.id);
        const joinName = ENV.normalizeColName(`${fromName}__${fieldName}__${toName}`);
        const joinQName = `${pgQuoteIdent(POSTGRES_SCHEMA)}.${pgQuoteIdent(joinName)}`;

        const insertPairs = [];
        for (const rec of records) {
          const fromId = extractAirtableId(rec);
          const fields = extractAirtableFields(rec);
          const arr = fields?.[fieldName] || fields?.[atField?.name] || null;
          if (!Array.isArray(arr) || arr.length === 0) continue;
          for (const toId of arr) {
            if (!toId) continue;
            insertPairs.push([fromId, toId]);
          }
        }

        if (!insertPairs.length) continue;
        lines.push(`-- Link data: ${fromNameRaw}.${atField?.name || atField?.id} -> ${toName}`);
        const BATCH = 500;
        for (let i = 0; i < insertPairs.length; i += BATCH) {
          const batch = insertPairs.slice(i, i + BATCH);
          const valuesSql = batch
            .map(([a, b]) => `(${pgValue(a)}, ${pgValue(b)})`)
            .join(',\n  ');
          lines.push(
            `INSERT INTO ${joinQName} (from_airtable_id, to_airtable_id) VALUES\n  ${valuesSql}\nON CONFLICT DO NOTHING;`
          );
          lines.push('');
        }
      }
    }
  }

  lines.push('COMMIT;');
  lines.push('');
  return lines.join('\n');
}

// Optional: target a specific NocoDB data source (e.g., an attached Postgres source).
// If unset, the script uses the base default source (current behavior).
const NOCODB_SOURCE_ID = (process.env.NOCODB_SOURCE_ID || '').toString().trim();

// If NOCODB_SOURCE_ID is set but the NocoDB instance does not support source-scoped
// table listing APIs, we should *not* silently import data into the base default source.
// Set NOCODB_SOURCE_FALLBACK=true to restore the old 'fall back to unscoped' behavior.
const NOCODB_SOURCE_FALLBACK = /^true$/i.test(process.env.NOCODB_SOURCE_FALLBACK || '');
 
// Source-scoped table listings are typically only exposed via v3 meta.
const SOURCE_META_PREFIX = '/api/v3/meta';

function getErrStatus(err) {
  if (!err) return undefined;
  if (err.response && typeof err.response.status === 'number') return err.response.status;
  if (typeof err.status === 'number') return err.status;
  if (typeof err.statusCode === 'number') return err.statusCode;
  const msg = String(err.message || '');
  const m = msg.match(/status\s*=\s*(\d{3})/i);
  if (m && m[1]) {
    const n = Number(m[1]);
    if (Number.isFinite(n)) return n;
  }
  return undefined;
}

function metaTablesUrl(baseId, { sourceId, forceV3 = false } = {}) {
  const prefix = forceV3 ? SOURCE_META_PREFIX : META_PREFIX;
  if (sourceId) return `${prefix}/bases/${baseId}/sources/${sourceId}/tables`;
  return `${prefix}/bases/${baseId}/tables`;
}

// Shared API client + caller (already configured w/ NOCODB_URL + xc-token)
const apiCall = ENV.apiCall;

// Optional: enable bulk insert (POST {data:[...]}) for speed. Default is OFF for safety.
const ENABLE_BULK_IMPORT = ENV.envBool('NOCODB_ENABLE_BULK_IMPORT', false);

// Local log alias (kept separate from load_env.js helpers for backwards compatibility)
const log = (...args) => console.log(...args);
// Some call sites historically used warn(); keep a stable alias.
const warn = (msg, ...rest) => {
  // Prefer the shared logger if present so output matches other scripts.
  if (ENV && typeof ENV.logWarn === 'function') return ENV.logWarn([msg, ...rest].join(' '));
  return console.warn(`[WARN] ${msg}`, ...rest);
};

// ------------------------------
// Retry + Link retry-queue helpers
// ------------------------------

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function isRetryableApiError(err) {
  const msg = (err && err.message) ? String(err.message) : String(err || '');
  const m = msg.toLowerCase();
  return (
    m.includes('timeout') ||
    m.includes('econnreset') ||
    m.includes('socket hang up') ||
    m.includes('etimedout') ||
    m.includes('ecanceled') ||
    m.includes('502') ||
    m.includes('503') ||
    m.includes('504')
  );
}

async function apiCallWithRetry(method, url, data, { retries = 6, baseDelayMs = 750 } = {}) {
  let attempt = 0;
  while (true) {
    try {
      return await apiCall(method, url, data);
    } catch (err) {
      attempt += 1;
      if (attempt > retries || !isRetryableApiError(err)) throw err;
      const delay = Math.min(30000, baseDelayMs * Math.pow(2, attempt - 1));
      log(`[WARN] Retryable API error on ${method.toUpperCase()} ${url} (attempt ${attempt}/${retries}): ${err?.message || err}`);
      await sleep(delay);
    }
  }
}

// Persisted queue for failed link updates so reruns can pick up where they left off.
// Does NOT require env vars; defaults are used if not provided.
const LINK_RETRY_QUEUE_PATH = process.env.NOCODB_LINK_RETRY_QUEUE_PATH
  ? path.resolve(process.cwd(), process.env.NOCODB_LINK_RETRY_QUEUE_PATH)
  : path.resolve(process.cwd(), '.nocodb_link_retry_queue.json');

function readJsonFileSafe(p, fallback) {
  try {
    if (!fs.existsSync(p)) return fallback;
    const raw = fs.readFileSync(p, 'utf8');
    if (!raw || !raw.trim()) return fallback;
    return JSON.parse(raw);
  } catch (_) {
    return fallback;
  }
}

function writeJsonFileSafe(p, obj) {
  try {
    fs.writeFileSync(p, JSON.stringify(obj, null, 2));
  } catch (e) {
    log(`[WARN] Could not write ${p}: ${e?.message || e}`);
  }
}

function loadLinkRetryQueue() {
  const q = readJsonFileSafe(LINK_RETRY_QUEUE_PATH, []);
  return Array.isArray(q) ? q : [];
}

function saveLinkRetryQueue(queue) {
  if (!Array.isArray(queue)) return;
  writeJsonFileSafe(LINK_RETRY_QUEUE_PATH, queue);
}

function enqueueLinkRetry(queue, item, err) {
  const now = new Date().toISOString();
  const next = {
    ...item,
    attempts: Number(item?.attempts || 0),
    lastError: err ? String(err?.message || err).slice(0, 800) : undefined,
    lastAt: now,
    firstAt: item?.firstAt || now,
  };
  queue.push(next);
}

let LINK_RETRY_QUEUE = null;

async function drainLinkRetryQueue(queue, { maxAttempts = 10 } = {}) {
  if (!Array.isArray(queue) || !queue.length) return;

  const remaining = [];
  for (const job of queue) {
    if (!job) continue;
    const attempts = Number(job.attempts || 0);
    if (attempts >= maxAttempts) {
      remaining.push(job);
      continue;
    }

    try {
      await ENV.setLinksExact({
        tableId: job.tableId,
        linkFieldId: job.linkFieldId,
        recordId: job.recordId,
        desiredIds: job.desiredIds,
        relatedPkName: job.relatedPkName || null,
      });
      // success -> drop
    } catch (err) {
      const updated = {
        ...job,
        attempts: attempts + 1,
        lastError: String(err?.message || err).slice(0, 800),
        lastAt: new Date().toISOString(),
      };
      remaining.push(updated);
      log(`[WARN] Link retry failed (${updated.attempts}/${maxAttempts}) for table=${job.tableName || job.tableId} recordId=${job.recordId} field=${job.field || job.linkFieldId}: ${updated.lastError}`);
      await sleep(500);
    }
  }

  queue.length = 0;
  queue.push(...remaining);
  saveLinkRetryQueue(queue);

  if (queue.length) {
    log(`[WARN] Link retry queue remaining: ${queue.length} item(s) (persisted to ${LINK_RETRY_QUEUE_PATH}).`);
  } else {
    try { if (fs.existsSync(LINK_RETRY_QUEUE_PATH)) fs.unlinkSync(LINK_RETRY_QUEUE_PATH); } catch (_) {}
    log('[OK] Link retry queue drained.');
  }
}

// ------------------------------
// Resume / checkpoint helpers
// ------------------------------
//
// When Pass A runs for many tables, a failure mid-run used to lose the in-memory Pass B job list.
// These helpers let you resume after a failure without losing the Pass B plan.
//
// Env:
//   NOCODB_RESUME=1                 -> enable resume behavior
//   NOCODB_CHECKPOINT_FILE=<path>   -> defaults to .nocodb_import_checkpoint.json
//
const RESUME_ENABLED = ENV.envBool('NOCODB_RESUME', false);
const CHECKPOINT_FILE = (process.env.NOCODB_CHECKPOINT_FILE || '.nocodb_import_checkpoint.json').toString();

function loadCheckpoint() {
  if (!RESUME_ENABLED) return { completedPassA: [], completedPassB: [] };
  try {
    if (!fs.existsSync(CHECKPOINT_FILE)) return { completedPassA: [], completedPassB: [] };
    const raw = fs.readFileSync(CHECKPOINT_FILE, 'utf-8');
    const data = JSON.parse(raw);
    return {
      completedPassA: Array.isArray(data?.completedPassA) ? data.completedPassA : [],
      completedPassB: Array.isArray(data?.completedPassB) ? data.completedPassB : [],
    };
  } catch (_) {
    return { completedPassA: [], completedPassB: [] };
  }
}

function saveCheckpoint(cp) {
  if (!RESUME_ENABLED) return;
  const safe = {
    completedPassA: Array.isArray(cp?.completedPassA) ? cp.completedPassA : [],
    completedPassB: Array.isArray(cp?.completedPassB) ? cp.completedPassB : [],
    updatedAt: new Date().toISOString(),
  };
  try {
    fs.writeFileSync(CHECKPOINT_FILE, JSON.stringify(safe, null, 2));
  } catch (e) {
    console.warn(`[WARN] Could not write checkpoint file ${CHECKPOINT_FILE}: ${e?.message || e}`);
  }
}

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

function isFormulaColumn(col) {
  // v2 meta uses uidt; v3 uses `type` (sometimes also uidt).
  const t = (col && (col.uidt || col.type)) ? String(col.uidt || col.type) : '';
  return t.toLowerCase() === 'formula';
}

function isIntegerDbType(col) {
  // NocoDB meta sometimes includes an underlying DB type hint (dt).
  // We treat int-like types as integer-only (e.g. Postgres bigint/int).
  const dt = String(col?.dt || col?.data_type || '').toLowerCase();
  if (!dt) return false;
  // numeric/decimal/float/double should allow fractional.
  if (dt.includes('numeric') || dt.includes('decimal') || dt.includes('float') || dt.includes('double')) return false;
  return dt.includes('int');
}

function coerceValueForColumn(value, col, warnOnceKey) {
  // Most common hard failure: fractional value being inserted into bigint/int.
  if (value == null) return value;

  const uidt = String(col?.uidt || col?.type || '').toLowerCase();

  if (uidt === 'number' && isIntegerDbType(col)) {
    let n = value;
    if (typeof n === 'string' && n.trim() !== '' && !Number.isNaN(Number(n))) n = Number(n);
    if (typeof n === 'number' && Number.isFinite(n) && !Number.isInteger(n)) {
      // Round to nearest int to keep import moving; legacy source retains original.
      const rounded = Math.round(n);
      const key = warnOnceKey || (col?.column_name || col?.name || col?.title || 'number');
      if (!coerceValueForColumn._warned) coerceValueForColumn._warned = new Set();
      if (!coerceValueForColumn._warned.has(key)) {
        coerceValueForColumn._warned.add(key);
        log(`[WARN] Coercing fractional value -> integer for column "${key}" (dt=${col?.dt || 'unknown'}). Example: ${n} -> ${rounded}`);
      }
      return rounded;
    }
  }

  return value;
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

function metaTablesUrl(baseId, { sourceId, forceV3 = false } = {}) {
  const prefix = forceV3 ? LINK_META_PREFIX : META_PREFIX;
  if (sourceId) return `${prefix}/bases/${baseId}/sources/${sourceId}/tables`;
  return `${prefix}/bases/${baseId}/tables`;
}

async function fetchTables() {
  const baseId = NOCODB_BASE_ID;
  const tryUrls = [];
  if (NOCODB_SOURCE_ID) {
    // Prefer meta v3 for source-scoped listing when available.
    tryUrls.push(metaTablesUrl(baseId, { sourceId: NOCODB_SOURCE_ID, forceV3: true }));
    tryUrls.push(metaTablesUrl(baseId, { sourceId: NOCODB_SOURCE_ID }));
  }
  // Unscoped listing targets the base default source.
  if (!NOCODB_SOURCE_ID || NOCODB_SOURCE_FALLBACK) {
    tryUrls.push(metaTablesUrl(baseId));
  }

  let lastErr;
  for (const url of tryUrls) {
    try {
      const data = await apiCall('get', url);
      const tables = Array.isArray(data?.list) ? data.list : data;
      if (!Array.isArray(tables)) {
        throw new Error(`Unexpected tables response: ${JSON.stringify(data).slice(0, 500)}`);
      }
      return tables;
    } catch (e) {
      lastErr = e;
      const status = e && e.response ? e.response.status : undefined;
      if (NOCODB_SOURCE_ID && (status === 404 || status === 405)) continue;
      throw e;
    }
  }
  if (NOCODB_SOURCE_ID && !NOCODB_SOURCE_FALLBACK) {
    throw new Error(
      `Source-scoped table APIs are not supported by this NocoDB build (or are disabled). ` +
      `Your server returned 404/405 for the /bases/{baseId}/sources/{sourceId}/tables endpoint. ` +
      `To import into a specific Postgres data source, make that data source the BASE DEFAULT in the NocoDB UI, ` +
      `or create a separate base that uses that Postgres source as its only/default source. ` +
      `If you *want* to fall back to the base default source, set NOCODB_SOURCE_FALLBACK=true.`
    );
  }
  throw lastErr || new Error('Failed to fetch meta tables');
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
      const data = await apiCallWithRetry('get', tableRecordsUrl(tableId, qs.toString(), false));
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
    const data = await apiCallWithRetry('get', tableRecordsUrl(tableId, qs.toString(), false));
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

  // Bulk insert (POST {data:[...]}) can be much faster, but some NocoDB builds have
  // been observed to create the correct number of rows with empty field values.
  // Default remains row-by-row for reliability; bulk can be enabled explicitly.
  if (ENABLE_BULK_IMPORT) {
    try {
      const data = await apiCall('post', tableRecordsUrl(tableId, null, false), { data: rows });
      const list = Array.isArray(data?.list) ? data.list : data;
      const created = Array.isArray(list) ? list : [];

      // Lightweight sanity check: if verifyKey is provided, ensure at least one created row
      // includes it (some buggy builds return empty objects / omit fields).
      if (verifyKey && created.length) {
        const ok = created.some((r) => r && typeof r === 'object' && typeof r[verifyKey] !== 'undefined');
        if (!ok) {
          throw new Error(`Bulk insert returned ${created.length} row(s) but none contained verifyKey=${verifyKey}`);
        }
      }

      if (NOCODB_DEBUG) {
        console.warn(`[DEBUG] createRows(): bulk enabled; created ${created.length}/${rows.length} row(s).`);
      }
      return created;
    } catch (e) {
      const msg = (e && e.message) ? e.message : String(e);
      console.warn(`[WARN] Bulk insert failed or looked unsafe; falling back to row-by-row. Reason: ${msg}`);
      // Fall through to row-by-row path below.
    }
  }

  if (NOCODB_DEBUG) {
    console.warn('[DEBUG] createRows(): inserting one-by-one for reliability.');
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
    out[apiKey] = coerceValueForColumn(v, col, apiKey);
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
  // Primary key column name (needed for v2 links payload; many Postgres installs use "nocopk")
  const pkCol = (Array.isArray(columns) ? columns : []).find((c) => {
    if (!c) return false;
    if (c.pk || c.primary_key || c.isPk || c.is_primary_key) return true;
    const name = String(c.column_name || c.name || c.title || '').toLowerCase();
    return name === 'nocopk' || name === 'id';
  });
  const pkName = pkCol ? (pkCol.column_name || pkCol.name || pkCol.title || 'nocopk') : 'nocopk';
  
  // IMPORTANT: only fetch minimal fields to avoid NocoDB rollup/lookups exploding on select
  // (e.g. Postgres error "function sum(text) does not exist")
  // NOTE (NocoDB 0.265.1): `fields` can only include *real columns*. `id` is not a column.
  // Ask only for airtable_id; the row identifier still comes back as `id` / `Id` / `nocopk` depending on setup.
  const pvCol = getDisplayValueColumn(columns || []);
  const pvName = pvCol?.column_name || pvCol?.title || pvCol?.name;
  const fieldList = [AIRTABLE_ID_KEY];

  // Ensure the primary key field is requested when using fields= filters.
  // Some NocoDB builds omit the row identifier unless the pk column is included.
  if (pkName && !fieldList.includes(pkName) && pkName !== AIRTABLE_ID_KEY) fieldList.push(pkName);

  if (pvName && pvName !== 'airtable_id' && pvName !== AIRTABLE_ID_KEY && !fieldList.includes(pvName)) fieldList.push(pvName);

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
  return { byAirtableId, byDisplayValue, pvName, pkName };
}

// ------------------------------
// Link relationship helpers (Pass B)
// ------------------------------

// Cache: (tableId|columnId) -> best ref to use for LINKS endpoint
// - LINKS=v2: wants column UUID-ish id in path
// - LINKS=v3: wants v3 field ref in path (and load_env will resolve to v3 field id)
const _linksFieldRefCache = new Map();

async function resolveLinksFieldRef(tableId, columnId, columnNameHint = null) {
  const cacheKey = `${String(tableId)}|${String(columnId || columnNameHint || '')}`;
  if (_linksFieldRefCache.has(cacheKey)) return _linksFieldRefCache.get(cacheKey);

  // LINKS=v2: the links URL expects the column id in the path.
  if (ENV.LINKS_IS_V2) {
    const ref = columnId || columnNameHint || null;
    _linksFieldRefCache.set(cacheKey, ref);
    return ref;
  }

  // LINKS=v3: prefer an API-name-like ref (column_name / name / title),
  // because setLinksExact() will resolve it to the v3 field id.
  if (columnNameHint && typeof columnNameHint === 'string' && columnNameHint.trim()) {
    const ref = columnNameHint.trim();
    _linksFieldRefCache.set(cacheKey, ref);
    return ref;
  }

  // If we were given a column id (common in _schema_nocodb.json: fk_child_column_id),
  // look up that column and use its column_name.
  try {
    const cols = await fetchTableColumns(tableId);
    const hit = (Array.isArray(cols) ? cols : []).find((c) => String(c?.id) === String(columnId));
    const ref = hit ? (hit.column_name || hit.name || hit.title) : null;
    _linksFieldRefCache.set(cacheKey, ref);
    return ref;
  } catch (_) {
    _linksFieldRefCache.set(cacheKey, null);
    return null;
  }
}

function uniqStrings(arr) {
  const out = [];
  const seen = new Set();
  for (const x of arr || []) {
    const s = String(x);
    if (!s || seen.has(s)) continue;
    seen.add(s);
    out.push(s);
  }
  return out;
}

function normalizeRelationType(rt) {
  if (!rt) return null;
  const s = String(rt).toLowerCase().trim();
  // common nocodb shorthands / variants
  if (s === 'hm' || s.includes('hasmany')) return 'hm';
  if (s === 'bt' || s.includes('belongsto') || s.includes('manytoone')) return 'bt';
  if (s === 'mm' || s.includes('manytomany')) return 'mm';
  if (s === 'oo' || s.includes('onetoone')) return 'oo';
  return s;
}

function parseLinkListIds(cur) {
  // links endpoints return different shapes depending on NOCODB_API_VERSION_LINKS
  const list = Array.isArray(cur?.list) ? cur.list : (Array.isArray(cur) ? cur : null);
  const records = Array.isArray(cur?.records) ? cur.records : (Array.isArray(cur) ? cur : null);
  const src = list || records || [];
  return src
    .map((r) => r?.Id ?? r?.id ?? r?.ID ?? r?.pk ?? r?.nocopk)
    .filter((x) => typeof x !== 'undefined' && x !== null)
    .map((x) => String(x));
}

async function resolveFkColumnName(childTableId, fkColumnId, fkColumnNameHint = null) {
  if (fkColumnNameHint && String(fkColumnNameHint).trim()) return String(fkColumnNameHint).trim();
  if (!childTableId || !fkColumnId) return null;
  const cols = await fetchTableColumns(childTableId);
  const hit = (cols || []).find((c) => String(c?.id) === String(fkColumnId));
  if (!hit) return null;
  return apiFieldName(hit);
}

async function setHasManyExactByForeignKey({
  parentTableId,
  parentRowId,
  linkFieldId,
  childTableId,
  fkColumnId,
  fkColumnNameHint,
  desiredChildIds,
}) {
  // Determine FK column name on child
  const fkColName = await resolveFkColumnName(childTableId, fkColumnId, fkColumnNameHint);
  if (!fkColName) {
    debug(
      `  [WARN] hasMany: unable to resolve fk column name (childTableId=${childTableId}, fkColumnId=${fkColumnId})`
    );
    return;
  }

  // Read current linked children via links endpoint (works even when setting doesn't)
  const cur = await apiCall('get', linkRecordsUrl(parentTableId, linkFieldId, parentRowId));
  const currentIds = new Set(parseLinkListIds(cur));
  const wantIds = new Set((desiredChildIds || []).map((x) => String(x)));

  const toUnlink = [...currentIds].filter((id) => !wantIds.has(String(id)));
  const toLink = [...wantIds].filter((id) => !currentIds.has(String(id)));

  // Unlink: set FK to null on child rows that currently point to this parent, but shouldn't
  for (const childRowId of toUnlink) {
    await patchRow(childTableId, childRowId, { [fkColName]: null });
  }

  // Link: set FK to parentRowId on desired child rows
  for (const childRowId of toLink) {
    await patchRow(childTableId, childRowId, { [fkColName]: parentRowId });
  }
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

async function preparePassBJob(tableMeta, columns, allTableIdMaps) {
  const tableName = tableMeta?.title || tableMeta?.table_name;
  const tableId = tableMeta?.id;
  if (!tableName || !tableId) return null;

  columns = await ensureAirtableIdColumn(tableMeta, columns);
  columns = await fetchMergedTableFields(tableId, columns);

  const exportRecs = readExportJson(tableName);
  if (!exportRecs.length) return null;

  const linkCols = (columns || []).filter((c) => isLinkColumn(c) && ENV.isWritableLinkColumn(c));

  const linkColMap = new Map();
  for (const c of linkCols) {
    const k = apiFieldName(c);
    if (!k) continue;
    linkColMap.set(normalizeKey(k), k);
    if (c?.title) linkColMap.set(normalizeKey(c.title), k);
    if (c?.name) linkColMap.set(normalizeKey(c.name), k);
    if (c?.column_name) linkColMap.set(normalizeKey(c.column_name), k);
  }

  const mapAfterObj = await buildAirtableIdToRowMaps(tableId, columns);
  allTableIdMaps.set(tableId, mapAfterObj);

  return {
    tableMeta,
    tableId,
    tableName,
    columns,
    exportRecs,
    mapAfterObj,
    linkCols,
    linkColMap,
  };
}

async function importTable(tableMeta, columns, allTableIdMaps, opts = {}) {
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
  // Only attempt to write "real" relations. HasMany/Lookup/Rollup are often derived/virtual.
  const linkCols = (columns || []).filter((c) => isLinkColumn(c) && ENV.isWritableLinkColumn(c));


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

    // If the table's PV (display) column is a Formula, we cannot write it directly.
    // To preserve imported Airtable PV values (often dependent on CREATED_TIME()),
    // we write the value into a companion <pv>_legacy text column (created by the schema script),
    // and the PV formula is wrapped to prefer that legacy value when present.
    const pvCol = getDisplayValueColumn(columns);
    if (pvCol && isFormulaColumn(pvCol)) {
      const legacyName = `${pvCol.title || pvCol.column_name || pvCol.name}_legacy`;
      const legacyCol = colIndex.byName.get(legacyName) || colIndex.byTitle.get(legacyName);
      const srcKeyCandidates = [
        pvCol.title,
        pvCol.name,
        pvCol.column_name,
        apiFieldName(pvCol),
      ].filter(Boolean);

      let legacyValue = null;
      for (const k of srcKeyCandidates) {
        if (Object.prototype.hasOwnProperty.call(rec, k) && rec[k] != null && String(rec[k]).trim() !== '') {
          legacyValue = rec[k];
          break;
        }
      }

      if (legacyCol && legacyValue != null) {
        const legacyApiKey = apiFieldName(legacyCol);
        if (legacyApiKey) {
          fieldsA[legacyApiKey] = legacyValue;
        }
      }
    }

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

  // Make sure global maps include this table's final mapping before any Pass B runs.
  allTableIdMaps.set(tableId, mapAfterObj);

  // If we're deferring Pass B globally (recommended), return what Pass B needs.
  if (opts.deferLinks) {
    return {
      tableMeta,
      tableId,
      tableName,
      columns,
      exportRecs,
      mapAfterObj,
      linkCols,
      linkColMap,
    };
  }

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
  // Map: fieldName -> { relatedTableId, linkFieldId, relationType, fkColumnId, fkColumnNameHint }
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

    const relationType =
      normalizeRelationType(opt?.relation_type) ||
      normalizeRelationType(opt?.type) ||
      normalizeRelationType(c?.relation_type) ||
      normalizeRelationType(c?.type) ||
      null;

    const fkColumnId =
      opt?.fk_column_id ||
      opt?.fkColumnId ||
      opt?.fk_child_column_id ||
      opt?.fkChildColumnId ||
      c?.fk_column_id ||
      c?.fkColumnId ||
      null;

    // some builds include a column-name hint for the FK field
    const fkColumnNameHint =
      opt?.fk_column_name ||
      opt?.fkColumnName ||
      opt?.fk_child_column_name ||
      opt?.fkChildColumnName ||
      null;

    // For link endpoints we need:
    //  - LINKS=v2: numeric column id (c.id)
    //  - LINKS=v3: the LTAR api key (usually column_name; sometimes an internal _nc_m2m_* name)
    //
    // IMPORTANT:
    // In mixed deployments (API=v2, LINKS=v3), c.id is often a v2-style id and will not work
    // in the v3 links endpoint path. Prefer column_name/name/title so load_env.setLinksExact()
    // can resolve it to the correct v3 id.
    const linkFieldId = ENV.LINKS_IS_V3
      ? (c?.column_name || c?.name || c?.title)
       : (c?.id || c?.column_name || c?.name || c?.title);

    if (ENV.LINKS_IS_V3 && (!linkFieldId || linkFieldId === c?.id)) {
      // Extra safety: if we somehow ended up using c.id on LINKS=v3, log it loudly.
      // This is the exact regression that causes "no links updated" / silent no-ops.
      debug(
        `[WARN] LINKS=v3: linkFieldId resolved to c.id for ${tableName}.${field}. ` +
        `c.id=${c?.id} column_name=${c?.column_name} title=${c?.title}`
      );
    }

    if (relatedTableId && linkFieldId) {
      linkTargetByField.set(field, {
        relatedTableId,
        linkFieldId,
        relationType,
        fkColumnId,
        fkColumnNameHint,
      });
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
      const resolvedUniq = uniqStrings(resolved);

      // --- IMPORTANT: HasMany (hm) is virtual in NocoDB and not writable.
      // Airtable-export may store the relationship list on the "hm" side (e.g. items.ecommerce = [rec...]).
      // To materialize it, we must update the *child* table’s belongsTo (bt) field (fk_child_column_id).
      //
      // In NocoDB schema meta, hm columns frequently include:
      //   options.fk_child_column_id = <bt field id on the child table>
      // We use that to link each child row back to the parent row.
      if (meta?.relationType === 'hm') {
        if (!meta?.fkColumnId) {
          debug(
            `  [WARN] hm link field missing fkColumnId (fk_child_column_id) for ${tableName}.${field}; ` +
            `cannot materialize hasMany by updating child belongsTo.`
          );
          continue;
        }

        const childLinkFieldRef = await resolveLinksFieldRef(
          meta.relatedTableId,
          meta.fkColumnId,
          meta.fkColumnNameHint
        );
        if (!childLinkFieldRef) {
          debug(
            `  [WARN] Could not resolve child belongsTo field ref for hm ${tableName}.${field}. ` +
            `relatedTableId=${meta.relatedTableId} fkColumnId=${meta.fkColumnId}`
          );
          continue;
        }

        // For each child record, set its belongsTo to exactly [parentRowId]
        for (const childRowId of resolvedUniq) {
          try {
            await setLinksExact(meta.relatedTableId, childLinkFieldRef, childRowId, [item.rowId]);
          } catch (err) {
            log(
              `  [WARN] hm materialization failed for ${tableName}.${field}: ` +
              `childTable=${meta.relatedTableId} childRowId=${childRowId} parentRowId=${item.rowId}: ` +
              `${err?.message || err}`
            );
            if (LINK_RETRY_QUEUE) {
              enqueueLinkRetry(
                LINK_RETRY_QUEUE,
                {
                  tableId: meta.relatedTableId,
                  tableName: String(meta.relatedTableId),
                  field: String(childLinkFieldRef),
                  linkFieldId: String(childLinkFieldRef),
                  recordId: String(childRowId),
                  desiredIds: [String(item.rowId)],
                  relatedPkName: null,
                },
                err
              );
              saveLinkRetryQueue(LINK_RETRY_QUEUE);
            }            
            if (NOCODB_DEBUG) debug(err);
          }
        }
        continue;
      }

      // Normal writable relations (bt/mm/oo):
      // Use links endpoints to set the source record’s link field to the desired related ids.
      if (process.env.NOCODB_DEBUG === '1') {
        const u = ENV.linkRecordsUrl(tableId, meta.linkFieldId, item.rowId);
          console.warn('[DEBUG] setLinksExact url:', u, 'resolved:', resolvedUniq.length);
      }      

      const rt = normalizeRelationType(meta.relationType);

      // hasMany: setting the virtual link field often does nothing.
      // The reliable approach is to patch the child's FK column to the parent row id.
      // (We still use the links endpoint only to *read* current children for exactness.)
      if (rt === 'hm' && meta.fkColumnId) {
        await setHasManyExactByForeignKey({
          parentTableId: tableId,
          parentRowId: item.rowId,
          linkFieldId: meta.linkFieldId,
          childTableId: meta.relatedTableId,
          fkColumnId: meta.fkColumnId,
          fkColumnNameHint: meta.fkColumnNameHint,
          desiredChildIds: resolvedUniq,
        });
        continue;
      }

      // belongsTo / one-to-one: treat as singular
      if ((rt === 'bt' || rt === 'oo') && resolved.length > 1) {
        try {  
          await ENV.setLinksExact({
            tableId,
            linkFieldId: meta.linkFieldId,
            recordId: item.rowId,
            desiredIds: [resolvedUniq[0]],
            // For LINKS=v2, payload must include the related table PK column name.
            // buildAirtableIdToRowMaps() detects it from the related table meta.
            relatedPkName: targetMaps.pkName,
          });          
  
        } catch (err) {
          log(`  [WARN] Link update failed for ${tableName}.${field} rowId=${item.rowId}: ${err?.message || err}`);
          if (LINK_RETRY_QUEUE) {
            enqueueLinkRetry(
              LINK_RETRY_QUEUE,
              {
                tableId,
                tableName,
                field,
                linkFieldId: meta.linkFieldId,
                recordId: item.rowId,
                desiredIds: (rt === 'bt' || rt === 'oo') ? [resolvedUniq[0]] : resolvedUniq,
                relatedPkName: targetMaps.pkName,
              },
              err
            );
            saveLinkRetryQueue(LINK_RETRY_QUEUE);
          }
          if (NOCODB_DEBUG) debug(err);
        }        
        
        continue;
      }
      
      try {  
        // many-to-many (and unknown): use links API exact-set
        // IMPORTANT: Use the NocoDB links API (record PATCH often doesn't set LTAR reliably).
        await ENV.setLinksExact({
          tableId,
          linkFieldId: meta.linkFieldId,
          recordId: item.rowId,
          desiredIds: resolvedUniq,
          // For LINKS=v2, payload must include the related table PK column name.
          // buildAirtableIdToRowMaps() detects it from the related table meta.
          relatedPkName: targetMaps.pkName,
        });         
      } catch (err) {
        log(`  [WARN] Link update failed for ${tableName}.${field} rowId=${item.rowId}: ${err?.message || err}`);
        if (LINK_RETRY_QUEUE) {
          enqueueLinkRetry(
            LINK_RETRY_QUEUE,
            {
              tableId,
              tableName,
              field,
              linkFieldId: meta.linkFieldId,
              recordId: item.rowId,
              desiredIds: (rt === 'bt' || rt === 'oo') ? [resolvedUniq[0]] : resolvedUniq,
              relatedPkName: targetMaps.pkName,
            },
            err
          );
          saveLinkRetryQueue(LINK_RETRY_QUEUE);
        }
        if (NOCODB_DEBUG) debug(err);
      }
    }
  }

  log('  [OK] Done.');
}

async function runPassB(job, allTableIdMaps) {
  if (!job) return;
  const {
    tableMeta,
    tableId,
    tableName,
    columns,
    exportRecs,
    mapAfterObj,
    linkCols,
    linkColMap,
  } = job;

  // Safety: ensure we have final map for this table registered
  if (mapAfterObj) allTableIdMaps.set(tableId, mapAfterObj);

  if (!linkCols || !linkCols.length) {
    log(`  Pass B: no writable link fields to update for ${tableName}.`);
    return;
  }

  const mapAfter = mapAfterObj?.byAirtableId || new Map();

  const passB_links = [];
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
    log(`  Pass B: no link values found to apply for ${tableName}.`);
    if (NOCODB_DEBUG) {
      debug(
        `Pass B diagnostics for ${tableName}: missingRowId=${passB_missingRowId} linkExtracted=${passB_linkExtracted} linkCols=${linkCols.length}`
      );
    }
    return;
  }

  log(`  Pass B: updating link fields for ${passB_links.length} row(s) ...`);

  // Map: fieldName -> { relatedTableId, linkFieldId }
  const linkTargetByField = new Map();
  for (const c of linkCols) {
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

    // IMPORTANT: allow non-id refs; load_env.setLinksExact will resolve for v3 if needed
    const linkFieldId = c?.id || c?.column_name || c?.name || c?.title || field;
    if (relatedTableId && linkFieldId) {
      linkTargetByField.set(field, { relatedTableId, linkFieldId });
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
      if (!meta) continue;

      const targetMaps = await getTargetMaps(meta.relatedTableId);
      const byAirtableId = targetMaps?.byAirtableId || new Map();

      const resolved = (airtableIds || [])
        .map((aid) => byAirtableId.get(aid))
        .filter((x) => x !== undefined && x !== null)
        .map((x) => String(x));

      if (!resolved.length) continue;

      try {
        await setLinksExact(tableId, meta.linkFieldId, item.rowId, resolved);
      } catch (e) {
        log(`  [WARN] Link update failed for ${tableName}.${field} rowId=${item.rowId}: ${e?.message || e}`);
        if (NOCODB_DEBUG) debug(e);
      }
    }
  }

  log(`  [OK] Pass B complete for ${tableName}.`);
}

async function main() {
  if (POSTGRES_MODE) {
    const schemaPath = ENV.SCHEMA_PATH || path.join(AIRTABLE_EXPORT_DIR, '_schema.json');
    if (!fs.existsSync(schemaPath)) {
      throw new Error(`SCHEMA_PATH does not exist: ${schemaPath}`);
    }
    const schema = JSON.parse(fs.readFileSync(schemaPath, 'utf8'));
    const airtableMaps = buildAirtableMapsForSchema(schema);

    const requested = (process.env.TABLES || '')
      .split(',')
      .map((x) => x.trim())
      .filter(Boolean);

    const outPath = path.resolve(process.cwd(), POSTGRES_DATA_SQL_PATH);
    const outDir = path.dirname(outPath);

    if (POSTGRES_DATA_FORMAT === 'insert') {
      const sql = generatePostgresInserts(schema, airtableMaps, AIRTABLE_EXPORT_DIR, requested);
      fs.mkdirSync(outDir, { recursive: true });
      fs.writeFileSync(outPath, sql, 'utf8');
      log(`[INFO] Postgres data SQL written to: ${outPath}`);
      return;
    }

    // Default: CSV + psql \copy load script
    const csvDir = POSTGRES_CSV_DIR
      ? path.resolve(process.cwd(), POSTGRES_CSV_DIR)
      : path.join(outDir, 'csv');
    fs.mkdirSync(csvDir, { recursive: true });

    const loadLines = [];
    loadLines.push('BEGIN;');
    loadLines.push('');

    for (const atTable of schema.tables || []) {
      const tNameRaw = atTable?.name || atTable?.title || atTable?.id;
      if (requested.length && !requested.includes(String(tNameRaw))) continue;
      const tName = ENV.normalizeColName(tNameRaw);
      const qTable = `${pgQuoteIdent(POSTGRES_SCHEMA)}.${pgQuoteIdent(tName)}`;

      const tablePath = path.join(AIRTABLE_EXPORT_DIR, `${tNameRaw}.json`);
      const alt = path.join(AIRTABLE_EXPORT_DIR, `${tName}.json`);
      const jsonPath = fs.existsSync(tablePath) ? tablePath : (fs.existsSync(alt) ? alt : null);
      if (!jsonPath) {
        loadLines.push(`-- [WARN] Missing export file for table ${tNameRaw}`);
        loadLines.push('');
        continue;
      }

      let records;
      try {
        records = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
      } catch (e) {
        loadLines.push(`-- [WARN] Failed to parse ${jsonPath}: ${e?.message || e}`);
        loadLines.push('');
        continue;
      }
      if (!Array.isArray(records) || records.length === 0) continue;

      const cols = pgColumnsForTable(atTable);
      // Dedupe columns case-insensitively to avoid "column specified more than once".
      const seen = new Set();
      const colsDedup = [];
      for (const c of cols) {
        const k = String(c).toLowerCase();
        if (seen.has(k)) continue;
        seen.add(k);
        colsDedup.push(c);
      }

      const rows = [];
      for (const rec of records) {
        const id = extractAirtableId(rec);
        const fields = extractAirtableFields(rec);
        const row = {};
        for (const c of colsDedup) {
          if (c === 'airtable_id') row[c] = id;
          else row[c] = fields?.[c];
        }
        rows.push(row);
      }

      const csvFile = path.join(csvDir, `${tName}.csv`);
      writeCsvFile(csvFile, colsDedup, rows);
      const relCsv = path.relative(outDir, csvFile).replace(/\\/g, '/');

      loadLines.push(`-- Data: ${tNameRaw}`);
      loadLines.push(
        `\\copy ${qTable} (${colsDedup.map(pgQuoteIdent).join(', ')}) FROM '${relCsv}' WITH (FORMAT csv, HEADER true, NULL '\\\\N');`
      );
      loadLines.push('');
    }

    // Junction tables (links)
    if (POSTGRES_INCLUDE_LINK_TABLES) {
      for (const atTable of schema.tables || []) {
        const fromNameRaw = atTable?.name || atTable?.title || atTable?.id;
        if (requested.length && !requested.includes(String(fromNameRaw))) continue;
        const fromName = ENV.normalizeColName(fromNameRaw);

        const tablePath = path.join(AIRTABLE_EXPORT_DIR, `${fromNameRaw}.json`);
        const alt = path.join(AIRTABLE_EXPORT_DIR, `${fromName}.json`);
        const jsonPath = fs.existsSync(tablePath) ? tablePath : (fs.existsSync(alt) ? alt : null);
        if (!jsonPath) continue;

        let records;
        try {
          records = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
        } catch {
          continue;
        }
        if (!Array.isArray(records) || records.length === 0) continue;

        for (const atField of atTable.fields || []) {
          if ((atField?.type || '').toString() !== 'multipleRecordLinks') continue;

          const linkedTableId =
            atField?.options?.linkedTableId ||
            atField?.options?.linkedTable ||
            atField?.options?.foreignTableId ||
            atField?.options?.foreignTable ||
            null;

          const linked = linkedTableId ? (airtableMaps?.tableIdToTable?.[linkedTableId] || null) : null;
          const toName = ENV.normalizeColName(linked?.name || linked?.title || linked?.id || linkedTableId);
          if (!toName) continue;

          const fieldName = ENV.normalizeColName(atField?.name || atField?.id);
          const joinName = ENV.normalizeColName(`${fromName}__${fieldName}__${toName}`);
          const joinQName = `${pgQuoteIdent(POSTGRES_SCHEMA)}.${pgQuoteIdent(joinName)}`;

          const pairs = [];
          for (const rec of records) {
            const fromId = extractAirtableId(rec);
            const fields = extractAirtableFields(rec);
            const arr = fields?.[fieldName] || fields?.[atField?.name] || null;
            if (!Array.isArray(arr) || arr.length === 0) continue;
            for (const toId of arr) {
              if (!toId) continue;
              pairs.push({ from_airtable_id: fromId, to_airtable_id: toId });
            }
          }
          if (!pairs.length) continue;

          const linkCols = ['from_airtable_id', 'to_airtable_id'];
          const csvFile = path.join(csvDir, `${joinName}.csv`);
          writeCsvFile(csvFile, linkCols, pairs);
          const relCsv = path.relative(outDir, csvFile).replace(/\\/g, '/');

          loadLines.push(`-- Link data: ${fromNameRaw}.${atField?.name || atField?.id} -> ${toName}`);
          loadLines.push(
            `\\copy ${joinQName} (${linkCols.map(pgQuoteIdent).join(', ')}) FROM '${relCsv}' WITH (FORMAT csv, HEADER true, NULL '\\\\N');`
          );
          loadLines.push('');
        }
      }
    }

    loadLines.push('COMMIT;');
    loadLines.push('');

    fs.mkdirSync(outDir, { recursive: true });
    fs.writeFileSync(outPath, loadLines.join('\n'), 'utf8');
    log(`[INFO] Postgres load script written to: ${outPath}`);
    log(`[INFO] Postgres CSV directory: ${csvDir}`);
    return;
  }

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

  // Load any persisted failed link updates from previous runs.
  LINK_RETRY_QUEUE = loadLinkRetryQueue();
  if (LINK_RETRY_QUEUE.length) {
    log(`[INFO] Loaded ${LINK_RETRY_QUEUE.length} link retry item(s) from ${LINK_RETRY_QUEUE_PATH}.`);
  }

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

  const allTableIdMaps = new Map();
  const passBJobs = [];
  const checkpoint = loadCheckpoint();
  const completedPassA = new Set(checkpoint.completedPassA || []);
  const completedPassB = new Set(checkpoint.completedPassB || []);

  if (RESUME_ENABLED) {
    log(`\n[INFO] Resume enabled. Checkpoint file: ${CHECKPOINT_FILE}`);
    if (completedPassA.size) log(`[INFO] Pass A already completed for: ${Array.from(completedPassA).join(', ')}`);
    if (completedPassB.size) log(`[INFO] Pass B already completed for: ${Array.from(completedPassB).join(', ')}`);
  }

  // Pass A for ALL tables first
  for (const tableName of tableNames) {
    const tableMeta = tablesByName.get(tableName);
    if (!tableMeta) {
      log(`  [WARN] Table not found in base: ${tableName}`);
      continue;
    }
    const columns = await fetchTableColumns(tableMeta.id);
    let job = null;

    if (RESUME_ENABLED && completedPassA.has(tableName)) {
      // Pass A was already completed in a prior run; just prepare the Pass B job using current DB state.
      job = await preparePassBJob(tableMeta, columns, allTableIdMaps);
    } else {
      job = await importTable(tableMeta, columns, allTableIdMaps, { deferLinks: true });
      if (RESUME_ENABLED) {
        completedPassA.add(tableName);
        saveCheckpoint({ completedPassA: Array.from(completedPassA), completedPassB: Array.from(completedPassB) });
      }
    }

    if (job) passBJobs.push(job);
  }

  // Pass B for ALL tables after Pass A has fully populated row-id maps
  log(`\n=== Starting Pass B for ${passBJobs.length} table(s) (after Pass A for all tables) ===\n`);
  for (const job of passBJobs) {
    const tn = job?.tableName || job?.tableMeta?.title || job?.tableMeta?.table_name;
    if (RESUME_ENABLED && tn && completedPassB.has(tn)) {
      log(`  [SKIP] Pass B already completed for ${tn} (checkpoint).`);
      continue;
    }
    await runPassB(job, allTableIdMaps);
    if (RESUME_ENABLED && tn) {
      completedPassB.add(tn);
      saveCheckpoint({ completedPassA: Array.from(completedPassA), completedPassB: Array.from(completedPassB) });
    }
  }

  log('\nAll done.');

  if (RESTORE_ROLLUPS && rollupOriginals.length) {
    log('\n[INFO] Restoring Rollup fields to original rollup_function values ...');
    await restoreSumRollups(rollupOriginals);
    log('[INFO] Rollup restore complete.');
  }

  // Best-effort: retry any failed link updates (and persist any remaining).
  if (LINK_RETRY_QUEUE && LINK_RETRY_QUEUE.length) {
    log(`
[INFO] Retrying ${LINK_RETRY_QUEUE.length} queued link update(s) ...`);
    await drainLinkRetryQueue(LINK_RETRY_QUEUE);
  }

}

main().catch((err) => {
  console.error('FATAL:', err && err.stack ? err.stack : err);
  process.exit(1);
});
