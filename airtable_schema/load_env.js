#!/usr/bin/env node
/* eslint-disable no-console */
/**
 * Script: load_env.js
 * Version: 2025-12-25.1
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
 * Shared environment + API helpers for the airtable_schema scripts.
 *
 * Goals:
 *  - Zero external deps (no dotenv package)
 *  - Load `${__dirname}/.env` if present
 *  - Provide a single axios instance + apiCall helper
 *  - Centralize NocoDB API version branching (v2 vs v3), including an optional
 *    separate version just for link operations.
 */

const fs = require('fs');
const path = require('path');
const axios = require('axios');

// ---------------------------------------------------------------------------
// Minimal .env loader
// ---------------------------------------------------------------------------

function stripQuotes(v) {
  const s = String(v);
  if ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'"))) {
    return s.slice(1, -1);
  }
  return s;
}

function loadDotEnv(envPath = path.join(__dirname, '.env')) {
  try {
    if (!fs.existsSync(envPath)) return;
    const raw = fs.readFileSync(envPath, 'utf-8');

    for (const line of raw.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) continue;

      const eq = trimmed.indexOf('=');
      if (eq === -1) continue;

      const key = trimmed.slice(0, eq).trim();
      let val = trimmed.slice(eq + 1).trim();

      // Remove inline comments for unquoted values
      if (!(val.startsWith('"') || val.startsWith("'"))) {
        const hash = val.indexOf(' #');
        if (hash !== -1) val = val.slice(0, hash).trim();
        const hash2 = val.indexOf('\t#');
        if (hash2 !== -1) val = val.slice(0, hash2).trim();
        if (val.includes('#')) {
          const h = val.indexOf('#');
          if (h !== -1) val = val.slice(0, h).trim();
        }
      }

      val = stripQuotes(val);
      if (!key) continue;

      if (typeof process.env[key] === 'undefined') {
        process.env[key] = val;
      }
    }
  } catch (err) {
    // Fail-quietly; scripts should still run with explicit env vars
    // eslint-disable-next-line no-console
    console.warn('[WARN] Failed to load .env:', err?.message || err);
  }
}

// Load immediately when required
loadDotEnv();

// ---------------------------------------------------------------------------
// ENV + VERSION SWITCHING
// ---------------------------------------------------------------------------

const NOCODB_URL = (process.env.NOCODB_URL || process.env.NC_URL || 'http://localhost:8080').toString();
const NOCODB_BASE_ID = (process.env.NOCODB_BASE_ID || '').toString();
const NOCODB_API_TOKEN = (
  process.env.NOCODB_API_TOKEN ||
  process.env.NOCODB_AUTH_TOKEN ||
  process.env.NOCODB_TOKEN ||
  process.env.NC_TOKEN ||
  ''
).toString();

const AIRTABLE_EXPORT_DIR = (
  process.env.AIRTABLE_EXPORT_DIR || path.join(process.cwd(), 'export')
).toString();

const SCHEMA_PATH = (
  process.env.SCHEMA_PATH || path.join(AIRTABLE_EXPORT_DIR, '_schema.json')
).toString();

const NOCODB_API_VERSION =
  (process.env.NOCODB_API_VERSION || 'v2').toString().toLowerCase();

// Optional per-feature API version for Link creation.
// If NOCODB_API_VERSION_LINKS is not set, we fall back to NOCODB_API_VERSION.
const NOCODB_API_VERSION_LINKS =
  (process.env.NOCODB_API_VERSION_LINKS || NOCODB_API_VERSION)
    .toString()
    .toLowerCase();

function isV3Token(v) {
  const s = String(v || '').toLowerCase();
  return s === '3' || s === 'v3' || s === 'api_v3' || s === 'v3.0' || s === 'v03';
}

const IS_V3 = isV3Token(NOCODB_API_VERSION);
const IS_V2 = !IS_V3;
const LINKS_IS_V3 = isV3Token(NOCODB_API_VERSION_LINKS);
const LINKS_IS_V2 = !LINKS_IS_V3;

const NOCODB_BATCH_SIZE = Math.max(
  1,
  parseInt(process.env.NOCODB_BATCH_SIZE || '100', 10) || 100
);
const NOCODB_DEBUG = (process.env.NOCODB_DEBUG || '0').toString() === '1';

