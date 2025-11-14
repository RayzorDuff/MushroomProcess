/**
 * FreezeDry & Package â€“ consume tray product -> create packaged product
 * Inputs: source_product_id (tray), package_item_id, target_weight_g
 * Moves tray_state to "empty_tray"; creates packaged product with origin chain preserved
 */
import { makeNC } from "./lib/noco.js";
const { NOCO_BASE_URL, NOCO_TOKEN, NOCO_PROJECT="mushroom_inventory" } = process.env;
const nc = makeNC({ baseUrl: NOCO_BASE_URL, token: NOCO_TOKEN, projectSlug: NOCO_PROJECT });
export default async function handler(req,res){
  try{
    const { source_product_id, package_item_id, target_weight_g, operator } = req.body || {};
    const errs=[]; if(!source_product_id) errs.push("source_product_id required"); if(!package_item_id) errs.push("package_item_id required"); if(!(Number(target_weight_g)>0)) errs.push("target_weight_g must be > 0");
    if(errs.length) return res.status(400).json({ ok:false, error: errs.join("; ") });
    const src = await nc.getById("products", source_product_id);
    const now = new Date().toISOString();
    await nc.update("products", source_product_id, { tray_state: "empty_tray" });
    const created = await nc.create("products", {
      item_id: package_item_id,
      package_item_category: "freezedriedmushrooms",
      origin_lot_ids_json: src.origin_lot_ids_json||"[]",
      net_weight_g: Number(target_weight_g),
      net_weight_oz: Number(target_weight_g)/28.3495,
      pack_date: now,
      label_template_id: null
    });
    await nc.create("events", {
      lot_id: null, type:"PackageFreezeDried",
      timestamp: now, operator: operator||"system",
      station:"Packaging", fields_json: JSON.stringify({ source_product_id, package_item_id, target_weight_g })
    });
    res.status(200).json({ ok:true, product_id: created?.list?.[0]?.Id||created });
  }catch(e){ res.status(400).json({ ok:false, error:String(e.message||e) }); }
}
