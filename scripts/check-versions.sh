#!/usr/bin/env bash
# Verifies that every version-bearing surface in the repo agrees with the
# canonical version declared by project.yml's MARKETING_VERSION.
#
# Why: release 2.0.0 shipped with project.yml still pinned to 1.3.2. The
# release.yml workflow caught it via the "Verify tag version matches
# project.yml" step, but only AFTER the tag was already pushed. This
# script runs at PR time so the discrepancy is caught before merge.
#
# Canonical source: project.yml MARKETING_VERSION
# Derived surfaces (asserted to match):
#   - docs/INSTALLATION.md   line "- Latest release: X.Y.Z"
#   - docs/assets/sidebar.js line macOS 14+ . vX.Y.Z inside <span class="badge">
#
# Surfaces deliberately NOT asserted:
#   - CHANGELOG.md headings -- historical entries reference past versions,
#     which is correct. The [Unreleased] block is the staging area for
#     the next bump and only renames to [X.Y.Z] - YYYY-MM-DD at release
#     prep time. A separate assertion at release-PR time could verify
#     CHANGELOG has a heading matching MARKETING_VERSION, but during
#     ordinary feature work the CHANGELOG and project.yml legitimately
#     diverge.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CANONICAL="$(awk -F'"' '/^[[:space:]]*MARKETING_VERSION:/{print $2; exit}' project.yml)"
if [[ -z "$CANONICAL" ]]; then
  echo "::error::could not parse MARKETING_VERSION from project.yml" >&2
  exit 2
fi

fail=0
report() {
  echo "::error file=$1::version mismatch -- found '$2', expected '$CANONICAL' (from project.yml MARKETING_VERSION)" >&2
  fail=1
}

inst="$(awk -F': ' '/^- Latest release:/{print $2; exit}' docs/INSTALLATION.md)"
if [[ "$inst" != "$CANONICAL" ]]; then
  report "docs/INSTALLATION.md" "$inst"
fi

sidebar="$(grep -oE 'macOS 14\+ . v[0-9]+\.[0-9]+\.[0-9]+' docs/assets/sidebar.js | head -1 | sed 's/.* v//')"
if [[ "$sidebar" != "$CANONICAL" ]]; then
  report "docs/assets/sidebar.js" "$sidebar"
fi

if [[ $fail -ne 0 ]]; then
  echo "" >&2
  echo "Update the mismatched surfaces to match project.yml MARKETING_VERSION ($CANONICAL)," >&2
  echo "or update project.yml if the bump was intentional." >&2
  exit 1
fi

echo "version consistency: all surfaces match $CANONICAL"
