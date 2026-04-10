#!/bin/bash
#
# install.sh — build + install the yamete-accel-warmup LaunchDaemon
#
# Requires sudo (for /Library/LaunchDaemons and /usr/local/libexec).
# Run from the gist directory containing all four files.
#
# Source of truth: https://github.com/Studnicky/yamete/blob/develop/docs/community/
# Report problems:  https://github.com/Studnicky/yamete/issues/new

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SOURCE="${HERE}/yamete-accel-warmup.swift"
PLIST="${HERE}/com.studnicky.yamete.accel-warmup.plist"
BINARY_DEST="/usr/local/libexec/yamete-accel-warmup"
PLIST_DEST="/Library/LaunchDaemons/com.studnicky.yamete.accel-warmup.plist"
LABEL="com.studnicky.yamete.accel-warmup"

if [[ ! -f "${SOURCE}" ]]; then
    echo "error: ${SOURCE} not found — run this from the gist directory" >&2
    exit 1
fi
if [[ ! -f "${PLIST}" ]]; then
    echo "error: ${PLIST} not found — run this from the gist directory" >&2
    exit 1
fi

ARCH="$(uname -m)"
if [[ "${ARCH}" != "arm64" ]]; then
    echo "error: this helper is only useful on Apple Silicon Macs (detected: ${ARCH})" >&2
    exit 1
fi

# Build unsandboxed — no entitlements, no code-sign dance. The default
# ad-hoc signature the linker applies is sufficient for a LaunchDaemon
# that runs as root.
echo "==> Compiling yamete-accel-warmup"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "${BUILD_DIR}"' EXIT
swiftc "${SOURCE}" -o "${BUILD_DIR}/yamete-accel-warmup" \
       -framework IOKit -framework Foundation \
       -O

# Smoke-test the binary before installing. A probe on a cold sensor
# should exit with code 1, on a warm sensor with code 0, on non-SPU
# hardware with code 2. Any of 0/1/2 means the binary runs.
echo "==> Smoke-testing the binary"
set +e
"${BUILD_DIR}/yamete-accel-warmup" probe
SMOKE_EXIT=$?
set -e
if [[ ${SMOKE_EXIT} -ne 0 && ${SMOKE_EXIT} -ne 1 && ${SMOKE_EXIT} -ne 2 ]]; then
    echo "error: smoke test failed with unexpected exit ${SMOKE_EXIT}" >&2
    exit 1
fi

# Unload any previous instance before replacing files (so the old
# binary isn't held open by launchd).
if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
    echo "==> Unloading existing LaunchDaemon"
    sudo launchctl bootout "system/${LABEL}" 2>/dev/null || true
fi

echo "==> Installing binary to ${BINARY_DEST}"
sudo mkdir -p "$(dirname "${BINARY_DEST}")"
sudo cp "${BUILD_DIR}/yamete-accel-warmup" "${BINARY_DEST}"
sudo chown root:wheel "${BINARY_DEST}"
sudo chmod 755 "${BINARY_DEST}"

echo "==> Installing plist to ${PLIST_DEST}"
sudo cp "${PLIST}" "${PLIST_DEST}"
sudo chown root:wheel "${PLIST_DEST}"
sudo chmod 644 "${PLIST_DEST}"

echo "==> Loading LaunchDaemon (triggers RunAtLoad — sensor warms now)"
sudo launchctl bootstrap system "${PLIST_DEST}"

# Give launchd a moment to run the helper once.
sleep 1

echo "==> Verifying with probe"
if "${BINARY_DEST}" probe; then
    echo ""
    echo "Success — accelerometer is streaming. Launch or relaunch Yamete"
    echo "to pick up the warm sensor. Open the menu bar dropdown, expand"
    echo "the Sensors section, and toggle Accelerometer on."
else
    echo ""
    echo "The probe did not report an active sensor. Check the log at" >&2
    echo "  /var/log/yamete-accel-warmup.log" >&2
    echo "and the LaunchDaemon state with:" >&2
    echo "  sudo launchctl print system/${LABEL}" >&2
    echo "" >&2
    echo "If the issue persists, please file a report (see the README" >&2
    echo "for the exact diagnostics to include) at:" >&2
    echo "  https://github.com/Studnicky/yamete/issues/new" >&2
    exit 1
fi
