#!/usr/bin/env node
const fs = require('fs');
const app = JSON.parse(fs.readFileSync('appsmith/MushroomProcess.json', 'utf8'));

const targetPages = new Set(['Lots', 'Lab - Inoculate', 'Lab - Spawn to Bulk']);
for (const pageEntry of app.pageList || []) {
  for (const key of ['unpublishedPage', 'publishedPage']) {
    const page = pageEntry[key];
    if (!page || !targetPages.has(page.name)) continue;
    const children = page.layouts?.[0]?.dsl?.children || [];
    const eligible = children.find(w => w.widgetName === 'chkShowEligibleProducts');
    const expired = children.find(w => w.widgetName === 'chkShowExpiredProducts');
    if (!eligible) throw new Error(`${page.name}/${key}: missing chkShowEligibleProducts`);
    if (!expired) throw new Error(`${page.name}/${key}: missing chkShowExpiredProducts`);
    if (expired.label !== 'Show Expired Products') throw new Error(`${page.name}/${key}: wrong expired label`);
    if (!String(expired.isDisabled).includes('chkShowEligibleProducts.isChecked')) {
      throw new Error(`${page.name}/${key}: expired checkbox must depend on Show Eligible Products`);
    }
  }
}


for (const pageEntry of app.pageList || []) {
  const up = pageEntry.unpublishedPage;
  const pub = pageEntry.publishedPage;
  if (!up || !pub || !targetPages.has(up.name)) continue;
  const u = (up.layouts?.[0]?.dsl?.children || []).find(w => w.widgetName === 'chkShowExpiredProducts');
  const p = (pub.layouts?.[0]?.dsl?.children || []).find(w => w.widgetName === 'chkShowExpiredProducts');
  if (u?.widgetId !== p?.widgetId || u?.key !== p?.key) {
    throw new Error(`${up.name}: published/unpublished expired checkbox identity is not synchronized`);
  }
}

let eligibleActions = 0;
for (const entry of app.actionList || []) {
  for (const key of ['unpublishedAction', 'publishedAction']) {
    const action = entry[key];
    if (!action || action.name !== 'qEligibleCultivationProducts') continue;
    eligibleActions++;
    const body = action.actionConfiguration?.body || '';
    if (!body.includes('is_expired')) throw new Error(`${action.pageId}/${key}: qEligible query does not filter is_expired`);
    if (!body.includes('chkShowExpiredProducts.isChecked')) throw new Error(`${action.pageId}/${key}: qEligible query does not bind expired checkbox`);
  }
}
if (eligibleActions !== 6) throw new Error(`Expected 6 qEligible actions, found ${eligibleActions}`);

const migration = fs.readFileSync('schema/pgsql/046_expired_product_cultivation_opt_in.sql', 'utf8');
if (!migration.includes('AS is_expired')) throw new Error('046 migration does not expose is_expired');
if (migration.includes("c.use_by IS NOT NULL AND c.use_by <")) throw new Error('046 still rejects Product solely for expiration date');
if (migration.includes("'shipped','consumed','expired','retired'")) throw new Error('046 still treats Expired location as terminal');

console.log('Appsmith Issue #57 expired Product opt-in smoke tests passed.');
