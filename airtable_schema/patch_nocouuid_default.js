#!/usr/bin/env node

// patch_nocouuid_default.js
// One-off script to set gen_random_uuid() as the default for all `nocouuid` fields.

const axios = require('axios');

// ------------------------
// ENV & BASIC CONFIG
// ------------------------

const NOCODB_URL =
  process.env.NOCODB_URL ||
  process.env.NC_URL ||
  'http://localhost:8080';

const NOCODB_BASE_ID = process.env.NOCODB_BASE_ID;
if (!NOCODB_BASE_ID) {
  console.error('[ERROR] NOCODB_BASE_ID is required.');
  process.exit(1);
}

const NOCODB_API_TOKEN =
  process.env.NOCODB_API_TOKEN ||
  process.env.NOCODB_AUTH_TOKEN ||
  process.env.NOCODB_TOKEN ||
  process.env.NC_TOKEN ||
  '';

if (!NOCODB_API_TOKEN) {
  console.error('[ERROR] NOCODB_API_TOKEN / NC_TOKEN / xc-token is required.');
  process.exit(1);
}

const NOCODB_API_VERSION = process.env.NOCODB_API_VERSION || 'v3';
const IS_V2 =
  NOCODB_API_VERSION === '2' ||
  NOCODB_API_VERSION === 'v2' ||
  NOCODB_API_VERSION === 'api_v2';
const IS_V3 = !IS_V2;

console.log(
  `[INFO] Using NocoDB at ${NOCODB_URL} (base=${NOCODB_BASE_ID}, api=${IS_V2 ? 'v2' : 'v3'})`
);

const META_PREFIX = IS_V2 ? '/api/v2/meta' : '/api/v3/meta';
const META_TABLES = `${META_PREFIX}/bases/${NOCODB_BASE_ID}/tables`;
const META_TABLE_FIELDS = (tableId) =>
  IS_V2
    ? `${META_PREFIX}/tables/${tableId}/columns`
    : `${META_PREFIX}/bases/${NOCODB_BASE_ID}/tables/${tableId}/fields`;
const META_TABLE = (tableId) =>
  IS_V2
    ? `${META_PREFIX}/tables/${tableId}`
    : `${META_TABLES}/${tableId}`;
const META_FIELD = (fieldId) =>
  IS_V2
    ? `${META_PREFIX}/columns/${fieldId}`
    : `${META_PREFIX}/bases/${NOCODB_BASE_ID}/fields/${fieldId}`;

// ------------------------
// HTTP Helper
// ------------------------

const api = axios.create({
  baseURL: NOCODB_URL.replace(/\/+$/, ''),
  headers: {
    'xc-token': NOCODB_API_TOKEN,
    'Content-Type': 'application/json',
  },
  timeout: 60000,
  validateStatus: () => true,
});

async function apiCall(method, url, data) {
  const label = `${method.toUpperCase()} ${url}`;
  try {
    const res = await api.request({ method, url, data });
    if (res.status >= 200 && res.status < 300) {
      return res.data;
    }
    const payload = res.data ? JSON.stringify(res.data) : res.statusText;
    throw new Error(`${label} -> ${res.status} ${payload}`);
  } catch (err) {
    const status = err.response && err.response.status;
    const body =
      err.response && err.response.data
        ? JSON.stringify(err.response.data).slice(0, 500)
        : String(err);
    console.error(`[ERROR] ${label} failed (${status || 'n/a'}): ${body}`);
    throw err;
  }
}

// ------------------------
// Fetch tables + fields
// ------------------------

async function fetchTablesWithFields() {
  console.log(
    `[INFO] Fetching tables for base ${NOCODB_BASE_ID} using ${IS_V2 ? 'v2' : 'v3'} meta API ...`
  );

  if (IS_V3) {
    // v3: we can ask for fields inline
    const url = `${META_TABLES}?include_fields=true`;
    const data = await apiCall('get', url);

    let tables = data;
    if (data && Array.isArray(data.list)) {
      tables = data.list;
    }
    if (!Array.isArray(tables)) {
      throw new Error(
        `Unexpected tables response (v3): ${JSON.stringify(data).slice(0, 500)}`
      );
    }

    console.log(`[INFO] Fetched ${tables.length} tables (v3).`);
    return tables;
  }

  // v2: list tables, then hydrate with columns
  const data = await apiCall('get', META_TABLES);
  let tables = data;
  if (data && Array.isArray(data.list)) {
    tables = data.list;
  }
  if (!Array.isArray(tables)) {
    throw new Error(
      `Unexpected tables response (v2): ${JSON.stringify(data).slice(0, 500)}`
    );
  }

  for (const t of tables) {
    const meta = await apiCall('get', META_TABLE(t.id));
    const columns = Array.isArray(meta.columns) ? meta.columns : [];
    t.fields = columns;
  }

  console.log(`[INFO] Fetched ${tables.length} tables (v2).`);
  return tables;
}

// ------------------------
// Patch nocouuid defaults
// ------------------------

async function patchNocoUUIDDefaults() {
  const tables = await fetchTablesWithFields();
  let patchedCount = 0;
  let skippedCount = 0;

  for (const table of tables) {
    const fields = Array.isArray(table.fields) ? table.fields : [];
    const tableName = table.title || table.name || table.table_name || table.id;

    for (const field of fields) {
      const colName = field.column_name || field.name || field.id;
      if (!colName) continue;

      console.log(
        `[INFO] Checking ${colName} on table "${tableName}" (field id=${field.id}).`
      );

      if (colName !== 'nocouuid') continue;

      console.log(
        `[INFO] Found nocouuid on table "${tableName}" (field id=${field.id}).`
      );

      try {
        if (IS_V3) {
          const options = field.options || {};
          const nextOptions = {
            ...options,
            dbType: options.dbType || 'uuid',
            dbDefaultValue: 'gen_random_uuid()',
            nn: true,
            un: true,
          };

          const payload = {
            // we only patch options; other keys remain unchanged
            options: nextOptions,
            type: 'SpecificDBType',
          };

          await apiCall('patch', META_FIELD(field.id), payload);
          console.log(
            `[OK]  Set dbDefaultValue=gen_random_uuid() for "${tableName}".nocouuid (v3).`
          );
        } else {
          // v2: default is at top level
          const payload = {
            default: 'gen_random_uuid()',            
            uidt: 'SpecificDBType',
            dt: 'uuid',
            nn: true,     // not null
            un: true,     // unique
          };
          await apiCall('patch', META_FIELD(field.id), payload);
          console.log(
            `[OK]  Set default=gen_random_uuid() for "${tableName}".nocouuid (v2).`
          );
        }

        patchedCount += 1;
      } catch (err) {
        console.error(
          `[ERROR] Failed to patch nocouuid on table "${tableName}" (field id=${field.id}): ${err.message}`
        );
        skippedCount += 1;
      }
    }
  }

  console.log(
    `[DONE] Patched defaults for nocouuid: ${patchedCount} field(s), ${skippedCount} error(s).`
  );
}

// ------------------------
// Main
// ------------------------

patchNocoUUIDDefaults()
  .then(() => {
    console.log('[INFO] Finished patching nocouuid defaults.');
    process.exit(0);
  })
  .catch((err) => {
    console.error('[FATAL] Patch script failed:', err.message);
    process.exit(1);
  });
