#!/usr/bin/env node
'use strict';
const fs=require('fs'),vm=require('vm'),cp=require('child_process'),os=require('os'),path=require('path'),assert=require('assert');
const dir=fs.mkdtempSync(path.join(os.tmpdir(),'cash-ui-')),out=path.join(dir,'app.json');
cp.execFileSync('python3',['scripts/render_fulfillment_ui.py','--output',out]);
const app=JSON.parse(fs.readFileSync(out));fs.rmSync(dir,{recursive:true,force:true});
const collection=app.actionCollectionList.find(c=>c.id==='Fulfillment_FulfillmentUI');
const flow=JSON.parse(fs.readFileSync('n8n/workflows/MushroomProcess - Cash Receipts - PGSQL.json'));
assert.equal(flow.active,false);assert.equal(flow.nodes.find(n=>n.name==='Receive cash').parameters.authentication,'headerAuth');
assert.equal(app.datasourceList.find(d=>d.name==='mushroomprocess-cash-n8n').datasourceConfiguration.headers[0].value,'');
let receipts=0,refreshes=0;
const context={appsmith:{store:{fulfillment_selected_order_id:'cash-order'}},chkCashReceived:{isChecked:false},storeValue:async(k,v)=>context.appsmith.store[k]=v,resetWidget:async()=>{},showAlert:()=>{},apiFulfillmentCashReceived:{run:async()=>{receipts++;return {ok:true};}}};
vm.createContext(context);const ui=vm.runInContext('('+collection.unpublishedCollection.body.replace('export default','')+')',context);context.FulfillmentUI=ui;
ui.selectedOrderIsCashLike=()=>true;ui.refreshSelectedOrder=async()=>refreshes++;
(async()=>{await ui.recordCashReceived();assert.equal(receipts,0);context.chkCashReceived.isChecked=true;await ui.recordCashReceived();assert.equal(receipts,1);assert.equal(refreshes,1);assert.equal(context.appsmith.store.fulfillment_selected_order_id,'cash-order');assert.equal(context.appsmith.store.fulfillment_cash_busy,false);console.log('Cash UI: explicit receipt separate from allocation/dispatch, private authenticated workflow, preserved order.');})().catch(e=>{console.error(e);process.exitCode=1;});
