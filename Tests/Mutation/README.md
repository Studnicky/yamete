# Mutation Test Catalog

This directory holds the declarative catalog used by `make mutate`
(`scripts/mutation-test.sh`) to mechanically re-verify that every
production gate in `Sources/SensorKit/` has a behavioural test cell that
catches its removal.

## Why this exists

Mutation pairs ("remove guard X → assert cell Y fails") were previously
embedded only in agent narration / PR descriptions and forgotten the
moment the agent ended. This catalog makes them executable, repeatable,
and CI-targetable. Every release should be able to run `make mutate`
and confirm `total == caught`.

## Files

- `mutation-catalog.json` — single source of truth. Each entry pairs a
  production gate (encoded as a literal `search` / `replace` snippet)
  with the XCTest method that must fail when the gate is removed.
- `README.md` — this file.

The runner is `scripts/mutation-test.sh`; the Make target is
`make mutate`.

## Catalog entry shape

```json
{
  "id": "trackpad-gesture-recency-gate",
  "targetFile": "Sources/SensorKit/TrackpadActivitySource.swift",
  "search":  "guard sinceGesture <= tapAttributionWindow else {",
  "replace": "guard sinceGesture >= -1 else {",
  "expectedFailingTest": "MatrixDeviceAttributionTests/testExternalMouseClick_doesNotFireTrackpadTap",
  "expectedFailureSubstring": "[scenario=external-mouse-click]",
  "description": "..."
}
```

Field rules:

- `id` — unique slug, kebab-case, used as a stable handle in reports.
- `targetFile` — repo-relative path under `Sources/`.
- `search` — literal byte-exact string that MUST appear exactly once in
  the target file. The runner validates uniqueness before applying the
  mutation. Line numbers are intentionally NOT used — they drift the
  moment formatting changes; a search/replace pair stays valid as long
  as the gate's surface text is preserved.
- `replace` — literal replacement string. Must keep the file
  syntactically valid Swift (the runner reports a build failure as an
  infrastructure failure, not as a caught mutation).
- `expectedFailingTest` — `XCTestClass/testMethod` form, exactly as
  passed to `swift test --filter YameteTests.<expectedFailingTest>`.
- `expectedFailureSubstring` — literal substring that MUST appear in
  the captured XCTest output for the runner to count the mutation as
  CAUGHT. Anchors the runner to the specific assertion, not just any
  failure (a build error, an unrelated XCTSkip, etc., would otherwise
  masquerade as a catch).
- `description` — one-line rationale. Shown in reports.

## Adding a new mutation

1. Pick a production guard / threshold / debounce / phase gate in
   `Sources/SensorKit/*.swift` that has no catalog entry yet. The
   stretch coverage helper (`scripts/mutation-test.sh` → see runner
   header) can identify candidates that match `guard|if|threshold|
   debounce|gate` keywords without coverage.
2. Find (or write) a matrix test cell that asserts the behaviour the
   gate enforces. The assertion message MUST contain a stable
   substring you can pin in `expectedFailureSubstring`.
3. Append an entry to `mutation-catalog.json`. Run `make mutate` and
   confirm the new entry reports CAUGHT.
4. Commit catalog and (if you wrote one) test changes. Never commit a
   mutation applied to `Sources/`.

## What the runner does

For each entry, on a clean working tree:

1. Validates that `search` is present exactly once in `targetFile`.
2. Applies the mutation via Python literal `str.replace(..., 1)`.
3. Runs `swift test --filter YameteTests.<expectedFailingTest>`.
4. Reverts via `git checkout -- <targetFile>`.
5. Asserts the test exited non-zero AND the captured output contains
   `expectedFailureSubstring`.

Outcomes:

- **CAUGHT** — exit non-zero AND substring matched. Good.
- **ESCAPED** — test passed despite mutation, or failed without the
  expected substring (catalog drift), or test wasn't found. Bad — the
  gate is unverified.
- **INFRA** — search pattern missing/non-unique, or mutated code did
  not compile. Bad — catalog must be updated.

The runner refuses to start if any `targetFile` has uncommitted
changes; the revert path would otherwise clobber unstaged work.

## Why JSON, not Swift

Co-locating the catalog as `MutationCatalog.swift` would force the
runner to spawn `swift run` (slow + circular: the runner mutates the
same package) or to parse Swift literals via fragile regex. JSON is
shell-friendly via `jq`, language-agnostic, and trivially extensible.
