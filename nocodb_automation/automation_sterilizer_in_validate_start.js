/**
 * Sterilizer IN â€“ validate start
 * Ensures: planned_unit_size > 0, planned_count > 0, start_time set, operator set.
 * Writes validation errors to sterilization_runs.ui_error.
 * Trigger: Button on sterilization_runs -> Run Webhook with { run_id }
 */
import { makeNC } from "./lib/noco.js";
const { NOCO_BASE_URL, NOCO_TOKEN, NOCO_PROJECT="mushroom_inventory" } = process.env;
const nc = makeNC({ baseUrl: NOCO_BASE_URL, token: NOCO_TOKEN, projectSlug: NOCO_PROJECT });
async function fail(runId, msg){ try{ await nc.update("sterilization_runs", runId, { ui_error: msg }); }catch{} throw new Error(msg); }
export default async function handler(req,res){
  try{
    const { run_id } = req.body || {};
    if(!run_id) throw new Error("Missing run_id");
    const r = await nc.getById("sterilization_runs", run_id);
    const errs = [];
    if(!(Number(r.planned_unit_size)>0)) errs.push("planned_unit_size must be > 0");
    if(!(Number(r.planned_count)>0)) errs.push("planned_count must be > 0");
    if(!r.start_time) errs.push("start_time is required");
    if(!r.operator) errs.push("operator is required");
    if(errs.length) return await fail(run_id, errs.join("; "));
    await nc.update("sterilization_runs", run_id, { ui_error: "" });
    res.status(200).json({ ok:true });
  }catch(e){ res.status(400).json({ ok:false, error:String(e.message||e) }); }
}
