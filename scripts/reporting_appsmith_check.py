#!/usr/bin/env python3
"""Validate the Issue #87 Reporting page contract in the Appsmith export.

This is a read-only repository check.  It does not rewrite Appsmith JSON.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Dict, Iterable


EXPECTED_TABS = ["Lifecycle Trace", "Cohort analytics", "Inventory Snapshot"]
EXPECTED_CANVASES = {
    "Lifecycle Trace": "Canvas1",
    "Cohort analytics": "Canvas2",
    "Inventory Snapshot": "Canvas3",
}
EXPECTED_WIDGETS = {
    # Lifecycle Trace
    "inpLotSearch",
    "tblLots",
    "txtLifecycleSummary",
    "statColonization",
    "statSpawnToFruit",
    "statFruiting",
    "statHarvest",
    "tblEvents",
    "txtEventDetails",
    "tblLineage",
    # Cohort analytics
    "selCohortDateBasis",
    "dpStart",
    "dpEnd",
    "selCohortCategory",
    "selCohortItem",
    "selSpecies",
    "selGrain",
    "selSubstrate",
    "btnApply",
    "txtCohortSummary",
    "chMonthlyYield",
    "chContamRate",
    "tblCohortStats",
    "tblOutliers",
    # Inventory Snapshot
    "selInventoryScope",
    "selInventoryCategory",
    "selInventoryItem",
    "selInventoryStrain",
    "selInventoryLocation",
    "selInventoryExpiration",
    "txtInventorySummary",
    "btnInventoryRefresh",
    "tblInventorySummary",
    "tblInventoryProducts",
    "tblInventoryLots",
}
EXPECTED_DB_ACTIONS = {
    "Reporting_qLotsSearch",
    "Reporting_qLotMetrics",
    "Reporting_qEventsForLot",
    "Reporting_qLineageForLot",
    "Reporting_qSpeciesOptions",
    "Reporting_qGrainOptions",
    "Reporting_qSubstrateOptions",
    "Reporting_qContamIncidencePerItem",
    "Reporting_qCohortCycleTimes",
    "Reporting_qMonthlyHarvestYield",
    "Reporting_qContamIncidenceMonthly",
    "Reporting_qCohortOutliers",
    "Reporting_qInventoryDimensionOptions",
    "Reporting_qInventoryKpis",
    "Reporting_qInventorySummary",
    "Reporting_qInventoryProducts",
    "Reporting_qInventoryLotSummary",
}
EXPECTED_JS_ACTIONS = {
    "Reporting_ReportingUtils.monthlyYieldChartData",
    "Reporting_ReportingUtils.contamMonthlyChartData",
    "Reporting_ReportingUtils.applyAnalytics",
}
OBSOLETE_ACTIONS = {
    "Reporting_ReportingUtils.safeParse",
    "Reporting_ReportingUtils.durationDays",
    "Reporting_ReportingUtils.init",
}
COHORT_MANUAL_ACTIONS = {
    "Reporting_qContamIncidencePerItem",
    "Reporting_qCohortCycleTimes",
    "Reporting_qMonthlyHarvestYield",
    "Reporting_qContamIncidenceMonthly",
    "Reporting_qCohortOutliers",
}
PROTOTYPE_MARKERS = (
    "Sales Report",
    "Revenue($)",
    "Product Line",
    "jsonDetails",
    "selectedEventId",
    "ReportingUtils.safeParse",
    "ReportingUtils.durationDays",
    "ReportingUtils.init",
)


def fail(message: str) -> None:
    raise ValueError(message)


def walk_widgets(widget: Dict[str, Any]) -> Iterable[Dict[str, Any]]:
    yield widget
    for child in widget.get("children") or []:
        yield from walk_widgets(child)


def widget_list(page: Dict[str, Any]) -> list[Dict[str, Any]]:
    result: list[Dict[str, Any]] = []
    dsl = page["layouts"][0]["dsl"]
    for root in dsl.get("children") or []:
        result.extend(walk_widgets(root))
    return result


def widget_by_name(widgets: list[Dict[str, Any]], name: str) -> Dict[str, Any]:
    matches = [w for w in widgets if w.get("widgetName") == name]
    if not matches:
        fail(f"Reporting is missing expected widget {name!r}")
    if len(matches) > 1 and name != "Canvas3":
        fail(f"Reporting contains duplicate widgetName {name!r}")
    return matches[-1]


def action_body(action: Dict[str, Any], state: str) -> str:
    return ((action.get(state) or {}).get("actionConfiguration") or {}).get("body") or ""


def load_json(path: Path) -> Dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"Appsmith export not found: {path}")
    except json.JSONDecodeError as exc:
        fail(f"Invalid Appsmith JSON: {exc}")
    raise AssertionError("unreachable")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--appsmith",
        default="appsmith/MushroomProcess.json",
        help="Path to the canonical Appsmith export (default: %(default)s)",
    )
    args = parser.parse_args()

    path = Path(args.appsmith)
    app = load_json(path)

    reporting_pages = [
        p for p in app.get("pageList") or []
        if (p.get("unpublishedPage") or {}).get("name") == "Reporting"
    ]
    if len(reporting_pages) != 1:
        fail(f"Expected exactly one Reporting page, found {len(reporting_pages)}")
    reporting = reporting_pages[0]
    unpublished = reporting["unpublishedPage"]
    published = reporting["publishedPage"]

    if unpublished != published:
        fail("Published and unpublished Reporting page definitions differ")

    widgets = widget_list(unpublished)
    widget_names = {w.get("widgetName") for w in widgets if w.get("widgetName")}
    missing_widgets = sorted(EXPECTED_WIDGETS - widget_names)
    if missing_widgets:
        fail("Reporting is missing expected widgets: " + ", ".join(missing_widgets))

    if any(w.get("type") == "JSON_FORM_WIDGET" for w in widgets):
        fail("Reporting still contains the obsolete JSON Form event-detail widget")

    tabs = widget_by_name(widgets, "tabsMode")
    if not tabs or tabs.get("type") != "TABS_WIDGET":
        fail("Reporting tabsMode TABS_WIDGET is missing")
    tab_defs = sorted((tabs.get("tabsObj") or {}).values(), key=lambda t: t.get("index", 0))
    labels = [t.get("label") for t in tab_defs]
    if labels != EXPECTED_TABS:
        fail(f"Unexpected Reporting tabs: {labels!r}; expected {EXPECTED_TABS!r}")
    if tabs.get("defaultTab") != "Lifecycle Trace":
        fail("Reporting default tab must remain Lifecycle Trace")
    for tab in tab_defs:
        expected_canvas = EXPECTED_CANVASES[tab["label"]]
        actual_canvas = next(
            (widget.get("widgetName") for widget in widgets if widget.get("widgetId") == tab.get("widgetId")),
            None,
        )
        if actual_canvas != expected_canvas:
            fail(
                f"Tab {tab['label']!r} points to {actual_canvas!r}; expected {expected_canvas!r}"
            )

    if widget_by_name(widgets, "chMonthlyYield").get("chartType") != "COLUMN_CHART":
        fail("Yield by Cohort Month must remain a COLUMN_CHART")
    if widget_by_name(widgets, "chMonthlyYield").get("chartName") != "Yield by Cohort Month":
        fail("Yield chart title drifted from 'Yield by Cohort Month'")
    if widget_by_name(widgets, "chContamRate").get("chartName") != "Contamination Incidence by Cohort Month":
        fail("Contamination chart title drifted")

    action_by_id = {a.get("id"): a for a in app.get("actionList") or []}
    reporting_action_ids = {
        action_id for action_id, action in action_by_id.items()
        if ((action.get("unpublishedAction") or {}).get("pageId") == "Reporting")
    }
    expected_action_ids = EXPECTED_DB_ACTIONS | EXPECTED_JS_ACTIONS
    missing_actions = sorted(expected_action_ids - reporting_action_ids)
    if missing_actions:
        fail("Reporting is missing expected actions: " + ", ".join(missing_actions))
    obsolete_actions = sorted(OBSOLETE_ACTIONS & reporting_action_ids)
    if obsolete_actions:
        fail("Obsolete Reporting actions remain: " + ", ".join(obsolete_actions))

    for action_id in sorted(reporting_action_ids):
        action = action_by_id[action_id]
        ua = action.get("unpublishedAction") or {}
        pa = action.get("publishedAction") or {}
        if ua.get("name") != pa.get("name"):
            fail(f"Published/unpublished action name differs for {action_id}")
        if action_body(action, "unpublishedAction") != action_body(action, "publishedAction"):
            fail(f"Published/unpublished action body differs for {action_id}")

    # Cohort analytics is intentionally Apply-driven; none of its analytic
    # queries may drift back into page-load execution.
    on_load_ids = {
        entry.get("id")
        for group in unpublished["layouts"][0].get("layoutOnLoadActions") or []
        for entry in group
    }
    bad_load = sorted(COHORT_MANUAL_ACTIONS & on_load_ids)
    if bad_load:
        fail("Cohort analytic actions unexpectedly execute on page load: " + ", ".join(bad_load))

    collections = [
        c for c in app.get("actionCollectionList") or []
        if c.get("id") == "Reporting_ReportingUtils"
    ]
    if len(collections) != 1:
        fail(f"Expected one ReportingUtils collection, found {len(collections)}")
    collection = collections[0]
    pub_body = (collection.get("publishedCollection") or {}).get("body") or ""
    unpub_body = (collection.get("unpublishedCollection") or {}).get("body") or ""
    if pub_body != unpub_body:
        fail("Published/unpublished ReportingUtils bodies differ")
    for marker in ("safeParse(", "durationDays(", "async init("):
        if marker in unpub_body:
            fail(f"Obsolete ReportingUtils method remains: {marker}")

    reporting_blob = json.dumps({
        "page": reporting,
        "actions": [action_by_id[aid] for aid in sorted(reporting_action_ids)],
        "collection": collection,
    }, ensure_ascii=False)
    leftovers = [marker for marker in PROTOTYPE_MARKERS if marker in reporting_blob]
    if leftovers:
        fail("Obsolete Reporting prototype markers remain: " + ", ".join(leftovers))

    widget_count = len(widgets)
    db_count = sum(1 for aid in reporting_action_ids if action_by_id[aid].get("pluginType") == "DB")
    js_count = sum(1 for aid in reporting_action_ids if action_by_id[aid].get("pluginType") == "JS")
    print(
        "Reporting Appsmith check passed: "
        f"3 tabs, {widget_count} widgets, {db_count} DB actions, {js_count} JS methods; "
        "published/unpublished definitions synchronized."
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
