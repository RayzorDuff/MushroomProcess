#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const exportPath = path.join(__dirname, 'MushroomProcess.json');
const raw = fs.readFileSync(exportPath, 'utf8');
const app = JSON.parse(raw);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

// qSpawnToBulkLocations is already configured as an automatic/on-load query.
// LotsSpawnToBulk must only read its .data; manually triggering .run() from the
// same JS dependency tree causes Appsmith's reactive-dependency misuse error.
assert(
  !raw.includes('qSpawnToBulkLocations.run()'),
  'Issue #57 correction failed: qSpawnToBulkLocations.run() still appears in the Appsmith export.'
);

let automaticLocationActions = 0;
let eligibleCandidateQueries = 0;
for (const entry of app.actionList || []) {
  for (const side of ['unpublishedAction', 'publishedAction']) {
    const action = entry?.[side];
    if (!action) continue;
    if (action.name === 'qSpawnToBulkLocations') {
      assert(
        action.runBehaviour === 'AUTOMATIC',
        `${action.pageId}/${side}: qSpawnToBulkLocations must remain AUTOMATIC/on-load.`
      );
      automaticLocationActions += 1;
    }
    if (action.name === 'qEligibleCultivationProducts') {
      const body = String(action.actionConfiguration?.body || '');
      assert(
        body.includes('v_product_cultivation_candidates'),
        `${action.pageId}/${side}: eligible Product query is not using the canonical candidate view.`
      );
      eligibleCandidateQueries += 1;
    }
  }
}

assert(automaticLocationActions >= 4, 'Expected Spawn-to-Bulk location actions on both application copies.');
assert(eligibleCandidateQueries >= 6, 'Expected eligible Product queries on Lots, Inoculate, and Spawn-to-Bulk application copies.');

console.log('Appsmith Issue #57 Phase 2 corrective smoke tests passed.');
