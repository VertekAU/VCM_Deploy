#!/usr/bin/env bash
set -uo pipefail
# Opening a ttyUSB device as session leader (no controlling terminal) makes it
# the controlling terminal — HUP arrives if the modem resets. Ignore it here;
# child sessions opened via setsid handle their own terminal lifecycle.
trap '' HUP

LOG() { echo "[vcm-modem-reconnect $(date -Is)] $*"; }

UDEV_RULE="/etc/udev/rules.d/77-mm-quectel-ec25-qmi.rules"
NM_CONN_NAME="vertek-lte"
LTE_APN="super"

# --- Path 1: Sixfab migration (fleet devices with Sixfab agent still present) ---
if [[ -d /opt/sixfab ]]; then
    LOG "Sixfab detected, migration not done — running migration"
    if [[ ! -x /usr/local/sbin/vcm_modem_migrate.sh ]]; then
        LOG "ERROR: vcm_modem_migrate.sh not found — cannot migrate"
        exit 1
    fi
    /usr/local/sbin/vcm_modem_migrate.sh || { LOG "Migration failed"; exit 1; }
fi

# --- Path 2: ECM→QMI flip (fresh device, Quectel modem in ECM, no cdc-wdm0 yet) ---
if lsusb 2>/dev/null | grep -q "2c7c" && [[ ! -e /dev/cdc-wdm0 ]]; then
    LOG "Quectel modem detected in ECM mode (no cdc-wdm0) — flipping to QMI..."

    # Release ttyUSB ports from ModemManager if active
    if systemctl is-active --quiet ModemManager 2>/dev/null; then
        LOG "Stopping ModemManager to release ttyUSB ports..."
        systemctl stop ModemManager 2>/dev/null || true
        sleep 1
    fi

    # Send AT+QCFG="usbnet",0 then AT+CFUN=1,1 (modem self-reboots to apply).
    # Run in setsid so the ttyUSB becomes the controlling terminal of the child
    # session, not this script — when the modem resets and the device hangs up,
    # SIGHUP goes to the child, not here.
    FLIPPED=0
    for port in ttyUSB2 ttyUSB3 ttyUSB1 ttyUSB0; do
        [[ -e "/dev/$port" ]] || continue
        setsid bash -c "
            exec 3<>/dev/$port 2>/dev/null || exit 1
            printf 'AT+QCFG=\"usbnet\",0\r' >&3
            sleep 2
            printf 'AT+CFUN=1,1\r' >&3
            sleep 1
        " 2>/dev/null && FLIPPED=1 && LOG "QMI flip commands sent via /dev/$port — modem rebooting" && break || true
    done

    if [[ "$FLIPPED" -eq 0 ]]; then
        LOG "No ttyUSB port responded — cannot flip modem mode; wlan0 sufficient"
        exit 0
    fi

    LOG "Waiting for /dev/cdc-wdm0 after modem reboot (up to 3 min)..."
    for i in $(seq 1 60); do
        [[ -e /dev/cdc-wdm0 ]] && { LOG "cdc-wdm0 appeared"; break; }
        [[ "$i" -eq 60 ]] && { LOG "cdc-wdm0 not found after 3 minutes — wlan0 sufficient"; exit 0; }
        sleep 3
    done
fi

# --- Wait for QMI device node (up to 30s) ---
for i in $(seq 1 30); do
    [[ -e /dev/cdc-wdm0 ]] && break
    [[ "$i" -eq 30 ]] && { LOG "cdc-wdm0 not found after 30s — wwan0 unavailable, wlan0 sufficient"; exit 0; }
    sleep 1
done

# --- Wait for wwan0 interface (up to 30s) ---
for i in $(seq 1 30); do
    ip link show wwan0 &>/dev/null && break
    [[ "$i" -eq 30 ]] && { LOG "wwan0 not found after 30s — skipping LTE setup"; exit 0; }
    sleep 1
done

# --- Clean up legacy qmicli/dhcpcd artefacts from v1 ---
# dhcpcd wwan0 config is replaced by NM+MM; remove so they don't conflict.
# Old script appended both lines on every boot without an idempotency check,
# so there may be many duplicate entries — delete all occurrences.
if grep -qE "allowinterfaces wwan|nohook resolv.conf" /etc/dhcpcd.conf 2>/dev/null; then
    LOG "Removing legacy dhcpcd wwan0 config (allowinterfaces wwan* / nohook resolv.conf)..."
    sed -i '/allowinterfaces wwan/d; /nohook resolv\.conf/d' /etc/dhcpcd.conf
