#!/usr/bin/env bash
# VCM LTE watchdog — run every 15 minutes by vcm-lte-watchdog.timer.
#
# vcm_modem_reconnect.sh sets LTE up once, at boot. If the modem only registers
# later (SIM re-enabled, signal back) and the data connection won't come up by
# itself — e.g. a stale data session that needs a modem reset — nothing retries
# until the next reboot. This re-runs the reconnect, with its modem-reset
# recovery, only when wwan0 has no address while the modem is registered.
# A working LTE connection is never touched.
set -uo pipefail

LOG() { echo "[vcm-lte-watchdog $(date -Is)] $*"; }

NM_CONN_NAME="vertek-lte"
STATE_DIR="/run/vertek"                         # tmpfs — resets on boot
STATUS_FILE="$STATE_DIR/lte-watchdog.status"    # last status logged
BACKOFF_FILE="$STATE_DIR/lte-watchdog.backoff"  # "<failed attempts> <epoch of last attempt>"
BACKOFF_MAX_MIN=240
CHAIN=(vcm-modem-reconnect.service vcm-deploy.service vcm-update.service)

mkdir -p "$STATE_DIR"

# The timer fires 96 times a day — log a status only when it changes
note() {
    local status="$1"; shift
    [[ "$(cat "$STATUS_FILE" 2>/dev/null)" == "$status" ]] || LOG "$*"
    echo "$status" > "$STATUS_FILE"
}

# Same test as vcm_modem_reconnect.sh: an IPv4 address that isn't link-local
wwan_ip() {
    local ip
    ip="$(ip -4 addr show wwan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)"
    [[ -n "$ip" && "$ip" != 169.254.* ]] && echo "$ip"
    return 0
}

# No Quectel modem on USB (Wi-Fi/Ethernet-only core) — nothing to watch
lsusb 2>/dev/null | grep -q '2c7c:' || exit 0

# Boot provisioning or a manual update is already handling the modem
for u in "${CHAIN[@]}"; do
    [[ "$(systemctl show -p ActiveState --value "$u" 2>/dev/null)" == "activating" ]] && exit 0
    [[ -n "$(systemctl list-jobs --no-legend "$u" 2>/dev/null)" ]] && exit 0
done

ip="$(wwan_ip)"
if [[ -n "$ip" ]]; then
    note up "LTE up — wwan0 $ip"
    rm -f "$BACKOFF_FILE"
    exit 0
fi

# NM is mid-activation — let it finish
gsm_state="$(nmcli -t -f TYPE,STATE device 2>/dev/null | awk -F: '$1=="gsm"{print $2; exit}')"
[[ "$gsm_state" == connecting* ]] && exit 0

modem_state="$(mmcli -m any --output-keyvalue 2>/dev/null \
    | grep 'modem.generic.state[[:space:]]' | awk -F': ' '{print $NF}' | tr -d ' ')" || true
has_profile=1
nmcli connection show "$NM_CONN_NAME" &>/dev/null || has_profile=0

# Recover when the modem is on the network but has no data connection, when
# ModemManager has lost the modem, or when the LTE profile is missing. Anything
# else (searching, no signal, SIM locked or missing) is beyond a reconnect —
# NM connects by itself once the modem registers.
case "$modem_state" in
    registered|connected) reason="modem registered (state: $modem_state) but wwan0 has no address" ;;
    "")                   reason="ModemManager isn't reporting the modem" ;;
    *)
        if [[ "$has_profile" -eq 1 ]]; then
            note "waiting:$modem_state" "LTE down — modem not registered (state: $modem_state); '$NM_CONN_NAME' connects once it registers"
            exit 0
        fi
        reason="no '$NM_CONN_NAME' profile (modem state: $modem_state)"
        ;;
esac

# Back off after failed attempts — a SIM that registers but is refused data
# (e.g. plan exhausted) would otherwise reset the modem every 15 minutes
# Wait after N failed attempts: 30, 60, 120, then 240 minutes
backoff_min() { local n=$(( $1 > 5 ? 5 : $1 )) m; m=$(( 15 << n )); echo $(( m > BACKOFF_MAX_MIN ? BACKOFF_MAX_MIN : m )); }
fails=0; last=0
[[ -f "$BACKOFF_FILE" ]] && read -r fails last < "$BACKOFF_FILE"
wait_min="$(backoff_min "$fails")"
if (( fails > 0 && $(date +%s) - last < wait_min * 60 )); then
    exit 0
fi

LOG "LTE down: $reason — re-running modem reconnect (attempt $((fails + 1)))"
echo "$((fails + 1)) $(date +%s)" > "$BACKOFF_FILE"
systemctl restart vcm-modem-reconnect.service || true

ip="$(wwan_ip)"
if [[ -n "$ip" ]]; then
    LOG "LTE restored — wwan0 $ip"
    rm -f "$BACKOFF_FILE"
    echo up > "$STATUS_FILE"
else
    LOG "LTE still down after reconnect (see: journalctl -u vcm-modem-reconnect) — next attempt in $(backoff_min $((fails + 1))) min"
    echo "recovery-failed" > "$STATUS_FILE"
fi
exit 0