const META_PREFIX = IS_V2 ? '/api/v2/meta' : '/api/v3/meta';

// Data APIs:
// - v2: /api/v2/tables/{tableId}/records
// - v3: /api/v3/data/{baseId}/{tableId}/records
const DATA_PREFIX = IS_V2 ? '/api/v2' : `/api/v3/data/${NOCODB_BASE_ID}`;
const LINK_DATA_PREFIX = LINKS_IS_V2 ? '/api/v2' : `/api/v3/data/${NOCODB_BASE_ID}`;


// ---------------------------------------------------------------------------
// Endpoint helpers (used by multiple scripts)
// ---------------------------------------------------------------------------

// v2 & v3 share the same base tables list shape
const META_TABLES = `${META_PREFIX}/bases/${NOCODB_BASE_ID}/tables`;

// Field creation endpoint differs between v2 & v3.
const META_TABLE_FIELDS = (tableId) =>
  IS_V2
    ? `${META_PREFIX}/tables/${tableId}/columns`
    : `${META_PREFIX}/bases/${NOCODB_BASE_ID}/tables/${tableId}/fields`;

// Field patch/delete endpoint differs in v2 vs v3
const META_FIELD = (fieldId) =>
  IS_V2
    ? `${META_PREFIX}/columns/${fieldId}`
    : `${META_PREFIX}/bases/${NOCODB_BASE_ID}/fields/${fieldId}`;
    
// Link-specific meta endpoints so we can talk to v3 for links even when the
// rest of the script uses v2 meta APIs.
const LINK_META_PREFIX = LINKS_IS_V2 ? '/api/v2/meta' : '/api/v3/meta';

// Link-specific versions (when you need to create/edit link fields)
const LINK_META_TABLE_FIELDS = (tableId) =>
  LINKS_IS_V2
    ? `${LINK_META_PREFIX}/tables/${tableId}/columns`
    : `${LINK_META_PREFIX}/bases/${NOCODB_BASE_ID}/tables/${tableId}/fields`;

const LINK_META_FIELD = (fieldId) =>
  LINKS_IS_V2
    ? `${LINK_META_PREFIX}/columns/${fieldId}`
    : `${LINK_META_PREFIX}/bases/${NOCODB_BASE_ID}/fields/${fieldId}`;    

// Data endpoints for rows
const DATA_TABLE_RECORDS = (tableId) =>
  IS_V2 ? `${DATA_PREFIX}/tables/${tableId}/records` : `${DATA_PREFIX}/${tableId}/records`;

const LINK_DATA_TABLE_RECORDS = (tableId) =>
  LINKS_IS_V2
    ? `${LINK_DATA_PREFIX}/tables/${tableId}/records`
    : `${LINK_DATA_PREFIX}/${tableId}/records`;

// Convenience URL builders used by multiple scripts (and intentionally global)
function addQuery(url, queryString) {
  if (!queryString) return url;
  const qs = String(queryString);
  if (!qs) return url;
  return qs.startsWith('?') ? `${url}${qs}` : `${url}?${qs}`;
}

function tableRecordsUrl(tableId, queryString = null, useLinksApi = false) {
  const isV2 = useLinksApi ? LINKS_IS_V2 : IS_V2;
  const prefix = useLinksApi ? LINK_DATA_PREFIX : DATA_PREFIX;
  const base = isV2 ? `${prefix}/tables/${tableId}/records` : `${prefix}/${tableId}/records`;
  return addQuery(base, queryString);
}

function tableRecordUrl(tableId, recordId, queryString = null, useLinksApi = false) {
  const isV2 = useLinksApi ? LINKS_IS_V2 : IS_V2;
  const prefix = useLinksApi ? LINK_DATA_PREFIX : DATA_PREFIX;
  const base = isV2
    ? `${prefix}/tables/${tableId}/records/${recordId}`
    : `${prefix}/${tableId}/records/${recordId}`;
  return addQuery(base, queryString);
}

function linkRecordsUrl(tableId, linkFieldId, recordId) {
  return LINKS_IS_V2
    ? `${LINK_DATA_PREFIX}/tables/${tableId}/links/${linkFieldId}/records/${recordId}`
    : `${LINK_DATA_PREFIX}/${tableId}/links/${linkFieldId}/${recordId}`;
}

