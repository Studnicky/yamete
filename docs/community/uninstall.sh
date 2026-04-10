#!/bin/bash
#
# uninstall.sh — remove the yamete-accel-warmup LaunchDaemon

set -euo pipefail

BINARY_DEST="/usr/local/libexec/yamete-accel-warmup"
PLIST_DEST="/Library/LaunchDaemons/com.studnicky.yamete.accel-warmup.plist"
LABEL="com.studnicky.yamete.accel-warmup"
LOG_PATH="/var/log/yamete-accel-warmup.log"

if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
    echo "==> Unloading LaunchDaemon"
    sudo launchctl bootout "system/${LABEL}"
else
    echo "==> LaunchDaemon not loaded (nothing to unload)"
fi

if [[ -f "${PLIST_DEST}" ]]; then
    echo "==> Removing ${PLIST_DEST}"
    sudo rm "${PLIST_DEST}"
fi

if [[ -f "${BINARY_DEST}" ]]; then
    echo "==> Removing ${BINARY_DEST}"
    sudo rm "${BINARY_DEST}"
fi

if [[ -f "${LOG_PATH}" ]]; then
    echo "==> Removing ${LOG_PATH}"
    sudo rm "${LOG_PATH}"
fi

echo ""
echo "Uninstalled. The accelerometer will go cold on next reboot."
echo "Yamete's App Store build will continue running on microphone +"
echo "headphone-motion as it did before the helper was installed."
