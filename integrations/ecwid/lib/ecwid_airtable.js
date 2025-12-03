// lib/ecwid_airtable.js
// Shared helpers for Ecwid <-> Airtable sync

const fetch = require('node-fetch');
require('dotenv').config();

const {
  AIRTABLE_API_KEY,
  AIRTABLE_BASE_ID,
  ECWID_STORE_ID,
  ECWID_TOKEN,
} = process.env;

function assertCommonEnv() {
  const required = [
    'AIRTABLE_API_KEY',
    'AIRTABLE_BASE_ID',
    'ECWID_STORE_ID',
    'ECWID_TOKEN',
  ];

  const missing = required.filter((k) => !process.env[k]);
  if (missing.length) {
    console.error('Missing required env vars:', missing.join(', '));
    process.exit(1);
  }
}

// ---------- Airtable helpers ----------

async function airtableRequest(path, options = {}) {
  const baseUrl = `https://api.airtable.com/v0/${encodeURIComponent(
    AIRTABLE_BASE_ID
  )}`;

  const res = await fetch(`${baseUrl}${path}`, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${AIRTABLE_API_KEY}`,
      ...(options.headers || {}),
    },
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Airtable error ${res.status} ${path}: ${text}`);
  }

  if (res.status === 204) return null;
  return res.json();
}

/**
 * Fetch all records from a table (optionally with view or filter params).
 */
async function airtableFetchAllRecords(tableName, queryParams = {}) {
  const records = [];
  let offset = null;

  do {
    const params = new URLSearchParams({
      pageSize: '100',
      ...queryParams,
    });

    if (offset) params.append('offset', offset);

    const encodedTable = encodeURIComponent(tableName);
    const data = await airtableRequest(`/${encodedTable}?${params.toString()}`);

    records.push(...(data.records || []));
    offset = data.offset;
  } while (offset);

  return records;
}

/**
 * Create a record in a table.
 */
async function airtableCreateRecord(tableName, fields) {
  const encodedTable = encodeURIComponent(tableName);
  const body = JSON.stringify({ fields });

  return airtableRequest(`/${encodedTable}`, {
    method: 'POST',
    body,
  });
}

/**
 * Update a record in a table by recordId.
 */
async function airtableUpdateRecord(tableName, recordId, fields) {
  const encodedTable = encodeURIComponent(tableName);
  const encodedId = encodeURIComponent(recordId);
  const body = JSON.stringify({ fields });

  return airtableRequest(`/${encodedTable}/${encodedId}`, {
    method: 'PATCH',
    body,
  });
}

// ---------- Ecwid helpers ----------

async function ecwidRequest(path, options = {}) {
  const baseUrl = `https://app.ecwid.com/api/v3/${encodeURIComponent(
    ECWID_STORE_ID
  )}`;

  const res = await fetch(`${baseUrl}${path}`, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${ECWID_TOKEN}`,
      ...(options.headers || {}),
    },
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Ecwid error ${res.status} ${path}: ${text}`);
  }

  if (res.status === 204) return null;
  return res.json();
}

/**
 * Find Ecwid product (and possibly variation) by SKU.
 * Returns { product, variation } where variation may be null.
 */
async function findEcwidProductBySku(sku) {
  const params = new URLSearchParams({ sku });
  const data = await ecwidRequest(`/products?${params.toString()}`);

  if (!data.items || !Array.isArray(data.items) || data.items.length === 0) {
    return { product: null, variation: null };
  }

  const product = data.items[0];

  // Exact base product SKU match?
  if (product.sku === sku) {
    return { product, variation: null };
  }

  // Look through variations (combinations)
  if (Array.isArray(product.variations)) {
    const variation = product.variations.find((v) => v.sku === sku);
    if (variation) {
      return { product, variation };
    }
  }

  // Product found, but SKU didn't match base or a variation explicitly
  return { product, variation: null };
}

/**
 * Update base product quantity via Ecwid Update Product API.
 */
async function updateEcwidBaseProductQuantity(productId, quantity) {
  const body = {
    quantity,
    unlimited: false,
  };

  return ecwidRequest(`/products/${productId}`, {
    method: 'PUT',
    body: JSON.stringify(body),
  });
}

/**
 * Update variation quantity via Ecwid Update Product Variation API.
 */
async function updateEcwidVariationQuantity(productId, combinationId, quantity) {
  const body = {
    quantity,
    unlimited: false,
  };

  return ecwidRequest(
    `/products/${productId}/combinations/${combinationId}`,
    {
      method: 'PUT',
      body: JSON.stringify(body),
    }
  );
}

module.exports = {
  assertCommonEnv,
  airtableRequest,
  airtableFetchAllRecords,
  airtableCreateRecord,
  airtableUpdateRecord,
  ecwidRequest,
  findEcwidProductBySku,
  updateEcwidBaseProductQuantity,
  updateEcwidVariationQuantity,
};