// ---------------------------------------------------------------------------
// Links helpers
// ---------------------------------------------------------------------------

async function resolveV3LinkFieldId(tableId, linkFieldRef) {
  if (!tableId || !linkFieldRef) return null;
  const ref = String(linkFieldRef).trim();
  if (!ref) return null;
  try {
    const meta = await fetchTableMeta(tableId, { useLinksApi: true });
    const fields = extractFieldsFromTableMeta(meta);
    const hit = (fields || []).find((f) => {
      const id = f?.id != null ? String(f.id) : '';
      const cn = (f?.column_name || f?.name || '').toString();
      const title = (f?.title || f?.label || '').toString();
      return id === ref || cn === ref || title === ref;
    });
    return hit?.id != null ? String(hit.id) : null;
  } catch {
    return null;
  }
}

async function resolveLinkFieldId(tableId, linkFieldRef) {
  if (!LINKS_IS_V3) return linkFieldRef;
  const resolved = await resolveV3LinkFieldId(tableId, linkFieldRef);
  return resolved || linkFieldRef;
}

// Cache for resolving a link field reference (often column_name/title) into the
// concrete field identifier required by the v3 links endpoints.
const _v3LinkFieldIdCache = new Map();

function _normKey(s) {
  return String(s || '')
    .trim()
    .toLowerCase()
    .replace(/\s+/g, '_');
}

function _looksLikeStableId(s) {
  const v = String(s || '');
  if (!v) return false;

  // v2 column ids are frequently numeric-ish; they MUST NOT be treated as v3 field ids.
  // If we treat these as "stable", LINKS=v3 will call /links/<v2id>/... which breaks.
  if (/^\d+$/.test(v)) return false;

  // Very short tokens are unlikely to be v3 ids (and are often internal numeric ids).
  if (v.length < 8) return false;
  
  // Heuristic: v3 field ids are usually opaque, URL-safe identifiers without spaces.
  // We treat anything containing whitespace or obvious column_name punctuation as a ref.
  if (/\s/.test(v)) return false;
  if (v.includes('/')) return false;
  if (v.includes('\\')) return false;
  // Underscore is common in column_name refs (e.g. "strain_id").
  if (v.includes('_')) return false;

  // Must include at least one letter to avoid numeric / punctuation-only ids.
  if (!/[a-z]/i.test(v)) return false;
  
  // NOTE:
  // Titles like "ecommerce" were being misclassified as "stable ids" which prevented
  // v3 resolution and caused: FIELD_NOT_FOUND (Field 'ecommerce' not found).
  // Require a bit more entropy/length to treat as an opaque id.
  if (v.length < 12) return false;
  return true;
}

async function resolveV3LinkFieldId(tableId, linkFieldRef) {
  const ref = String(linkFieldRef || '');
  const cacheKey = `${tableId}:${ref}`;
  if (_v3LinkFieldIdCache.has(cacheKey)) return _v3LinkFieldIdCache.get(cacheKey);

  // Pull v3 field metadata for this table via the LINKS meta version.
  // This is important when NOCODB_API_VERSION="v2" but NOCODB_API_VERSION_LINKS="v3".
  const fields = await fetchTableFields(tableId, { useLinksApi: true });
  const nref = _normKey(ref);

  // If caller already passed a real v3 field id, accept it as-is.
  const direct = fields.find((f) => String(f?.id || '') === ref);
  if (direct?.id) {
    _v3LinkFieldIdCache.set(cacheKey, direct.id);
    return direct.id;
  } 

  // Try common keys: column_name, title, and a normalized API field name.
  const match = fields.find((f) => {
    const cn = _normKey(f?.column_name || f?.name);
    const title = _normKey(f?.title || f?.name);
    const api = _normKey(f?.name);
    return nref === cn || nref === title || nref === api;
  });

  const id = match?.id || null;
  _v3LinkFieldIdCache.set(cacheKey, id);
  return id;
}

