# Contributing

This repository maintains Airtable Automation scripts for the Mushroom production system.

## Branching
- **main**: stable, reviewed scripts (deploy-ready).
- **production**: scripts currently deployed in Airtable (source of truth for behavior).
- **feature/***: proposals or updates; open PRs into **main**.

## Workflow
1. Branch from `main`: `git checkout -b feature/<short-topic>`
2. Update scripts under `/scripts`. Do not change table/field names casually; update docs if you do.
3. Run formatting: `npm run lint:fix` (see ESLint/Prettier config).
4. Commit with Conventional Commits, e.g., `feat(lc): validate syringe_count as integer ≥ 1`.
5. Open a PR to **main** using the template. Assign a reviewer.
6. After merge, cherry-pick to **production** or open a PR from `main` → `production` when ready to deploy.

## Headers
Each script has a succinct header:
```js
/**
 * Script: <file>
 * Version: YYYY-MM-DD.1
 * Summary: <one line>
 * Notes: Production behavior preserved; includes resilience guards.
 */
```

## Schema changes
- If table/field names change, update `/doc/FIELD_MAP.md` and bump the version in all impacted scripts.
- Prefer additive changes and deprecate old fields gracefully.

## Testing
- Dry-run scripts in Airtable's automation tester with realistic records.
- For print queue logic, use a staging printer and the `Queued_Staging` view.

