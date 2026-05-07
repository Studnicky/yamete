#!/usr/bin/env bash
# Pre-push companion to scripts/check-host-app-tests-fresh.sh.
#
# Refreshes the host-app test target's snapshot baselines so a push
# never carries a stale comparison reference into CI.
#
# The host-app sandbox mirror lives at
# `~/Library/Containers/com.studnicky.yamete/Data/tmp/yamete-snapshots/HostApp/SnapshotUI_Tests/`
# and is the only path the SnapshotTesting library can read or write
# from inside the App Sandbox. `SnapshotUI_Tests.snapshotDirectory`
# seeds it from `Tests/__Snapshots__/HostApp/SnapshotUI_Tests/` on
# first call; entries that exist only in the mirror linger across
# runs and serve as references the next time SwiftUI emits subtly
# different pixels — manifesting as "Snapshot does not match
# reference" even on a clean source tree.
#
# Flow (dual-run pattern):
#
#   1. Wipe the sandbox mirror's HostApp PNGs so the next test run
#      reseeds entirely from source.
#   2. Run `make test-host-app` once — the recording iteration. Under
#      `recordMode=.missing`, the SnapshotTesting library records any
#      missing baselines and reports each recording as a test failure
#      with a "no reference was found" message. Tolerate a non-zero
#      exit here; the recordings end up in the mirror regardless.
#   3. Copy mirror PNGs back to source tree at
#      Tests/__Snapshots__/HostApp/SnapshotUI_Tests/.
#   4. Run `make test-host-app` again — the verification iteration.
#      Source tree now matches what the mirror holds, so every
#      baseline compares equal and the run exits clean (refreshing
#      the freshness sentinel as a side effect).
#   5. Refuse the push if step 3 moved the source tree — the
#      developer must commit recorded baselines explicitly.
#
# Self-skips when:
#   - Running on CI (`CI=true`). CI seeds via the
#     `.github/workflows/snapshot-baseline-seed.yml` workflow.
#   - The push target is not `release/*` or `hotfix/*`. Feature
#     branches push without this gate; the slow record-and-sync flow
#     is reserved for the release path.

set -euo pipefail

if [[ "${CI:-}" == "true" ]]; then
  exit 0
fi

# Read the same git-pre-push stdin shape the freshness gate consumes.
gate_required=0
while IFS=' ' read -r lref lsha rref rsha; do
  case "$rref" in
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

# The host-app test target builds the App Store-flavoured `Yamete.app`
# and runs inside its sandbox; the mirror lives under that container's
# tmp directory regardless of which Direct identifier the rest of the
# project uses. Path stays bound to com.studnicky.yamete.
BUNDLE_ID="com.studnicky.yamete"
MIRROR_ROOT="$HOME/Library/Containers/$BUNDLE_ID/Data/tmp/yamete-snapshots/HostApp/SnapshotUI_Tests"
SOURCE_DIR="Tests/__Snapshots__/HostApp/SnapshotUI_Tests"

if [[ ! -d "$SOURCE_DIR" ]]; then
  # Source-tree dir hasn't been created yet — nothing to refresh
  # against. The freshness gate will catch this if it matters.
  exit 0
fi

printf "  refresh   host-app snapshot mirror (%s)\n" "$MIRROR_ROOT"

# Step 1 — wipe stale mirror entries. The mirror only lives inside
# the sandbox container, so this is local-only state — no remote
# implications. `rm -rf` against a non-existent path is fine.
rm -rf "$MIRROR_ROOT"

# Step 2 — recording iteration. With the mirror cleared, the
# SnapshotTesting library re-records every baseline under
# recordMode=.missing semantics. Each recording surfaces as a test
# failure ("no reference was found"); the test target exits non-zero
# even though the recordings land in the mirror successfully. This
# is by library design — tolerate the exit and move on.
printf "  record    initial baseline pass (recordings surface as failures by design)\n"
make test-host-app >/dev/null 2>&1 || true

# Step 3 — sync mirror PNGs back to the source tree. Only PNGs;
# don't trample sentinels or other files that may live alongside.
synced=0
if [[ -d "$MIRROR_ROOT" ]]; then
  shopt -s nullglob
  for src in "$MIRROR_ROOT"/*.png; do
    base=$(basename "$src")
    dst="$SOURCE_DIR/$base"
    if [[ ! -f "$dst" ]] || ! cmp -s "$src" "$dst"; then
      cp "$src" "$dst"
      synced=$((synced + 1))
    fi
  done
  shopt -u nullglob
fi

# Step 4 — verification iteration. Source tree now matches the mirror
# so every cell compares equal and the test target exits clean. This
# also refreshes build/.host-app-test-fresh, so the freshness gate
# that runs after this script sees a current sentinel.
printf "  verify    second pass (source tree now matches recorded mirror)\n"
if ! make test-host-app; then
  cat >&2 <<EOF
✗ refresh-host-app-snapshots: \`make test-host-app\` failed on the
   verification pass — a real test failure (not a snapshot recording)
   stopped the run. Inspect the output above and fix the underlying
   failure before re-pushing.

   To bypass in a true emergency, \`git push --no-verify\` (DISCOURAGED).
EOF
  exit 1
fi

# Step 5 — refuse the push if source-tree baselines moved. The
# developer must commit them so the next checkout (and CI) compares
# against the same baselines this run recorded.
changed_paths=$(git status --porcelain -- "$SOURCE_DIR" | sed '/^$/d')
if [[ -n "$changed_paths" ]]; then
  count=$(echo "$changed_paths" | wc -l | tr -d ' ')
  cat >&2 <<EOF
✗ refresh-host-app-snapshots: $count host-app snapshot baseline(s)
   re-recorded during pre-push:

$(echo "$changed_paths" | sed 's/^/   /')

   Stage and commit these baselines, then re-push:

     git add $SOURCE_DIR
     git commit -m "chore: re-record host-app snapshot baselines"
     git push

   The mirror seeds fresh from source tree before the test runs,
   so these recordings are authoritative. Do NOT bypass — without
   the commit, CI and future developers compare against stale or
   missing baselines.
EOF
  exit 1
fi

if [[ $synced -gt 0 ]]; then
  printf "  sync      %d baseline(s) refreshed (no source-tree drift)\n" "$synced"
else
  printf "  sync      host-app baselines already current\n"
fi
