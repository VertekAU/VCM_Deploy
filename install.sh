#!/usr/bin/env bash
# VCM_Deploy installer
# Production: curl -sS https://raw.githubusercontent.com/VertekAU/VCM_Deploy/main/install.sh | sudo bash
# Dev branch: curl -sS https://raw.githubusercontent.com/VertekAU/VCM_Deploy/dev/install.sh | sudo VCM_BRANCH=dev bash
set -euo pipefail

LOG() { echo "[vcm-deploy install $(date -Is)] $*"; }

[[ "$EUID" -ne 0 ]] && { echo "Run as root: sudo bash"; exit 1; }

REPO="https://github.com/VertekAU/VCM_Deploy.git"
INSTALL_DIR="/home/pi/vcm_deploy"
# If repo already exists, default to its current branch so re-runs stay on the same branch.
# VCM_BRANCH overrides everything; fresh clone defaults to main.
BRANCH="${VCM_BRANCH:-$(git -C "$INSTALL_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)}"
SBIN="/usr/local/sbin"
SYSTEMD="/etc/systemd/system"

# Create required directories
mkdir -p /etc/vertek /var/lib/vcm
chmod 755 /etc/vertek

# Mask Sixfab services before installing modemmanager — the Sixfab agent
# removes MM when it detects it. Mask only (do NOT stop) — stopping the agent
# drops the ECM routing and kills any SSH session running this script.
# The kernel USB gadget stays up; the agent keeps running until vcm_modem_migrate.sh
# stops it safely from within a systemd service (detached from this terminal).
if systemctl cat core_agent.service &>/dev/null; then
    LOG "Sixfab detected — masking services before MM install..."
    systemctl mask  core_agent.service core_manager.service 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
fi

# Install QMI dependencies — needs internet at setup time; pre-installed in OS image
# DEBIAN_FRONTEND=noninteractive prevents dpkg from prompting for config file conflicts.
# --force-confold keeps existing config files (e.g. dhcpcd.conf) without asking.
LOG "Installing QMI dependencies..."
# Sixfab agent may still be running its own apt-get — wait for the lock
for _apt_wait in $(seq 1 24); do
    flock -n /var/lib/apt/lists/lock true 2>/dev/null && break
    LOG "Waiting for apt lock (attempt $_apt_wait/24)..."
    sleep 5
done
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-upgrade \
    -o Dpkg::Options::="--force-confold" \
    git libqmi-utils udhcpc busybox modemmanager

# Clone or update VCM_Deploy repo
if [[ -d "$INSTALL_DIR/.git" ]]; then
    LOG "Updating existing VCM_Deploy at $INSTALL_DIR (branch: $BRANCH)"
    git -C "$INSTALL_DIR" fetch origin
    git -C "$INSTALL_DIR" checkout "$BRANCH"
    git -C "$INSTALL_DIR" pull --ff-only
else
    LOG "Cloning VCM_Deploy to $INSTALL_DIR (branch: $BRANCH)"
    git clone -b "$BRANCH" "$REPO" "$INSTALL_DIR"
fi
chown -R pi:pi "$INSTALL_DIR"

# Install scripts to /usr/local/sbin
LOG "Installing scripts..."
install -m 0755 -o root -g root "$INSTALL_DIR/vcm_modem_migrate.sh"   "$SBIN/vcm_modem_migrate.sh"
install -m 0755 -o root -g root "$INSTALL_DIR/vcm_modem_reconnect.sh" "$SBIN/vcm_modem_reconnect.sh"
install -m 0755 -o root -g root "$INSTALL_DIR/vcm_deploy.sh"          "$SBIN/vcm_deploy.sh"

# Install systemd units
LOG "Installing systemd units..."
install -m 0644 -o root -g root "$INSTALL_DIR/vcm-modem-reconnect.service" "$SYSTEMD/vcm-modem-reconnect.service"
install -m 0644 -o root -g root "$INSTALL_DIR/vcm-deploy.service"          "$SYSTEMD/vcm-deploy.service"
install -m 0644 -o root -g root "$INSTALL_DIR/vcm-failure-reboot.service"  "$SYSTEMD/vcm-failure-reboot.service"

systemctl daemon-reload
systemctl enable vcm-modem-reconnect.service vcm-deploy.service

LOG "Installation complete. Starting provisioning chain..."
# Start both services together — systemd honours After= ordering between them
# (modem-reconnect runs first, deploy starts when it finishes). Both run as
# systemd services so they survive terminal death (e.g. Sixfab agent killed
# during Sixfab removal).
systemctl start --no-block vcm-modem-reconnect.service vcm-deploy.service
LOG "Provisioning running. Following logs (Ctrl+C to detach — services continue)..."
# exec replaces this shell with journalctl — Ctrl+C exits the log tail only,
# services keep running as they are systemd-managed.
exec journalctl -f -u vcm-modem-reconnect.service -u vcm-deploy.service -u vcm-update.service