// Set a link field to match exactly the desired related-record ids.
// Uses the data-links endpoints (v2 or v3) depending on NOCODB_API_VERSION_LINKS.
async function setLinksExact(tableId, linkFieldId, recordId, desiredIds) {
  // Backwards compatible signature:
  //   setLinksExact(tableId, linkFieldId, recordId, desiredIds)
  //   setLinksExact({ tableId, linkFieldId, recordId, desiredIds, relatedPkName })
  //
  // IMPORTANT: normalize args FIRST (before any v3 field-id resolution),
  // otherwise callers passing an object can produce tables/[object Object].
  let opts;
  if (tableId && typeof tableId === 'object') {
    opts = tableId;
  } else {
    opts = { tableId, linkFieldId, recordId, desiredIds };
  }

  const tId = opts.tableId;
  const rId = opts.recordId;
  const desired = Array.isArray(opts.desiredIds) ? opts.desiredIds : [];
  const relatedPkName = (opts.relatedPkName || '').toString().trim();

  // Resolve the link field identifier for LINKS=v3:
  // The v3 links endpoint typically needs the *v3 field id* in the URL path,
  // and human refs like "ecommerce" often map to internal _nc_m2m_* columns.
  let lfRef = opts.linkFieldId;
  if (LINKS_IS_V3) {
    try {
      const resolved = await resolveV3LinkFieldId(tId, lfRef);
      if (resolved) lfRef = resolved;
    } catch (e) {
      // Don't fail the whole import if one column can't be resolved.
      // Fall back to caller-provided ref and let the API respond.
      if (typeof debug === 'function') {
        debug(
          `[WARN] LINKS=v3: failed to resolve link field ref "${opts.linkFieldId}" for table=${tId}: ${e?.message || e}`
        );
      }
    }
  }

  const url = linkRecordsUrl(tId, lfRef, rId);

  // Fetch current links
  const cur = await apiCall('get', url);
  let currentIds = [];
  if (LINKS_IS_V2) {
    const list = Array.isArray(cur) ? cur : cur?.list;
    if (Array.isArray(list)) {
      currentIds = list
        .map((r) => r?.Id ?? r?.id ?? r?.ID ?? r?.pk ?? r?.nocopk)
        .filter((x) => typeof x !== 'undefined' && x !== null)
        .map((x) => String(x));
    }
  } else {
    // v3 /db/data/nc/{tableId}/{recordId}/{linkFieldId} commonly returns either
    // an array of records, or { records: [...] }
    const records = Array.isArray(cur) ? cur : cur?.records;
    if (Array.isArray(records)) {
      currentIds = records
        .map((r) => r?.id ?? r?.Id ?? r?.nocopk)
        .filter((x) => typeof x !== 'undefined' && x !== null)
        .map((x) => String(x));
    }
  }

  const want = new Set(desired.map((x) => String(x)));
  const have = new Set(currentIds);

  const toUnlink = [...have].filter((id) => !want.has(id));
  const toLink = [...want].filter((id) => !have.has(id));

  // v2 link endpoints validate against the *related model primary key column name*.
  // Allow the importer to pass relatedPkName; default to "nocopk".
  const pk = relatedPkName || 'nocopk';
  if (toUnlink.length) {
    let payload;
    if (LINKS_IS_V2) {
      payload = toUnlink.map((id) => {
        const o = { [pk]: id };
        // Some deployments accept "Id" as alias; include only if different.
        if (pk !== 'Id') o.Id = id;
        return o;
      });
    } else {
      payload = toUnlink.map((id) => ({ id }));
    }
     await apiCall('delete', url, payload);
  }

  if (toLink.length) {
    let payload;
    if (LINKS_IS_V2) {
      payload = toLink.map((id) => {
        const o = { [pk]: id };
        if (pk !== 'Id') o.Id = id;
        return o;
      });
    } else {
      payload = toLink.map((id) => ({ id }));
    }
     await apiCall('post', url, payload);
  }
}

// ---------------------------------------------------------------------------
// Meta helpers (shared by schema + importer scripts)
// ---------------------------------------------------------------------------

function _normalizeCreateFieldPayload(payload, isV3) {
  const p = payload ? { ...payload } : {};
  if (!isV3) return p;

  // v3 requires { title, type } (OpenAPI: FieldBaseCreate)
  if (!p.title) {
    p.title = (p.column_name || p.name || p.label || '').toString() || p.title;
  }
  if (!p.type) {
    // Many scripts historically used `uidt` (UI data type) for field type.
    p.type = (p.uidt || p.column_type || p.data_type || '').toString() || p.type;
  }

  // Normalize default value casing
  if (typeof p.default_value === 'undefined' && typeof p.defaultValue !== 'undefined') {
    p.default_value = p.defaultValue;
    delete p.defaultValue;
  }
  return p;
}

