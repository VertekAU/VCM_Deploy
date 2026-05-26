#!/usr/bin/env bash
set -uo pipefail

LOG() { echo "[vcm-modem-migrate $(date -Is)] $*"; }

LOG "=== Sixfab removal ==="

# Mask Sixfab services BEFORE installing modemmanager — the agent removes MM
# when it detects it. Masking does not drop the ECM interface (kernel-managed
# USB gadget); internet connectivity is preserved for the installs below.
LOG "Masking Sixfab services to prevent ModemManager interference..."
for svc in core_agent.service core_manager.service; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl mask "$svc" 2>/dev/null || true
done
systemctl daemon-reload 2>/dev/null || true

# Install QMI tooling and ModemManager while Sixfab ECM still provides internet.
# MM must be installed here — after the QMI flip the modem reboots and there
# is no internet for apt-get until LTE is fully set up.
LOG "Installing QMI dependencies..."
apt-get update -qq
apt-get install -y --no-upgrade libqmi-utils udhcpc busybox modemmanager

# Run Sixfab's own uninstaller — services are already masked so it cannot
# restart them. ECM internet is still available for the download.
LOG "Running Sixfab uninstaller..."
bash -c "$(curl -sN https://install.connect.sixfab.com)" -- --uninstall 2>/dev/null || true

# Remove Sixfab directory (services already masked above, no need to re-mask)
LOG "Cleaning up Sixfab remnants..."
rm -rf /opt/sixfab 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

LOG "=== Sixfab removed — handing off to reconnect.sh for QMI setup ==="
