#!/usr/bin/env bash
# VCM_Deploy installer
# Production: curl -sS https://raw.githubusercontent.com/VertekAU/VCM_Deploy/main/install.sh | sudo bash
# Dev branch: curl -sS https://raw.githubusercontent.com/VertekAU/VCM_Deploy/dev/install.sh | sudo VCM_BRANCH=dev bash
set -euo pipefail

LOG() { echo "[vcm-deploy install $(date -Is)] $*"; }

[[ "$EUID" -ne 0 ]] && { echo "Run as root: sudo bash"; exit 1; }

REPO="https://github.com/VertekAU/VCM_Deploy.git"
BRANCH="${VCM_BRANCH:-main}"
INSTALL_DIR="/home/pi/vcm_deploy"
SBIN="/usr/local/sbin"
SYSTEMD="/etc/systemd/system"

# Create required directories
mkdir -p /etc/vertek /var/lib/vcm
chmod 755 /etc/vertek

# Install QMI dependencies — needs internet at setup time; pre-installed in OS image
# DEBIAN_FRONTEND=noninteractive prevents dpkg from prompting for config file conflicts.
# --force-confold keeps existing config files (e.g. dhcpcd.conf) without asking.
LOG "Installing QMI dependencies..."
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-upgrade \
    -o Dpkg::Options::="--force-confold" \
    git libqmi-utils udhcpc busybox

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
