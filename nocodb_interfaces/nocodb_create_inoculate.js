/**
 * nocodb_create_inoculate.js
 *
 * Replacement for nocodb_create_inoculate_lc_to_grain_view.js
 * for the new source-first, multi-target inoculation flow.
 *
 * This script expects a helper function `createOrUpdateView(tableName, viewDef)`
 * which does the actual NocoDB API call or SQL. If your existing migration
 * scripts use a different helper (e.g. createView, upsertView, etc.), simply
 * swap that in and keep the viewDefinition object intact.
 */

const { createOrUpdateView } = require('./nocodb_view_helpers'); // adjust path/name if needed

async function main() {
  const tableName = 'lots';

  const viewDefinition = {
    name: 'Inoculate',
    title: 'Inoculate',
    type: 'grid',          // standard grid view
    isDefault: false,

    // Filter: show candidate SOURCE lots
    // item_category in (lc_flask, plate, grain) AND status in (Sterilized, Sealed, Ready)
    filter: {
      op: 'and',
      items: [
        {
          column: 'item_category',
          op: 'in',
          value: ['lc_flask', 'plate', 'grain']
        },
        {
          column: 'status',
          op: 'in',
          value: ['Sterilized', 'Sealed', 'Ready']
        }
      ]
    },

    // Sort / group are advisory; the UI layer (Retool) may also apply its own.
    sort: [
      { column: 'item_category', direction: 'asc' },
      { column: 'strain_id',     direction: 'asc' },
      { column: 'sterilized_at', direction: 'asc' }
    ],

    // Columns visible in the grid; you can add/remove to match your base.
    columns: [
      { name: 'lot_id',             visible: true }, // primary key
      { name: 'item_category',      visible: true },
      { name: 'status',             visible: true },
      { name: 'strain_id',          visible: true },
      { name: 'unit_size',          visible: true },
      { name: 'remaining_volume_ml',visible: true },
      { name: 'lc_volume_ml',       visible: true }, // per-target volume on source
      { name: 'target_lot_ids',     visible: true }, // multi-link to targets
      { name: 'override_inoc_time', visible: true },
      { name: 'operator',           visible: true },
      { name: 'notes',              visible: true },
      { name: 'ui_error',           visible: true },
      { name: 'validation',         visible: true }
    ]
  };

  await createOrUpdateView(tableName, viewDefinition);
  console.log('Inoculate view created/updated successfully.');
}

if (require.main === module) {
  main().catch((err) => {
    console.error('Error creating Inoculate view:', err);
    process.exit(1);
  });
}

module.exports = { main };
