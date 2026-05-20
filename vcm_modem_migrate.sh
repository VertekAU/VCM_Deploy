#!/usr/bin/env bash
set -uo pipefail

LOG() { echo "[vcm-modem-migrate $(date -Is)] $*"; }

LOG "=== Sixfab removal ==="

# Install QMI tooling while Sixfab ECM still provides internet
LOG "Installing QMI dependencies..."
apt-get update -qq
apt-get install -y --no-upgrade libqmi-utils udhcpc busybox

# Stop and mask Sixfab services
LOG "Stopping Sixfab services..."
for svc in core_agent.service core_manager.service; do
    systemctl stop    "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    systemctl mask    "$svc" 2>/dev/null || true
done

# Remove Sixfab — absence of /opt/sixfab prevents re-trigger on next boot
LOG "Removing Sixfab..."
rm -rf /opt/sixfab 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

LOG "=== Sixfab removed — handing off to reconnect.sh for QMI setup ==="
