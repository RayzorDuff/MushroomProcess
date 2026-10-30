# Contributing

This repository maintains the MushroomProcess Airtable parity implementation, PostgreSQL schema and workflow functions, Appsmith application, n8n integrations, and print tooling.

git clone https://github.com/RayzorDuff/MushroomProcess.git

## Branching
- **main**: stable, reviewed scripts (deploy-ready).
- **production**: the current deployed operational codebase (PostgreSQL, Appsmith, n8n, print tooling and retained Airtable compatibility).
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


## Change size, risk, and review policy

Decide whether a change needs a pull request (PR) by **risk and scope**, not by a fixed line-count threshold.

- **Trivial:** spelling, comments, README/CONTRIBUTING clarifications, formatting — a direct commit to `main` is allowed after checking the diff.
- **Small, localized:** a focused syntax correction or narrow bug fix, even across a few scripts — a direct commit to `main` is allowed after relevant validation.
- **Substantial:** features, multiple subsystems, or changes whose side effects are hard to review — use a topic branch and PR, then notify the repository owner and leave the final merge to them.
- **High risk, regardless of lines changed:** significant file deletion/renaming, Docker/infrastructure, deployment, bootstrap/restore or backup workflows, database schema/data migration, authentication/permissions, payroll/financial processing, or production security — use a topic branch and PR. Do not push such changes straight to `main`.

For any substantial/high-risk PR:

1. Branch from current `main`, keep unrelated changes out, and document the scope and risk.
2. Inspect `git diff --stat`, `git diff --check`, and the complete changed/deleted/renamed file list. Specifically verify that all deletions are intended. For broad cleanup, compare against the pre-change tree before committing.
3. Run applicable lint, tests, validation, and build checks; record what passed and what could not be run.
4. Open the PR, make it ready for review (not a draft), include issue references and a concise validation/rollback summary, and notify the owner with its link.
5. **Do not self-merge:** the repository owner reviews and performs the final merge. Respond to PR review comments and revalidate as needed.

## Branch protection and review limitations

The `main` ruleset is intended to block branch deletion and force pushes, with active enforcement and no bypass. The baseline ruleset does **not** itself mandate PRs for substantial changes, CI checks, or conversation resolution. Those requirements above are contributor workflow conventions; do not represent them as GitHub-enforced. If CI status checks are subsequently required, configure actual reliable checks for this repository and verify the effect on direct commits. Do not rewrite protected branch history to repair a mistake.

## MushroomProcess production branch policy

The rules above apply to `main`. The `production` branch represents the current deployed operational codebase and requires a deliberate promotion step: make implementation changes on a topic branch from `main`, submit substantial/high-risk changes through a PR into `main`, and only then cherry-pick or promote reviewed changes into `production` when they are ready to deploy. The repository owner controls final PR merges and production promotion. Do not make feature/deployment changes directly on `production`; narrowly scoped emergency corrections require clear documentation and subsequent reconciliation to `main`. Before starting new work, compare `main` with `production`. If production contains unreconciled operational fixes, reconcile production back into main through a reviewed merge PR first, preserving newer reviewed main features. Do not replace production files with an older main snapshot. Git reconciliation does not itself deploy services or apply database migrations.
