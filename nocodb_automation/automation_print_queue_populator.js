/**
 * Print Queue Populator â€“ creates print_queue rows for lots/products
 * Inputs: source_kind ("lot"|"product"), source_id, printer_name, copies (default 1)
 * Copies label_* fields from source and sets print_status="queued"
 */
import { makeNC } from "./lib/noco.js";
const { NOCO_BASE_URL, NOCO_TOKEN, NOCO_PROJECT="mushroom_inventory" } = process.env;
const nc = makeNC({ baseUrl: NOCO_BASE_URL, token: NOCO_TOKEN, projectSlug: NOCO_PROJECT });
function pick(obj, keys){ const out={}; keys.forEach(k=>{ if(obj[k]!==undefined) out[k]=obj[k]; }); return out; }
export default async function handler(req,res){
  try{
    const { source_kind, source_id, printer_name, copies=1 } = req.body || {};
    if(!source_kind) throw new Error("source_kind required");
    if(!source_id) throw new Error("source_id required");
    const table = source_kind==="product" ? "products" : "lots";
    const row = await nc.getById(table, source_id);
    const labelFields = Object.keys(row).filter(k=>k.startsWith("label_"));
    const payload = pick(row, labelFields);
    const jobs = [];
    for(let i=0;i<Number(copies||1);i++){
      jobs.push({ source_kind, source_id, printer_name: printer_name||null, print_status:"queued", ...payload });
    }
    await nc.create("print_queue", jobs);
    res.status(200).json({ ok:true, enqueued: jobs.length });
  }catch(e){ res.status(400).json({ ok:false, error:String(e.message||e) }); }
}
