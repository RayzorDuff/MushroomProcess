/**
 * Fruiting actions â€“ StartFruiting (from Fruiting page) and Composted
 */
import { makeNC } from "./lib/noco.js";
const { NOCO_BASE_URL, NOCO_TOKEN, NOCO_PROJECT="mushroom_inventory" } = process.env;
const nc = makeNC({ baseUrl: NOCO_BASE_URL, token: NOCO_TOKEN, projectSlug: NOCO_PROJECT });
async function fail(lotId,msg){ try{ await nc.update("lots", lotId, { ui_error: msg }); }catch{} throw new Error(msg); }
export default async function handler(req,res){
  try{
    const { lot_id, action, operator } = req.body || {};
    if(!lot_id) throw new Error("Missing lot_id");
    const now = new Date().toISOString();
    if(action==="StartFruiting"){
      await nc.update("lots", lot_id, { status:"Fruiting", ui_error:"" });
      await nc.create("events",{ lot_id, type:"StartFruiting", timestamp: now, operator: operator||"system", station:"Fruiting", fields_json:"{}" });
    }else if(action==="Composted"){
      await nc.update("lots", lot_id, { status:"Retired", ui_error:"" });
      await nc.create("events",{ lot_id, type:"Composted", timestamp: now, operator: operator||"system", station:"Fruiting", fields_json:"{}" });
    }else{
      return await fail(lot_id, `Unknown action: ${action}`);
    }
    res.status(200).json({ ok:true });
  }catch(e){ res.status(400).json({ ok:false, error:String(e.message||e) }); }
}
