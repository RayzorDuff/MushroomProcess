# Airtable Reference Implementation

This directory contains the Airtable-side implementation retained for the
v1.1.0 parity release and final production migration.

## Contents

- `automation/` — Airtable Automation scripts for production workflow actions, with corresponding reference images under `automation/screenshots/`.
- `extensions/` — one-off Airtable extension scripts used for backfills and
  administrative maintenance.
- `interfaces/` — Airtable Interface specifications, exports, setup notes, and page images under `interfaces/screenshots/`.

The shared Airtable export, migration tools, generated PostgreSQL modules, and
optional NocoDB schema snapshot live separately under [`../schema/`](../schema/).
The Appsmith implementation lives under [`../appsmith/`](../appsmith/), and
external/asynchronous workflows live under [`../n8n/`](../n8n/).

## Lifecycle

Airtable remains the production reference implementation through the v1.1.0
migration release. After production cutover, this directory is retained as the
final Airtable implementation and parity reference. New operational development
should occur in Appsmith, PostgreSQL, and n8n rather than by extending these
Airtable scripts.
