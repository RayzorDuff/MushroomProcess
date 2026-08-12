# Reporting Data Contract

Issue: [#87 — Reporting: Rebuild lifecycle, cohort analytics, and inventory reporting](https://github.com/RayzorDuff/MushroomProcess/issues/87)

Status: Phase 1 audit/data contract

## Purpose

This document defines the source-of-truth rules that the rebuilt MushroomProcess Reporting interface must use for lifecycle, cohort, lineage, contamination, yield, and inventory reporting.

The contract is based on both:

1. the current PostgreSQL schema and workflow functions in `schema/pgsql/`; and
2. the actual PostgreSQL migration CSV set generated from the Airtable production data for the v1.1.0 migration.

The historical migration data is important because fields populated by current PostgreSQL workflows were not always populated on migrated Airtable rows. Reporting must therefore work across both historical migrated records and records created natively after migration.

This phase changes no runtime schema, view, Appsmith page, or workflow behavior. It defines what later reporting views may safely claim.

## Existing Reporting implementation audit

The current Appsmith Reporting page is preserved as the baseline for later UI phases, but it should be treated as a prototype rather than as the reporting contract.

### Widget inventory

The unpublished Reporting definition currently contains 24 serialized widgets, including layout/canvas widgets and the application navigation. The functional reporting widgets are:

**Lot timeline tab**

- `inpLotSearch` — lot text search input;
- `tblLots` — search-result lot table;
- `tblEvents` — raw event table for the selected lot;
- `statCards` with `Text1`, `Text2`, and `Text3` — currently exposes colonization days plus first-flush/total-harvest text;
- `jsonDetails` — JSON Form bound to selected event `fields_json`.

**Cohort analytics tab**

- `selSpecies`;
- `selGrain`;
- `selSubstrate`;
- `dpStart`;
- `dpEnd`;
- `btnApply`;
- `chMonthlyYield`;
- `chContamRate`;
- `tblCohortStats`;
- `tblOutliers`.

The page also contains the shared `navMainNavigation` and its tab/canvas layout widgets.

### SQL/action inventory

The current page has eleven PostgreSQL actions:

| Action | Run behavior | Current role / audit finding |
| --- | --- | --- |
| `qLotsSearch` | AUTOMATIC | Searches lots only; the input also explicitly calls `.run()`, creating duplicate execution semantics. |
| `qEventsForLot` | AUTOMATIC | Returns raw events directly attached to the selected lot; does not provide product/lineage traversal. |
| `qLotMetrics` | AUTOMATIC | Event-only lifecycle aggregation; misses historical milestones that survived only in direct lot fields. |
| `qSpeciesOptions` | ON_PAGE_LOAD | Species selector source. |
| `qGrainOptions` | ON_PAGE_LOAD | Casts the entire grain `text[]` value to text instead of producing individual array elements. |
| `qSubstrateOptions` | ON_PAGE_LOAD | Casts the entire substrate `text[]` value to text instead of producing individual array elements. |
| `qCohortCycleTimes` | AUTOMATIC | Uses species + substrate, but not grain/date, and treats substrate arrays like scalar strings. |
| `qContamIncidencePerItem` | MANUAL | Calculates contamination incidence, but no current widget displays the result; uses species + grain + date but not substrate. |
| `qMonthlyHarvestYield` | AUTOMATIC | Uses species + substrate + date but not grain; substrate filtering uses scalar-style matching against array data. |
| `qContamIncidenceMonthly` | AUTOMATIC | Uses the date range only; ignores species, grain, and substrate selectors. |
| `qCohortOutliers` | ON_PAGE_LOAD | Returns the longest cycle durations rather than a defined anomaly statistic; ignores grain/date and uses scalar-style substrate filtering. |

The page also contains one JSObject, `ReportingUtils`, whose generated methods are serialized as six action entries:

- `safeParse`;
- `durationDays`;
- `monthlyYieldChartData`;
- `contamMonthlyChartData`;
- `init`;
- `applyAnalytics`.

`ReportingUtils.applyAnalytics()` runs five analytics queries with `Promise.allSettled()` but does not inspect/report rejected results, so a failed report may appear to be an empty report. `ReportingUtils.init()` also overlaps with Appsmith's configured automatic/on-page-load action behavior instead of being the single authoritative initialization path.

### Current widget/action wiring findings

The current wiring is internally understandable, but not yet coherent enough for production reporting:

- `inpLotSearch.onTextChanged` explicitly calls `qLotsSearch.run()` even though `qLotsSearch` is `AUTOMATIC`.
- `tblLots.onRowSelected` stores `selectedLotId` and immediately calls `qEventsForLot.run()` and `qLotMetrics.run()` even though both are also `AUTOMATIC`; the `storeValue()` result is not awaited before the dependent runs.
- `tblEvents` stores a selected event ID, but the event detail presentation is a `JSON_FORM_WIDGET` configured from a sample/static schema rather than a general read-only event viewer.
- the lifecycle stat area displays only colonization duration and first-flush/total-harvest text even though `qLotMetrics` calculates additional timestamps.
- `qContamIncidencePerItem` is executed by `applyAnalytics()` but has no result widget.
- `tblOutliers.primaryColumns` is empty, so the table was not fully configured.
- both analytics charts still carry the prototype chart name `Sales Report` rather than production-specific titles/axis semantics.
- the cohort selectors imply one cohort definition, but the SQL actions apply inconsistent subsets of the selected dimensions.

These findings establish the replacement boundary for later phases. Phase 1 does **not** remove or repair these widgets/actions; Phase 2 first creates a tested PostgreSQL lifecycle layer, and later Appsmith phases will replace the prototype wiring only after the new data contract is validated.

## Historical migration snapshot audited

The supplied v1.1.0 migration dataset contains:

- 2,011 lots;
- 5,932 events;
- 1,235 products.

The audit can be reproduced with `scripts/reporting_data_audit.py` against the generated PostgreSQL CSV directory. For the supplied migration snapshot, inventory measurements in this document use `2026-08-06` as the explicit as-of date.

### Historical event vocabulary

The migrated data contains meaningful lifecycle history rather than only terminal events:

| Event type | Rows |
| --- | ---: |
| Sterilized | 1,001 |
| FullyColonized | 867 |
| Inoculated | 681 |
| SpawnedToBulk | 575 |
| Consumed | 549 |
| FruitingStart | 393 |
| Harvest | 390 |
| Contaminated | 374 |
| Package | 244 |
| Pasteurized | 232 |
| CasingApplied | 215 |
| Composted | 152 |
| Inviable | 91 |
| LCInoculate | 49 |
| Received | 40 |
| Destroyed | 35 |
| SyringesDrawn | 15 |
| BeneficialTrichodermaApplied | 13 |
| PlatesPoured | 11 |
| FreezeDry | 4 |
| blank | 1 |

The historical events are valuable, but they cannot be treated as the sole lifecycle source because 783 migrated events have no timestamp. In particular, 394 `SpawnedToBulk` and 388 `Consumed` events are undated.

## Core reporting principle: use complementary sources

Reporting must not be event-only and must not be direct-column-only.

The normalized reporting layer must reconcile direct lot/product fields with dated events using a defined precedence for each lifecycle milestone. Where both sources exist, the direct lifecycle field is the canonical value unless a later phase identifies a reason to change that rule. The event remains available for timeline/audit detail.

If the direct field and event timestamp materially disagree, Reporting must expose a data-quality flag instead of silently hiding the discrepancy.

Historical evidence supports this approach. Where both sources are available, they are highly consistent:

- processed/sterilized: 1,229 rows have both sources and all 1,229 agree within 60 seconds;
- spawned to bulk: 181 rows have both sources and all 181 agree within 60 seconds;
- terminal date: 384 rows have both sources and all 384 agree within 60 seconds;
- inoculation: 640 rows have both sources and all agree within one day, with nearly all matching at effectively the same timestamp.

## Lifecycle milestone contract

The Phase 2 lifecycle view should expose, at minimum, the following normalized milestone columns and provenance fields.

### `record_created_at`

Source: the source record's `lots.created_at`.

Meaning: database/source-record creation time only.

It must **not** be presented as the universal physical creation/inception date for migrated lots. In the migration data:

- 314 of 2,011 lots have a known lifecycle milestone more than one day before their Airtable `created_at`;
- 205 lots have a known lifecycle milestone more than 30 days before `created_at`.

### `lifecycle_start_at`

Meaning: earliest trustworthy known lifecycle timestamp for the entity.

Candidate sources should include applicable received, processed/sterilized/pasteurized, inoculated, spawned, fruiting, harvest, and dated event milestones. `record_created_at` is a fallback only when no earlier operational timestamp is known.

Also expose:

- `lifecycle_start_source`;
- `lifecycle_start_is_record_created_fallback` or equivalent quality/provenance indicator.

Do not invent a physical inception date when none was preserved.

### `processed_at`

Precedence:

1. `lots.sterilized_at`;
2. earliest dated `Sterilized` or `Pasteurized` event.

Historical migration coverage:

- direct: 1,230 lots;
- dated event: 1,229 lots;
- either source: 1,230 lots.

The reporting row should retain enough information to distinguish sterilization from pasteurization where the process type/event supports that distinction.

### `inoculated_at`

Precedence:

1. `lots.inoculated_at`;
2. earliest dated `Inoculated` event.

Historical migration coverage:

- direct: 659 lots;
- dated event: 658 lots;
- both: 640 lots;
- direct only: 19 lots;
- event only: 18 lots;
- either source: 677 lots.

The union is materially more complete than either source by itself.

### `fully_colonized_at`

Source:

1. earliest dated `FullyColonized` event.

There is no equivalent canonical direct lot timestamp in the current data model.

Historical migration coverage: 860 lots have a dated `FullyColonized` event.

### `spawned_at`

Precedence:

1. `lots.spawned_at`;
2. earliest dated `SpawnedToBulk` event.

Historical migration coverage:

- direct: 575 lots;
- dated event: 181 lots;
- either source: 575 lots.

This is a critical historical fallback rule: all 575 migrated fruiting blocks have the direct spawn timestamp, while 394 historical `SpawnedToBulk` events are undated.

### `fruiting_start_at`

Precedence:

1. `lots.beganfruiting_at`;
2. earliest dated `FruitingStart` event (and any explicitly supported legacy equivalent).

Historical migration coverage:

- direct `beganfruiting_at`: 0 rows;
- dated event: 393 lots.

Current PostgreSQL workflows populate `beganfruiting_at` and write the `FruitingStart` event, so the source balance is expected to differ for post-migration data.

### `first_harvest_at`

Precedence:

1. `lots.firstharvested_at`;
2. earliest dated `Harvest` event.

Historical migration coverage:

- direct: 0 rows;
- dated event: 213 lots.

Current harvest functions populate `firstharvested_at`.

### `last_harvest_at`

Precedence:

1. `lots.lastharvested_at`;
2. latest dated `Harvest` event.

Historical migration coverage:

- direct: 0 rows;
- dated event: 213 lots.

Current harvest functions populate `lastharvested_at`.

### `contaminated_at`

Source:

1. earliest dated `Contaminated` event.

Historical migration coverage: 373 linked lots have a dated contamination event.

Do not infer contamination time from a terminal status when no dated contamination event survives.

### `terminal_at`

Precedence:

1. `lots.retired_at`;
2. latest dated terminal event appropriate to the lot (`Contaminated`, `Inviable`, `Composted`, `Consumed`, `Destroyed`, `Expired`, or later explicitly supported terminal types).

Historical migration coverage:

- direct `retired_at`: 384 lots;
- dated terminal event: 773 lots;
- both: 384 lots;
- event only: 389 lots;
- either source: 773 lots.

If a lot is currently terminal but no timestamp survives, return a null terminal date and mark it as status-only/undated. Do not derive a fake terminal date from record modification time.

### `terminal_reason`

Prefer the explicit terminal event type/reason where available. If only the current terminal status survives, expose that status together with a provenance/quality value indicating that the reason/date is not fully evidenced by a dated event.

## Data origin and provenance

Normalized reporting rows should identify the broad origin of the record:

- `airtable_migrated` when an Airtable source ID is retained;
- `postgres_native` when no Airtable source ID is present.

Recommended provenance/quality columns include:

- `data_origin`;
- per-milestone source (for example `spawned_at_source`);
- direct/event mismatch flags;
- missing-event/missing-date flags;
- lifecycle completeness level or a set of explicit quality flags.

Reporting should distinguish a genuinely missing fact from a valid zero/false value.

## Harvest and flush contract

Historical Harvest events are strong enough to support useful yield/flush reporting:

- 390 Harvest event rows;
- 213 harvested fruiting blocks;
- every historical Harvest event includes `harvest_weight_g`;
- every historical Harvest event includes `flush_no`.

Historical flush event counts are:

- flush 1: 213;
- flush 2: 121;
- flush 3: 46;
- flush 4: 9;
- flush 5: 1.

The lifecycle reporting layer should expose:

- `harvest_event_count`;
- `flush_count` = count of distinct valid numbered flushes;
- `max_flush_no`;
- `first_harvest_at`;
- `last_harvest_at`;
- `first_flush_g`;
- `total_harvest_g` = sum of Harvest-event `harvest_weight_g` values;
- optional per-flush detail through the entity timeline/child report.

Do not use `lots.harvest_weight_g` as the historical total-yield source. Historical lot-level harvest values do not consistently represent the event sum.

The migration audit identifies:

- 4 lot/flush-number groups with duplicate Harvest events;
- 2 harvested lots with non-contiguous flush numbers.

Those are source-data quality conditions. A later reporting view should flag them rather than silently correcting or deleting history.

## Lineage contract

### Fruiting-block inputs

Historical fruiting-block lineage is very strong:

- 575/575 fruiting blocks have a grain-input relation;
- 575/575 have substrate-input relation(s);
- 575/575 have a strain relation.

The explicit M2M relations are the canonical lineage source. Computed array fields may be convenient display dimensions but should not replace the underlying relationships when exact lineage is needed.

### Lot-to-product lineage

Historical product origin lineage is also strong:

- 1,235/1,235 products have an explicit origin-lot relation.

Use `_m2m_products_lots_origin_lots` (or its current equivalent/view) as the canonical product→origin-lot relationship.

### Harvested tray creation

Historical `products.harvested_at` is blank, but Harvest events preserve created product IDs:

- all 437 historical fresh/freezer tray products can be associated with a Harvest event through `created_product_id` or `created_product_ids`.

For historical tray products, a normalized reporting layer may recover `harvested_at` from the explicit Harvest-event product reference. The provenance must identify it as event-derived.

### Product-to-product lineage

Explicit product-to-product relations should be used where they exist. The migrated dataset contains explicit tray merge relationships, and current PostgreSQL packaging/freeze-dry workflows write richer source/created-product metadata.

Legacy `Package` events contain a `from_product_id`, but do not consistently identify the newly created output product ID. Therefore exact historical source-product→packaged-output-product lineage is **historically incomplete**. Do not infer an output link solely from matching dates, item types, or quantities.

Expose a lineage-completeness/provenance indication when a trace crosses a historical packaging boundary that cannot be proven exactly.

## Cohort analytics contract

All reports shown for a selected cohort must share one canonical cohort definition. Individual charts must not silently use different subsets of the selected filters.

Initial cohort dimensions should support, where applicable:

- date range;
- explicit date basis (for example lifecycle start, inoculation, spawn, harvest, or current inventory snapshot);
- lot/product category;
- item;
- species;
- strain;
- grain input;
- substrate input;
- recipe where supported.

### Array/relationship dimensions

Current computed fields such as grain/substrate input names are PostgreSQL arrays. Reporting must not compare a `text[]` value using scalar `ILIKE` logic.

For filtering/grouping, use either:

- the canonical M2M relationship tables/joins; or
- explicit array operations such as `unnest()`/`ANY()` where a computed view is appropriate.

Selector option queries must return individual grain/substrate values, not the text rendering of an entire array.

### Derived lifecycle measures

The normalized reporting layer should expose the component timestamps necessary to calculate, where supported:

- `days_processed_to_inoculation`;
- `days_inoculation_to_fully_colonized`;
- `days_spawn_to_fruiting`;
- `days_in_fruiting` (to terminal date, last harvest, or an explicitly defined observation date);
- `days_inoculation_to_contamination`;
- grain age at downstream spawn;
- substrate age at downstream spawn;
- flush count and yield metrics.

Null source timestamps must result in null derived durations, not fabricated zeroes.

## Grain/substrate age and contamination analysis

The historical migration data is already sufficient to support the class of question:

> Do grain bags used later have a different downstream contamination incidence than grain bags used sooner?

For all 575 historical fruiting blocks, the audit can identify:

- a linked grain input;
- the fruiting block spawn timestamp;
- the grain input inoculation timestamp using the direct/event fallback contract.

Therefore all 575 migrated fruiting blocks can supply a historical `days_from_grain_inoculation_to_block_spawn` value. Of those, 208 resulting fruiting blocks have a contamination event.

This should be modeled as a **downstream-outcome analysis**, distinct from contamination of the grain bag itself.

The migration data also supports grain self-contamination analysis:

- 607 historical grain lots;
- 475 have an inoculation timestamp;
- 109 have a contamination event;
- 88 have both inoculation and contamination timing available.

Reporting should preserve the distinction between:

1. grain lot self-contamination; and
2. contamination of a downstream fruiting block associated with that grain's age/use.

The same pattern can be applied to substrate-age-at-spawn analysis. All 575 migrated fruiting blocks have sufficient linked substrate processing timestamps for a cohort-level age measure, although individual anomalous/negative deltas must be treated as quality flags rather than normalized away.

## Inventory contract

The Reporting inventory snapshot should centralize the same definition of active finished inventory currently used by the Products interface.

At minimum, active inventory excludes products whose normalized tray state is one of:

- empty tray;
- compost/composted;
- spoiled;
- retired;
- expired;
- consumed;
- shipped;

and products whose current storage location is a terminal location such as:

- Compost;
- Consumed;
- Expired;
- Retired;
- Shipped.

The rule should be centralized in a reporting view rather than independently copied into Appsmith widgets.

Recommended inventory fields include:

- product/business ID;
- item/name/category;
- strain/species where applicable;
- storage location, including an explicit `Unknown`/null bucket;
- pack date;
- use-by date;
- stock age;
- expiration status (`expired`, `expiring`, `current`, `unknown`) using an explicitly supplied/current as-of date;
- active/terminal classification and reason;
- count/quantity and weight/volume dimensions where meaningful.

Historical migration snapshot, using the current Products-page active rule as of 2026-08-06:

- 687 active products;
- 78 active products already past `use_by`;
- 261 active products without a storage-location relation.

Reporting must therefore support unknown storage location rather than dropping those rows.

The source data also contains 32 products with `use_by < pack_date`. Preserve and flag those records; do not silently alter source dates.

## Availability classification

### Directly available

These facts are directly represented by current source columns and/or explicit relations:

- business/internal IDs;
- item/category;
- current lot/product status/state;
- processing/inoculation/spawn timestamps where populated;
- product `pack_date` and `use_by`;
- lot strain/item/location relations;
- fruiting-block grain/substrate input relations;
- product origin-lot relations;
- event timestamp/type/fields where present.

### Derivable with strong historical support

These values can be derived without inventing data when the source components are present:

- normalized lifecycle milestone timestamps using the field/event fallback contract;
- lifecycle duration metrics;
- grain age at fruiting-block spawn;
- substrate age at fruiting-block spawn;
- contamination incidence by cohort;
- inoculation-to-contamination durations;
- distinct flush count;
- first/last harvest date;
- first-flush and total Harvest-event yield;
- historical tray-product harvest timestamp from explicit Harvest event product IDs;
- active/expired inventory counts using the established inventory rule.

### Historically incomplete

These areas are usable but should expose incomplete provenance or null values where the migration did not preserve enough information:

- terminal timestamps when only a terminal status survives;
- exact legacy package source-product→output-product lineage;
- storage location for some historical products;
- inoculation/colonization timestamps for categories that were never inoculated or for older records lacking those milestones;
- fruiting/harvest metrics for lots with no corresponding direct field/event evidence.

### Unavailable / not safely inferable

Do not fabricate these values:

- exact physical inception date for a backfilled historical lot when no operational milestone predates record creation;
- exact historical packaged-output product from a legacy `Package` event when the output ID was not stored;
- exact terminal date/reason when only an undated status/event survived;
- duration metrics whose required start or end timestamp is missing.

Return null/unknown together with source-quality information.

## Historical data-quality facts to retain

The migration audit currently identifies:

- 40 events with no lot relation (35 `Destroyed`, 4 `Sterilized`, 1 blank type);
- 783 undated events (394 `SpawnedToBulk`, 388 `Consumed`, 1 blank type);
- 44 lots with no linked event at all;
- 85 lots with no linked **dated** event;
- 314 lots whose known lifecycle begins more than one day before Airtable record creation;
- 205 lots whose known lifecycle begins more than 30 days before Airtable record creation;
- 4 duplicate lot/flush-number groups;
- 2 harvested lots with non-contiguous flush numbering;
- 32 products whose `use_by` precedes `pack_date`.

These should inform reporting quality flags and tests. They are not authorization to mutate historical source data.

## Phase 2 canonical lifecycle implementation

Migration `schema/pgsql/036_reporting_lifecycle.sql` implements the first
normalized reporting interface defined by this contract as
`public.v_reporting_lot_lifecycle`. It is deliberately read-only and produces
exactly one row per `lots.nocopk`.

The view exposes the direct and event candidate timestamps alongside each
normalized milestone and its source. It also includes direct/event mismatch
flags, event/date coverage counts, Harvest-event flush/yield metrics, exact
grain/substrate relationship arrays, lifecycle-duration measures, and a
`quality_flags` array. This preserves source-data anomalies for analysis rather
than repairing them in a reporting view.

`lifecycle_start_at` is selected from the earliest operational evidence and
uses `lots.created_at` only as an explicitly labeled fallback. Ongoing fruiting
lots do not receive a fabricated current-time end date: `days_in_fruiting` is
only populated when a terminal date or last-harvest date provides an evidenced
observation endpoint.

Phase 2 intentionally does not implement product lineage, entity timelines,
cohort membership, or inventory snapshots. Those remain separate later phases
so the lot-level lifecycle contract can be validated independently before the
Appsmith Reporting UI consumes it.

## Current PostgreSQL write compatibility

The current workflow implementation is compatible with the hybrid contract:

- inoculation writes `lots.inoculated_at` and an `Inoculated` event;
- lot transition logic writes `beganfruiting_at` and a `FruitingStart` event;
- full-colonization transitions write `FullyColonized` events;
- spawn-to-bulk writes `lots.spawned_at` and `SpawnedToBulk` events;
- harvest writes `firstharvested_at`/`lastharvested_at` and `Harvest` events;
- terminal lot actions write `retired_at` and reason-specific terminal events.

The migration package and current repository retain compatible core lifecycle semantics, while newer views/functions may contain additional fields and richer event metadata. Reporting should prefer explicit current relationships/fields while maintaining the historical fallbacks defined above.

## Phase 2 target contract

Phase 2 should implement the first read-only PostgreSQL reporting layer, centered on a canonical lot lifecycle view. A likely initial object is:

- `v_reporting_lot_lifecycle`

The exact name may be adjusted during implementation, but Phase 2 should not require the Reporting Appsmith page to change until the lifecycle view has been tested independently against known historical and current records.

The view should provide one normalized row per lot with:

- identity/category/item/strain dimensions;
- record/data provenance;
- normalized milestone timestamps and milestone-source fields;
- lifecycle duration fields;
- contamination outcome/timing;
- harvest/flush summary;
- terminal state/reason;
- grain/substrate lineage summary sufficient for cohort dimensions;
- explicit data-quality flags.

Later phases may add separate read-only views such as:

- `v_reporting_entity_timeline`;
- `v_reporting_cohort_lifecycle`;
- `v_reporting_product_inventory`.

Those later views must reuse the lifecycle contract rather than re-implementing conflicting milestone logic independently.

## Reproducing the historical audit

Given the generated migration PostgreSQL CSV directory:

```bash
python3 scripts/reporting_data_audit.py \
  --csv-dir /path/to/airtable-export-1.1.0/tmp/schema/pgsql/csv \
  --as-of 2026-08-06
```

Machine-readable output is available with:

```bash
python3 scripts/reporting_data_audit.py \
  --csv-dir /path/to/airtable-export-1.1.0/tmp/schema/pgsql/csv \
  --as-of 2026-08-06 \
  --format json
```

The audit utility is intentionally read-only and uses only the generated migration CSVs. It does not connect to or modify PostgreSQL.

## Phase 3 Lifecycle Trace UI contract

Phase 3 binds the first Reporting tab directly to `public.v_reporting_lot_lifecycle`.  The tab is renamed **Lifecycle Trace** and remains lot-scoped; product/ancestor/descendant traversal is deferred to Phase 4.

The first-tab execution contract is:

1. `qLotsSearch` searches lifecycle-view dimensions only.
2. Selecting one search result stores its `lot_nocopk`, then explicitly runs `qLotMetrics` and `qEventsForLot` after the store completes.
3. `qLotMetrics` reads one canonical lifecycle row and adds presentation-only current-stage/age and contamination-stage fields.
4. `qEventsForLot` renders an understandable timeline from canonical milestones plus individual Harvest events and other preserved Events.  Canonical milestones carry the provenance selected by Phase 2.  Undated historical Events are retained at the end of the timeline rather than assigned fabricated timestamps.
5. The old editable JSON Form is removed.  Timeline-row details are read-only and display source, operator/station/product context, and preserved event metadata.

The UI exposes lifecycle start/source, status/stage, immediate grain/substrate inputs, colonization duration, spawn-to-fruiting duration, fruiting duration, flush count, first-flush/total yield, contamination timing/stage, terminal outcome, origin (`airtable_migrated` versus `postgres_native`), and Phase 2 quality flags.

`created_at` remains explicitly labeled as record creation in the timeline and is not presented as physical lifecycle inception unless Phase 2 identifies it as the lifecycle-start fallback.

## Phase 4 adjacent lineage contract

Phase 4 extends Lifecycle Trace from one isolated lot to the explicitly related
entities immediately upstream and downstream of that lot.  The implementation
uses `public.v_reporting_lot_lineage`; no relationship may be inferred from
matching strain, item, date, recipe, or naming patterns.

The initial traversal contract is deliberately bounded rather than recursively
expanding every descendant:

- selecting a fruiting block exposes each explicit source grain and substrate;
- source-grain rows expose the grain's own inoculation/colonization history and
  its age when the block was spawned;
- selecting a grain exposes every explicitly linked resulting fruiting block,
  including spawn-to-fruiting duration, fruiting duration, flush/yield summary,
  contamination, and terminal outcome;
- selecting a substrate similarly exposes explicitly linked resulting lots;
- source/parent lot relationships are shown when the schema records them;
- products linked by `products.origin_lots` are shown as resulting products,
  including available harvest/package/state/location metadata;
- selecting a related **lot** pivots Lifecycle Trace to that lot; product rows
  remain read-only during Phase 4.

The Phase 3 summary's grain/substrate line is populated from the same explicit
lineage rows rather than relying on PostgreSQL-array serialization in Appsmith.
This keeps the visible input labels and the traversal source identical.

Historical data must not be artificially limited to an assumed branching
factor.  The migration dataset contains one source grain linked to as many as
six fruiting blocks, so all explicit adjacent relationships are preserved even
when the normal operational expectation is smaller.

### Deferred lineage visualization

A radial/tree lineage visualization is a desirable future presentation layer,
particularly for culture or LC roots where branching can become large.  A
possible visualization would place the selected LC/syringe at the center,
grains on the next ring, fruiting blocks outside those, and Harvest/products on
an outer ring.  Phase 4 intentionally does **not** implement that visualization;
it establishes the explicit edge/data contract needed to support it later
without recursively flooding the normal Lifecycle Trace UI.

Phase 4 also makes timeline-row details store-backed (`selectedLifecycleEvent`)
so selecting canonical rows with no Event ID still produces read-only detail
content reliably.
