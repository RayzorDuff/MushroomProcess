# Appsmith Project

This directory contains the supported MushroomProcess operator interface for the PostgreSQL-backed implementation.

## Contents

- `MushroomProcess.json` — canonical Appsmith application export used for repository review, import, and release packaging.
- `pretty-json.mjs` — normalization utility for converting an Appsmith directory export into stable, reviewable JSON.
- `spec/` — retained page-planning notes from the migration. These files are useful historical references, but `MushroomProcess.json` is authoritative for the current application.

The removed NocoDB view-creation scripts and REST-automation prototypes are not part of the production architecture. Internal operational workflows run in PostgreSQL functions and triggers; n8n is reserved for external systems and asynchronous work.

## Import into Appsmith

1. Open the target Appsmith workspace.
2. Import `appsmith/MushroomProcess.json`.
3. Resolve the PostgreSQL datasource and any n8n/external API credentials for the target environment.
4. Confirm page-load queries, PostgreSQL function calls, and application-level environment values.
5. Save and publish only after the applicable release-matrix tests pass.

The application generally reads from `vc_*` computed views and performs transactional writes through `mp_*` PostgreSQL functions. Avoid moving multi-row business logic into widget actions when a database function already owns the operation.

## Normalize an Appsmith export

When Appsmith produces a raw JSON export, normalize it from the repository root with:

```bash
node appsmith/pretty-json.mjs \
  --in appsmith/MushroomProcess.exported.json \
  --out appsmith/MushroomProcess.json \
  --sort-keys
```

On PowerShell:

```powershell
node .\appsmith\pretty-json.mjs `
  --in .\appsmith\MushroomProcess.exported.json `
  --out .\appsmith\MushroomProcess.json `
  --sort-keys
```

Validate the normalized export before committing:

```bash
python3 -m json.tool appsmith/MushroomProcess.json >/dev/null
git diff --check
```

## Retained specifications

The files under `appsmith/spec/` describe intended pages, widgets, and workflows from earlier migration planning. They may be useful when reviewing page coverage or reconstructing a widget manually, but they can lag the current exported application.

Current responsibilities are:

- **Appsmith:** operator UI, client-side validation, and orchestration.
- **PostgreSQL:** internal validation, transactions, lifecycle changes, events, lineage, and print-queue creation.
- **n8n:** ecommerce, reporting, reconciliation, document, and other external or asynchronous integrations.
- **NocoDB:** optional administrative browsing and compatibility where still useful; it is not the workflow-automation layer.

## Change discipline

- Existing pages, widgets, queries, and JS objects may be patched directly in the exported JSON.
- New pages or widgets should normally be created through the Appsmith UI and then re-exported.
- Keep published and unpublished page/action definitions synchronized.
- Validate JSON, JavaScript syntax, query bindings, widget references, and the applicable PostgreSQL smoke tests before release.

## Lots deep links and QR routing

The published **Lots** page accepts an optional `lot` query parameter:

```text
...?lot=LOT-260624-rTT0&source=qr
```

When a valid Lot identifier is supplied, the main Lots query always includes that
record even when the page's current filters would otherwise hide it, sorts it to
the first row, and `LotsPage.init()` resets the table so the scanned Lot becomes
the active/default selection. The page does not automatically open a workflow
modal; the operator still chooses the appropriate action for the Lot's current
state.

`source=qr` is informational and causes a brief success notification after the
Lot is focused. Direct deep links without `source=qr` use the same selection
behavior.

### Product QR deep links

The published Products page accepts `?product=PROD-...&source=qr`. The requested Product is included even if the current table filters would normally hide it, sorted first, and made the only selected row. This is used for fresh/freezer tray QR routing.

Legacy Airtable `public_link*` columns are not part of the active Lots table metadata. Internal navigation is driven by the stable Product/Lot query-parameter contract instead.

## Inventory reconciliation QR scanner (Issue #78)

`InventoryReconcile.addProduct(rawValue, fromScan)` supports both the existing
manual Product/Lot entry path and values supplied by an Appsmith Code Scanner.
When `fromScan` is `true`, the controller extracts the first canonical
`PROD-...` or `LOT-...` identifier from the scanned value. This supports the
stable MushroomProcess QR payloads such as:

```text
https://qr.danks.store/r?i=PROD-260801-bojs
https://qr.danks.store/r?i=LOT-260624-rTT0
```

The scanner UI is intentionally **not** serialized into this repository patch.
Create the widget manually on **Inventory - Reconcile** and then re-export the
application if the widget definition should be committed later.

Recommended widget setup:

- Widget type: **Code Scanner**
- Widget name: `scnReconInventory`
- Place it adjacent to the existing `inpReconProductNumber` input / **Add Product / Lot** control.
- Use an on-demand scanner layout so each inventory scan is intentional.
- Disable it until a reconciliation session is active, if the widget version exposes a Disabled property:

  ```javascript
  {{ !InventoryReconcile.isSessionActive() }}
  ```

- Set **OnCodeDetected** to:

  ```javascript
  {{ InventoryReconcile.addProduct(scnReconInventory.value, true) }}
  ```

Do not change the existing input `onSubmit` or **Add Product / Lot** button;
both continue to call `InventoryReconcile.addProduct()` with no arguments.

Scanner behavior:

- extracts `PROD-*` / `LOT-*` from a full stable QR URL or accepts a canonical ID directly;
- rejects scans that do not contain a valid Product/Lot identifier;
- writes the normalized identifier into the existing input while it is being resolved;
- uses the same exact Product/Lot query and reconciliation rules as manual entry;
- suppresses immediate duplicate scanner callbacks and concurrent scan handling;
- clears the input after a successful or already-found scan;
- leaves unresolved identifiers visible for operator review;
- makes no inventory database change until the existing reconciliation Finalize step.
