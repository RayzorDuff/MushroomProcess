/**
 * Auto-generated from airtable_interfaces/Interface_Package_Grain_Substrate_Blocks.txt
 * Interface: Package Grain, Substrate or Block
 * Table: lots
 *
 * Creates (or updates) a NocoDB grid view that mirrors the Airtable Interface:
 * - Filters
 * - Grouping
 * - Visible fields (best-effort)
 * - Row actions (best-effort; depends on your NocoDB build)
 */
'use strict';

const BASE_URL = process.env.NOCO_BASE_URL;
const PROJECT_SLUG = process.env.NOCO_PROJECT;
const API_TOKEN = process.env.NOCO_TOKEN;

if (!BASE_URL || !PROJECT_SLUG || !API_TOKEN) {
  console.error('Missing env. Expected NOCO_BASE_URL, NOCO_PROJECT, NOCO_TOKEN.');
  process.exit(1);
}

async function api(path, method = 'GET', body) {
  const url = `${BASE_URL.replace(/\/$/, '')}/api/v2/${path.replace(/^\//, '')}`;
  const res = await fetch(url, {
    method,
    headers: {
      accept: 'application/json',
      'xc-token': API_TOKEN,
      'content-type': 'application/json',
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`API ${method} ${url} failed (${res.status}): ${text}`);
  }
  return res.json();
}

async function getTable(tableName) {
  const tables = await api(`meta/projects/${PROJECT_SLUG}/tables`);
  const list = tables.list || tables;
  const table = list.find(t => t.title === tableName || t.table_name === tableName || t.name === tableName);
  if (!table) throw new Error(`Table "${tableName}" not found in project "${PROJECT_SLUG}"`);
  return table;
}

async function upsertView(tableId, title, meta) {
  // Try to find existing
  let views;
  try {
    views = await api(`meta/tables/${tableId}/views`);
  } catch (e) {
    // fallback older path
    views = await api(`tables/${tableId}/views`);
  }
  const list = views.list || views;
  const existing = list.find(v => v.title === title);
  if (existing) {
    return api(`meta/views/${existing.id}`, 'PATCH', { title, meta });
  }
  return api(`meta/tables/${tableId}/views`, 'POST', {
    title,
    type: 'grid',
    fk_model_id: tableId,
    meta,
  });
}

async function createViewAction(viewId, title, updates) {
  try {
    await api(`meta/views/${viewId}/actions`, 'POST', {
      title,
      type: 'updateRow',
      meta: { updates },
    });
    console.log(`  ✓ Added action: ${title}`);
  } catch (e) {
    console.warn(`  ! Skipped action "${title}" (view actions not supported or endpoint differs).`);
  }
}

async function main() {
  console.log(`🔧 Upserting view: Package Grain, Substrate or Block`);
  const table = await getTable('lots');
  const meta = {
    fields: [],
    groupBy: [
  {
    "column_name": "item_category",
    "order": "asc"
  }
],
    sort: [],
    allowExport: false,
    allowPrint: true,
  };

  const view = await upsertView(table.id, 'Package Grain, Substrate or Block', meta);
  console.log(`✅ View ready: ${view.title || 'Package Grain, Substrate or Block'} (id=${view.id || 'unknown'})`);

}

main().catch(err => {
  console.error('ERROR:', err.message);
  process.exit(1);
});