function _coerceV3FormulaPayloadToV2(payload) {
  const p = payload ? { ...payload } : {};
  const title = (p.title || p.column_name || p.name || 'formula').toString();
  const column_name = (p.column_name || p.name || title).toString();

  // v3 schema code tends to send formula in options.formula.
  const formula_raw =
    (p.colOptions && (p.colOptions.formula_raw || p.colOptions.formula)) ||
    (p.options && (p.options.formula_raw || p.options.formula)) ||
    p.formula_raw ||
    '';

  // v2 expects uidt + dt + colOptions.formula_raw
  const out = {
    title,
    column_name,
    uidt: 'Formula',
    // IMPORTANT: underlying DB type must be something real (text is safe).
    dt: 'text',
    colOptions: {
      formula_raw: String(formula_raw),
    },
  };

  // Preserve display value flag if present
  if (p.pv === true) out.pv = true;

  return out;
}

// v2:
//   GET /api/v2/meta/tables/{tableId}              -> { columns: [...] }
// v3:
//   GET /api/v3/meta/bases/{baseId}/tables/{id}    -> { fields: [...] }
async function fetchTableMeta(tableId, { useLinksApi = false } = {}) {
  const isV3 = useLinksApi ? LINKS_IS_V3 : IS_V3;
  const metaPrefix = useLinksApi ? LINK_META_PREFIX : META_PREFIX;
  const url = !isV3
    ? `${metaPrefix}/tables/${tableId}`
    : `${metaPrefix}/bases/${NOCODB_BASE_ID}/tables/${tableId}`;
  return apiCall('get', url);
}

function extractFieldsFromTableMeta(data) {
  const cols = data?.columns || data?.fields || data?.list || [];
  return Array.isArray(cols) ? cols : [];
}

async function fetchTableFields(tableId, { useLinksApi = false } = {}) {
  const data = await fetchTableMeta(tableId, { useLinksApi });
  const fields = extractFieldsFromTableMeta(data);
  if (!Array.isArray(fields)) {
    throw new Error(
      `Unexpected fields response for ${tableId}: ${JSON.stringify(data).slice(0, 500)}`
    );
  }
  return fields;
}

async function createMetaField(tableId, payload, { useLinksApi = false } = {}) {
  const isV3 = useLinksApi ? LINKS_IS_V3 : IS_V3;
  const urlBuilder = useLinksApi ? LINK_META_TABLE_FIELDS : META_TABLE_FIELDS;
  const url = urlBuilder(tableId);
  const body = _normalizeCreateFieldPayload(payload, isV3);

  try {
    return await apiCall('post', url, body);
  } catch (err) {
    // NocoDB v3 meta API has been observed to reject certain Formula payloads with a
    // server-side exception (e.g. 400 "Cannot read properties of undefined (reading 'id')"),
    // even when the same formula succeeds via the v2 meta endpoint.
    //
    // To keep schema imports unblocked, fall back to v2 meta *only* for Formula fields
    // when we're otherwise running on v3 meta.
    const isFormula =
      !!payload &&
      typeof payload === 'object' &&
      ((payload.type && String(payload.type) === 'Formula') ||
        (payload.uidt && String(payload.uidt) === 'Formula'));

    if (isV3 && !useLinksApi && isFormula) {
      const v2Url = `/api/v2/meta/tables/${tableId}/columns`;
      const v2Body = _coerceV3FormulaPayloadToV2(payload);
      logWarn(
        `v3 meta rejected Formula field; retrying via v2 meta endpoint: ${v2Url}`
      );
      return apiCall('post', v2Url, v2Body);
    }

    throw err;
  }
}

async function patchMetaField(fieldId, payload, { useLinksApi = false } = {}) {
  const urlBuilder = useLinksApi ? LINK_META_FIELD : META_FIELD;
  const url = urlBuilder(fieldId);
  return apiCall('patch', url, payload);
}

/**
 * Refresh fields/columns for a NocoDB table in-place.
 * - v2 stores fields under columns[]
 * - v3 stores fields under fields[]
 */
