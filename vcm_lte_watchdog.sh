#!/usr/bin/env bash
# VCM LTE watchdog — run every 2 minutes by vcm-lte-watchdog.timer.
#
# vcm_modem_reconnect.sh sets LTE up once, at boot. If the modem only registers
# later (SIM re-enabled, signal back) and the data connection won't come up by
# itself — e.g. a stale data session that needs a modem reset — nothing retries
# until the next reboot. This re-runs the reconnect, with its modem-reset
# recovery, when wwan0 has no address and the modem is registered, missing from
# ModemManager, failed (not for a SIM reason), switched off, stuck at "enabling"
# for 10 minutes, or (Sixfab Base HAT) gone from USB. A modem that is just not
# registered is left alone — NetworkManager connects once it registers.
# A working LTE connection is never touched. When a reset has already failed, or the
# modem is stuck or off USB, the reconnect power-cycles it (soft resets don't clear
# a wedged modem — Nov 2026 fleet).
set -uo pipefail

LOG() { echo "[vcm-lte-watchdog $(date -Is)] $*"; }

NM_CONN_NAME="vertek-lte"
STATE_DIR="/run/vertek"                         # tmpfs — resets on boot
STATUS_FILE="$STATE_DIR/lte-watchdog.status"    # last status logged
BACKOFF_FILE="$STATE_DIR/lte-watchdog.backoff"  # "<failed attempts> <epoch of last attempt>"
BACKOFF_MAX_MIN=240
STUCK_FILE="$STATE_DIR/lte-watchdog.stuck"       # "<modem state> <epoch first seen>"
STUCK_MIN=10
HARD_RESET_FLAG="$STATE_DIR/modem-reset-hard"    # read (and removed) by vcm_modem_reconnect.sh
MODEM_POWER="/usr/local/sbin/vcm_modem_power.sh"
CHAIN=(vcm-modem-reconnect.service vcm-deploy.service vcm-update.service)

mkdir -p "$STATE_DIR"

# The timer fires 720 times a day — log a status only when it changes
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

# No Quectel modem on USB: nothing to watch on a Wi-Fi/Ethernet-only core. With the
# Sixfab Base HAT fitted the modem should be there — it has crashed off USB.
on_usb=1
if ! lsusb 2>/dev/null | grep -q '2c7c:'; then
    "$MODEM_POWER" supported 2>/dev/null || exit 0
    on_usb=0
fi

# Boot provisioning or a manual update is already handling the modem
for u in "${CHAIN[@]}"; do
    [[ "$(systemctl show -p ActiveState --value "$u" 2>/dev/null)" == "activating" ]] && exit 0
    [[ -n "$(systemctl list-jobs --no-legend "$u" 2>/dev/null)" ]] && exit 0
done

ip="$(wwan_ip)"
if [[ -n "$ip" ]]; then
    note up "LTE up — wwan0 $ip"
    rm -f "$BACKOFF_FILE" "$STUCK_FILE"
    exit 0
fi

# NM is mid-activation — let it finish
gsm_state="$(nmcli -t -f TYPE,STATE device 2>/dev/null | awk -F: '$1=="gsm"{print $2; exit}')"
[[ "$gsm_state" == connecting* ]] && exit 0

modem_state="$(mmcli -m any --output-keyvalue 2>/dev/null \
    | grep 'modem.generic.state[[:space:]]' | awk -F': ' '{print $NF}' | tr -d ' ')" || true
has_profile=1
nmcli connection show "$NM_CONN_NAME" &>/dev/null || has_profile=0
[[ "$modem_state" =~ ^(enabling|initializing|disabling)$ ]] || rm -f "$STUCK_FILE"
hard=0   # go straight to a power-cycle

