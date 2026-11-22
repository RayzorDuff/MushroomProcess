"""Keep both Appsmith revisions and compiled FulfillmentUI actions in sync."""
import argparse
import copy
import json
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parents[1]
def render(app):
    source=(ROOT/'appsmith/fulfillment_ui.js').read_text()
    collection=next(c for c in app['actionCollectionList'] if c['id']=='Fulfillment_FulfillmentUI')
    for side in ['publishedCollection','unpublishedCollection']: collection[side]['body']=source
    js="const fs=require('fs');const o=eval('('+fs.readFileSync(0,'utf8').replace('export default','')+')');console.log(JSON.stringify(Object.fromEntries(Object.entries(o).filter(([k,v])=>typeof v==='function').map(([k,v])=>[k,v.toString().replace(/^(async )?[^ (]+\\(/,(_,a)=>(a||'')+'function (')]))));"
    methods=json.loads(subprocess.check_output(['node','-e',js],input=source,text=True))
    template=next(a for a in app['actionList'] if a['id']=='Fulfillment_FulfillmentUI.searchProducts')
    for name,body in methods.items():
        ident='Fulfillment_FulfillmentUI.'+name
        found=next((a for a in app['actionList'] if a['id']==ident),None)
        if found is None:
            found=copy.deepcopy(template);found['id']=ident;found['gitSyncId']='fulfillment-060-'+name;app['actionList'].append(found)
        for side in ['publishedAction','unpublishedAction']:
            d=found[side];d['name']=name;d['fullyQualifiedName']='FulfillmentUI.'+name
            d['actionConfiguration']['body']=body;d['jsonPathKeys']=[body]
    overlay=json.loads((ROOT/'appsmith/fulfillment_allocation_overlay.json').read_text())
    page=next(p for p in app['pageList'] if p['unpublishedPage']['name']=='Fulfillment')
    for side,changes in overlay['widgets'].items():
        widgets=page[side]['layouts'][0]['dsl']['children']
        for name,fields in changes.items():
            widget=next((w for w in widgets if w['widgetName']==name),None)
            if widget is None:
                widget={};widgets.append(widget)
            widget.update(copy.deepcopy(fields))
    for action in overlay['actions']:
        existing=next((a for a in app['actionList'] if a['id']==action['id']),None)
        if existing is None:app['actionList'].append(copy.deepcopy(action))
        else:existing.update(copy.deepcopy(action))
    return app
if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,default=ROOT/'appsmith/MushroomProcess.json')
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    if args.source.resolve()==args.output.resolve():parser.error('Preserve the original export; choose a separate output')
    args.output.write_text(json.dumps(render(json.loads(args.source.read_text())),indent=2,ensure_ascii=False)+'\n')
    print('Rendered Fulfillment allocation export; private datasource must be retained at import.')
