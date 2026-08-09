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

assert(start >= 0 && end > start, 'Unable to locate NocoDB where helper functions in print-daemon.js');

const context = {
  PRINT_TARGET_FIELD: 'print_target',
  PRINT_TARGET_VALUE: '',
  NOCODB_EXTRA_WHERE: '',
};
vm.createContext(context);
vm.runInContext(source.slice(start, end), context);

assert.strictEqual(
  context.nocoV3Where('print_status', 'eq', 'Queued'),
  '(print_status,eq,"Queued")',
  'NocoDB v3 queue status must be quoted safely'
);

assert.strictEqual(
  context.combineNocoV3WhereClauses([
    '(print_status,eq,"Queued")',
    '(print_target,eq,"ZEBRA")',
  ]),
  '(print_status,eq,"Queued")~and(print_target,eq,"ZEBRA")',
  'NocoDB v3 clauses must use the documented ~and syntax'
);

assert.strictEqual(
  context.buildNocoV3QueueWhere('print_target', 'ZEBRA', ''),
  '(print_status,eq,"Queued")~and(print_target,eq,"ZEBRA")',
  'Zebra polling must be filtered to queued Zebra jobs on the server'
);

assert.strictEqual(
  context.buildNocoV3QueueWhere('print_target', 'TRAYS', ''),
  '(print_status,eq,"Queued")~and(print_target,eq,"TRAYS")',
  'Tray polling must be filtered to queued tray jobs on the server'
);

assert.strictEqual(
  context.buildNocoV3QueueWhere('print_target', '', ''),
  '(print_status,eq,"Queued")',
  'An un-routed daemon must still filter to queued jobs'
);

assert.strictEqual(
  context.buildNocoV3QueueWhere('print_target', 'ZEBRA', '(source_kind,neq,"product")'),
  '(print_status,eq,"Queued")~and(print_target,eq,"ZEBRA")~and(source_kind,neq,"product")',
  'Advanced NOCODB_EXTRA_WHERE clauses must be appended to the queue filter'
);

assert(
  source.includes('const where = buildNocoV3QueueWhere();') &&
  source.includes('where,') &&
  source.includes("log.debug('Polled NocoDB v3 print queue'"),
  'fetchQueued() must send the server-side where clause and log the poll result'
);

console.log('NocoDB v3 server-side queue polling smoke tests passed.');
