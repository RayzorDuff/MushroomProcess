/**
 * Dark Room actions â€“ MoveToFridge, ColdShock, ApplyCasing, StartFruiting, Contaminated, Shake
 * Validations & status updates mirrored from Airtable flow; errors -> ui_error.
 */
import { makeNC } from "./lib/noco.js";
const { NOCO_BASE_URL, NOCO_TOKEN, NOCO_PROJECT="mushroom_inventory" } = process.env;
const nc = makeNC({ baseUrl: NOCO_BASE_URL, token: NOCO_TOKEN, projectSlug: NOCO_PROJECT });
async function fail(lotId,msg){ try{ await nc.update("lots", lotId, { ui_error: msg }); }catch{} throw new Error(msg); }
export default async function handler(req,res){
  try{
    const { lot_id, action, casing_lot_id, operator } = req.body || {};
    if(!lot_id) throw new Error("Missing lot_id");
    const lot = await nc.getById("lots", lot_id);
    const now = new Date().toISOString();
    const okFully = lot.status==="FullyColonized" || lot.status==="Fridge";
    switch(action){
      case "MoveToFridge":
      case "ColdShock":{
        const exception = lot.item_category==="lc_syringe_purchased";
        if(!okFully && !exception) return await fail(lot_id, `${action} requires FullyColonized`);
        await nc.update("lots", lot_id, { status:"Fridge", ui_error:"" });
        await nc.create("events",{ lot_id, type: action, timestamp: now, operator: operator||"system", station:"Dark Room", fields_json:"{}" });
        break;
      }
      case "ApplyCasing":{
        if(lot.item_category!=="fruiting_block") return await fail(lot_id,"ApplyCasing only on fruiting_block");
        if(!casing_lot_id) return await fail(lot_id,"casing_lot_id required");
        await nc.update("lots", lot_id, { casing_lot_id, ui_error:"" });
        await nc.create("events",{ lot_id, type:"ApplyCasing", timestamp: now, operator: operator||"system", station:"Dark Room", fields_json: JSON.stringify({ casing_lot_id }) });
        break;
      }
      case "StartFruiting":{
        await nc.update("lots", lot_id, { status:"Fruiting", ui_error:"" });
        await nc.create("events",{ lot_id, type:"StartFruiting", timestamp: now, operator: operator||"system", station:"Dark Room", fields_json:"{}" });
        break;
      }
      case "Contaminated":{
        await nc.update("lots", lot_id, { status:"Retired", ui_error:"" });
        await nc.create("events",{ lot_id, type:"Contaminated", timestamp: now, operator: operator||"system", station:"Dark Room", fields_json:"{}" });
        break;
      }
      case "Shake":{
        await nc.create("events",{ lot_id, type:"Shake", timestamp: now, operator: operator||"system", station:"Dark Room", fields_json:"{}" });
        await nc.update("lots", lot_id, { ui_error:"" });
        break;
      }
      default: return await fail(lot_id, `Unknown action: ${action}`);
    }
    res.status(200).json({ ok:true });
  }catch(e){ res.status(400).json({ ok:false, error:String(e.message||e) }); }
}
