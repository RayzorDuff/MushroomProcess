This document describes the **lot-centric** Appsmith UI approach used for the Postgres-first MushroomProcess migration.

The legacy Airtable UI is station-centric (Sterilizer, Inoculate, Dark Room, Fruiting, Harvest). The long-term UI direction is:

- **Lots page** as the primary operational hub
- **Products page** as the outbound/shipping hub
- Station pages exist where they provide strong operator value (e.g., Sterilizer IN/OUT), but most actions are performed from lots via modals.

## Core principles

- Read from `public.vc_*` views (optimized for operator display and computed fields)
- Write to base tables (e.g. `public.lots`, `public.products`, `public.sterilization_runs`)
- Centralize workflow side-effects in Postgres functions/triggers (`nocodb_schema/pgsql/005+`)
- Keep Appsmith widgets “dumb”: widgets call JS, JS calls SQL

## Lots page (current)

- Filter widgets drive a single `qLots` query against `public.vc_lots`
- Multi-select actions use modals:
  - Shake (log event)
  - Retire (multi-reason, update status/location, log events)

## Next pages

- Products page (ship/move/expire/assign ecommerce IDs)
- Spawn-to-Bulk and Inoculate as modals/pages that accept multiple inputs and create downstream lots (consuming sources)

## Why modals

Modals provide:
- Clear confirmation for multi-lot actions
- A place to enforce validation and show computed summaries
- A consistent pattern for “one SQL function per user action”

