/**
 * LC Receive Syringe â€“ create purchased syringe lot
 * Requires: item_id (syringe item), strain_id, remaining_volume_ml (10 default).
 * Sets status=Fridge, item_category='lc_syringe_purchased'.
 */
import { makeNC } from "./lib/noco.js";
const { NOCO_BASE_URL, NOCO_TOKEN, NOCO_PROJECT="mushroom_inventory" } = process.env;
const nc = makeNC({ baseUrl: NOCO_BASE_URL, token: NOCO_TOKEN, projectSlug: NOCO_PROJECT });
export default async function handler(req,res){
  try{
    const { item_id, strain_id, remaining_volume_ml=10, operator } = req.body || {};
    const errs=[]; if(!item_id) errs.push("item_id required"); if(!strain_id) errs.push("strain_id required"); if(!(Number(remaining_volume_ml)>0)) errs.push("remaining_volume_ml must be > 0");
    if(errs.length) return res.status(400).json({ ok:false, error: errs.join("; ") });
    const now = new Date().toISOString();
    const created = await nc.create("lots", {
      item_id, strain_id,
      item_category:"lc_syringe_purchased",
      remaining_volume_ml: Number(remaining_volume_ml),
      status:"Fridge",
      created_at: now,
      operator: operator||"system"
    });
    res.status(200).json({ ok:true, id: created?.list?.[0]?.Id||created });
  }catch(e){ res.status(400).json({ ok:false, error:String(e.message||e) }); }
}
