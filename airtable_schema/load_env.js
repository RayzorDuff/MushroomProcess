#!/usr/bin/env node
/* eslint-disable no-console */
/**
 * load_env.js
 *
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

// Set a link field to match exactly the desired related-record ids.
// Uses the data-links endpoints (v2 or v3) depending on NOCODB_API_VERSION_LINKS.
async function setLinksExact(tableId, linkFieldId, recordId, desiredIds) {
  const url = linkRecordsUrl(tableId, linkFieldId, recordId);
  const desired = Array.isArray(desiredIds) ? desiredIds : [];

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
    const records = Array.isArray(cur) ? cur : cur?.records;
    if (Array.isArray(records)) {
      currentIds = records
        .map((r) => r?.id ?? r?.Id)
        .filter((x) => typeof x !== 'undefined' && x !== null)
        .map((x) => String(x));
    }
  }

  const want = new Set(desired.map((x) => String(x)));
  const have = new Set(currentIds);

  const toUnlink = [...have].filter((id) => !want.has(id));
  const toLink = [...want].filter((id) => !have.has(id));

  if (toUnlink.length) {
    const payload = LINKS_IS_V2
      ? toUnlink.map((id) => ({ Id: id }))
      : toUnlink.map((id) => ({ id }));
    await apiCall('delete', url, payload);
  }

  if (toLink.length) {
    const payload = LINKS_IS_V2
      ? toLink.map((id) => ({ Id: id }))
      : toLink.map((id) => ({ id }));
    await apiCall('post', url, payload);
  }
}

// ---------------------------------------------------------------------------
// Logging helpers
// ---------------------------------------------------------------------------

function debug(...args) { if (NOCODB_DEBUG) console.log('[DEBUG]', ...args); }

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
  setLinksExact,  
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