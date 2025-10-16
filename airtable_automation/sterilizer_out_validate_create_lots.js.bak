/**
 * Sterilizer OUT – Validate & Create Lots
 * Trigger: Interface button → Run a script on `sterilization_runs` record
 * Input variables: { runRecordId }
 * Creates `lots` records for good_count and logs Events of Sterilized/Pasteurized.
 */
const runsTbl = base.getTable('sterilization_runs');
const lotsTbl = base.getTable('lots');
const eventsTbl = base.getTable('events');
const itemsTbl = base.getTable('items');
const recipesTbl = base.getTable('recipes');

const { runRecordId } = input.config();

async function setErr(id, msg){ await runsTbl.updateRecordAsync(id, { ui_error: msg ?? '' }); }
async function fail(msg){ await setErr(runRecordId, msg); output.set('error', msg); return; }

if (!runRecordId){ await fail('Missing runRecordId'); return; }

const run = await runsTbl.selectRecordAsync(runRecordId);
if (!run){ await fail('Run not found'); return; }

const plannedItem = run.getCellValue('planned_item');
const plannedRecipe = run.getCellValue('planned_recipe');
const plannedUnit = run.getCellValue('planned_unit_size');
const plannedCount = run.getCellValue('planned_count');
const good = run.getCellValue('good_count');
const bad = run.getCellValue('destroyed_count');
const processType = (run.getCellValueAsString('process_type') || '').toLowerCase();

if (!(typeof good === 'number') || !(typeof bad === 'number')){ await fail('Enter numbers for good_count and destroyed_count.'); return; }
if (good < 0 || bad < 0){ await fail('Counts must be ≥ 0.'); return; }
if (good + bad !== plannedCount){ await fail(`good_count + destroyed_count must equal planned_count (${plannedCount}).`); return; }
if (!plannedItem?.length || !plannedRecipe?.length){ await fail('Missing planned_item or planned_recipe.'); return; }
if (!(typeof plannedUnit === 'number') || plannedUnit <= 0){ await fail('planned_unit_size must be a positive number.'); return; }

// set end_time now
await runsTbl.updateRecordAsync(runRecordId, { end_time: new Date(), ui_error: '' });

const itemRef = plannedItem[0];
const recipeRef = plannedRecipe[0];

// Create lots for "good" bags
let newLotIds = [];
for (let i = 0; i < good; i++){
  const rec = await lotsTbl.createRecordAsync({
    item_id: [{ id: itemRef.id }],
    recipe_id: [{ id: recipeRef.id }],
    unit_size: plannedUnit,
    status: { name: (processType === 'pasteurized' ? 'Pasteurized' : 'Sterilized') },
    steri_run_id: runRecordId
  });
  newLotIds.push(rec);
}

// Log event on each new lot
for (const lotId of newLotIds){
  await eventsTbl.createRecordAsync({
    lot_id: [{ id: lotId }],
    type: { name: (processType === 'pasteurized' ? 'Pasteurized' : 'Sterilized') },
    timestamp: new Date(),
    station: 'Sterilizer',
    fields_json: JSON.stringify({ run_id: runRecordId })
  });
}

output.set('created_lots', newLotIds.length);
