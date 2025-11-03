/**
 * nocodb_create_spawn_to_bulk_view.js
 * 
 * Creates the "Spawn to Bulk" view in NocoDB using the API.
 * This script replicates Airtable interface configuration:
 *   - Source table: lots
 *   - Filters: status ∈ {FullyColonized, Fridge}, item_category ∈ {grain}
 *   - Grouping: item_name, strain_species_strain
 *   - Visible fields: item_name, strain_species_strain, inoculated_at, substrate_inputs,
 *                     output_count, fruiting_goal, override_spawn_time, operator, notes,
 *                     ui_error, validation
 *   - Custom Action Button: "Spawn to Bulk" → sets action = "SpawnToBulk"
 *
 * Usage:
 *   1. Set environment variable NOCO_TOKEN to your NocoDB API token.
 *   2. Update BASE_URL and PROJECT_SLUG below.
 *   3. Run:  node nocodb_create_spawn_to_bulk_view.js
 */

import fetch from "node-fetch";

// ---------------------------
// Configuration
// ---------------------------

// Example: "https://yourdomain.nocodb.com"
const BASE_URL = "https://your-nocodb-instance.com";

// Example: "dank_mushrooms_inventory"
const PROJECT_SLUG = "mushroom_inventory";

// Example: "lots"
const TABLE_NAME = "lots";

// Use token from environment or paste directly for testing
const API_TOKEN = process.env.NOCO_TOKEN || "YOUR_API_TOKEN_HERE";

// ---------------------------
// Helper functions
// ---------------------------

async function api(path, method = "GET", body = null) {
  const res = await fetch(`${BASE_URL}/api/v2/${path}`, {
    method,
    headers: {
      "accept": "application/json",
      "xc-token": API_TOKEN,
      "content-type": "application/json",
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`API ${method} ${path} failed: ${res.status} ${errText}`);
  }
  return res.json();
}

// ---------------------------
// Main logic
// ---------------------------

async function createSpawnToBulkView() {
  console.log("🔧 Creating 'Spawn to Bulk' view...");

  // Step 1: Get table ID
  const tables = await api(`project/${PROJECT_SLUG}/tables`);
  const table = tables.list.find(t => t.title === TABLE_NAME || t.table_name === TABLE_NAME);
  if (!table) throw new Error(`Table '${TABLE_NAME}' not found`);
  const tableId = table.id;

  // Step 2: Create the view
  const viewPayload = {
    title: "Spawn to Bulk",
    type: "grid",
    fk_model_id: tableId,
    meta: {
      colorBy: null,
      sort: [],
      allowPrint: true,
      allowExport: false,
      fields: [
        "item_name",
        "strain_species_strain",
        "inoculated_at",
        "substrate_inputs",
        "output_count",
        "fruiting_goal",
        "override_spawn_time",
        "operator",
        "notes",
        "ui_error",
        "validation",
      ],
      groupBy: [
        { column_name: "item_name", order: "asc" },
        { column_name: "strain_species_strain", order: "asc" },
      ],
      filter: {
        condition: "AND",
        children: [
          {
            column_name: "status",
            comparator: "in",
            value: ["FullyColonized", "Fridge"],
          },
          {
            column_name: "item_category",
            comparator: "in",
            value: ["grain"],
          },
        ],
      },
    },
  };

  const createdView = await api(`tables/${tableId}/views`, "POST", viewPayload);
  console.log(`✅ Created view: ${createdView.title}`);

  // Step 3: Add custom Action (button equivalent)
  const actionPayload = {
    title: "Spawn to Bulk",
    type: "updateRow",
    meta: {
      updates: [{ column_name: "action", value: "SpawnToBulk" }],
    },
  };

  await api(`views/${createdView.id}/actions`, "POST", actionPayload);
  console.log("✅ Added custom action: Spawn to Bulk");

  console.log("🎉 Spawn to Bulk view successfully created in NocoDB!");
}

// ---------------------------
// Execute
// ---------------------------

createSpawnToBulkView().catch(err => {
  console.error("❌ Error:", err.message);
  process.exit(1);
});
