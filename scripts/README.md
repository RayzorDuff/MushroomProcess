# Repository Scripts

This directory contains repository-level maintenance utilities that are run from
the MushroomProcess repository root.

## `pretty-json.mjs`

Normalizes JSON exports into stable, reviewable files. It preserves source key
order by default, supports configurable indentation and line endings, and can
optionally sort object keys recursively.

For the canonical Appsmith export:

```bash
node scripts/pretty-json.mjs \
  --in appsmith/MushroomProcess.exported.json \
  --out appsmith/MushroomProcess.json \
  --sort-keys
```

On PowerShell:

```powershell
node .\scripts\pretty-json.mjs `
  --in .\appsmith\MushroomProcess.exported.json `
  --out .\appsmith\MushroomProcess.json `
  --sort-keys
```

The utility was moved from `appsmith/pretty-json.mjs` as part of issue #83 so
repository-level utilities have one maintained location. Its behavior was not
changed by the move.

## `sync_navigation.js`

Synchronizes the logical contents of every existing Appsmith
`navMainNavigation` widget from the canonical definition in
`appsmith/navigation/navigation_manifest.json`. Run it from the repository
root after changing navigation labels, grouping, ordering, target pages/slugs,
or enabled state.

Write synchronized navigation when changes are required:

```bash
node scripts/sync_navigation.js
```

Validate without writing and fail when the export is out of sync:

```bash
node scripts/sync_navigation.js --check
```

Preview which published/unpublished page definitions would change without
writing the export:

```bash
node scripts/sync_navigation.js --dry-run
```

Optional `--appsmith <path>` and `--manifest <path>` arguments support testing
or alternate copies. See `node scripts/sync_navigation.js --help`.

The utility validates enabled manifest page names and slugs against both the
published and unpublished Appsmith definitions before changing any navigation
widget. It requires exactly one existing `navMainNavigation` per page
definition and refuses to create or reposition a missing widget.

Synchronization owns only:

- the navigation `groupButtons` definition;
- dynamic binding metadata for active-category colors and click handlers;
- dynamic property/trigger metadata for navigation click handlers.

It preserves each page's navigation widget ID/key, coordinates, layout, canvas
size, workflow widgets, queries, and JS Objects. Groups are derived from enabled
manifest items: zero enabled items are hidden, one is a direct button, and two
or more become a dropdown.

Do not add page-specific workflow logic to repository maintenance scripts.
Navigation synchronization must remain independent of PostgreSQL and n8n.
