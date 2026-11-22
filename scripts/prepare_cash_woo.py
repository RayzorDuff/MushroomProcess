"""Render cash-aware Woo fulfillment artifacts after reviewed Woo stack merge."""
import argparse
import copy
import json
from pathlib import Path
from render_fulfillment_ui import render, ROOT

def workflow(source):
    result=copy.deepcopy(source)
    node=next(n for n in result['nodes'] if n['name']=='Commerce list')
    sql=node['parameters']['query']
    old="AND o.reservation_confirmed"
    if sql.count(old)!=1:raise ValueError('Review changed Woo list query before cash overlay')
    sql=sql.replace(old,"AND (o.reservation_confirmed OR (o.snapshot->>'payment_processor'='cash' AND o.status IN ('pending','on-hold','processing','completed') AND jsonb_array_length(o.snapshot->'refunds')=0))")
    sql=sql.replace("'status',o.status,", "'status',o.status,'currency',o.snapshot->>'currency','total',o.snapshot->>'total','payment_processor',o.snapshot->>'payment_processor',")
    node['parameters']['query']=sql
    result['active']=False
    return result

def application(base,woo):
    app=render(copy.deepcopy(base))
    existing={a['id'] for a in app['actionList']}
    if existing & {a['id'] for a in woo['actions']}:raise ValueError('Woo overlay already present: use a clean backed-up source export')
    app['actionList'].extend(copy.deepcopy(woo['actions']))
    if not any(d['name']==woo['datasource']['name'] for d in app['datasourceList']):app['datasourceList'].append(copy.deepcopy(woo['datasource']))
    page=next(p for p in app['pageList'] if p['unpublishedPage']['name']=='Fulfillment')
    for side,widgets in woo['widgets'].items():
        dsl=page[side]['layouts'][0]['dsl'];last=max(w['bottomRow'] for w in dsl['children'])
        if last>172:raise ValueError('Review changed Fulfillment layout before overlay')
        offset=last-164+4
        for widget in copy.deepcopy(widgets):
            for prop in ['topRow','bottomRow','mobileTopRow','mobileBottomRow','originalTopRow','originalBottomRow']:
                if prop in widget:widget[prop]+=offset
            if widget['widgetName']=='tblWooOrders':
                widget['onRowSelected']='{{ storeValue("woo_selected_order_id", tblWooOrders.selectedRow.order_id) }}'
                widget['defaultSelectedRowIndex']='{{ (apiWooOrders.data.orders || []).findIndex(r => r.order_id === appsmith.store.woo_selected_order_id) }}'
                widget.setdefault('dynamicTriggerPathList',[]).append({'key':'onRowSelected'})
                widget.setdefault('dynamicBindingPathList',[]).append({'key':'defaultSelectedRowIndex'})
            dsl['children'].append(widget)
        # Cash receipt action uses the private cash datasource, not browser state secrets.
        amount=copy.deepcopy(next(w for w in widgets if w['widgetName']=='inpWooPostage'))
        amount.update(widgetName='inpWooCashAmount',widgetId='woo-cash-amount-061',key='woo-cash-amount-061',label='Cash amount received',topRow=292+offset,bottomRow=299+offset,leftColumn=0,rightColumn=20,defaultText='')
        dsl['children'].append(amount)
        cash_widgets=json.loads((ROOT/'appsmith/fulfillment_cash_overlay.json').read_text())['widgets'][side]
        checkbox=copy.deepcopy(cash_widgets['chkCashReceived']);checkbox.update(widgetName='chkWooCashReceived',widgetId='woo-cash-check-061',key='woo-cash-check-061',isVisible=True,topRow=292+offset,bottomRow=297+offset,leftColumn=21,rightColumn=43)
        dsl['children'].append(checkbox)
        button=copy.deepcopy(next(w for w in widgets if w['widgetName']=='btnWooPick'))
        button.update(widgetName='btnWooCashReceived',widgetId='woo-cash-receipt-061',key='woo-cash-receipt-061',text='Record Cash Received',topRow=299+offset,bottomRow=303+offset,leftColumn=0,rightColumn=24,
            isDisabled='{{ !chkWooCashReceived.isChecked || tblWooOrders.selectedRow.payment_processor !== "cash" }}',onClick='{{ apiWooCashReceived.run(r=>{showAlert("Cash receipt saved; ERP posting is separately reviewed/retried.","success");resetWidget("chkWooCashReceived",true);}) }}')
        dsl['children'].append(button);dsl['bottomRow']=max(dsl['bottomRow'],307+offset)
    cash=json.loads((ROOT/'appsmith/fulfillment_cash_overlay.json').read_text())
    api=copy.deepcopy(cash['actions'][0]);api['id']='Fulfillment_apiWooCashReceived';api['gitSyncId']='woo-cash-receipt-061'
    for side in ['publishedAction','unpublishedAction']:
        api[side]['name']='apiWooCashReceived'
        api[side]['actionConfiguration']['body']='{ "provider":"woocommerce", "site_key":"danks.store", "external_order_id": {{ tblWooOrders.selectedRow.order_id || "" }}, "operator": {{ appsmith.user.email || appsmith.user.name || "" }}, "amount": {{ inpWooCashAmount.text || "" }}, "currency": {{ tblWooOrders.selectedRow.currency || "" }}, "cash_received": {{ chkWooCashReceived.isChecked }} }'
    app['actionList'].append(api)
    for side in ['publishedPage','unpublishedPage']:
        for widget in page[side]['layouts'][0]['dsl']['children']:
            for key,value in list(widget.items()):
                if isinstance(value,str) and '{{' in value:
                    kind='dynamicTriggerPathList' if key.startswith('on') else 'dynamicBindingPathList'
                    entries=widget.setdefault(kind,[])
                    if not any(x['key']==key for x in entries):entries.append({'key':key})
    return app

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--woo-workflow',type=Path,required=True);p.add_argument('--woo-overlay',type=Path,required=True)
    p.add_argument('--source',type=Path,default=ROOT/'appsmith/MushroomProcess.json');p.add_argument('--output-dir',type=Path,required=True)
    a=p.parse_args();a.output_dir.mkdir(parents=True,exist_ok=True)
    (a.output_dir/'Woo Pack and Dispatch.json').write_text(json.dumps(workflow(json.loads(a.woo_workflow.read_text())),indent=2)+'\n')
    (a.output_dir/'MushroomProcess.json').write_text(json.dumps(application(json.loads(a.source.read_text()),json.loads(a.woo_overlay.read_text())),indent=2,ensure_ascii=False)+'\n')
    print('Rendered inactive Woo cash workflow and scoped Appsmith bundle; configure private credentials before activation.')
