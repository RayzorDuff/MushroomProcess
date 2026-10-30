/**
 * Script: commerce_test_readiness_smoke.js
 * Version: 2026-10-30.1
 * Summary: Static export readiness only; never reports browser E2E acceptance.
 */
'use strict';
const assert=require('node:assert/strict');const fs=require('node:fs');const path=require('node:path');
const root=path.join(__dirname,'..');
const app=JSON.parse(fs.readFileSync(path.join(__dirname,'MushroomProcess.json'),'utf8'));
const plan=JSON.parse(fs.readFileSync(path.join(root,'integrations/commerce/appsmith-readiness.json'),'utf8'));
assert.equal(plan.evidence_kind,'static_export_contract_only');
assert.equal(plan.future_test_database,'mushroomprocess_e2e');
for(const journey of plan.journeys) {
  assert.ok(['not_executed','blocked'].includes(journey.browser_status),'Static source cannot claim browser success');
  if(journey.browser_status==='blocked')assert.ok(journey.blocker);
  for(const name of journey.required_pages) {
    assert.ok(app.pageList.some(p=>p.unpublishedPage?.name===name && p.publishedPage?.name===name),`Missing canonical page: ${name}`);
  }
}
console.log('Static commerce Appsmith readiness contract passed; browser E2E remains unexecuted');