async function fetchMetaFieldsForTable(tableId) {
  const meta = await fetchTableMeta(tableId);
  const fields = meta?.columns || meta?.fields || meta?.list || [];
  if (!Array.isArray(fields)) {
    throw new Error(
      `Unexpected columns/fields response for ${tableId}: ${JSON.stringify(meta).slice(0, 500)}`
    );
  }
  return fields;
}

/**
 * Fetch all NocoDB tables for the base, including field/column metadata.
 *
 * v3:
 *   GET /api/v3/meta/bases/{baseId}/tables?include_fields=true
 *
 * v2:
 *   GET /api/v2/meta/bases/{baseId}/tables         (list only)
 *   GET /api/v2/meta/tables/{tableId}             (per-table columns[])
 */
async function fetchMetaTables({ includeFields = false } = {}) {
  if (IS_V3 && includeFields) {
    const url = `${META_TABLES}?include_fields=true`;
    const data = await apiCall('get', url);
    const tables = Array.isArray(data?.list) ? data.list : data;
    if (!Array.isArray(tables)) {
      throw new Error(`Unexpected tables response: ${JSON.stringify(data).slice(0, 500)}`);
    }
    return tables;
  }

  const data = await apiCall('get', META_TABLES);
  const tables = Array.isArray(data?.list) ? data.list : data;
  if (!Array.isArray(tables)) {
    throw new Error(`Unexpected tables response: ${JSON.stringify(data).slice(0, 500)}`);
  }
  return tables;
}

function isLinkColumn(c) {
  // NocoDB can represent link fields differently depending on endpoint/version:
  // - uidt: 'Links'
  // - type: 'LinkToAnotherRecord', 'Rollup' 'Lookup'
  // - options.type: 'mm'/'hm'/'bt' etc.
  const uidt = (c?.uidt || '').toString();
  const type = (c?.type || '').toString();
  const opt = c?.colOptions || c?.options || c?.column_options || {};
  const relType = (opt?.type || '').toString();

  if (uidt === 'Links') return true;
  if (uidt === 'LinkToAnotherRecord') return true;
  if (type === 'LinkToAnotherRecord' || type === 'Rollup' || type === 'Lookup') return true;
  if (relType === 'mm' || relType === 'hm' || relType === 'bt' || relType === 'oo') return true;

  // Sometimes relation metadata shows up via fk_* keys
  if (opt?.fk_related_model_id || opt?.fk_mm_model_id) return true;
  if (c?.fk_related_model_id || c?.fk_mm_model_id) return true;

  return false;
}

/**
 * Returns true if a column/field is safe to write via row create/patch.
 *
 * Why this exists:
 * - Airtable rollups/lookups/formulas frequently become "virtual" (computed) in NocoDB.
 * - Some NocoDB endpoints/version combos do NOT label these consistently as uidt/type=Rollup|Lookup,
 *   but they are still read-only and will cause imports to fail if included in the payload.
 *
 * We therefore treat any "virtual/system/computed" field as non-writable even if it looks like a normal column.
 */
function isWritableColumn(c) {
  if (!c || typeof c !== 'object') return false;

  const name = normalizeColName(c).toLowerCase();
  const uidt = (c?.uidt || c?.type || '').toString();
  const opt = c?.colOptions || c?.options || c?.column_options || {};

  // Primary keys / auto fields / system-managed
  // Noco often exposes these flags in different shapes depending on API version.
  const pk =
    c?.pk === true || c?.pk === 1 ||
    opt?.pk === true || opt?.pk === 1;
  const ai =
    c?.ai === true || c?.ai === 1 ||
    opt?.ai === true || opt?.ai === 1;
  const system =
    c?.system === true || c?.system === 1 ||
    opt?.system === true || opt?.system === 1;

  if (pk || ai || system) return false;

  // Common non-writable system columns by name
  // (varies by DB + Noco internal schema)
  const NON_WRITABLE_NAMES = new Set([
    'id',
    'created_at',
    'updated_at',
    'createdat',
    'updatedat',
    'nocopk',
    'nc_record_id',
    'nc_created_at',
    'nc_updated_at',
  ]);
  if (NON_WRITABLE_NAMES.has(name)) return false;

  // Virtual/computed/read-only flags (varies by endpoint/build)
  const virtual =
    c?.virtual === true || c?.virtual === 1 ||
    c?.is_virtual === true || c?.is_virtual === 1 ||
    opt?.virtual === true || opt?.virtual === 1 ||
    opt?.is_virtual === true || opt?.is_virtual === 1 ||
    c?.readOnly === true || c?.readonly === true || c?.read_only === true ||
    opt?.readOnly === true || opt?.readonly === true || opt?.read_only === true;
  if (virtual) return false;

  // Anything that is a relation/computed field should not be written as a normal scalar.
  // NOTE: isLinkColumn already covers Links + many Rollup/Lookup representations,
  // but we keep this list as a second line of defense.
  const NON_WRITABLE_UIDT = new Set([
    'Links',
    'LinkToAnotherRecord',
    'Lookup',
    'Rollup',
    'Formula',
    'QrCode',
    'Barcode',
  ]);
  if (NON_WRITABLE_UIDT.has(uidt)) return false;

  // Otherwise OK to write
  return true;
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

  logInfo(`Creating missing column "airtable_id" on table "${tableName}" ...`);
  await createMetaField(tableId, {
    column_name: 'airtable_id',
    title: 'airtable_id',
    uidt: 'LongText',
  });

  return fetchTableFields(tableId);
}

