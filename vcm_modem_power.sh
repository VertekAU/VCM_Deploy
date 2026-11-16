#!/usr/bin/env bash
# Power control for the LTE modem on a Sixfab 3G/4G & LTE Base HAT.
#
# The HAT's GPIO26 (HAT_PWR_OFF) cuts the HAT's power regulator when driven HIGH
# — the modem's only supply — while the Pi keeps running. It is the one reset that
# clears a modem whose firmware has wedged: no AT port, ports that never come back
# after a USB reset, or stuck at "enabling". A Pi reboot keeps the modem powered, so
# a wedged modem carried on into the next boot and only a site visit cleared it
# (Criterion, Benchmark, Strathfield, Roundhouse UNSW — Nov 2026). Bench: modem off
# USB within 1 s; back on USB 16 s after power returns, LTE connected at 30 s.
#
#   vcm_modem_power.sh supported   exit 0 if this Core has the Base HAT and pinctrl
#   vcm_modem_power.sh cycle       power off 5 s, power on, wait for the modem's ports
#   vcm_modem_power.sh off         power off and stay off (shutdown: the Pi's reset at
#                                  reboot releases GPIO26, so the modem powers back up)
set -uo pipefail

LOG() { echo "[vcm-modem-power $(date -Is)] $*"; }

PIN=26
HAT_DIR=/proc/device-tree/hat

supported() {
    command -v pinctrl &>/dev/null || return 1
    [[ "$(tr -d '\0' < "$HAT_DIR/vendor" 2>/dev/null)" == "Sixfab" ]] || return 1
    [[ "$(tr -d '\0' < "$HAT_DIR/product" 2>/dev/null)" == *"Base HAT"* ]]
}

power_off() { pinctrl set "$PIN" op dh; }
# Back to the boot default (input, pulled down): the HAT's own pull-down holds power on
power_on()  { pinctrl set "$PIN" op dl; pinctrl set "$PIN" ip pd; }

case "${1:-}" in
    supported)
        supported
        ;;
    cycle)
        supported || { LOG "No Sixfab Base HAT (or no pinctrl) — can't power-cycle the modem"; exit 1; }
        LOG "Power-cycling the modem (HAT power off for 5 s)"
        power_off
        sleep 5
        power_on
        for i in $(seq 1 60); do
            [[ -e /dev/cdc-wdm0 ]] && { LOG "Modem back on USB after $((i * 2)) s"; exit 0; }
            sleep 2
        done
        LOG "Modem not back on USB 2 minutes after the power-cycle"
        exit 1
        ;;
    off)
        supported || exit 0
        LOG "Powering the modem off for the reboot"
        power_off
        # Give the modem time to lose power fully before the Pi resets and releases GPIO26
        sleep 3
        ;;
    *)
        echo "Usage: $0 supported|cycle|off" >&2
        exit 2
        ;;
esac
