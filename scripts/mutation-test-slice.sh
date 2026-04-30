#!/usr/bin/env bash
# Yamete — Mutation Test Slice Runner (per-PR)
#
# Phase 2.1 CI sustainability layer: the full `make mutate` runs all 112
# catalogued mutations, taking ~20 minutes per PR push at ~5–10 s/entry.
# This sliced runner inspects the diff against the PR base branch, picks
# only the catalog entries whose `targetFile` was touched, and invokes
# the existing `scripts/mutation-test.sh` runner with a temporary catalog
# containing just that subset. A typical PR touches 1–5 files (1–10
# mutations) so a sliced run finishes in ~1–2 minutes — fast enough to
# stay a required PR gate.
#
# Why a temporary catalog file?
#   `scripts/mutation-test.sh` reads `Tests/Mutation/mutation-catalog.json`
#   directly and we are NOT permitted to modify the runner. Driving it
#   via env var is the cleanest seam: we point CATALOG at a generated
#   file via the script's `CATALOG=...` override (see how the runner
#   declares CATALOG with `CATALOG="Tests/Mutation/mutation-catalog.json"`
#   — bash doesn't honour shell-export overrides for that form, so we
#   instead generate a sliced JSON, swap it in by symlink, run, restore).
#
# Strategy:
#   1. Resolve base branch (BASE_REF env or origin/develop fallback).
#   2. `git diff --name-only <base>...HEAD` for changed files.
#   3. Filter the catalog to entries whose `targetFile` ∈ changed files.
#   4. If the filtered set is empty → exit 0 (no production gates touched
#      means no mutation work to do; the full nightly catches drift).
#   5. Atomically swap the canonical catalog with the sliced one via
#      mv-rename, run `scripts/mutation-test.sh`, restore on exit.
#
# Exit code:
#   0   if no relevant mutations OR all sliced mutations CAUGHT.
#   1   if any sliced mutation ESCAPED or INFRA-failed (delegated to
#       the underlying runner).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CATALOG="Tests/Mutation/mutation-catalog.json"
CATALOG_BACKUP="Tests/Mutation/mutation-catalog.json.full"
SLICED_CATALOG="$(mktemp -t mutation-catalog-sliced.XXXXXX).json"

# ── colours ───────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_DIM=""; C_BOLD=""; C_RESET=""
fi

# ── pre-flight ────────────────────────────────────────────────
[[ -f "$CATALOG" ]] || {
    printf "  ${C_RED}FAIL${C_RESET}      catalog not found: %s\n" "$CATALOG" >&2
    exit 1
}

command -v jq >/dev/null 2>&1 || {
    printf "  ${C_RED}FAIL${C_RESET}      jq required (brew install jq)\n" >&2
    exit 1
}

# ── resolve base branch ───────────────────────────────────────
# Priority:
#   1. BASE_REF env var (CI sets this from github.base_ref).
#   2. GITHUB_BASE_REF env (set automatically by Actions on pull_request).
#   3. origin/develop (sensible default for feature branches).
BASE_REF="${BASE_REF:-${GITHUB_BASE_REF:-develop}}"
# Normalise to a remote ref the runner can diff against.
if git rev-parse --verify "origin/${BASE_REF}" >/dev/null 2>&1; then
    BASE_RESOLVED="origin/${BASE_REF}"
elif git rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
    BASE_RESOLVED="$BASE_REF"
else
    printf "  ${C_RED}FAIL${C_RESET}      cannot resolve base ref: %s\n" "$BASE_REF" >&2
    exit 1
fi

printf "${C_BOLD}  slice     base: %s${C_RESET}\n" "$BASE_RESOLVED"

# ── diff: changed files since branch point ────────────────────
# Use three-dot syntax so we get files changed on this branch since
# diverging from base, ignoring concurrent base-branch commits the
# branch hasn't merged yet.
CHANGED_FILES="$(git diff --name-only "${BASE_RESOLVED}...HEAD" || true)"

if [[ -z "$CHANGED_FILES" ]]; then
    printf "  ${C_DIM}slice     no changed files vs %s — nothing to mutate${C_RESET}\n" "$BASE_RESOLVED"
    exit 0
fi

CHANGED_COUNT=$(echo "$CHANGED_FILES" | wc -l | tr -d ' ')
printf "  ${C_DIM}slice     changed files: %d${C_RESET}\n" "$CHANGED_COUNT"

# ── filter catalog by changed targetFile ──────────────────────
# Build a JSON array of changed file paths so jq can membership-test
# each catalog entry's targetFile.
CHANGED_JSON=$(printf '%s\n' $CHANGED_FILES | jq -R . | jq -s .)

jq --argjson changed "$CHANGED_JSON" '
    .mutations |= map(select(.targetFile as $t | $changed | index($t)))
' "$CATALOG" > "$SLICED_CATALOG"

SLICED_COUNT=$(jq '.mutations | length' "$SLICED_CATALOG")
TOTAL_COUNT=$(jq '.mutations | length' "$CATALOG")

printf "  ${C_BOLD}slice     mutations: %d / %d${C_RESET}\n" "$SLICED_COUNT" "$TOTAL_COUNT"

if [[ "$SLICED_COUNT" -eq 0 ]]; then
    printf "  ${C_GREEN}OK${C_RESET}        no catalogued production gates touched in diff\n"
    rm -f "$SLICED_CATALOG"
    exit 0
fi

# ── swap catalog, run, restore ────────────────────────────────
# scripts/mutation-test.sh reads $CATALOG as a hard-coded relative path
# and we cannot edit it. We instead atomically swap the canonical file
# for the sliced subset, restore it on EXIT (success or failure), and
# delegate to the existing runner.
cleanup() {
    if [[ -f "$CATALOG_BACKUP" ]]; then
        mv "$CATALOG_BACKUP" "$CATALOG"
    fi
    rm -f "$SLICED_CATALOG"
}
trap cleanup EXIT INT TERM

cp "$CATALOG" "$CATALOG_BACKUP"
cp "$SLICED_CATALOG" "$CATALOG"

# Hand off to the canonical runner. Its exit code becomes ours.
scripts/mutation-test.sh
