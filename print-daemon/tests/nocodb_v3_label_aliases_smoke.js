'use strict';

const assert = require('assert');
const {
  detectItemCategory,
  gatherFields,
  hasRenderableLabelText,
} = require('../print-daemon.js');

const lotRecord = {
  fields: {
    source_kind: 'lot',
    item_category_mat_from_lot_id: ['fruiting_block'],
    label_company_lot_from_lot_id: ['Dank Mushrooms'],
    label_title_lot_from_lot_id: ['Fruiting Block'],
    label_subtitle_lot_from_lot_id: ['8.5 lb • Chestnut Fungaia'],
    label_footer_lot_from_lot_id: ['Lot: LOT-260805-9c70'],
    label_proc_line_from_lot_id: ['Sterilized: 2026-08-05'],
    label_spawned_line_from_lot_id: ['Spawned: 2026-08-05'],
    label_useby_line_from_lot_id: ['Use by: 2026-11-03'],
    label_graininputblocks_line_from_lot_id: ['Wild Bird Seed 2026-08-05'],
    label_substrateinputblocks_line_from_lot_id: ['Sterilized Masters Mix 75/25'],
    public_link_from_lot_id: ['https://example.invalid/lots/LOT-260805-9c70'],
  },
};

assert.strictEqual(detectItemCategory(lotRecord), 'fruiting_block');
const lotLabel = gatherFields(lotRecord);
assert.strictEqual(lotLabel.company, 'Dank Mushrooms');
assert.strictEqual(lotLabel.title, 'Fruiting Block');
assert.strictEqual(lotLabel.subtitle, '8.5 lb • Chestnut Fungaia');
assert.strictEqual(lotLabel.footer, 'Lot: LOT-260805-9c70');
assert.strictEqual(lotLabel.qr, 'https://example.invalid/lots/LOT-260805-9c70');
assert(lotLabel.extras.includes('Grain: Wild Bird Seed 2026-08-05'));
assert(lotLabel.extras.includes('Substrate: Sterilized Masters Mix 75/25'));
assert(hasRenderableLabelText(lotLabel));

const productRecord = {
  fields: {
    source_kind: 'product',
    label_type: 'Product_Package',
    item_category_mat_from_product_id: ['grain'],
    label_company_prod_from_product_id: ['Dank Mushrooms'],
    label_title_prod_from_product_id: ['Wild Bird Seed Grain'],
    label_subtitle_prod_from_product_id: ['2 lb • Sterilized'],
    label_footer_prod_from_product_id: ['PROD-260806-test'],
    label_packaged_prod_from_product_id: ['Packaged: 2026-08-06'],
    label_useby_prod_from_product_id: ['Use by: 2026-11-04'],
    label_proc_prod_from_product_id: ['Sterilized: 2026-08-05'],
    public_link_from_product_id: ['https://example.invalid/products/PROD-260806-test'],
  },
};

assert.strictEqual(detectItemCategory(productRecord), 'grain');
const productLabel = gatherFields(productRecord);
assert.strictEqual(productLabel.title, 'Wild Bird Seed Grain');
assert.strictEqual(productLabel.subtitle, '2 lb • Sterilized');
assert.strictEqual(productLabel.qr, 'https://example.invalid/products/PROD-260806-test');
assert(productLabel.extras.includes('Packaged: 2026-08-06'));
assert(productLabel.extras.includes('Use by: 2026-11-04'));
assert(hasRenderableLabelText(productLabel));

// NocoDB v3 can serialize PostgreSQL text[] columns as PostgreSQL array
// literals instead of JavaScript arrays. These braces are transport syntax
// and must not be printed on tray/product labels.
const postgresArrayProductRecord = {
  fields: {
    source_kind: 'product',
    label_type: 'Product_Package',
    item_category_mat_from_product_id: '{freezer_tray}',
    label_company_prod_from_product_id: '{"Dank Mushrooms"}',
    label_title_prod_from_product_id: '{"Freezer Tray"}',
    label_subtitle_prod_from_product_id: '{"349.7 g • Blue Oyster"}',
    label_footer_prod_from_product_id: '{PROD-260114-ZbzO}',
    label_spawned_prod_from_product_id: '{"Spawned: 2025-11-13"}',
    label_packaged_prod_from_product_id: '{"Packaged: 2026-01-13"}',
    public_link_from_product_id: '{"https://example.invalid/products/PROD-260114-ZbzO"}',
  },
};

assert.strictEqual(detectItemCategory(postgresArrayProductRecord), 'freezer_tray');
const postgresArrayProductLabel = gatherFields(postgresArrayProductRecord);
assert.strictEqual(postgresArrayProductLabel.company, 'Dank Mushrooms');
assert.strictEqual(postgresArrayProductLabel.title, 'Freezer Tray');
assert.strictEqual(postgresArrayProductLabel.subtitle, '349.7 g • Blue Oyster');
assert.strictEqual(postgresArrayProductLabel.footer, 'PROD-260114-ZbzO');
assert.strictEqual(
  postgresArrayProductLabel.qr,
  'https://example.invalid/products/PROD-260114-ZbzO'
);
assert(postgresArrayProductLabel.extras.includes('Spawned: 2025-11-13'));
assert(postgresArrayProductLabel.extras.includes('Packaged: 2026-01-13'));
for (const value of [
  postgresArrayProductLabel.company,
  postgresArrayProductLabel.title,
  postgresArrayProductLabel.subtitle,
  postgresArrayProductLabel.footer,
  postgresArrayProductLabel.qr,
  ...postgresArrayProductLabel.extras,
]) {
  assert(!/^\{.*\}$/.test(String(value)), `Transport braces leaked into label text: ${value}`);
}
assert(hasRenderableLabelText(postgresArrayProductLabel));

