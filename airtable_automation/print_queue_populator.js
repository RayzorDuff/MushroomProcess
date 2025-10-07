/**
 * Print Queue Populator (example)
 * Trigger: When certain fields change on lots/products, append to print_queue.
 * Adjust filterByFormula and pushed fields to match your base.
 */
const printTbl = base.getTable('print_queue');

// Example input
const { sourceKind, sourceId, copies } = input.config(); // e.g., 'lot'/'product', recordId, copies (default 1)
const n = typeof copies === 'number' && copies > 0 ? copies : 1;

for (let i=0;i<n;i++){
  await printTbl.createRecordAsync({
    source_kind: sourceKind,
    print_status: 'Queued',
    source_record_id: sourceId
  });
}
output.set('queued', n);
