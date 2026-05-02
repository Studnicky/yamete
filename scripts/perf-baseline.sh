#!/usr/bin/env bash
# Yamete — Performance Baseline Regression Detector
#
# Drives Tests/Performance_Tests.swift cells, captures the per-cell
# `PERFMETRIC: cell=<name> wallclock=<seconds> memory=<bytes>` lines
# they emit, and compares each measurement against the committed
# `Tests/Performance/baselines.json` with a per-cell tolerance factor.
#
# Why a sibling shell driver and not a `swift test` target?
#   The cells already run under `swift test --filter Performance_Tests`.
#   What's missing is absolute-baseline regression detection: today's
#   cells assert bounded RATIOS (median(second_half) ≤ 3× first_half)
#   but a 2× CPU regression that stays inside the per-cell ratio slips
#   through. The driver layers absolute-baseline tracking ON TOP of
#   the existing functional ratio asserts — `swift test` keeps its
#   role (functional pass/fail), this script keeps its role (drift
#   detection across hosts/time).
#
# Pre-flight gates:
#   - Refuses to run on a dirty Sources/ tree (the run is supposed to
#     measure committed code; uncommitted noise muddies baselines).
#   - Verifies `swift build` succeeds before starting the measurement
#     run, so a compile failure surfaces with a clear error rather
#     than as missing PERFMETRIC lines.
#
# Output:
#   Per-cell PASS / FAIL with observed value, baseline value, and
#   ratio. Aggregate report with total / passed / regressed counts.
#
# Exit code:
#   0   when every cell observed is within tolerance.
#   1   when any cell exceeds tolerance OR a baselined cell is missing
#       from output OR pre-flight gates fail.
#
# Companion: `scripts/perf-baseline-record.sh` writes a fresh
# baselines.json (gated behind YAMETE_BASELINE_RECORD=1).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BASELINE_FILE="Tests/Performance/baselines.json"
TEST_FILTER="Performance_Tests"

# ── colours ───────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_DIM=""; C_BOLD=""; C_RESET=""
fi

# ── pre-flight ────────────────────────────────────────────────
command -v jq >/dev/null 2>&1 || {
    printf "  ${C_RED}FAIL${C_RESET}      jq required (brew install jq)\n" >&2
    exit 1
}
command -v python3 >/dev/null 2>&1 || {
    printf "  ${C_RED}FAIL${C_RESET}      python3 required\n" >&2
    exit 1
}

if [[ ! -f "$BASELINE_FILE" ]]; then
    printf "  ${C_RED}FAIL${C_RESET}      baseline file missing: %s\n" "$BASELINE_FILE" >&2
    printf "            Run: YAMETE_BASELINE_RECORD=1 make perf-baseline-record\n" >&2
    exit 1
fi

if [[ -n "$(git status --porcelain -- Sources)" ]]; then
    printf "  ${C_RED}FAIL${C_RESET}      working tree dirty under Sources/\n" >&2
    printf "            Baselines compare against committed production code; uncommitted\n" >&2
    printf "            edits in Sources/ would muddy the measurement.\n" >&2
    printf "            Stash or commit local changes in Sources/ first.\n" >&2
    exit 1
fi

printf "${C_BOLD}  perf      build${C_RESET}\n"
if ! swift build >/tmp/perf_build.log 2>&1; then
    printf "  ${C_RED}FAIL${C_RESET}      swift build failed — see /tmp/perf_build.log\n" >&2
    tail -20 /tmp/perf_build.log >&2
    exit 1
fi
printf "  perf      ${C_GREEN}build ok${C_RESET}\n"

# ── run Performance_Tests, capture PERFMETRIC lines ──────────
printf "${C_BOLD}  perf      run Performance_Tests${C_RESET}\n"
RAW_LOG=$(mktemp)
set +e
swift test --filter "$TEST_FILTER" >"$RAW_LOG" 2>&1
TEST_EXIT=$?
set -e

if [[ $TEST_EXIT -ne 0 ]]; then
    printf "  ${C_YELLOW}WARN${C_RESET}      swift test exited %d — functional asserts may have failed\n" "$TEST_EXIT" >&2
    printf "            Continuing baseline comparison on whatever PERFMETRIC lines were emitted.\n" >&2
fi

# ── compare against baseline ──────────────────────────────────
printf "\n${C_BOLD}  perf      compare against %s${C_RESET}\n\n" "$BASELINE_FILE"

# Hand off to Python: parse PERFMETRIC lines, merge with baseline
# JSON, emit per-cell PASS/FAIL, return exit code.
python3 - "$BASELINE_FILE" "$RAW_LOG" <<'PY'
import json, pathlib, re, sys

baseline_path = pathlib.Path(sys.argv[1])
log_path = pathlib.Path(sys.argv[2])

baseline = json.loads(baseline_path.read_text())
cells_baseline = baseline.get("cells", {})

