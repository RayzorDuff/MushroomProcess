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
    '(source_kind,neq,"product")',
  ]),
  '(print_status,eq,"Queued")~and(source_kind,neq,"product")',
  'NocoDB v3 clauses must use the documented ~and syntax'
);

const fetchStart = source.indexOf('async function fetchQueued(viewName)');
const fetchEnd = source.indexOf('/**\n * Update a single print_queue record', fetchStart);
assert(fetchStart >= 0 && fetchEnd > fetchStart, 'Unable to isolate fetchQueued()');
const fetchSource = source.slice(fetchStart, fetchEnd);

assert(
  fetchSource.includes('PRINT_QUEUE_WRITE_TABLE') &&
  fetchSource.includes("nocoV3Where('print_status', 'eq', 'Queued')") &&
  fetchSource.includes('where: candidateWhere') &&
  fetchSource.includes('pageSize: 100'),
  'NocoDB v3 polling must read Queued candidates from the simple print_queue table'
);

assert(
  fetchSource.includes('PRINT_QUEUE_READ_TABLE') &&
  fetchSource.includes("nocoV3Where('nocopk', 'eq', writeId)") &&
  fetchSource.includes('pageSize: 1'),
  'Each queued base-table candidate must be hydrated individually from vc_print_queue by nocopk'
);

assert(
  fetchSource.includes("target !== PRINT_TARGET_VALUE") &&
  fetchSource.includes('hydrated.push(rec)'),
  'Print-target routing must be enforced locally after computed-view hydration'
);

assert(
  !fetchSource.includes('const where = buildNocoV3QueueWhere();'),
  'fetchQueued() must not filter vc_print_queue directly by computed print_target'
);

assert(
  source.includes("log.error('Failed to hydrate queued print job from vc_print_queue'") &&
  source.includes("log.error('Cycle error', { err: e?.message || String(e), ...httpErrorMeta(e) });"),
  'NocoDB failures must include request/status/response diagnostics'
);

console.log('NocoDB v3 base-table queue polling and per-job hydration smoke tests passed.');
