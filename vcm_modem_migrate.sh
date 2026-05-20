#!/usr/bin/env bash
set -uo pipefail

LOG() { echo "[vcm-modem-migrate $(date -Is)] $*"; }

LOG "=== Sixfab removal ==="

# Install QMI tooling while Sixfab ECM still provides internet
LOG "Installing QMI dependencies..."
apt-get update -qq
apt-get install -y --no-upgrade libqmi-utils udhcpc busybox

# Run Sixfab's own uninstaller while ECM internet is still up — it stops/removes services
LOG "Running Sixfab uninstaller..."
bash -c "$(curl -sN https://install.connect.sixfab.com)" -- --uninstall 2>/dev/null || true

# Belt-and-suspenders: mask any remaining services and delete directory
LOG "Cleaning up Sixfab remnants..."
for svc in core_agent.service core_manager.service; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl mask "$svc" 2>/dev/null || true
done
rm -rf /opt/sixfab 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

LOG "=== Sixfab removed — handing off to reconnect.sh for QMI setup ==="
