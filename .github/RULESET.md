# Branch Protection Ruleset Guidance

This file documents the recommended GitHub branch-protection / ruleset
configuration for `Studnicky/yamete`. It is **guidance**, not enforced
machinery — branch-protection lives in the repo settings on GitHub, not
in version control. Apply these rules via the repo Settings → Rules →
Rulesets UI (or `gh api` if scripted) and keep this file in sync as
the workflow surface evolves.

## Workflows in scope

| Workflow file | Display name | Required jobs |
|---------------|--------------|---------------|
| `.github/workflows/ci.yml` | CI | `actionlint`, `lint`, `build`, `test` |
| `.github/workflows/test.yml` | Test | `swift-test`, `swift-test-direct-build`, `lint`, `mutate-pr` |
| `.github/workflows/host-app-test.yml` | Host-app test | `host-app-test` |
| `.github/workflows/mutate-nightly.yml` | Mutate nightly | `mutate-nightly` (cron + master/develop push) |
| `.github/workflows/perf-baseline.yml` | Perf baseline | `perf-baseline` (cron + dispatch only) |
| `.github/workflows/snapshot-baseline-seed.yml` | Snapshot baseline seed | `snapshot-baseline-seed` (workflow_dispatch only) |
| `.github/workflows/release.yml` | Release | `release` (tag-push only) |

The `Test` workflow's `lint` job and the existing `CI` workflow's
`lint` job are intentionally redundant — `Test` is the Phase 2
correctness-gate aggregate; `CI` keeps `lint` so existing
branch-protection that targets `lint` (CI) doesn't break the moment
this ruleset lands.

## Phase 2.1 mutate split

The full 112-entry mutation catalog used to run on every PR push,
costing ~20 minutes wall-clock per push. Phase 2.1 splits the gate:

- **Per-PR (`mutate-pr`)** — runs `make mutate-pr` which slices the
  catalog to entries whose `targetFile` was touched on this branch
  vs. the PR base. Typical PR touches 1–5 files (1–10 mutations) so a
  slice run finishes in ~1–2 minutes. **This is the required check.**
- **Nightly + on push to master/develop (`mutate-nightly`)** — runs
  the full `make mutate` against every catalogued mutation. Catches
  drift the slice can miss (catalog edits on un-touched files,
  refactors that move a search snippet without renaming targetFile).
  On failure during the cron run, opens a tracking issue tagged
  `mutation-catalog-regression`. **Informational only — never wired
  to PR branch protection.**

## `master` (production)

Required status checks before merge:

- `lint` (from `Test` workflow — strict-concurrency type-check)
- `swift-test` (from `Test` workflow — `swift test` default)
- `swift-test-direct-build` (from `Test` workflow — `swift test
  -Xswiftc -DDIRECT_BUILD`)
- `mutate-pr` (from `Test` workflow — sliced mutation catalog,
  filtered to entries whose targetFile was touched on this branch;
  `caught == total` over the slice)

Additional rules:

- Require pull request before merging.
- Require linear history (no merge commits except via PR merge button).
- Require branches to be up to date before merging.
- Restrict force-pushes (force-with-lease only via explicit operator
  override; see `~/.claude/CLAUDE.md` and project CLAUDE.md ops notes).
- Require signed commits — recommended, not strictly enforced today.

## `develop` (integration)

Required status checks before merge: **same set as `master`**.

- `lint`
- `swift-test`
- `swift-test-direct-build`
- `mutate-pr`

Same protection posture as `master`. Feature branches must rebase
onto `develop` and pass all four checks before squash-merge.

## Required (post-merge only)

These checks run on every PR but are not yet blocking on the PR
itself; they are required on the post-merge `push` events to
`master` / `develop`. Promote to required on PRs once a 4-week
sample shows zero spurious failures attributable to runner state
(Force-Touch availability, Accessibility prompts, UN-center
entitlements).

- `host-app-test` (from `Host-app test` workflow). Runs the
  YameteHostTest xcodebuild scheme so cells that XCTSkip under raw
  `swift test` execute their Real-driver halves inside a real
  `Yamete.app` bundle.

## Cron-only / informational (never required)

These checks are scheduled, never wired to PR branch protection.
Failures here open issues or alerts out-of-band; they never block a
merge.

- `mutate-nightly` (from `Mutate nightly` workflow). Daily 08:00 UTC
  cron + every push to `master` / `develop`. Full 112-entry catalog;
  fails loud with a tracking issue on regression.
- `perf-baseline` (from `Perf baseline` workflow). Weekly Mondays
  09:00 UTC cron + `workflow_dispatch`. Drift detection runs on a
  stable cadence on the same runner class, not per-PR.

## Manual-trigger only

- `snapshot-baseline-seed` (from `Snapshot baseline seed` workflow).
  `workflow_dispatch` only. Records a fresh set of snapshot baselines
  under `Tests/__Snapshots__/CI/` from the macos-15 runner and opens
  a PR adding them. Trigger this once after the CI surface is first
  wired up, then again only when a deliberate visual change to a
  snapshotted view requires re-baselining. The runtime resolver in
  `Tests/SnapshotUI_Tests.swift` selects the `CI` variant when
  `CI=true`, so SPM runs on the runner assert against runner-rendered
  baselines and dev runs on a workstation assert against
  `AppStore` / `Direct` baselines.

## Updating this file

Whenever a workflow's job names change, update the table above
**and** the GitHub repo ruleset in the same PR. The ruleset is keyed
on the literal job-name string GitHub Actions reports, so any rename
silently breaks branch protection until the ruleset catches up.