fi
# WDS state file is no longer used — remove if present.
rm -f /var/lib/vcm/wds-state

# --- Ensure ModemManager is installed ---
if ! command -v mmcli &>/dev/null; then
    LOG "ModemManager not installed — installing..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y modemmanager 2>/dev/null \
        || { LOG "ModemManager install failed — wlan0 sufficient, continuing"; exit 0; }
fi

# --- Ensure udev rule for EC25 QMI port type ---
# MM's shipped rules for 2c7c:0125 tag ttyUSB ports only; this rule tells MM
# that cdc-wdm0 on the same device is a QMI control port, enabling full modem detection.
if [[ ! -f "$UDEV_RULE" ]]; then
    LOG "Installing udev rule for EC25 QMI port detection..."
    cat > "$UDEV_RULE" <<'EOF'
SUBSYSTEM=="usbmisc", KERNEL=="cdc-wdm*", ATTRS{idVendor}=="2c7c", ATTRS{idProduct}=="0125", ENV{ID_MM_PORT_TYPE_QMI}="1"
EOF
    udevadm control --reload-rules
fi

# --- Ensure ModemManager is unmasked and running ---
# Legacy scripts masked MM to prevent it grabbing the QMI device mid-WDS setup.
# Under NM+MM, MM owns the device — unmask if needed.
if systemctl is-masked ModemManager 2>/dev/null; then
    LOG "Unmasking ModemManager..."
    systemctl unmask ModemManager
fi
if ! systemctl is-active --quiet ModemManager; then
    LOG "Starting ModemManager..."
    systemctl start ModemManager
    sleep 3
fi

# --- Replay udev events so MM detects the already-enumerated modem ---
# USB events fire at boot before MM starts; MM misses them. Three subsystems
# are required: tty (AT command ports), usbmisc (cdc-wdm0 QMI port),
# net (wwan0 — MM needs the net port to build a complete modem object).
LOG "Triggering udev for modem detection..."
udevadm trigger --subsystem-match=tty
udevadm trigger --subsystem-match=usbmisc
udevadm trigger --subsystem-match=net

# --- Wait for MM to detect the modem (up to 60s) ---
MODEM_IDX=""
for i in $(seq 1 30); do
    MODEM_IDX="$(mmcli -L 2>/dev/null | grep -o 'Modem/[0-9]*' | grep -o '[0-9]*' | tail -1)"
    [[ -n "${MODEM_IDX:-}" ]] && { LOG "Modem detected at index $MODEM_IDX"; break; }
    [[ "$i" -eq 30 ]] && { LOG "MM did not detect modem after 60s — wlan0 sufficient, continuing"; exit 0; }
    sleep 2
done

# --- Wait for LTE registration (up to 60s) ---
LOG "Waiting for LTE registration..."
for i in $(seq 1 30); do
    state="$(mmcli -m "$MODEM_IDX" --output-keyvalue 2>/dev/null \
        | grep 'modem.generic.state[[:space:]]' | awk -F': ' '{print $NF}' | tr -d ' ')"
    if [[ "$state" == "registered" || "$state" == "connected" ]]; then
        LOG "LTE registered (state: $state)"
        break
    fi
    [[ "$i" -eq 30 ]] && { LOG "No LTE registration after 60s — wlan0 sufficient, continuing"; exit 0; }
    sleep 2
done

# --- Ensure NM GSM connection profile exists ---
if ! nmcli connection show "$NM_CONN_NAME" &>/dev/null; then
    LOG "Creating NM connection profile '$NM_CONN_NAME'..."
    nmcli connection add \
        type gsm \
        ifname '*' \
        con-name "$NM_CONN_NAME" \
        gsm.apn "$LTE_APN" \
        connection.autoconnect yes \
        ipv4.route-metric 700 \
        ipv6.route-metric 700 2>/dev/null \
        || { LOG "Failed to create NM profile — wlan0 sufficient, continuing"; exit 0; }
fi

