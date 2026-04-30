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
| `.github/workflows/test.yml` | Test | `swift-test`, `swift-test-direct-build`, `lint`, `mutate` |
| `.github/workflows/host-app-test.yml` | Host-app test | `host-app-test` |
| `.github/workflows/perf-baseline.yml` | Perf baseline | `perf-baseline` (cron + dispatch only) |
| `.github/workflows/release.yml` | Release | `release` (tag-push only) |

The `Test` workflow's `lint` job and the existing `CI` workflow's
`lint` job are intentionally redundant — `Test` is the Phase 2
correctness-gate aggregate; `CI` keeps `lint` so existing
branch-protection that targets `lint` (CI) doesn't break the moment
this ruleset lands.

## `master` (production)

Required status checks before merge:

- `lint` (from `Test` workflow — strict-concurrency type-check)
- `swift-test` (from `Test` workflow — `swift test` default)
- `swift-test-direct-build` (from `Test` workflow — `swift test
  -Xswiftc -DDIRECT_BUILD`)
- `mutate` (from `Test` workflow — full mutation catalog,
  `caught == total`)

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
- `mutate`

Same protection posture as `master`. Feature branches must rebase
onto `develop` and pass all four checks before squash-merge.

## Recommended (not yet required)

These checks should run on every PR but are not blocking yet — they
become required once they prove stable on the `macos-15` runner over
several PRs without flake.

- `host-app-test` (from `Host-app test` workflow). Promote to
  required once a 4-week sample shows zero spurious failures attributable
  to runner state (Force-Touch availability, Accessibility prompts,
  UN-center entitlements).

## Informational only (never required)

- `perf-baseline` (from `Perf baseline` workflow). Cron-driven
  weekly + on-demand `workflow_dispatch`; intentionally NOT wired
  to PRs. Drift detection is best run on a stable cadence on the
  same runner class, not per-PR. Failures here open an issue or
  Slack ping out-of-band; they never block a merge.

## Updating this file

Whenever a workflow's job names change, update the table above
**and** the GitHub repo ruleset in the same PR. The ruleset is keyed
on the literal job-name string GitHub Actions reports, so any rename
silently breaks branch protection until the ruleset catches up.
