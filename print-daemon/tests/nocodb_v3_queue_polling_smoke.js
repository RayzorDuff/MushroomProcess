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
  linkedNocoValue(value) {
    if (value && typeof value === 'object') {
      return value.nocopk ?? value.id ?? '';
    }
    return value;
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
  source.includes('hydrateNocoV3QueueCandidate(candidateRow)'),
  'NocoDB v3 must poll Queued rows from print_queue and hydrate each candidate'
);
assert(
  source.includes("sourceKind === 'product' ? PRODUCTS_TABLE : LOTS_TABLE") &&
  source.includes("where: nocoV3Where('nocopk', 'eq', sourcePk)") &&
  source.includes("['vc_products', 'products']") &&
  source.includes("['vc_lots', 'lots']"),
  'Label data must hydrate from vc_products/vc_lots by source nocopk'
);
assert(
  !source.includes("Failed to hydrate queued print job from vc_print_queue") &&
  source.includes("Failed to hydrate queued print job from source view"),
  'The NocoDB v3 polling path must no longer read vc_print_queue'
);

console.log('NocoDB v3 base-queue and source-view hydration smoke tests passed.');
