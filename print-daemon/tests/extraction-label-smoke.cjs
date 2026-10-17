// Test the extraction-label formatter without a printer or database.
// Run: node print-daemon/tests/extraction-label-smoke.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const daemon = fs.readFileSync(path.join(__dirname, '..', 'print-daemon.js'), 'utf8').replace(/\r\n/g, '\n');
const match = daemon.match(/function extractionLabelText\(row\) \{[\s\S]*?\n\}\n\nasync function hydrateExtractionLabelFields/);
assert.ok(match, 'extraction label formatter found');
const context = { toFlat: value => value };
vm.runInNewContext(match[0].replace(/\n\nasync function hydrateExtractionLabelFields$/, ''), context);
const result = context.extractionLabelText({
  lot_id: 'LOT-261016-ABCD', material_weight_g: '37.50',
  solvent_type: 'ethanol', solvent_proof: '200',
  solvent_volume_ml: '100', created_at: '2026-10-16T13:00:00',
});
assert.equal(result.label_title_lot, 'Extraction Batch');
assert.equal(result.label_subtitle_lot, '37.5 g • 100 mL ethanol • 200 proof');
assert.equal(result.label_proc_line, 'Extraction started: 2026-10-16');
assert.equal(result.label_footer_lot, 'Lot: LOT-261016-ABCD');
const withoutProof = context.extractionLabelText({
  lot_id: 'LOT-261016-ZZZZ', material_weight_g: 20,
  solvent_type: 'ethanol', solvent_volume_ml: 80,
});
assert.equal(withoutProof.label_subtitle_lot, '20 g • 80 mL ethanol');
console.log('Extraction label formatter smoke: PASS');
