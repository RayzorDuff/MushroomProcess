#!/usr/bin/env python3
import json
import re
from pathlib import Path

APP = Path("appsmith/MushroomProcess.json")

REMOVED_COLLECTIONS = {
    "Lots_LotsSpawnToBulk",
    "Lots_LotsHarvest",
    "Lots_LotsInoculate",
    "Lots_LotsDrawSyringes",
}

REMOVED_QUERIES = {
    "qSpawnToBulkLots",
    "qSpawnToBulkLocations",
    "qSpawnSourceLotsSearch",
    "qHarvestFlushNo",
    "qHarvestItems",
    "qHarvestLot",
    "qInoculateLots",
    "qInocLocations",
    "qSourceLotsSearch",
    "qDrawSyringeProducts",
    "qDrawSyringes",
    "qSyringeItems",
}

REMOVED_WIDGETS = {
    "btnDrawSyringes",
    "modalDrawSyringes",
    "btnInoculateLots",
    "modalInoculateLots",
    "btnSpawnToBulkLots",
    "modalSpawnToBulk",
    "btnHarvestLots",
    "modalHarvestLot",
}


def prune(node):
    if isinstance(node, list):
        return [v for item in node if (v := prune(item)) is not None]
    if not isinstance(node, dict):
        return node
    if node.get("widgetName") in REMOVED_WIDGETS:
        return None
    out = {}
    for key, value in node.items():
        pruned = prune(value)
        if pruned is not None:
            out[key] = pruned
    return out


def main():
    app = json.loads(APP.read_text())

    app["actionCollectionList"] = [
        c for c in app["actionCollectionList"]
        if c.get("id") not in REMOVED_COLLECTIONS
    ]

    def keep_action(action):
        published = action.get("publishedAction") or {}
        unpublished = action.get("unpublishedAction") or {}
        return (
            published.get("collectionId") not in REMOVED_COLLECTIONS
            and unpublished.get("collectionId") not in REMOVED_COLLECTIONS
            and published.get("name") not in REMOVED_QUERIES
            and unpublished.get("name") not in REMOVED_QUERIES
        )

    app["actionList"] = [a for a in app["actionList"] if keep_action(a)]

    for page in app.get("pageList", {}).values():
        for variant in ("publishedPage", "unpublishedPage"):
            page_data = page.get(variant)
            if not page_data or page_data.get("name") != "Lots":
                continue

            for layout in page_data.get("layouts", []):
                layout["dsl"] = prune(layout.get("dsl"))
                layout["layoutOnLoadActions"] = [
                    kept
                    for group in layout.get("layoutOnLoadActions", [])
                    if (kept := [
                        action for action in (group or [])
                        if action.get("name") not in REMOVED_QUERIES
                    ])
                ]

    for collection in app["actionCollectionList"]:
        if collection.get("id") != "Lots_LotsPage":
            continue
        for variant in ("publishedCollection", "unpublishedCollection"):
            collection_data = collection.get(variant)
            if not collection_data or not collection_data.get("body"):
                continue
            body = collection_data["body"]
            body = re.sub(
                r"\n\s*inoculate:\s*\{[\s\S]*?\n\s*\},(?=\n\s*draw_syringes:)",
                "",
                body,
            )
            body = re.sub(
                r"\n\s*draw_syringes:\s*\{[\s\S]*?\n\s*\},(?=\n\s*harvest:)",
                "",
                body,
            )
            body = re.sub(
                r"\n\s*harvest:\s*\{[\s\S]*?\n\s*\},(?=\n\s*\};)",
                "",
                body,
            )
            collection_data["body"] = body

    text = json.dumps(app, indent=2, ensure_ascii=False) + "\n"
    APP.write_text(text)


if __name__ == "__main__":
    main()
