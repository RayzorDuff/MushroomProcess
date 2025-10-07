/**
 * Sterilizer IN – Validate & Start
 * Trigger: Interface button → Run a script on `sterilization_runs` record
 * Input variables: { runRecordId }
 * Writes user-visible errors to `ui_error` on the run.
 */
const runsTbl = base.getTable('sterilization_runs');

const { runRecordId } = input.config();

async function setErr(id, msg){ await runsTbl.updateRecordAsync(id, { ui_error: msg ?? '' }); }
async function fail(msg){ await setErr(runRecordId, msg); output.set('error', msg); return; }

if (!runRecordId){ await fail('Missing runRecordId'); return; }

const run = await runsTbl.selectRecordAsync(runRecordId);
if (!run){ await fail('Run not found'); return; }

const processType = run.getCellValueAsString('process_type');
const plannedItem = run.getCellValue('planned_item');
const plannedRecipe = run.getCellValue('planned_recipe');
const plannedUnit = run.getCellValue('planned_unit_size');
const plannedCount = run.getCellValue('planned_count');
const startTime = run.getCellValue('start_time');
const operator = run.getCellValueAsString('operator');

if (!processType){ await fail('Set process_type (Sterilized or Pasteurized).'); return; }
if (!plannedItem?.length){ await fail('Select planned_item.'); return; }
if (!plannedRecipe?.length){ await fail('Select planned_recipe.'); return; }
if (!(typeof plannedUnit === 'number') || plannedUnit <= 0){ await fail('planned_unit_size must be a positive number.'); return; }
if (!(typeof plannedCount === 'number') || plannedCount <= 0){ await fail('planned_count must be a positive number.'); return; }
if (!startTime){ await fail('start_time must be set.'); return; }
if (!operator){ await fail('operator must be set.'); return; }

await setErr(runRecordId, '');
output.set('ok', true);