# Stable line shape: PERFMETRIC: cell=<name> wallclock=<seconds> memory=<bytes>
LINE_RE = re.compile(
    r"^PERFMETRIC:\s+cell=(?P<cell>\S+)\s+wallclock=(?P<wall>[\d.eE+-]+)\s+memory=(?P<mem>-?\d+)\s*$"
)

observed = {}
for raw in log_path.read_text().splitlines():
    m = LINE_RE.match(raw.strip())
    if not m:
        continue
    cell = m.group("cell")
    observed[cell] = {
        "wallclock_seconds": float(m.group("wall")),
        "memory_delta_bytes": int(m.group("mem")),
    }

if not observed:
    print("  FAIL      no PERFMETRIC lines emitted by Performance_Tests")
    print("            Cells must call self.emitPerfMetric(...) at end of measurement block.")
    sys.exit(1)

# RED / GREEN escape codes for the report (terminal-only).
import os, sys as _sys
isatty = _sys.stdout.isatty()
RED   = "\033[31m" if isatty else ""
GREEN = "\033[32m" if isatty else ""
YEL   = "\033[33m" if isatty else ""
DIM   = "\033[2m"  if isatty else ""
BOLD  = "\033[1m"  if isatty else ""
RST   = "\033[0m"  if isatty else ""

total      = 0
passed     = 0
regressed  = 0
missing    = 0
fail_lines = []

# Iterate over the union: every baselined cell + every observed cell.
all_cells = sorted(set(cells_baseline) | set(observed))
for cell in all_cells:
    total += 1
    base = cells_baseline.get(cell)
    obs  = observed.get(cell)
    if obs is None:
        print(f"  {RED}MISSING{RST}   {cell}: baselined cell did not emit PERFMETRIC")
        missing += 1
        fail_lines.append(f"{cell}: baselined cell produced no PERFMETRIC line")
        continue
    if base is None:
        # Observed but not baselined — info-only, not a regression.
        print(f"  {YEL}NEW{RST}       {cell}: observed but no baseline (record to seed)")
        continue
    tol = float(base.get("tolerance_factor", 2.0))
    base_wall = float(base["wallclock_seconds"])
    base_mem  = int(base["memory_delta_bytes"])
    obs_wall  = obs["wallclock_seconds"]
    obs_mem   = obs["memory_delta_bytes"]

    # Wallclock ratio: observed / baseline. Skip if baseline ~0 (sub-ms cell).
    wall_ratio = (obs_wall / base_wall) if base_wall > 0.001 else 0.0
    # Memory ratio: positive deltas only. Negative or zero baseline = skip.
    mem_ratio  = (obs_mem / base_mem) if base_mem > 0 else 0.0

    wall_pass = (wall_ratio == 0.0) or (wall_ratio <= tol)
    # Memory tolerance: also allow shrinkage (obs <= base always passes).
    mem_pass  = (base_mem <= 0) or (obs_mem <= max(base_mem * tol, 64 * 1024))

    cell_pass = wall_pass and mem_pass
    if cell_pass:
        passed += 1
        print(f"  {GREEN}PASS{RST}      {cell}")
        print(f"  {DIM}            wall={obs_wall:.4f}s (baseline {base_wall:.4f}s, ratio {wall_ratio:.2f}×, tol {tol}×){RST}")
        print(f"  {DIM}            mem ={obs_mem} B    (baseline {base_mem} B, ratio {mem_ratio:.2f}×){RST}")
    else:
        regressed += 1
        print(f"  {RED}FAIL{RST}      {cell}")
        if not wall_pass:
            print(f"            wallclock REGRESSION: {obs_wall:.4f}s vs baseline {base_wall:.4f}s (ratio {wall_ratio:.2f}×, tol {tol}×)")
            fail_lines.append(f"{cell}: wallclock {obs_wall:.4f}s > {tol}× baseline {base_wall:.4f}s (ratio {wall_ratio:.2f}×)")
        if not mem_pass:
            print(f"            memory REGRESSION: {obs_mem} B vs baseline {base_mem} B (ratio {mem_ratio:.2f}×, tol {tol}×)")
            fail_lines.append(f"{cell}: memory {obs_mem} B > {tol}× baseline {base_mem} B (ratio {mem_ratio:.2f}×)")

print()
print(f"  {BOLD}─────────────────────────────────────────{RST}")
print(f"  perf      total:     {total}")
print(f"  perf      {GREEN}passed:    {passed}{RST}")
if regressed:
    print(f"  perf      {RED}regressed: {regressed}{RST}")
if missing:
    print(f"  perf      {RED}missing:   {missing}{RST}")

if regressed or missing:
    print()
    print(f"  {BOLD}Failures:{RST}")
    for f in fail_lines:
        print(f"    - {f}")
    sys.exit(1)

print()
print(f"  {GREEN}OK{RST}        all {passed} cells within tolerance")
sys.exit(0)
PY
RC=$?
rm -f "$RAW_LOG"
exit $RC
