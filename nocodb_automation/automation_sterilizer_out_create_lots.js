/**
 * Sterilizer OUT â€“ create lots
 * Validation: planned_count = good_count + destroyed_count; required item/recipe/unit_size.
 * Creates 'good_count' lots with status "Sterilized" and logs an Event "Sterilized".
 * Sets sterilization_runs.end_time if missing. Errors -> ui_error.
 * Trigger: Button on sterilization_runs -> Run Webhook { run_id }
 */
import { makeNC } from "./lib/noco.js";
const { NOCO_BASE_URL, NOCO_TOKEN, NOCO_PROJECT="mushroom_inventory" } = process.env;
const nc = makeNC({ baseUrl: NOCO_BASE_URL, token: NOCO_TOKEN, projectSlug: NOCO_PROJECT });
async function fail(runId, msg){ try{ await nc.update("sterilization_runs", runId, { ui_error: msg }); }catch{} throw new Error(msg); }
export default async function handler(req,res){
  try{
    const { run_id } = req.body || {};
    if(!run_id) throw new Error("Missing run_id");
    const run = await nc.getById("sterilization_runs", run_id);
    const { planned_item, planned_recipe, planned_unit_size, planned_count, good_count, destroyed_count, operator, end_time, process_type } = run;
    if(planned_count==null || good_count==null || destroyed_count==null) return await fail(run_id, "planned_count, good_count, destroyed_count required");
    const sum = Number(good_count)+Number(destroyed_count);
    if(Number(planned_count)!==sum) return await fail(run_id, `Counts mismatch planned=${planned_count} vs good+destroyed=${sum}`);
    if(!planned_item||!planned_recipe||!planned_unit_size) return await fail(run_id, "planned_item, planned_recipe, planned_unit_size required");
    const nowIso = new Date().toISOString();
    const rows = Array.from({length:Number(good_count)},()=>({
      item_id: planned_item,
      recipe_id: planned_recipe,
      unit_size: Number(planned_unit_size),
      qty:1,
      status:"Sterilized",
      operator: operator||"system",
      steri_run_id: run.steri_run_id ?? run_id
    }));
    if(rows.length) await nc.create("lots", rows);
    await nc.create("events", {
      type:"Sterilized",
      timestamp: nowIso,
      operator: operator||"system",
      station:"Sterilizer",
      fields_json: JSON.stringify({ run_id, process_type: process_type||"Sterilized", planned_count, good_count, destroyed_count })
    });
    await nc.update("sterilization_runs", run_id, { end_time: end_time||nowIso, ui_error: "" });
    res.status(200).json({ ok:true, created: rows.length });
  }catch(e){ res.status(400).json({ ok:false, error:String(e.message||e) }); }
}
