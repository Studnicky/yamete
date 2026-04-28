#!/usr/bin/env bash
# Yamete — Mutation Test Runner
#
# Drives the catalog at Tests/Mutation/mutation-catalog.json, applying each
# declarative production-code mutation on a clean working tree, running the
# named XCTest (which MUST fail), then reverting via `git checkout --`. The
# runner is a meta-test: it asserts that for every entry, the production gate
# under mutation is genuinely covered by a behavioural test cell that fails
# with the expected error substring.
#
# Why not a `swift test` target?
#   The runner mutates production source. Putting it inside `swift test` is
#   circular (the same target the runner mutates would be the harness host).
#   Keeping it as a sibling shell driver isolates the mutation phase from
#   the test harness and lets us treat any non-zero `swift test` exit as the
#   signal of a caught mutation.
#
# Why JSON catalog?
#   Shell-friendly. `jq` parses each entry; Python performs the literal
#   in-place string replacement. No regex DSL, no line numbers (which drift
#   the moment formatting changes).
#
# Mutation strategy:
#   Each catalog entry encodes a (search, replace) pair. The search string
#   MUST be unique in its target file (the runner asserts this). Mutations
#   are applied via Python's `str.replace(..., 1)` for byte-exact substitution,
#   then reverted via `git checkout -- <file>` — which restores the working
#   tree copy from HEAD (or staged state) without touching the index. The
#   runner refuses to run on a dirty tree so the revert path is always safe.
#
# Outcome semantics for each mutation:
#   - CAUGHT     — `swift test --filter <id>` exited non-zero AND captured
#                  output contained the expected failure substring.
#   - ESCAPED    — test passed despite mutation, OR failed with a different
#                  substring (drift between catalog and test message), OR the
#                  named test could not be found.
#   - INFRA-FAIL — search pattern not unique / not present, or the underlying
#                  swift compile failed independent of the test assertion.
#
# Exit code:
#   0   when total == caught (every catalogued mutation was detected).
#   1   when any mutation escaped or any infrastructure check failed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CATALOG="Tests/Mutation/mutation-catalog.json"
SWIFT_TEST_TARGET="YameteTests"
MODE="run"

for arg in "$@"; do
    case "$arg" in
        --coverage|-c)  MODE="coverage" ;;
        --help|-h)
            echo "Usage: $0 [--coverage]"
            echo ""
            echo "  (default)    apply each catalog mutation, run its expected"
            echo "               failing test, assert CAUGHT, revert."
            echo "  --coverage   list Sources/SensorKit/*.swift gate-shaped lines"
            echo "               (guard|if|threshold|debounce|gate) that have NO"
            echo "               catalog entry covering them. A punch-list of"
            echo "               un-mutated production gates."
            exit 0
            ;;
    esac
done

# ── colours ───────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_DIM=""; C_BOLD=""; C_RESET=""
fi

# ── pre-flight ────────────────────────────────────────────────
if [[ ! -f "$CATALOG" ]]; then
    printf "  ${C_RED}FAIL${C_RESET}      catalog not found: %s\n" "$CATALOG" >&2
    exit 1
fi

command -v jq >/dev/null 2>&1 || {
    printf "  ${C_RED}FAIL${C_RESET}      jq required (brew install jq)\n" >&2
    exit 1
}
command -v python3 >/dev/null 2>&1 || {
    printf "  ${C_RED}FAIL${C_RESET}      python3 required\n" >&2
    exit 1
}

# ── coverage mode ─────────────────────────────────────────────
# Emits a punch-list of gate-shaped production lines in
# Sources/SensorKit/*.swift that have NO catalog entry covering them.
# A line is "covered" if the file appears as the targetFile of any
# catalog entry AND any catalog `search` snippet is a substring of the
# line's source text. Gate-shaped = matches the regex
# `(guard|threshold|debounce)|^\s*if\s` (case-insensitive). We exclude
# `guard let`, presence-check `if !monitor`, comments, and empty-line
# noise to avoid drowning real gates in plumbing.
if [[ "$MODE" == "coverage" ]]; then
    printf "${C_BOLD}  coverage  un-mutated production gates${C_RESET}\n\n"
    python3 - "$CATALOG" <<'PY'
import json, pathlib, re, sys

catalog = json.loads(pathlib.Path(sys.argv[1]).read_text())
# Map file → list of (search, id) pairs from the catalog.
covered = {}
for m in catalog["mutations"]:
    covered.setdefault(m["targetFile"], []).append((m["search"], m["id"]))

