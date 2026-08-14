# MushroomProcess v1.2.0

Release date: 2026-08-13

## Summary

This release establishes the supported MushroomProcess baseline immediately before the planned cross-system commerce, purchasing, donation-reporting, and inventory architecture change. It is the first stable release whose operational behavior intentionally differs from the final Airtable reference in documented areas.

## Highlights

- Added categorized Appsmith navigation while preserving stable page names, slugs, and deep links.
- Added database-backed recipe management, full instruction editing, ingredients, and printable previews.
- Added inventory reconciliation by location with Product and Lot QR scanning.
- Added stable QR resolver URLs, regulated/internal routing, deep-linked Lot selection, and scan analytics.
- Added provider-neutral commerce metadata and PostgreSQL Ecwid catalog synchronization as a migration bridge.
- Added an auditable reporting layer for historical data, lot lifecycle traces, cohort analytics, and inventory snapshots.
- Added Spawn to Bulk date overrides and hardened Harvest regulation-filter refresh behavior.
- Hardened print-queue hydration against NocoDB view and record-link limitations.

## Architecture boundary

Ecwid and Clover remain legacy/current integrations at this baseline. Their planned replacement or abstraction through ERPNext and a new payment architecture is future work, not functionality claimed by this release.

## Coordinated baseline

- MushroomProcess `v1.2.0`
- SignatureGate `v1.1.0`
- RootedOps `v1.1.0`
- BookWorks `bookworks-v3.3.0`
