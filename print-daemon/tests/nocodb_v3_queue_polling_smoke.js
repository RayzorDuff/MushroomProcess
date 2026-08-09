#!/usr/bin/env node
'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const daemonPath = path.resolve(__dirname, '..', 'print-daemon.js');
const source = fs.readFileSync(daemonPath, 'utf8');
const start = source.indexOf('function quoteNocoWhereValue');
const end = source.indexOf('function normalizeRunMatchTargets');
assert(start >= 0 && end > start, 'Unable to locate NocoDB queue helper functions');

const context = {
  PRINT_TARGET_FIELD: 'print_target',
  PRINT_TARGET_VALUE: '',
  NOCODB_EXTRA_WHERE: '',
  toFlat(value) {
    if (Array.isArray(value)) return value.join(', ');
    return value == null ? '' : String(value);
  },
  linkedNocoValue(value, fieldNames = []) {
    const one = Array.isArray(value) ? value[0] : value;
    if (one == null) return '';
    if (typeof one !== 'object') return one;

    const fields = one.fields && typeof one.fields === 'object' ? one.fields : {};
    const idFields = one.id_fields && typeof one.id_fields === 'object' ? one.id_fields : {};

    for (const key of fieldNames) {
      if (fields[key] !== undefined && fields[key] !== null && String(fields[key]).trim() !== '') {
        return fields[key];
      }
      if (idFields[key] !== undefined && idFields[key] !== null && String(idFields[key]).trim() !== '') {
        return idFields[key];
      }
    }

    return one.id ?? one.Id ?? idFields.nocopk ?? '';
  },
};
vm.createContext(context);
vm.runInContext(source.slice(start, end), context);

assert.strictEqual(
  context.nocoV3Where('print_status', 'eq', 'Queued'),
  '(print_status,eq,"Queued")'
);
assert.strictEqual(
  context.combineNocoV3WhereClauses([
    '(print_status,eq,"Queued")',
    '(source_kind,neq,"product")',
  ]),
  '(print_status,eq,"Queued")~and(source_kind,neq,"product")'
);

assert.strictEqual(context.printTargetForSource('steri_sheet', ''), 'ZEBRA');
assert.strictEqual(context.printTargetForSource('product', 'freezer_tray'), 'TRAYS');
assert.strictEqual(context.printTargetForSource('product', 'fresh_tray'), 'TRAYS');
assert.strictEqual(context.printTargetForSource('product', 'fresh_mushrooms'), 'TRAYS');
assert.strictEqual(context.printTargetForSource('product', 'freezedriedmushrooms'), 'ZEBRA');
assert.strictEqual(context.printTargetForSource('lot', 'fruiting_block'), 'ZEBRA');

assert.strictEqual(context.queueSourcePk({ product_id: 728 }, 'product'), '728');
assert.strictEqual(context.queueSourcePk({ lot_id: 1581 }, 'lot'), '1581');

// NocoDB v3 expands Link fields into LTAR-shaped linked records only when
// linksAsLtar=true. Use the linked Record ID/nocopk, not its display value.
assert.strictEqual(
  context.queueSourcePk(
    {
      product_id: [{ id: 2075, fields: { product_id: 'PROD-260805-example' } }],
    },
    'product'
  ),
  '2075'
);
assert.strictEqual(
  context.queueSourcePk(
    {
      lot_id: [{ id: 1581, id_fields: { nocopk: 1581 }, fields: { lot_id: 'LOT-260805-example' } }],
    },
    'lot'
  ),
  '1581'
);
assert.strictEqual(
  context.queueSourcePk(
    {
      Products: [{ id: 728, fields: { product_id: 'PROD-260804-HBhS' } }],
    },
    'product'
  ),
  '728',
  'Display-oriented NocoDB link titles should be accepted conservatively'
);

assert.strictEqual(
  context.queueSourceBusinessId(
    { product_id: [{ id: 409, fields: { product_id: 'PROD-260804-HBhS' } }] },
    'product'
  ),
  'PROD-260804-HBhS'
);
assert.strictEqual(
  context.queueSourceBusinessId(
    { lot_id: [{ id: 1581, fields: { lot_id: 'LOT-260805-9c70' } }] },
    'lot'
  ),
  'LOT-260805-9c70'
);
assert(context.nocoV3SourceFieldNames('product').includes('label_title_prod'));
assert(context.nocoV3SourceFieldNames('lot').includes('label_title_lot'));

const merged = context.mergeQueueSourceFields(
  { nocopk: 871, source_kind: 'lot', print_status: 'Queued' },
  { nocopk: 1581, label_title_lot: 'Small CVG', item_category_mat: 'fruiting_block' },
  'ZEBRA'
);
assert.strictEqual(merged.nocopk, 871, 'Queue identity must win over source-view identity');
assert.strictEqual(merged.label_title_lot, 'Small CVG');
assert.strictEqual(merged.print_target, 'ZEBRA');

assert(
  source.includes("nocoV3Where('print_status', 'eq', 'Queued')") &&
  source.includes("linksAsLtar: 'true'") &&
  source.includes('hydrateNocoV3QueueCandidate(candidateRow)'),
  'NocoDB v3 must poll Queued rows from print_queue with linked source records expanded'
);
assert(
  source.includes("sourceKind === 'product' ? PRODUCTS_TABLE : LOTS_TABLE") &&
  source.includes('`${nocoV3RecordsPath(tableId)}/${encodeURIComponent(sourcePk)}`') &&
  source.includes("where: nocoV3Where(businessField, 'eq', businessId)") &&
  !source.includes("where: nocoV3Where('nocopk', 'eq', sourcePk)") &&
  source.includes("['vc_products', 'products']") &&
  source.includes("['vc_lots', 'lots']"),
  'Label data must read vc_products/vc_lots by linked Record ID with business-id fallback'
);
assert(
  !source.includes("Failed to hydrate queued print job from vc_print_queue") &&
  source.includes("Failed to hydrate queued print job from source view"),
  'The NocoDB v3 polling path must no longer read vc_print_queue'
);

console.log('NocoDB v3 base-queue and source-view hydration smoke tests passed.');
