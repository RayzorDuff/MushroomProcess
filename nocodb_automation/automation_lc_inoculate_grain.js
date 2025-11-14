/**
 * LC â†’ Grain â€“ inoculate grain bag from LC lot
 * Requires: grain_lot_id, lc_lot_id, lc_volume_ml (>0)
 * Sets grain strain from LC, status=Colonizing, last_inoculation_date, decrements LC remaining_volume_ml
 * Respects override_inoc_time
 * Event: "Inoculated"
 */
import { makeNC } from "./lib/noco.js";
const { NOCO_BASE_URL, NOCO_TOKEN, NOCO_PROJECT="mushroom_inventory" } = process.env;
const nc = makeNC({ baseUrl: NOCO_BASE_URL, token: NOCO_TOKEN, projectSlug: NOCO_PROJECT });
async function fail(grainId,msg){ try{ await nc.update("lots", grainId, { ui_error: msg }); }catch{} throw new Error(msg); }
export default async function handler(req,res){
  try{
    const { grain_lot_id, lc_lot_id, lc_volume_ml, operator, override_inoc_time } = req.body || {};
    if(!grain_lot_id) throw new Error("grain_lot_id required");
    if(!lc_lot_id) return await fail(grain_lot_id, "lc_lot_id required");
    const vol = Number(lc_volume_ml); if(!(vol>0)) return await fail(grain_lot_id, "lc_volume_ml must be > 0");
    const grain = await nc.getById("lots", grain_lot_id);
    const lc    = await nc.getById("lots", lc_lot_id);
    if(!["Sterilized","Sealed"].includes(grain.status)) return await fail(grain_lot_id, `Grain status must be Sterilized/Sealed (got ${grain.status})`);
    if(lc.remaining_volume_ml!=null && Number(lc.remaining_volume_ml)<vol) return await fail(grain_lot_id, "LC has insufficient remaining_volume_ml");
    const inocAt = override_inoc_time ? new Date(override_inoc_time).toISOString() : new Date().toISOString();
    await nc.update("lots", grain_lot_id, {
      strain_id: lc.strain_id||grain.strain_id||null,
      status:"Colonizing",
      last_inoculation_date: inocAt,
      ui_error: ""
    });
    if(lc.remaining_volume_ml!=null){
      await nc.update("lots", lc_lot_id, { remaining_volume_ml: Math.max(0, Number(lc.remaining_volume_ml)-vol) });
    }
    await nc.create("events", {
      lot_id: grain_lot_id, type:"Inoculated",
      timestamp: inocAt, operator: operator||"system",
      station:"LC â†’ Grain", fields_json: JSON.stringify({ lc_lot_id, lc_volume_ml: vol })
    });
    res.status(200).json({ ok:true });
  }catch(e){ res.status(400).json({ ok:false, error:String(e.message||e) }); }
}
