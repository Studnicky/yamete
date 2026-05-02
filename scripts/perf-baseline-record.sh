#!/usr/bin/env bash
# Yamete — Performance Baseline Recorder
#
# Captures fresh per-cell wallclock + memory measurements from
# Tests/Performance_Tests.swift and OVERWRITES Tests/Performance/baselines.json
# with them. Use ONLY when the team has explicitly accepted a perf
# delta (a legitimate optimization landed, or hardware changed).
#
# Foot-gun guard: refuses to run unless YAMETE_BASELINE_RECORD=1 is
# set in the environment. Recording new baselines silently would
# defeat the entire regression-detection purpose of the file —
# a dropped guard could let a 4× slowdown become "the new baseline"
# on the next CI run. Forcing an env var keeps the record-action
# explicit and grep-able in shell history.
#
# Companion: `scripts/perf-baseline.sh` reads the file this writes.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BASELINE_FILE="Tests/Performance/baselines.json"
TEST_FILTER="Performance_Tests"
DEFAULT_TOLERANCE="2.0"

# ── colours ───────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BOLD=""; C_RESET=""
fi

# ── foot-gun guard ────────────────────────────────────────────
if [[ "${YAMETE_BASELINE_RECORD:-}" != "1" ]]; then
    printf "  ${C_RED}FAIL${C_RESET}      record-mode requires YAMETE_BASELINE_RECORD=1\n" >&2
    printf "            This script overwrites %s.\n" "$BASELINE_FILE" >&2
    printf "            Recording silently would defeat regression detection.\n" >&2
    printf "            To proceed (rare!): YAMETE_BASELINE_RECORD=1 make perf-baseline-record\n" >&2
    exit 1
fi

command -v python3 >/dev/null 2>&1 || {
    printf "  ${C_RED}FAIL${C_RESET}      python3 required\n" >&2
    exit 1
}

# ── pre-flight ────────────────────────────────────────────────
printf "${C_BOLD}  perf      build${C_RESET}\n"
if ! swift build >/tmp/perf_build.log 2>&1; then
    printf "  ${C_RED}FAIL${C_RESET}      swift build failed — see /tmp/perf_build.log\n" >&2
    tail -20 /tmp/perf_build.log >&2
    exit 1
fi
printf "  perf      ${C_GREEN}build ok${C_RESET}\n"

printf "${C_BOLD}  perf      record fresh baselines (Performance_Tests)${C_RESET}\n"
RAW_LOG=$(mktemp)
set +e
swift test --filter "$TEST_FILTER" >"$RAW_LOG" 2>&1
TEST_EXIT=$?
set -e

if [[ $TEST_EXIT -ne 0 ]]; then
    printf "  ${C_YELLOW}WARN${C_RESET}      swift test exited %d — recording PERFMETRICs anyway,\n" "$TEST_EXIT"
    printf "            but you should investigate the functional failures.\n"
fi

HOST_ARCH=$(uname -m)
NOW_ISO=$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')

python3 - "$BASELINE_FILE" "$RAW_LOG" "$HOST_ARCH" "$NOW_ISO" "$DEFAULT_TOLERANCE" <<'PY'
import json, pathlib, re, sys

baseline_path = pathlib.Path(sys.argv[1])
log_path = pathlib.Path(sys.argv[2])
host_arch = sys.argv[3]
captured_at = sys.argv[4]
default_tol = float(sys.argv[5])

LINE_RE = re.compile(
    r"^PERFMETRIC:\s+cell=(?P<cell>\S+)\s+wallclock=(?P<wall>[\d.eE+-]+)\s+memory=(?P<mem>-?\d+)\s*$"
)

cells = {}
for raw in log_path.read_text().splitlines():
    m = LINE_RE.match(raw.strip())
    if not m:
        continue
    cells[m.group("cell")] = {
        "wallclock_seconds": float(m.group("wall")),
        "memory_delta_bytes": int(m.group("mem")),
        "captured_at": captured_at,
        "host_arch": host_arch,
        "tolerance_factor": default_tol,
    }

if not cells:
    print("FAIL: no PERFMETRIC lines emitted; nothing to record", file=sys.stderr)
    sys.exit(1)

baseline_path.parent.mkdir(parents=True, exist_ok=True)

# Preserve existing tolerance_factor overrides: if a previous baseline
# existed and had a non-default tolerance for a cell, keep it.
existing = {}
if baseline_path.exists():
    try:
        existing = json.loads(baseline_path.read_text()).get("cells", {})
    except json.JSONDecodeError:
        existing = {}

for cell, fresh in cells.items():
    prior = existing.get(cell, {})
    if "tolerance_factor" in prior and prior["tolerance_factor"] != default_tol:
        fresh["tolerance_factor"] = prior["tolerance_factor"]

doc = {"cells": dict(sorted(cells.items()))}
baseline_path.write_text(json.dumps(doc, indent=2) + "\n")

print(f"  recorded {len(cells)} cells → {baseline_path}")
for name, c in doc["cells"].items():
    print(f"    {name}: wall={c['wallclock_seconds']:.4f}s mem={c['memory_delta_bytes']} B")
PY
RC=$?
rm -f "$RAW_LOG"
if [[ $RC -ne 0 ]]; then
    exit $RC
fi

printf "  ${C_GREEN}OK${C_RESET}        baselines written → %s\n" "$BASELINE_FILE"
printf "  ${C_BOLD}NEXT${C_RESET}      review the diff and commit if intentional:\n"
printf "            git diff -- %s\n" "$BASELINE_FILE"