# --- Activate NM connection if not already active --- with stale PDP recovery ---
# interface-in-use-config-match means the modem has an existing data session from
# a previous manager (Sixfab agent, old WDS session, or soft-reboot with USB power
# maintained). NM cannot create a new bearer until it is cleared. The only reliable
# fix is a modem reset via AT+CFUN=1,1 — same approach as v1 qmicli path.
if ! nmcli connection show --active 2>/dev/null | grep -q "$NM_CONN_NAME"; then
    LOG "Bringing up '$NM_CONN_NAME'..."
    if ! nmcli connection up "$NM_CONN_NAME" 2>/dev/null; then
        LOG "NM activation failed — attempting modem reset to clear stale PDP context..."

        RESET_SENT=0
        for port in ttyUSB2 ttyUSB3 ttyUSB1 ttyUSB0; do
            [[ -e "/dev/$port" ]] || continue
            setsid bash -c "
                exec 3<>/dev/$port 2>/dev/null || exit 1
                printf 'AT+CFUN=1,1\r' >&3
                sleep 2
            " 2>/dev/null \
                && RESET_SENT=1 \
                && LOG "AT+CFUN=1,1 sent via /dev/$port — modem rebooting" \
                && break || true
        done

        if [[ "$RESET_SENT" -eq 0 ]]; then
            LOG "Could not send modem reset — wlan0 sufficient, continuing"
            exit 0
        fi

        LOG "Waiting for cdc-wdm0 to drop after reset..."
        for i in $(seq 1 15); do
            [[ ! -e /dev/cdc-wdm0 ]] && break
            sleep 1
        done
        LOG "Waiting for cdc-wdm0 to reappear after reset (up to 3 min)..."
        for i in $(seq 1 60); do
            [[ -e /dev/cdc-wdm0 ]] && { LOG "cdc-wdm0 reappeared"; break; }
            [[ "$i" -eq 60 ]] && { LOG "cdc-wdm0 not found after reset — wlan0 sufficient"; exit 0; }
            sleep 3
        done

        # Restart MM so it re-discovers the modem with clean state — without this,
        # MM may retain stale bearer/connection state from the failed activation attempt,
        # causing re-detection or re-registration to behave inconsistently.
        LOG "Restarting ModemManager for clean modem re-discovery..."
        systemctl restart ModemManager 2>/dev/null || true
        sleep 3

        udevadm trigger --subsystem-match=tty
        udevadm trigger --subsystem-match=usbmisc
        udevadm trigger --subsystem-match=net

        for i in $(seq 1 30); do
            MODEM_IDX="$(mmcli -L 2>/dev/null | grep -o 'Modem/[0-9]*' | grep -o '[0-9]*' | tail -1)"
            [[ -n "${MODEM_IDX:-}" ]] && { LOG "Modem re-detected at index $MODEM_IDX"; break; }
            [[ "$i" -eq 30 ]] && { LOG "MM did not re-detect modem after reset — wlan0 sufficient"; exit 0; }
            sleep 2
        done

        for i in $(seq 1 30); do
            state="$(mmcli -m "$MODEM_IDX" --output-keyvalue 2>/dev/null \
                | grep 'modem.generic.state[[:space:]]' | awk -F': ' '{print $NF}' | tr -d ' ')"
            [[ "$state" == "registered" || "$state" == "connected" ]] && break
            [[ "$i" -eq 30 ]] && { LOG "No LTE registration after reset — wlan0 sufficient"; exit 0; }
            sleep 2
        done

        LOG "Retrying NM activation after modem reset..."
        nmcli connection up "$NM_CONN_NAME" 2>/dev/null \
            || { LOG "NM activation failed after reset — wlan0 sufficient, continuing"; exit 0; }
    fi
fi

# --- Wait for wwan0 valid IP (up to 60s) ---
CURRENT_IP=""
for i in $(seq 1 30); do
    ip="$(ip -4 addr show wwan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)"
    if [[ -n "${ip:-}" ]]; then
        case "$ip" in
            169.254.*) ;;
            *) CURRENT_IP="$ip"; break ;;
        esac
    fi
    [[ "$i" -eq 30 ]] && { LOG "wwan0 no valid IP after 60s — wlan0 sufficient, continuing"; exit 0; }
    sleep 2
done

LOG "LTE ready — wwan0 IP: $CURRENT_IP (metric 700, wlan0 preferred)"

exit 0
