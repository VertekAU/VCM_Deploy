#!/usr/bin/env bash
set -euo pipefail

LOG() { echo "[vcm-modem-migrate $(date -Is)] $*"; }
FAIL() { LOG "FATAL: $*"; exit 1; }

MARKER="/var/lib/vcm/migration_qmi_done"
mkdir -p /var/lib/vcm

[[ -f "$MARKER" ]] && { LOG "Already migrated ($(cat "$MARKER"))"; exit 0; }

LOG "=== Starting Sixfab ECM to QMI migration ==="

# Install QMI tooling — atcom and libqmi need internet (Sixfab ECM provides it at this point)
LOG "Installing QMI dependencies..."
apt-get update -qq
apt-get install -y --no-upgrade libqmi-utils udhcpc busybox
pip3 install atcom --break-system-packages -q

# Mask Sixfab services immediately — we're headless so no shell-persistence concerns
LOG "Masking Sixfab services..."
for svc in core_agent.service core_manager.service; do
    systemctl stop    "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    systemctl mask    "$svc" 2>/dev/null || true
done
sleep 2

# Detect current modem mode via AT+QCFG
LOG "Detecting modem USB mode..."
MODE=""
for p in /dev/ttyUSB2 /dev/ttyUSB3 /dev/ttyUSB1 /dev/ttyUSB0; do
    [[ -e "$p" ]] || continue
    R="$(atcom -p "$p" -t 3 'AT+QCFG="usbnet"' 2>/dev/null || true)"
    echo "$R" | grep -q '"usbnet",0' && MODE="qmi" && break
    echo "$R" | grep -q '"usbnet"'   && MODE="ecm" && break
done
LOG "Detected modem mode: ${MODE:-unknown}"

if [[ "${MODE:-}" != "qmi" ]]; then
    LOG "Flipping modem to QMI mode..."
    systemctl restart systemd-resolved 2>/dev/null || true
    for p in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2 /dev/ttyUSB3; do
        [[ -e "$p" ]] && atcom -p "$p" -t 3 'AT+QCFG="usbnet",0' 2>/dev/null || true
    done
    sleep 2
    for p in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2 /dev/ttyUSB3; do
        [[ -e "$p" ]] && atcom -p "$p" -t 3 'AT+CFUN=1,1' 2>/dev/null || true
    done
    systemctl restart systemd-resolved 2>/dev/null || true

    LOG "Waiting for /dev/cdc-wdm0 (up to 3 min)..."
    for i in $(seq 1 60); do
        [[ -e /dev/cdc-wdm0 ]] && break
        [[ "$i" -eq 60 ]] && FAIL "/dev/cdc-wdm0 not found after 3 minutes"
        sleep 3
    done
fi

[[ -e /dev/cdc-wdm0 ]] || FAIL "cdc-wdm0 not found after mode detection"

LOG "Waiting for modem hardware ready..."
for i in $(seq 1 30); do
    qmicli -d /dev/cdc-wdm0 --dms-get-operating-mode &>/dev/null && break
    [[ "$i" -eq 30 ]] && FAIL "Modem not ready after 60s"
    sleep 2
done

LOG "Waiting for LTE network registration..."
for i in $(seq 1 30); do
    qmicli -d /dev/cdc-wdm0 --nas-get-signal-strength 2>/dev/null | grep -q "Network 'lte'" && break
    [[ "$i" -eq 30 ]] && FAIL "No LTE registration after 60s"
    sleep 2
done
sleep 3

LOG "Setting up QMI bearer..."
ip link set wwan0 down
echo 'Y' | tee /sys/class/net/wwan0/qmi/raw_ip >/dev/null
ip link set wwan0 up
qmicli -d /dev/cdc-wdm0 --wda-get-data-format
qmicli -p -d /dev/cdc-wdm0 \
    --device-open-net='net-raw-ip|net-no-qos-header' \
    --wds-start-network="apn='super',ip-type=4" \
    --client-no-release-cid
udhcpc -q -f -i wwan0

WAN_GW="$(ip route show default dev wwan0 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')"
if [[ -n "${WAN_GW:-}" ]]; then
    ip route del default dev wwan0 2>/dev/null || true
    ip route add default via "$WAN_GW" dev wwan0 metric 700
    LOG "wwan0 default route set via $WAN_GW metric 700"
fi

ping -c 3 -W 5 8.8.8.8 >/dev/null 2>&1 || FAIL "LTE ping verification failed after bearer setup"
LOG "LTE verified"

date -Is > "$MARKER"
LOG "Migration marker written. Uninstalling Sixfab..."

bash -c "$(curl -sN https://install.connect.sixfab.com)" -- --uninstall 2>/dev/null || true
rm -rf /opt/sixfab 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

LOG "=== Migration complete $(date -Is) ==="