# Recover when the modem is on the network but has no data connection, when
# ModemManager has lost the modem, or when the LTE profile is missing. Anything
# else (searching, no signal, SIM locked or missing) is beyond a reconnect —
# NM connects by itself once the modem registers.
case "$modem_state" in
    registered|connected) reason="modem registered (state: $modem_state) but wwan0 has no address" ;;
    # The reconnect resets a modem ModemManager has dropped (e.g. its control port
    # hung: "marking modem as invalid"), which used to need a Core reboot
    "")
        if [[ "$on_usb" -eq 0 ]]; then
            reason="modem not on USB"; hard=1
        else
            reason="ModemManager isn't reporting the modem"
        fi ;;
    # A modem that doesn't finish enabling has a wedged control port (Benchmark,
    # Mildura, Criterion, Nov 2026 — they sat there for hours)
    enabling|initializing|disabling)
        since="$(awk -v s="$modem_state" '$1==s{print $2}' "$STUCK_FILE" 2>/dev/null)"
        [[ -n "$since" ]] || { since="$(date +%s)"; echo "$modem_state $since" > "$STUCK_FILE"; }
        mins=$(( ($(date +%s) - since) / 60 ))
        if (( mins < STUCK_MIN )); then
            note "stuck-$modem_state" "LTE down — modem $modem_state; power-cycling it if still $modem_state after $STUCK_MIN min"
            exit 0
        fi
        reason="modem stuck at $modem_state for $mins min"; hard=1 ;;
    failed)
        failed_reason="$(mmcli -m any --output-keyvalue 2>/dev/null \
            | awk -F': ' '/modem.generic.state-failed-reason/{print $NF}' | tr -d ' ')"
        case "$failed_reason" in
            sim-*|esim-*)
                note waiting "LTE down — modem failed: $failed_reason (a reset can't fix the SIM)"
                exit 0 ;;
        esac
        reason="modem failed to initialise (${failed_reason:-unknown}) — resetting it" ;;
    # Switched off locally (low-power) — the network can't clear this; connecting the
    # profile enables the modem. Seen when a connection was taken down by hand, after
    # which NetworkManager doesn't auto-connect again until the next boot.
    disabled)             reason="modem is switched off (disabled)" ;;
    *)
        if [[ "$has_profile" -eq 1 ]]; then
            note waiting "LTE down — modem not registered (state: $modem_state); '$NM_CONN_NAME' connects once it registers"
            exit 0
        fi
        reason="no '$NM_CONN_NAME' profile (modem state: $modem_state)"
        ;;
esac

# Back off after failed attempts — a SIM that registers but is refused data
# (e.g. plan exhausted) would otherwise reset the modem every 2 minutes
# Wait after N failed attempts: 30, 60, 120, then 240 minutes
backoff_min() { local n=$(( $1 > 5 ? 5 : $1 )) m; m=$(( 15 << n )); echo $(( m > BACKOFF_MAX_MIN ? BACKOFF_MAX_MIN : m )); }
fails=0; last=0
[[ -f "$BACKOFF_FILE" ]] && read -r fails last < "$BACKOFF_FILE"
wait_min="$(backoff_min "$fails")"
if (( fails > 0 && $(date +%s) - last < wait_min * 60 )); then
    exit 0
fi

# A modem a reset didn't bring back gets its power cut on the next attempt
[[ "$fails" -gt 0 && ( -z "$modem_state" || "$modem_state" == "failed" ) ]] && hard=1

LOG "LTE down: $reason — recovering (attempt $((fails + 1))$([[ "$hard" -eq 1 ]] && echo ", power-cycle"))"
echo "$((fails + 1)) $(date +%s)" > "$BACKOFF_FILE"
[[ "$hard" -eq 1 ]] && touch "$HARD_RESET_FLAG"
if [[ "$modem_state" == "disabled" && "$has_profile" -eq 1 ]]; then
    # Bringing the profile up enables the modem, registers and connects
    timeout 90 nmcli connection up "$NM_CONN_NAME" >/dev/null 2>&1 || true
    sleep 5
else
    systemctl restart vcm-modem-reconnect.service || true
fi

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
