"""Render the opt-in Woo section into the existing MP Appsmith export."""
import argparse
import json
from pathlib import Path


def render(application, overlay):
    existing = {action['id'] for action in application['actionList']}
    added = {action['id'] for action in overlay['actions']}
    if existing & added:
        raise ValueError('Woo actions already present. Import a freshly rendered export.')
    application['actionList'].extend(overlay['actions'])
    if any(row['name'] == overlay['datasource']['name'] for row in application['datasourceList']):
        raise ValueError('Woo datasource already present')
    application['datasourceList'].append(overlay['datasource'])
    page, = [page for page in application['pageList'] if page['unpublishedPage']['name'] == 'Fulfillment']
    for side, widgets in overlay['widgets'].items():
        dsl = page[side]['layouts'][0]['dsl']
        if max(widget['bottomRow'] for widget in dsl['children']) > 164:
            raise ValueError('Fulfillment layout changed. Review Woo section placement.')
        dsl['children'].extend(widgets)
        dsl['bottomRow'] = max(dsl['bottomRow'], 280)
    return application


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    app = json.loads((root / 'appsmith/MushroomProcess.json').read_text())
    overlay = json.loads((root / 'appsmith/commerce_fulfillment_overlay.json').read_text())
    args.output.write_text(json.dumps(render(app, overlay), indent=2, ensure_ascii=False) + '\n')
    print('Rendered Woo fulfillment section. Configure its private datasource before publication.')
