/**
 * LC Inoculate Flask â€“ uses purchased syringe or other LC as source
 * Requires: target_flask_lot_id, source_lc_lot_id, lc_volume_ml (>0)
 * Updates target strain, status=FullyColonized (LC context), last_inoculation_date
 * Decrements source remaining_volume_ml
 * Event: "LCFlaskInoculated"
 */
import { makeNC } from "./lib/noco.js";
const { NOCO_BASE_URL, NOCO_TOKEN, NOCO_PROJECT="mushroom_inventory" } = process.env;
const nc = makeNC({ baseUrl: NOCO_BASE_URL, token: NOCO_TOKEN, projectSlug: NOCO_PROJECT });
async function fail(lotId,msg){ try{ await nc.update("lots", lotId, { ui_error: msg }); }catch{} throw new Error(msg); }
export default async function handler(req,res){
  try{
    const { target_flask_lot_id, source_lc_lot_id, lc_volume_ml, operator, override_inoc_time } = req.body || {};
    if(!target_flask_lot_id) throw new Error("target_flask_lot_id required");
    if(!source_lc_lot_id) return await fail(target_flask_lot_id, "source_lc_lot_id required");
    const vol = Number(lc_volume_ml); if(!(vol>0)) return await fail(target_flask_lot_id, "lc_volume_ml must be > 0");
    const target = await nc.getById("lots", target_flask_lot_id);
    const source = await nc.getById("lots", source_lc_lot_id);
    if(source.remaining_volume_ml!=null && Number(source.remaining_volume_ml)<vol) return await fail(target_flask_lot_id,"Insufficient source remaining_volume_ml");
    const inocAt = override_inoc_time ? new Date(override_inoc_time).toISOString() : new Date().toISOString();
    await nc.update("lots", target_flask_lot_id, {
      strain_id: source.strain_id||target.strain_id||null,
      status:"FullyColonized",
      last_inoculation_date: inocAt,
      ui_error: ""
    });
    if(source.remaining_volume_ml!=null){
      await nc.update("lots", source_lc_lot_id, { remaining_volume_ml: Math.max(0, Number(source.remaining_volume_ml)-vol) });
    }
    await nc.create("events", {
      lot_id: target_flask_lot_id, type:"LCFlaskInoculated",
      timestamp: inocAt, operator: operator||"system",
      station:"LC Lab", fields_json: JSON.stringify({ source_lc_lot_id, lc_volume_ml: vol })
    });
    res.status(200).json({ ok:true });
  }catch(e){ res.status(400).json({ ok:false, error:String(e.message||e) }); }
}
