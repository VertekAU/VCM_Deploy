#!/usr/bin/env bash
set -uo pipefail
# Opening a ttyUSB device as session leader (no controlling terminal) makes it
# the controlling terminal — HUP arrives if the modem resets. Ignore it here;
# child sessions opened via setsid handle their own terminal lifecycle.
trap '' HUP

LOG() { echo "[vcm-modem-reconnect $(date -Is)] $*"; }

MARKER="/var/lib/vcm/migration_qmi_done"
WDS_STATE="/var/lib/vcm/wds-state"   # persists CID and PDH across runs

# --- Path 1: Sixfab migration (fleet devices with Sixfab agent still present) ---
if [[ ! -f "$MARKER" ]] && [[ -d /opt/sixfab ]]; then
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

# --- Check for a valid (non-APIPA) IPv4 on wwan0 ---
CURRENT_IP="$(ip -4 addr show wwan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)"
HEALTHY=0
if [[ -n "${CURRENT_IP:-}" ]]; then
    case "$CURRENT_IP" in
        169.254.*) ;;
        *) HEALTHY=1 ;;
    esac
fi

if [[ "$HEALTHY" -eq 1 ]]; then
    LOG "wwan0 already has valid IP $CURRENT_IP — healthy path"
else
    LOG "wwan0 has no valid IP (current: ${CURRENT_IP:-none}) — running QMI setup"

    LOG "Waiting for modem hardware ready..."
    for i in $(seq 1 30); do
        qmicli -d /dev/cdc-wdm0 --dms-get-operating-mode &>/dev/null && break
        [[ "$i" -eq 30 ]] && { LOG "Modem not ready after 60s — wlan0 sufficient, continuing"; exit 0; }
        sleep 2
    done

    LOG "Waiting for LTE registration..."
    for i in $(seq 1 30); do
        qmicli -d /dev/cdc-wdm0 --nas-get-signal-strength 2>/dev/null | grep -q "Network 'lte'" && break
        [[ "$i" -eq 30 ]] && { LOG "No LTE registration after 60s — wlan0 sufficient, continuing"; exit 0; }
        sleep 2
    done
    sleep 10

    # Stop any stale WDS session from a previous run (prevents interface-in-use-config-match)
    if [[ -f "$WDS_STATE" ]]; then
        read -r STALE_CID STALE_PDH < "$WDS_STATE" 2>/dev/null || true
        if [[ -n "${STALE_CID:-}" && -n "${STALE_PDH:-}" ]]; then
            LOG "Stopping stale WDS session (CID $STALE_CID, PDH $STALE_PDH)..."
            qmicli -p -d /dev/cdc-wdm0 \
                --client-cid="$STALE_CID" \
                --wds-stop-network="$STALE_PDH" \
                --client-no-release-cid 2>/dev/null || true
        fi
        rm -f "$WDS_STATE"
    fi

    ip link set wwan0 down
    echo 'Y' | tee /sys/class/net/wwan0/qmi/raw_ip >/dev/null
    ip link set wwan0 up

    wds_start_network() {
        WDS_OUTPUT="$(qmicli -p -d /dev/cdc-wdm0 \
            --device-open-net='net-raw-ip|net-no-qos-header' \
            --wds-start-network="apn='super',ip-type=4" \
            --client-no-release-cid 2>&1)"
        WDS_CID="$(echo "$WDS_OUTPUT" | sed -n "s/.*CID: '\([0-9]*\)'.*/\1/p")"
        WDS_PDH="$(echo "$WDS_OUTPUT" | sed -n "s/.*Packet data handle: '\([0-9]*\)'.*/\1/p")"
    }

    LOG "Starting WDS network..."
    wds_start_network

    # Endpoint hangup: modem briefly unresponsive after LTE network attach completes.
    # Wait and retry once.
    if echo "$WDS_OUTPUT" | grep -q "endpoint hangup"; then
        LOG "Endpoint hangup after LTE attach — waiting 15s for modem to stabilise..."
        sleep 15
        wds_start_network
    fi

    # If the modem retained a stale PDP context (USB power not cut on reboot),
    # do a soft modem reset via AT+CFUN=1,1 and retry once.
    # --dms-set-operating-mode=offline drops the QMI endpoint entirely and requires
    # a physical power cycle to recover — AT+CFUN=1,1 is a clean soft reset.
    if echo "$WDS_OUTPUT" | grep -q "interface-in-use"; then
        LOG "Stale PDP context detected — soft-resetting modem via AT+CFUN=1,1..."
        systemctl stop ModemManager 2>/dev/null || true
        sleep 1
        for port in ttyUSB2 ttyUSB3 ttyUSB1 ttyUSB0; do
            [[ -e "/dev/$port" ]] || continue
            setsid bash -c "
                exec 3<>/dev/$port 2>/dev/null || exit 1
                printf 'AT+CFUN=1,1\r' >&3
                sleep 2
            " 2>/dev/null && LOG "AT+CFUN=1,1 sent via /dev/$port" && break || true
        done
        LOG "Waiting for modem to recover (up to 60s)..."
        for i in $(seq 1 30); do
            qmicli -d /dev/cdc-wdm0 --dms-get-operating-mode &>/dev/null && break
            sleep 2
        done
        sleep 3
        rm -f "$WDS_STATE"
        wds_start_network
    fi

    if [[ -z "${WDS_PDH:-}" ]]; then
        LOG "WDS start-network failed: $WDS_OUTPUT"
        LOG "wwan0 has no bearer — wlan0 sufficient, continuing"
        exit 0
    fi

    echo "$WDS_CID $WDS_PDH" > "$WDS_STATE"
    LOG "WDS network started (CID $WDS_CID, PDH $WDS_PDH)"

    # Get IP settings from modem directly (more reliable than DHCP over QMI)
    SETTINGS="$(qmicli -p -d /dev/cdc-wdm0 \
        --client-cid="$WDS_CID" \
        --wds-get-current-settings 2>/dev/null)"
    WDS_IP="$(echo "$SETTINGS"    | sed -n 's/.*IPv4 address: \(.*\)/\1/p' | tr -d ' ')"
    WDS_MASK="$(echo "$SETTINGS"  | sed -n 's/.*IPv4 subnet mask: \(.*\)/\1/p' | tr -d ' ')"
    WDS_GW="$(echo "$SETTINGS"    | sed -n 's/.*IPv4 gateway address: \(.*\)/\1/p' | tr -d ' ')"
    WDS_DNS1="$(echo "$SETTINGS"  | sed -n 's/.*IPv4 primary DNS: \(.*\)/\1/p' | tr -d ' ')"
    WDS_MTU="$(echo "$SETTINGS"   | sed -n 's/.*MTU: \(.*\)/\1/p' | tr -d ' ')"

    if [[ -n "${WDS_IP:-}" ]]; then
        LOG "Configuring wwan0 from WDS settings: IP=$WDS_IP GW=$WDS_GW DNS=$WDS_DNS1"
        # Convert subnet mask to prefix length
        PREFIX="$(python3 -c "import ipaddress; print(ipaddress.IPv4Network('0.0.0.0/${WDS_MASK}').prefixlen)" 2>/dev/null || echo "30")"
        ip addr flush dev wwan0 2>/dev/null || true
        ip addr add "${WDS_IP}/${PREFIX}" dev wwan0
        [[ -n "${WDS_GW:-}" ]] && ip route add default via "$WDS_GW" dev wwan0 metric 700 2>/dev/null || true
        [[ -n "${WDS_MTU:-}" ]] && ip link set wwan0 mtu "$WDS_MTU" 2>/dev/null || true
        [[ -n "${WDS_DNS1:-}" ]] && echo "nameserver $WDS_DNS1" > /etc/resolv.conf
    else
        LOG "No IP in WDS settings — falling back to udhcpc..."
        udhcpc -q -f -n -i wwan0 2>/dev/null || true
    fi

    CURRENT_IP="$(ip -4 addr show wwan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)"
    if [[ -z "${CURRENT_IP:-}" ]]; then
        LOG "QMI setup ran but wwan0 has no IP — wlan0 sufficient, continuing"
        exit 0
    fi
    LOG "QMI setup complete, wwan0 IP: $CURRENT_IP"
fi

# --- Set wwan0 default route metric to 700 so wlan0 remains preferred ---
WAN_GW="$(ip route show default dev wwan0 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')"
if [[ -n "${WAN_GW:-}" ]]; then
    ip route del default dev wwan0 2>/dev/null || true
    ip route add default via "$WAN_GW" dev wwan0 metric 700
    LOG "wwan0 default route set via $WAN_GW metric 700"
else
    LOG "No default route on wwan0 to fix"
fi

exit 0
