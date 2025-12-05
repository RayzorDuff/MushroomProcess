/**
 * Harvest â€“ create fresh/freezer tray products from a fruiting block
 * Inputs: source_block_lot_id, harvest_item_id, harvest_weight_g, flush_no
 * Creates product row referencing origin lot, sets tray_state based on item category
 * Event: "Harvest"
 */
import { makeNC } from "./lib/noco.js";
const { NOCO_BASE_URL, NOCO_TOKEN, NOCO_PROJECT="mushroom_inventory" } = process.env;
const nc = makeNC({ baseUrl: NOCO_BASE_URL, token: NOCO_TOKEN, projectSlug: NOCO_PROJECT });
export default async function handler(req,res){
  try{
    const { source_block_lot_id, harvest_item_id, harvest_weight_g, flush_no, operator } = req.body || {};
    const errs=[]; if(!source_block_lot_id) errs.push("source_block_lot_id required"); if(!harvest_item_id) errs.push("harvest_item_id required"); if(!(Number(harvest_weight_g)>0)) errs.push("harvest_weight_g must be > 0");
    if(errs.length) return res.status(400).json({ ok:false, error: errs.join("; ") });
    const now = new Date().toISOString();
    const trayState = /freezer_tray/i.test(harvest_item_id) ? "freezer_tray" : (/fresh_tray/i.test(harvest_item_id) ? "fresh_tray" : "tray");
    const created = await nc.create("products", {
      item_id: harvest_item_id,
      package_item_category: trayState,
      origin_lot_ids_json: JSON.stringify([source_block_lot_id]),
      net_weight_g: Number(harvest_weight_g),
      net_weight_oz: Number(harvest_weight_g)/28.3495,
      pack_date: now,
      label_template_id: null,
      tray_state: trayState
    });
    await nc.create("events", {
      lot_id: source_block_lot_id, type:"Harvest",
      timestamp: now, operator: operator||"system",
      station:"Harvest", fields_json: JSON.stringify({ harvest_item_id, harvest_weight_g, flush_no })
    });
    res.status(200).json({ ok:true, product_id: created?.list?.[0]?.Id||created });
  }catch(e){ res.status(400).json({ ok:false, error:String(e.message||e) }); }
}
