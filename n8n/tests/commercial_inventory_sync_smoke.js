#!/usr/bin/env node
'use strict';
const fs = require('fs');
const path = require('path');
const assert = require('assert');
const root = path.resolve(__dirname, '../..');
const old = JSON.parse(fs.readFileSync(path.join(root,'n8n/workflows/MushroomProcess - Ecwid Catalog Sync - PGSQL.json'),'utf8'));
const flow = JSON.parse(fs.readFileSync(path.join(root,'n8n/workflows/MushroomProcess - Commercial Inventory Sync - PGSQL.json'),'utf8'));
const byName = name => { const n = flow.nodes.find(n=>n.name===name); assert(n,'Missing node: '+name);return n; };
assert.strictEqual(flow.active,false);
assert.notStrictEqual(flow.name,old.name);
assert(!flow.nodes.some(n=>JSON.stringify(n).toLowerCase().includes('airtable')));
for(const name of old.nodes.map(n=>n.name).filter(n=>n!=='Schedule - Hourly Ecwid Catalog Sync')) {
  const a=old.nodes.find(n=>n.name===name);
  const b=byName(name);
  assert.deepStrictEqual(b.parameters,a.parameters,'Legacy Ecwid behavior altered: '+name);
}
const ecwid = byName('IF - Ecwid Provider Enabled?').parameters.conditions.conditions[0].leftValue;
const erp = byName('IF - ERP Availability Enabled?').parameters.conditions.conditions[0].leftValue;
const woo = byName('IF - Woo Inventory Enabled?').parameters.conditions.conditions[0].leftValue;
assert(ecwid.includes("|| 'true'"),'Ecwid must be default enabled');
assert(erp.includes("|| 'false'"),'ERP must be default disabled');
assert(woo.includes("|| 'false'"),'Woo must be default disabled');
assert(byName('PGSQL - Read Reservation-adjusted MP Inventory').parameters.query.includes('mp_commerce_inventory()'));
assert(byName('PGSQL - Read Reservation-adjusted MP Inventory').parameters.query.includes('mp_ecommerce_catalog_inventory()'));
assert(byName('HTTP - Update ERP Operational Availability').parameters.url.includes('inventory_api.update_availability'));
const updateWoo=byName('HTTP - Update Woo Managed Stock Only').parameters;
assert.strictEqual(updateWoo.method,'PUT');
assert(updateWoo.jsonBody.includes('stock_quantity'));
assert(!/(regular_price|sale_price|tax_class|status|catalog_visibility|images)/.test(updateWoo.jsonBody));
assert(byName('Code - Verify Reviewed Woo Mapping').parameters.jsCode.includes('shop-test.danks.store'));
assert(byName('Code - Verify Woo Ownership and Draft').parameters.jsCode.includes('_rootedops_source_key'));
assert(byName('Code - Verify Woo Ownership and Draft').parameters.jsCode.includes('manage_stock'));
assert(byName('Code - Verify Woo Stock Response').parameters.jsCode.includes('stock_quantity'));
for(const name of ['Manual Trigger','Schedule - Hourly Commercial Inventory Sync']) {
  const targets=(flow.connections[name]?.main||[]).flat().map(v=>v.node);
  assert(targets.includes('IF - Ecwid Provider Enabled?'));
  assert(targets.includes('PGSQL - Read Reservation-adjusted MP Inventory'));
}
assert.deepStrictEqual(flow.connections['IF - Ecwid Provider Enabled?'].main[0].map(x=>x.node),
 ['PGSQL - Load Ecwid Catalog Sync Candidates']);
for(const node of flow.nodes.filter(n=>n.type==='n8n-nodes-base.code')) {
  new Function('$json','$', '$env', 'Buffer',node.parameters.jsCode);
}
console.log('Merged inventory workflow: legacy Ecwid unchanged, MP snapshot merged, ERP/Woo opt-in disabled and checked.');