GATE_RE = re.compile(r"\b(guard|threshold|debounce)\b|^\s*if\s+!", re.IGNORECASE)
NOISE_RE = re.compile(r"guard\s+(let|var)\s|guard\s+self\b|guard\s+!\s*Task\.isCancelled")

src_dir = pathlib.Path("Sources/SensorKit")
total = 0
uncovered = 0
covered_count = 0
for swift in sorted(src_dir.glob("*.swift")):
    rel = str(swift)
    file_searches = covered.get(rel, [])
    for lineno, line in enumerate(swift.read_text().splitlines(), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("//") or stripped.startswith("///"):
            continue
        if not GATE_RE.search(line):
            continue
        if NOISE_RE.search(line):
            continue
        total += 1
        is_covered = any(s in line for s, _ in file_searches)
        if is_covered:
            covered_count += 1
            continue
        uncovered += 1
        print(f"  - {rel}:{lineno:4d}  {stripped[:120]}")

print()
print(f"  total gate-shaped lines: {total}")
print(f"  covered by catalog:      {covered_count}")
print(f"  un-mutated punch-list:   {uncovered}")
PY
    exit 0
fi

# Refuse to run if any catalog target file has uncommitted modifications.
# The runner reverts via `git checkout -- <file>`, which would clobber
# unstaged edits on those files. We scope the dirty check to files the
# runner will actually touch — unrelated edits (Makefile, this script,
# the catalog, other Tests/) may be dirty without affecting safety.
TARGET_FILES=$(jq -r '.mutations[].targetFile' "$CATALOG" | sort -u)
DIRTY_TARGETS=""
for f in $TARGET_FILES; do
    if [[ -n "$(git status --porcelain -- "$f")" ]]; then
        DIRTY_TARGETS="$DIRTY_TARGETS $f"
    fi
done
if [[ -n "$DIRTY_TARGETS" ]]; then
    printf "  ${C_RED}FAIL${C_RESET}      mutation target files are dirty — refuse to run\n" >&2
    printf "            The runner reverts via 'git checkout -- <file>', which would\n" >&2
    printf "            clobber unstaged edits on these files:\n" >&2
    for f in $DIRTY_TARGETS; do
        printf "              %s\n" "$f" >&2
    done
    printf "            Stash or commit changes to the listed files first:\n" >&2
    printf "              git stash push --${DIRTY_TARGETS}\n" >&2
    exit 1
fi

# ── helpers ───────────────────────────────────────────────────

# Apply a literal search→replace mutation to a file. Refuses if the search
# pattern is not present, or appears more than once. Uses Python for
# byte-exact substitution (no regex).
apply_mutation() {
    local file="$1" search="$2" replace="$3"
    python3 - "$file" "$search" "$replace" <<'PY'
import sys, pathlib
path = pathlib.Path(sys.argv[1])
search = sys.argv[2]
replace = sys.argv[3]
text = path.read_text()
count = text.count(search)
if count == 0:
    print(f"INFRA-FAIL: search pattern not found in {path}", file=sys.stderr)
    sys.exit(2)
if count > 1:
    print(f"INFRA-FAIL: search pattern matches {count} times in {path} (must be unique)", file=sys.stderr)
    sys.exit(2)
path.write_text(text.replace(search, replace, 1))
PY
}

# Revert a single file to the HEAD/staged state. Safe because pre-flight
# refused to run on a dirty tree.
revert_file() {
    local file="$1"
    git checkout -- "$file"
}

# ── catalog walk ──────────────────────────────────────────────
total=0
caught=0
escaped=0
infra=0
escape_details=()

mutation_count=$(jq '.mutations | length' "$CATALOG")
printf "${C_BOLD}  mutate    catalog: %d entries${C_RESET}\n" "$mutation_count"
printf "  mutate    target:  %s\n" "$SWIFT_TEST_TARGET"
printf "\n"

for i in $(seq 0 $((mutation_count - 1))); do
    total=$((total + 1))
    id=$(jq -r ".mutations[$i].id" "$CATALOG")
    target_file=$(jq -r ".mutations[$i].targetFile" "$CATALOG")
    search=$(jq -r ".mutations[$i].search" "$CATALOG")
    replace=$(jq -r ".mutations[$i].replace" "$CATALOG")
    expected_test=$(jq -r ".mutations[$i].expectedFailingTest" "$CATALOG")
    expected_substr=$(jq -r ".mutations[$i].expectedFailureSubstring" "$CATALOG")

    printf "  ${C_BOLD}[%2d/%d]${C_RESET}    %s\n" "$((i + 1))" "$mutation_count" "$id"
    printf "  ${C_DIM}          file: %s${C_RESET}\n" "$target_file"
    printf "  ${C_DIM}          test: %s${C_RESET}\n" "$expected_test"

    # Pre-flight: target file must exist
    if [[ ! -f "$target_file" ]]; then
        printf "  ${C_RED}INFRA${C_RESET}     target file missing: %s\n\n" "$target_file"
        infra=$((infra + 1))
        escape_details+=("[$id] INFRA: target file missing: $target_file")
        continue
    fi

    # Apply mutation
    if ! apply_mutation "$target_file" "$search" "$replace" 2>/tmp/mutate_apply.err; then
        printf "  ${C_RED}INFRA${C_RESET}     %s\n\n" "$(cat /tmp/mutate_apply.err)"
        infra=$((infra + 1))
        escape_details+=("[$id] INFRA: $(cat /tmp/mutate_apply.err)")
        revert_file "$target_file" 2>/dev/null || true
        continue
    fi

    # Run targeted test. We expect it to FAIL.
    test_filter="${SWIFT_TEST_TARGET}.${expected_test}"
    test_log=$(mktemp)
    set +e
    swift test --filter "$test_filter" >"$test_log" 2>&1
    test_exit=$?
    set -e

    # Always revert before evaluating, so a runner crash doesn't leave the
    # tree mutated.
    revert_file "$target_file"

    # Evaluate outcome
    output="$(cat "$test_log")"
    rm -f "$test_log"

    if [[ $test_exit -eq 0 ]]; then
        printf "  ${C_RED}ESCAPED${C_RESET}   test passed despite mutation\n\n"
        escaped=$((escaped + 1))
        escape_details+=("[$id] ESCAPED: test '$expected_test' passed despite mutation")
        continue
    fi

    # Distinguish "test failed because of our mutation" (CAUGHT) from
    # "test failed for some other reason" (compile error, missing test, etc).
    if echo "$output" | grep -qF "Build complete!"; then
        : # build succeeded → mutation took effect; failure was test assertion
    else
        # Compile failure means the mutation broke the syntax (or unrelated
        # build error) — we cannot conclude the test gate caught the mutation.
        printf "  ${C_RED}INFRA${C_RESET}     mutated code failed to compile — mutation invalid\n\n"
        infra=$((infra + 1))
        escape_details+=("[$id] INFRA: mutated code did not compile")
        continue
    fi

    if echo "$output" | grep -qE "no tests matched|No matching test"; then
        printf "  ${C_RED}ESCAPED${C_RESET}   test '%s' not found\n\n" "$expected_test"
        escaped=$((escaped + 1))
        escape_details+=("[$id] ESCAPED: test '$expected_test' not found")
        continue
    fi

    if echo "$output" | grep -qF "$expected_substr"; then
        printf "  ${C_GREEN}CAUGHT${C_RESET}    expected substring matched\n\n"
        caught=$((caught + 1))
    else
        printf "  ${C_YELLOW}ESCAPED${C_RESET}   test failed but substring missing: %s\n\n" "$expected_substr"
        escaped=$((escaped + 1))
        # Capture the actual XCTest failure for diagnostics
        actual_msg=$(echo "$output" | grep -E "XCTAssert|failed:" | head -3 | tr '\n' ' ')
        escape_details+=("[$id] ESCAPED: substring '$expected_substr' missing; actual: ${actual_msg:0:200}")
    fi
done

# ── final report ──────────────────────────────────────────────
printf "${C_BOLD}  ─────────────────────────────────────────${C_RESET}\n"
printf "  mutate    total:   %d\n" "$total"
printf "  mutate    ${C_GREEN}caught:  %d${C_RESET}\n" "$caught"
if [[ $escaped -gt 0 ]]; then
    printf "  mutate    ${C_RED}escaped: %d${C_RESET}\n" "$escaped"
fi
if [[ $infra -gt 0 ]]; then
    printf "  mutate    ${C_RED}infra:   %d${C_RESET}\n" "$infra"
fi

if [[ ${#escape_details[@]} -gt 0 ]]; then
    printf "\n${C_BOLD}  Details:${C_RESET}\n"
    for d in "${escape_details[@]}"; do
        printf "    - %s\n" "$d"
    done
fi

if [[ $caught -eq $total ]]; then
    printf "\n  ${C_GREEN}OK${C_RESET}        all %d catalogued mutations caught\n" "$total"
    exit 0
else
    printf "\n  ${C_RED}FAIL${C_RESET}      %d / %d mutations caught\n" "$caught" "$total"
    exit 1
fi