// ---------------------------------------------------------------------------
// Logging helpers
// ---------------------------------------------------------------------------

function debug(...args) {
  if (NOCODB_DEBUG) console.log('[DEBUG]', ...args);
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

// ---------------------------------------------------------------------------
// Shared axios + apiCall
// ---------------------------------------------------------------------------

const api = axios.create({
  baseURL: NOCODB_URL.replace(/\/+$/, ''),
  headers: {
    'xc-token': NOCODB_API_TOKEN,
    'Content-Type': 'application/json',
    accept: 'application/json',
  },
  timeout: 120000,
  validateStatus: () => true,
});

async function apiCall(method, url, data) {
  try {
    const res = await api.request({
      method,
      url,
      data,
    });
    if (res.status >= 200 && res.status < 300) {
      return res.data;
    }
    const payload = res.data ? JSON.stringify(res.data) : res.statusText;
    throw new Error(`${method.toUpperCase()} ${url} -> ${res.status} ${payload}`);
  } catch (err) {
    const status = err.response && err.response.status;
    const body =
      err.response && err.response.data
        ? JSON.stringify(err.response.data).slice(0, 500)
        : String(err);
    throw new Error(
      `API ${method.toUpperCase()} ${url} failed (status=${status}): ${body}`
    );
  }
}

module.exports = {
  // env
  NOCODB_URL,
  NOCODB_BASE_ID,
  NOCODB_API_TOKEN,
  NOCODB_API_VERSION,
  NOCODB_API_VERSION_LINKS,
  NOCODB_BATCH_SIZE,
  NOCODB_DEBUG,
  AIRTABLE_EXPORT_DIR,
  SCHEMA_PATH,  
  IS_V2,
  IS_V3,
  LINKS_IS_V2,
  LINKS_IS_V3,
  META_PREFIX,
  LINK_META_PREFIX,
  DATA_PREFIX,
  LINK_DATA_PREFIX,
  // endpoints
  META_TABLES,
  META_TABLE_FIELDS,
  META_FIELD,
  LINK_META_TABLE_FIELDS,
  LINK_META_FIELD,
  DATA_TABLE_RECORDS,
  LINK_DATA_TABLE_RECORDS,
  // URL builders
  tableRecordsUrl,
  tableRecordUrl,
  linkRecordsUrl,
  resolveLinkFieldId,
  resolveV3LinkFieldId,  
  setLinksExact,
  // meta helpers
  fetchTableMeta,
  fetchTableFields,
  fetchMetaFieldsForTable,
  fetchMetaTables,
  createMetaField,
  patchMetaField,      
  isLinkColumn,
  isWritableColumn,
  normalizeColName,
  ensureAirtableIdColumn,
  // api
  api,
  apiCall,
  // logging
  debug,
  logInfo,
  logWarn,
  logError,
  // dotenv loader
  loadDotEnv,
};

// Backwards-compatible globals: both scripts currently rely on `require('./load_env')`
// side-effects to expose ENV + constants.
global.ENV = module.exports;
Object.assign(global, module.exports);