#!/usr/bin/env bash
# VCM_Deploy installer
# Usage: curl -sS https://raw.githubusercontent.com/VertekAU/VCM_Deploy/main/install.sh | sudo bash
set -euo pipefail

LOG() { echo "[vcm-deploy install $(date -Is)] $*"; }

[[ "$EUID" -ne 0 ]] && { echo "Run as root: sudo bash"; exit 1; }

REPO="https://github.com/VertekAU/VCM_Deploy.git"
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
    LOG "Updating existing VCM_Deploy at $INSTALL_DIR"
    git -C "$INSTALL_DIR" pull --ff-only
else
    LOG "Cloning VCM_Deploy to $INSTALL_DIR"
    git clone "$REPO" "$INSTALL_DIR"
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

systemctl daemon-reload
systemctl enable vcm-modem-reconnect.service vcm-deploy.service

LOG "Installation complete. Starting provisioning chain..."
LOG "(Modem setup may take several minutes if Sixfab removal is required)"
systemctl start vcm-modem-reconnect.service
LOG "Modem setup complete. Starting device provisioning in background..."
systemctl start --no-block vcm-deploy.service
LOG "Follow progress: journalctl -u vcm-deploy -u vcm-update -f"
