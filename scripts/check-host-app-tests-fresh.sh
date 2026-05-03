#!/usr/bin/env bash
# Pre-push gate: refuse to push a release/* or hotfix/* branch unless
# `make test-host-app` has been run since the most recent change to any
# tracked SOURCE file (not docs) that affects the host-app target.
#
# Why: v2.0.0 nearly shipped with project.yml still pinned to 1.3.2 —
# CI caught it AFTER the tag was pushed. We've moved the host-app
# integration check off every PR (it ran 2h to assert error-handling
# paths on hardware-absent runners), so the local version becomes the
# gate. This script enforces that the local run is FRESH.
#
# Sentinel: build/.host-app-test-fresh — written by `make test-host-app`
# on success. Contains the git HEAD sha at test time. Pre-push computes
# `git diff --name-only <sentinel-sha> HEAD` and fails only if changed
# files intersect the source set (Sources/, Tests/, project.yml,
# Package.swift, Package.resolved, Makefile). Doc-only changes pass.
#
# Why a sha and not mtimes? `git checkout` updates working-tree mtimes
# when switching branches even when file content is unchanged, so an
# mtime-based gate falses-positive on every branch switch. Sha + diff
# is content-truthful.
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
local_sha=""
while IFS=' ' read -r lref lsha rref rsha; do
  case "$rref" in
    refs/heads/release/*|refs/heads/hotfix/*)
      gate_required=1
      local_sha="$lsha"
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

   To bypass in a true emergency, \`git push --no-verify\` (project
   policy DISCOURAGES this — fix the underlying issue instead).
EOF
  exit 1
fi

sentinel_sha=$(cat "$SENTINEL" | tr -d '[:space:]')
if [[ -z "$sentinel_sha" ]]; then
  echo "✗ pre-push gate: $SENTINEL is empty (corrupt). Run \`make test-host-app\` and re-push." >&2
  exit 1
fi
if ! git rev-parse --verify "$sentinel_sha^{commit}" >/dev/null 2>&1; then
  echo "✗ pre-push gate: sentinel sha $sentinel_sha is not a known commit. Run \`make test-host-app\` and re-push." >&2
  exit 1
fi

# Use the local sha being pushed (HEAD of the ref about to land remotely)
# rather than HEAD of the working tree — they're usually the same but
# `git push <branch>:<remote-branch>` style invocations can differ.
target_sha="${local_sha:-HEAD}"

# Source set: anything that affects the host-app build or test surface.
# Docs / READMEs / CHANGELOG / .github/workflows changes do NOT require
# a re-run — they cannot affect host-app behaviour.
source_paths=(Sources Tests project.yml Package.swift Package.resolved Makefile)

# Files changed in source set between sentinel and target.
changed=$(git diff --name-only "$sentinel_sha" "$target_sha" -- "${source_paths[@]}" 2>/dev/null || true)

# Also include uncommitted source-set changes — devs sometimes push
# with a dirty working tree via `git push origin HEAD:branch`.
dirty=$(git diff --name-only "$target_sha" -- "${source_paths[@]}" 2>/dev/null || true)
dirty_staged=$(git diff --name-only --cached "$target_sha" -- "${source_paths[@]}" 2>/dev/null || true)

all_changed=$(printf "%s\n%s\n%s" "$changed" "$dirty" "$dirty_staged" | sed '/^$/d' | sort -u)

if [[ -n "$all_changed" ]]; then
  count=$(echo "$all_changed" | wc -l | tr -d ' ')
  cat >&2 <<EOF
✗ pre-push gate: $count source-set file(s) have changed since the last
   \`make test-host-app\` run (sentinel sha $sentinel_sha):

$(echo "$all_changed" | sed 's/^/   /')

   Run \`make test-host-app\` locally and re-push. The release/* and
   hotfix/* lanes require a fresh host-app integration check — CI does
   not run host-app on these branches anymore.

   To bypass in a true emergency, \`git push --no-verify\` (DISCOURAGED).
EOF
  exit 1
fi

echo "host-app gate: sentinel fresh (sha $sentinel_sha, no source-set drift)"