const jsonWrappedProductRecord = {
  fields: {
    source_kind: 'product',
    item_category_mat_from_product_id: '["freezer_tray"]',
    label_title_prod_from_product_id: '["Freezer Tray"]',
    label_subtitle_prod_from_product_id: '{"value":"349.7 g • Blue Oyster"}',
    label_footer_prod_from_product_id: '{"display_value":"PROD-json-wrapper"}',
  },
};
const jsonWrappedProductLabel = gatherFields(jsonWrappedProductRecord);
assert.strictEqual(jsonWrappedProductLabel.title, 'Freezer Tray');
assert.strictEqual(jsonWrappedProductLabel.subtitle, '349.7 g • Blue Oyster');
assert.strictEqual(jsonWrappedProductLabel.footer, 'PROD-json-wrapper');

const legacyRecord = {
  fields: {
    source_kind: 'lot',
    'label_title_lot (from lot_id)': ['Legacy Lot Title'],
    'label_footer_lot (from lot_id)': ['Lot: LOT-legacy'],
  },
};
assert.strictEqual(gatherFields(legacyRecord).title, 'Legacy Lot Title');
assert(hasRenderableLabelText(gatherFields(legacyRecord)));

assert.strictEqual(
  hasRenderableLabelText({ kind: 'lot', company: 'Dank Mushrooms', extras: [] }),
  false
);

const fs = require('fs');
const path = require('path');
const {
  nocoV3Where,
  lotMatchesRun,
  steriSheetRunFields,
  steriSheetLotFields,
} = require('../print-daemon.js');

assert.strictEqual(
  nocoV3Where('steri_run_id', 'eq', 'RUN-260716-4YjH'),
  '(steri_run_id,eq,"RUN-260716-4YjH")'
);
assert.strictEqual(
  nocoV3Where('steri_run_id', 'eq', 166),
  '(steri_run_id,eq,166)'
);
assert.strictEqual(
  nocoV3Where('name', 'eq', 'Recipe "A" \\ test'),
  '(name,eq,"Recipe \\"A\\" \\\\ test")'
);

for (const row of [
  { fields: { steri_run_id: 'RUN-260716-4YjH' } },
  { fields: { steri_run_id: ['RUN-260716-4YjH'] } },
  { fields: { steri_run_id: '{"RUN-260716-4YjH"}' } },
  {
    fields: {
      sterilization_runs: {
        id: 'linked-row',
        fields: { steri_run_id: 'RUN-260716-4YjH' },
      },
    },
  },
]) {
  assert(lotMatchesRun(row, ['RUN-260716-4YjH', 166]));
}
// The production vc_lots view stores the numeric run FK, not the RUN-* value.
assert(lotMatchesRun(
  { fields: { steri_run_id: 166 } },
  ['RUN-260716-4YjH', 166]
));
assert(!lotMatchesRun(
  { fields: { steri_run_id: 999 } },
  ['RUN-260716-4YjH', 166]
));

const sheetRun = steriSheetRunFields({
  id: 55,
  fields: {
    steri_run_id: 'RUN-260716-4YjH',
    process_type: 'Sterilize',
    operator: 'bobbyweber13@gmail.com',
    start_time: '2026-07-15T19:08:00.000Z',
    end_time: '2026-07-16T19:09:00.000Z',
    planned_item_id: 7,
    planned_item_name: 'Hardwood Substrate Bag',
    planned_count: 8,
    planned_unit_size: 7.5,
    good_count: 8,
    destroyed_count: 0,
  },
});
assert.strictEqual(sheetRun.runNo, 'RUN-260716-4YjH');
assert.strictEqual(sheetRun.plannedItem, 'Hardwood Substrate Bag');
assert.strictEqual(sheetRun.goodCount, 8);

const sheetLot = steriSheetLotFields({
  id: 101,
  fields: {
    lot_id: '{"LOT-260716-F4ex"}',
    item_name: '{"Hardwood Substrate Bag"}',
    recipe_name: '{"Masters Mix 75/25"}',
    unit_size: 7.5,
    status: '{Sterilized}',
    public_link: '{"https://example.invalid/lots/LOT-260716-F4ex"}',
  },
});
assert.deepStrictEqual(sheetLot, {
  lotId: 'LOT-260716-F4ex',
  itemName: 'Hardwood Substrate Bag',
  recipeName: 'Masters Mix 75/25',
  unit: '7.5',
  status: 'Sterilized',
  qrUrl: 'https://example.invalid/lots/LOT-260716-F4ex',
});

const daemonSource = fs.readFileSync(
  path.join(__dirname, '..', 'print-daemon.js'),
  'utf8'
);
assert(
  daemonSource.includes("where: nocoV3Where('steri_run_id', 'eq', candidate)"),
  'Sterilizer lot lookup must filter vc_lots on the NocoDB server'
);
assert(
  !daemonSource.includes('fetchNocoV3Records(LOTS_TABLE, LOTS_VIEW_ID, {}, true)'),
  'Sterilizer lot lookup must not scan the entire vc_lots view'
);
assert(
  daemonSource.includes('fetchLotsForRun(businessRunId, run.id)'),
  'Sterilizer lot lookup must include the numeric PostgreSQL run FK'
);
assert(
  daemonSource.includes('Refusing to print a blank sheet.'),
  'Sterilizer sheets with positive good_count must not print without linked lots'
);

console.log('NocoDB v3 label alias and sterilizer-sheet smoke tests passed.');
