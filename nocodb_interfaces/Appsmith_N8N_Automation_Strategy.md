# Appsmith + n8n Automation Strategy (NocoDB migration)

This repo’s Airtable implementation relies heavily on “automation scripts” (see `airtable_automation/`), and the operator UIs (interfaces) typically work by writing an **`action`** value (single-select) onto a record, then letting automation logic do the heavy lifting:
- validate inputs
- create downstream records
- advance statuses / stations
- populate print queues
- write `ui_error` and `validation` feedback fields
- clear/reset `action` after completion

When migrating to **NocoDB + Appsmith + n8n**, keep the same pattern, but move the *script execution* out of Airtable:

## Current recommended division of responsibility (Postgres-first)

As of Feb 2026, the migration path prioritizes **direct Postgres access from Appsmith** and moves most “Airtable-style” workflow logic into **Postgres functions/triggers** under `nocodb_schema/pgsql/` (005+).

- **Postgres (primary automation layer)**  
  Owns internal workflow side-effects:
  - writing `events` (audit log)
  - maintaining event↔lot links (so events are visible from lots)
  - populating `print_queue` on lot/product creation or transitions
  - station workflow helpers (e.g., sterilizer run completion creates lots)
  - lot actions (shake/retire, etc.)

- **Appsmith (UI + validation + orchestration)**  
  Owns operator experience:
  - UI constraints (hide/disable) + redundant JS validation
  - calling Postgres queries / functions (prefer `vc_*` views for reads, base tables for writes)
  - modal-driven multi-step actions (e.g., “Retire” with multiple reasons)

- **NocoDB (metadata + attachments + compatibility)**  
  Used when it is the pragmatic path:
  - file uploads / attachments (Appsmith→NocoDB API or via n8n)
  - quick admin browsing of base tables
  - optional view creation scripts (still useful for parity)

- **n8n (external systems + async work)**  
  Reserve for cross-system work:
  - Ecwid sync
  - file storage (e.g., Google Drive for images)
  - scheduled/async jobs that don’t need to block the UI

This keeps Appsmith lightweight, avoids duplicating logic across UI and automations, and makes workflows testable at the DB layer.

## Recommended division of responsibility

### Appsmith (UI)
- Shows station queues (Tables / Views)
- Collects operator input (Forms / Modals)
- Writes small, explicit updates:
  - set `action`
  - set a few immediate fields (notes, timestamps, simple selects)
- Calls **n8n** for anything that needs multi-row logic or business rules

### n8n (server-side workflows; “Airtable scripts replacement”)
- Executes the logic currently implemented in `airtable_automation/*.js` where such automation interfaces with external systems, such as Ecwid or a cloud filesystem.
- Performs multi-step updates safely (transactions / retries)
- Writes back:
  - `ui_error`
  - `validation`
  - status transitions
  - any created/linked records
  - print queue jobs
- Clears the `action` field when done

### Postgres/NocoDB (data + views)
- Holds the imported schema
- Stores status fields and transitions
- Provides views (or filtered queries) that match Airtable station queues

---

## Trigger patterns

### Pattern A (preferred): Appsmith → n8n webhook or postgres function
When a user clicks a station action button:
1) Appsmith/Postgres updates the row (sets `action`, plus any required input fields)
2) Appsmith calls a postgres function or an n8n webhook (when necessary) with `{ table, rowId, action }`
3) Postgres/n8n loads the row, performs the workflow, writes back results, clears `action`

**Pros:** deterministic, low-latency, no polling  
**Cons:** requires webhook URLs + auth management

### Pattern B: n8n watches for pending actions
1) Appsmith only sets `action`
2) n8n runs on a schedule (e.g., every 15–60 seconds) and queries for `action != null`
3) n8n processes actions and clears them

**Pros:** simple UI; fewer moving parts in Appsmith  
**Cons:** latency; must handle concurrency/locking

> Concurrency tip: add a field like `automation_lock` or `automation_started_at` and have n8n set it before processing.

---

## What to port from `airtable_automation/`

It is not necessary to port these scripts 1:1 as “code files” in Appsmith. Instead:
- Use postgres/n8n workflows as the orchestration layer
- Put any reusable logic in:
  - Postgres functions
  - n8n “Code” nodes (JS)
  - or a small companion Node service (optional)

A good first set to migrate (because they are directly UI-driven):
- `dark_room_actions.js`
- `fruiting_actions.js`
- `harvest_create_tray_product.js`
- `print_queue_populator*.js`
- `spawn_to_bulk_create_blocks.js`
- `sterilizer_in_validate_start.js`
- `sterilizer_out_validate_create_lots.js`

---

## Payload conventions (suggested)

Have Appsmith send this to n8n:

```json
{
  "table": "lots",
  "rowId": 123,
  "action": "ColdShock",
  "actor": "{{appsmith.user.email}}",
  "source": "appsmith",
  "timestamp": "{{Date.now()}}"
}
```

n8n then:
1) GET the row from NocoDB
2) Validate required fields
3) Execute the workflow
4) PATCH updates back to NocoDB
5) Clear `action` (or set to `null`) on success
6) Write `ui_error` and leave `action` for review on failure

---

## Where Appsmith specs live

For each prior Retool spec file, there is now a matching Appsmith spec:

- `nocodb_interfaces/Appsmith_*.txt`

These documents are *implementation checklists* for recreating each station UI in Appsmith using the NocoDB REST API datasource and n8n webhooks.


### Postgres-first Datasource (current)

This project is transitioning to **direct Postgres queries** wherever possible.

- Use Postgres datasource for:
  - tables / forms / actions
  - validation queries
  - workflow functions (e.g., `mp_sterilizer_complete_run`, `mp_lots_shake`, `mp_lots_retire`)
- Use NocoDB API only where it adds value (notably **file uploads/attachments**), or where NocoDB metadata is required.

n8n remains integral for:
- external integrations (Ecwid)
- file storage pipelines (e.g., Google Drive)
- cross-system sync workflows
