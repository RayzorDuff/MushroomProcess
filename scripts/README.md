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

## Navigation synchronization

Issue #83 stores the canonical logical navigation definition in
`appsmith/navigation/navigation_manifest.json`. A later phase will add
`sync_navigation.js` here after the Appsmith navigation component exists to
synchronize. The script should be run from the repository root and documented
here when it is implemented.

Do not add page-specific workflow logic to repository maintenance scripts.
Navigation synchronization must remain independent of PostgreSQL and n8n.
