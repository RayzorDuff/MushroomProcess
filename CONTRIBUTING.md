# Contributing

This repository maintains the MushroomProcess Airtable parity implementation, PostgreSQL schema and workflow functions, Appsmith application, n8n integrations, and print tooling.

git clone https://github.com/RayzorDuff/MushroomProcess.git

## Branching
- **main**: stable, reviewed scripts (deploy-ready).
- **production**: scripts currently deployed in Airtable (source of truth for behavior).
- **feature/***: proposals or updates; open PRs into **main**.

## Workflow
1. Branch from `main`: `git checkout -b feature/<short-topic>`
2. Change the appropriate component. Airtable parity work lives under `/airtable`, database work under `/schema/pgsql`, Appsmith under `/appsmith`, and external workflows under `/n8n`. Do not change table or field names casually; update documentation when you do.
3. Run formatting: `npm run lint:fix` (see ESLint/Prettier config).
4. Commit with Conventional Commits, e.g., `feat(lc): validate syringe_count as integer ≥ 1`.
5. Open a PR to **main** using the template. Assign a reviewer.
6. After merge, cherry-pick to **production** or open a PR from `main` → `production` when ready to deploy.

## Operational Workflow Architecture

New operational workflows should prefer:

- Postgres SQL functions
- Appsmith-driven UI
- explicit event logging
- lineage preservation

Legacy Airtable automation code and discarded migration prototypes should be treated as reference material rather than primary operational logic.

Avoid duplicating business logic between:

- Appsmith JS
- automation scripts
- SQL functions

Business rules should preferentially live in Postgres functions.

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

