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

# Stash source-tree baselines to a temp dir so a real test failure
# during the recording iteration doesn't leave the working tree with
# zero baselines. Restored on any error path that exits non-zero.
STASH_DIR="$(mktemp -d -t yamete-host-app-snapshots-stash)"
restore_stash() {
  if [[ -d "$STASH_DIR" ]]; then
    rsync -a --delete "$STASH_DIR/" "$SOURCE_DIR/" 2>/dev/null || true
    rm -rf "$STASH_DIR"
  fi
}
trap 'restore_stash' EXIT
rsync -a "$SOURCE_DIR/" "$STASH_DIR/"

# Step 1 — wipe both the sandbox mirror and the source-tree
# baselines. The seed step in `SnapshotUI_Tests.snapshotDirectory`
# copies source-tree PNGs into the mirror on first call; if the
# source-tree PNG is stale (rendered pixels have moved on since the
# last record), the mirror inherits the staleness and the
# `recordMode=.missing` library skips re-recording on a file that
# already exists. Wiping both forces every cell into the
# "no reference, record fresh" branch.
rm -rf "$MIRROR_ROOT"
find "$SOURCE_DIR" -maxdepth 1 -name '*.png' -delete 2>/dev/null

# Step 2 — recording iteration. With both source tree and mirror
# wiped, every cell records under `recordMode=.missing` semantics.
# Each recording surfaces as a test failure ("recorded snapshot")
# so the test target exits non-zero — tolerate it.
printf "  record    initial baseline pass (recordings surface as failures by design)\n"
make test-host-app >/dev/null 2>&1 || true

# Step 3 — sync mirror PNGs back to the source tree. Source tree
# was wiped before recording, so this populates the entire HostApp
# baseline set from what the test just rendered.
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

# Step 3a — bail with stash restore if recording produced nothing.
# A real test crash (build failure, signal-11) would leave both
# source tree and mirror empty; restoring from stash lets the
# developer iterate without losing the prior baselines.
if [[ $synced -eq 0 ]]; then
  cat >&2 <<EOF
✗ refresh-host-app-snapshots: recording iteration produced no
   baselines. Either the test target failed to build, or every
   cell crashed before reaching its assertImageSnapshot call.
   Restoring the prior baselines from stash. Inspect the
   xcodebuild output above and fix the underlying failure.

   To bypass in a true emergency, \`git push --no-verify\` (DISCOURAGED).
EOF
  exit 1
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

# Step 5a — restore the stashed bytes for any baseline that already
# existed before the script ran. SnapshotTesting renders pixels
# with sub-pixel hinting drift between runs; two consecutive
# recordings of the same view differ at the byte level even when
# the verification iteration considers them equal under the
# `precision: 0.99, perceptualPrecision: 0.98` tolerance. Restoring
# the stashed (committed) bytes for existing baselines means the
# script doesn't churn git history with noise, while the precision
# threshold continues to absorb the drift on every subsequent run.
shopt -s nullglob
for stashed in "$STASH_DIR"/*.png; do
  base=$(basename "$stashed")
  cp "$stashed" "$SOURCE_DIR/$base"
done
shopt -u nullglob

# Step 5b — refuse the push only when truly NEW baselines landed
# (untracked files in git). Existing baselines whose bytes drifted
# under noise were already restored above; only genuine
# never-before-committed cells need a developer commit.
new_paths=$(git status --porcelain -- "$SOURCE_DIR" | grep '^?? ' | sed '/^$/d' || true)
if [[ -n "$new_paths" ]]; then
  count=$(echo "$new_paths" | wc -l | tr -d ' ')
  cat >&2 <<EOF
✗ refresh-host-app-snapshots: $count NEW host-app snapshot baseline(s)
   recorded during pre-push:

$(echo "$new_paths" | sed 's/^/   /')

   Stage and commit these baselines, then re-push:

     git add $SOURCE_DIR
     git commit -m "chore: record new host-app snapshot baselines"
     git push

   These cells had no committed baseline before this run. The
   pre-push hook records authoritative bytes; the developer
   commits them so CI compares against the same reference.
EOF
  exit 1
fi

# Clear the stash trap on the success path so the freshly-restored
# baselines aren't reverted on normal exit. Stash dir cleanup runs
# explicitly here.
trap - EXIT
rm -rf "$STASH_DIR"

if [[ $synced -gt 0 ]]; then
  printf "  sync      %d baseline(s) refreshed (no source-tree drift)\n" "$synced"
else
  printf "  sync      host-app baselines already current\n"
fi
