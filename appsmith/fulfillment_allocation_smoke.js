#!/usr/bin/env node
'use strict';
const fs=require('fs'),vm=require('vm'),assert=require('assert');
const os=require('os'),path=require('path'),cp=require('child_process');
const dir=fs.mkdtempSync(path.join(os.tmpdir(),'fulfillment-render-'));
const output=path.join(dir,'application.json');
cp.execFileSync('python3',['scripts/render_fulfillment_ui.py','--output',output]);
const app=JSON.parse(fs.readFileSync(output,'utf8'));
const original=JSON.parse(fs.readFileSync('appsmith/MushroomProcess.json','utf8'));
fs.rmSync(dir,{recursive:true,force:true});
for(const page of original.pageList.filter(p=>p.unpublishedPage.name!=='Fulfillment')) assert.deepEqual(app.pageList.find(p=>p.gitSyncId===page.gitSyncId),page);
const collection=app.actionCollectionList.find(c=>c.id==='Fulfillment_FulfillmentUI');
for(const side of ['publishedCollection','unpublishedCollection']) assert.equal(collection[side].body,fs.readFileSync('appsmith/fulfillment_ui.js','utf8'));
async function test(){
 const resets=[],alerts=[],store={fulfillment_selected_order_id:'order-1',fulfillment_selected_order:{airtable_record_id:'order-1',required_count:2}};
 let assigned=0,dispatches=0,searches=0;
 const detail=()=>({ok:true,items:[{line_id:'1',quantity:2,assigned_quantity:assigned,remaining_quantity:2-assigned}],progress:{linked_count:assigned,required_count:2,product_assignment_complete:assigned===2,can_dispatch:assigned>0},products_report:'Synthetic',product_ids_report:'P-1'});
 const context={appsmith:{store,user:{email:'operator@example.invalid'}},tblFulfillmentProducts:{selectedRow:{airtable_record_id:'product-1'}},tblFulfillmentOrders:{selectedRow:{}},tblFulfillmentOrderItems:{selectedRow:{line_id:'1'}},
  storeValue:async(k,v)=>{store[k]=v;},resetWidget:async n=>resets.push(n),showAlert:(...a)=>alerts.push(a),
  apiFulfillmentListOrders:{run:async()=>({ok:true,orders:[{airtable_record_id:'order-1',linked_count:assigned,required_count:2}]})},
  apiFulfillmentOrderDetail:{run:async()=>detail()},apiFulfillmentProductSearch:{run:async()=>{searches++;return {ok:true,products:[{product_id:'P-2'}],count:25};}},
  apiFulfillmentAssignProduct:{run:async()=>{assigned++;return {ok:true};}},apiFulfillmentDispatch:{run:async()=>{dispatches++;return {ok:true};}}
 };
 vm.createContext(context);context.FulfillmentUI=vm.runInContext('('+collection.unpublishedCollection.body.replace('export default','')+')',context);
 const ui=context.FulfillmentUI;
 await ui.reloadOrderDetail();
 await ui.searchProducts();assert.equal(searches,1);assert.equal(store.fulfillment_product_count,25);
 await ui.assignSelectedProduct();
 assert.equal(store.fulfillment_selected_order_id,'order-1');assert.equal(store.fulfillment_order_detail.items[0].remaining_quantity,1);
 assert.equal(store.fulfillment_linked_products[0].product_id,'P-1');assert.equal(dispatches,0);
 assert.deepEqual(resets,['inpFulfillmentProductSearch','tblFulfillmentProducts']);assert(!resets.includes('tblFulfillmentOrderItems'));
 await ui.assignSelectedProduct();assert(ui.selectedOrderProductAssignmentComplete());assert.equal(store.fulfillment_order_detail.items[0].remaining_quantity,0);assert.equal(dispatches,0);
 assert(alerts.some(a=>a[0].includes('All ordered units allocated')));
 const before=searches;await ui.searchProducts();assert.equal(searches,before);
 await ui.dispatchSelectedOrder();assert.equal(dispatches,1);assert.equal(store.fulfillment_selected_order_id,'order-1');
 context.apiFulfillmentAssignProduct.run=async()=>{throw Error('stale product');};assigned=0;await ui.reloadOrderDetail();
 await assert.rejects(ui.assignSelectedProduct(),/stale product/);assert.equal(store.fulfillment_assign_busy,false);
 // A delayed response for an old selection must not overwrite the new order.
 let release;context.apiFulfillmentProductSearch.run=()=>new Promise(r=>{release=r;});
 const promise=ui.searchProducts();await new Promise(r=>setImmediate(r));store.fulfillment_selected_order_id='order-2';release({ok:true,products:[{product_id:'STALE'}],count:1});await promise;
 assert(!store.fulfillment_product_results.some(r=>r.product_id==='STALE'));
 const flow=JSON.parse(fs.readFileSync('n8n/workflows/MushroomProcess - Fulfillment API - PGSQL.json','utf8'));
 const node=n=>flow.nodes.find(x=>x.name===n);
 const parse=new Function('$json',node('Code - Parse Product Search').parameters.jsCode);
 assert.equal(parse({body:{query:'',page:2,page_size:10}})[0].json.page,2);
 assert.throws(()=>parse({body:{page:1.5}}),/Invalid product page/);
 assert(node('PGSQL - List Products').parameters.query.includes('mp_fulfillment_search($1'));
 assert(node('PGSQL - Link Product To Order').parameters.query.includes('mp_fulfillment_assign($1'));
 assert(!flow.nodes.some(n=>n.name==='PGSQL - Mark Product Shipped'));
 for(const n of flow.nodes.filter(n=>n.type==='n8n-nodes-base.code'))new Function('$json','$','$env','$input',n.parameters.jsCode);
 const p=app.pageList.find(p=>p.unpublishedPage.name==='Fulfillment');
 for(const side of ['publishedPage','unpublishedPage']){
  const widgets=p[side].layouts[0].dsl.children;
  assert(widgets.find(w=>w.widgetName==='tblFulfillmentProducts').serverSidePaginationEnabled);
  assert(widgets.some(w=>w.widgetName==='btnFulfillmentDispatch'));
 }
 console.log('Fulfillment allocation UI: empty/paginated search, partial/full refresh, dispatch separation and stale-response guards passed.');
}
test().catch(e=>{console.error(e);process.exitCode=1;});
