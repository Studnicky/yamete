#!/usr/bin/env bash
# Pre-push gate: refuse to push a release/* or hotfix/* branch unless
# `make test-host-app` has been run since the most recent change to any
# tracked source file that affects the host-app target.
#
# Why: v2.0.0 nearly shipped with project.yml still pinned to 1.3.2 —
# CI caught it AFTER the tag was pushed. We're moving the host-app
# integration check off every PR (it ran 2h to assert error-handling
# paths on a runner with no real haptic / mic / accelerometer / Force
# Touch / UN-center / Accessibility hardware), so the local version
# becomes the gate. This script enforces that the local run is FRESH.
#
# Sentinel: build/.host-app-test-fresh — touched by `make test-host-app`
# on success. mtime compared against newest mtime among tracked files in
# the host-app input set (Sources/, Tests/, project.yml, Package.swift,
# Package.resolved, Makefile). If sentinel is missing or stale, fail.
#
# Skipped when:
#   - Running on CI (CI=true env). CI has its own checks.
#   - Branch is not a release/* or hotfix/* branch. Feature branches
#     do not need host-app validation; that runs at release-prep time.

set -euo pipefail

if [[ "${CI:-}" == "true" ]]; then
  exit 0
fi

# Read git's pre-push stdin: <local-ref> <local-sha> <remote-ref> <remote-sha>
# Gate only fires for refs being pushed to release/* or hotfix/* on
# the remote. Other branches push freely.
gate_required=0
while IFS=' ' read -r local_ref local_sha remote_ref remote_sha; do
  case "$remote_ref" in
    refs/heads/release/*|refs/heads/hotfix/*)
      gate_required=1
      ;;
  esac
done

if [[ $gate_required -eq 0 ]]; then
  exit 0
fi

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

SENTINEL="build/.host-app-test-fresh"
if [[ ! -f "$SENTINEL" ]]; then
  cat >&2 <<EOF
✗ pre-push gate: $SENTINEL is missing.

   This is a release/* or hotfix/* branch. Run \`make test-host-app\`
   locally and re-push.

   See scripts/check-host-app-tests-fresh.sh for details. To bypass in
   a true emergency, \`git push --no-verify\` (project policy DISCOURAGES
   this — fix the underlying issue instead).
EOF
  exit 1
fi

# stat -f %m on macOS, stat -c %Y on Linux (devs on macOS, but be explicit).
mtime() {
  if stat -f %m "$1" >/dev/null 2>&1; then
    stat -f %m "$1"
  else
    stat -c %Y "$1"
  fi
}

sentinel_mtime=$(mtime "$SENTINEL")

# Newest mtime across the host-app input set. `git ls-files` filters to
# tracked files only — ignores generated artefacts, gitignored files,
# and untracked scratch files.
newest=0
newest_path=""
while IFS= read -r f; do
  m=$(mtime "$f")
  if (( m > newest )); then
    newest=$m
    newest_path=$f
  fi
done < <(git ls-files Sources Tests project.yml Package.swift Package.resolved Makefile 2>/dev/null)

if (( newest > sentinel_mtime )); then
  newer_by=$(( newest - sentinel_mtime ))
  cat >&2 <<EOF
✗ pre-push gate: $SENTINEL is stale.

   Newest source change: $newest_path
   ($(date -r "$newest" 2>/dev/null || date -d @"$newest" 2>/dev/null))
   Last host-app run:   $(date -r "$sentinel_mtime" 2>/dev/null || date -d @"$sentinel_mtime" 2>/dev/null)
   ($newer_by seconds older)

   Run \`make test-host-app\` locally and re-push. The release/* and
   hotfix/* lanes require a fresh host-app integration check — CI does
   not run host-app on these PR pushes anymore (it ran 2h asserting
   error-handling paths on hardware-absent runners).

   See scripts/check-host-app-tests-fresh.sh for details. To bypass in
   a true emergency, \`git push --no-verify\` (DISCOURAGED).
EOF
  exit 1
fi

echo "host-app gate: sentinel fresh ($(date -r "$sentinel_mtime" 2>/dev/null || date -d @"$sentinel_mtime" 2>/dev/null))"
