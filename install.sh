#!/usr/bin/env bash
# VCM_Deploy installer
# Production: curl -sS https://raw.githubusercontent.com/VertekAU/VCM_Deploy/main/install.sh | sudo bash
# Dev branch: curl -sS https://raw.githubusercontent.com/VertekAU/VCM_Deploy/dev/install.sh | sudo VCM_BRANCH=dev bash
# --refresh:  reinstall scripts/units from the existing checkout only — no apt, git,
#             or service stops/starts. Run by vcm_update.sh on every boot.
set -euo pipefail

LOG() { echo "[vcm-deploy install $(date -Is)] $*"; }

[[ "$EUID" -ne 0 ]] && { echo "Run as root: sudo bash"; exit 1; }

REFRESH=0
[[ "${1:-}" == "--refresh" ]] && REFRESH=1

REPO="https://github.com/VertekAU/VCM_Deploy.git"
INSTALL_DIR="/home/pi/vcm_deploy"
SBIN="/usr/local/sbin"
SYSTEMD="/etc/systemd/system"
INSTALL_LOG="/var/log/vcm-install.log"

# Scripts are replaced via rename so a copy that is currently executing keeps
# reading its original file (bash reads scripts incrementally).
install_files() {
    local f
    for f in vcm_modem_migrate.sh vcm_modem_reconnect.sh vcm_deploy.sh; do
        install -m 0755 -o root -g root "$INSTALL_DIR/$f" "$SBIN/.$f.new"
        mv -f "$SBIN/.$f.new" "$SBIN/$f"
    done
    for f in vcm-modem-reconnect.service vcm-deploy.service vcm-failure-reboot.service; do
        install -m 0644 -o root -g root "$INSTALL_DIR/$f" "$SYSTEMD/$f"
    done
    systemctl daemon-reload
    systemctl enable vcm-modem-reconnect.service vcm-deploy.service
}

if [[ "$REFRESH" -eq 1 ]]; then
    LOG "Refreshing installed VCM_Deploy scripts and units"
    install_files
    exit 0
fi

# Persist the full run — the remote shell can drop mid-install (RPi Connect
# upgrade, reboot) and /tmp is cleared on boot.
exec 3>&1 4>&2
# tee ignores Ctrl+C: otherwise it dies with everything else in the process group and
# the cancel handler's message is lost (SIGPIPE kills the installer mid-handler)
exec > >(trap '' INT; exec tee -a "$INSTALL_LOG") 2>&1
LOG "=== VCM_Deploy install (log: $INSTALL_LOG) ==="

# Ctrl+C before the provisioning chain starts cancels the update. Put back anything
# this run stopped, and say so (the later detach trap replaces this one).
STOPPED_SVCS=()
on_cancel() {
    local s
    for s in "${STOPPED_SVCS[@]}"; do systemctl start --no-block "$s" 2>/dev/null || true; done
    echo
    LOG "Update cancelled before provisioning started — nothing was restarted. Run again to update."
    exit 130
}
trap on_cancel INT

# If repo already exists, default to its current branch so re-runs stay on the same branch.
# VCM_BRANCH overrides everything; fresh clone defaults to main.
BRANCH="${VCM_BRANCH:-$(git -C "$INSTALL_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)}"

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
# Sixfab agent or unattended-upgrades may be mid-run. apt's locks are fcntl locks,
# which flock(1) can't see, so wait on the processes instead.
# One name per pgrep: it rejects patterns over 15 characters (process name limit)
apt_busy() { local p; for p in apt apt-get dpkg unattended-upgr; do pgrep -x "$p" >/dev/null && return 0; done; return 1; }
for _apt_wait in $(seq 1 24); do
    apt_busy || break
    LOG "Waiting for another apt/dpkg process (attempt $_apt_wait/24)..."
    sleep 5
done
# An interrupted earlier apt run (e.g. power loss) leaves dpkg half-configured,
# and apt-get install refuses to run until it's resolved.
DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confold \
    || LOG "WARNING: dpkg --configure -a failed — apt-get may fail below"
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

LOG "Installing scripts and systemd units..."
install_files

# Old VCM (< v1.0.4) decal loop can block the modem's USB hub mid-provision.
# vcm_update.sh restarts these once VCM has been updated.
for svc in master.service core-diagnostics.service; do
    if systemctl is-active --quiet "$svc"; then
        LOG "Stopping $svc for provisioning..."
        systemctl stop "$svc" || true
        STOPPED_SVCS+=("$svc")
    fi
done

LOG "Installation complete. Starting provisioning chain..."
# restart, not start: these are RemainAfterExit oneshots, so start is a no-op when
# they already ran this boot. A unit that is mid-run is left alone — interrupting
# vcm-deploy can trip its OnFailure reboot on an unprovisioned device. Services are
# systemd-managed, so they survive this terminal dying.
CHAIN=(vcm-modem-reconnect.service vcm-deploy.service vcm-update.service)
CHAIN_START="$(date '+%Y-%m-%d %H:%M:%S')"
units=()
for u in "${CHAIN[@]}"; do
    systemctl cat "$u" &>/dev/null || continue
    if [[ "$(systemctl show -p SubState --value "$u")" == "start" ]]; then
        LOG "$u is mid-run — leaving it (updated scripts apply on its next run)"
        continue
    fi
    units+=("$u")
done
if [[ "${#units[@]}" -gt 0 ]]; then
    systemctl restart --no-block "${units[@]}" || LOG "WARNING: failed to queue restart of ${units[*]}"
fi
# From here the chain runs under systemd — Ctrl+C only detaches
trap 'echo; LOG "Detached — provisioning continues in the background."; exit 3' INT

# Stop teeing before following — journal lines don't belong in the install log
exec 1>&3 2>&4 3>&- 4>&-

# Unattended runs (`vcm update` from cron/master) have no controlling terminal —
# following logs there would never return.
if ! (: > /dev/tty) 2>/dev/null; then
    LOG "Provisioning running (no terminal — not following logs)."
    exit 0
fi

# A chain unit is busy while starting, waiting to restart, or with a queued job.
# On a first install vcm-update doesn't exist yet — vcm-deploy installs and queues it.
chain_busy() {
    local u
    for u in "${CHAIN[@]}"; do
        systemctl cat "$u" &>/dev/null || continue
        [[ "$(systemctl show -p ActiveState --value "$u")" == "activating" ]] && return 0
        [[ -n "$(systemctl list-jobs --no-legend "$u" 2>/dev/null)" ]] && return 0
    done
    return 1
}

LOG "Provisioning running — following logs until it finishes (Ctrl+C to detach; services continue)..."
LOG "If this shell drops (e.g. RPi Connect upgrade), reconnect and review with:"
LOG "  cat $INSTALL_LOG; journalctl -b -u vcm-modem-reconnect -u vcm-deploy -u vcm-update"
journalctl -f --since "$CHAIN_START" -u vcm-modem-reconnect.service -u vcm-deploy.service -u vcm-update.service &
JOURNAL_PID=$!
trap 'kill "$JOURNAL_PID" 2>/dev/null || true; echo; LOG "Detached — provisioning continues in the background."; exit 3' INT

# Two idle checks in a row, so the hand-off between units isn't mistaken for the end
idle=0
for _ in $(seq 1 600); do   # 30-minute ceiling
    if chain_busy; then idle=0; else idle=$((idle + 1)); fi
    [[ "$idle" -ge 2 ]] && break
    sleep 3
done
sleep 2   # let the last journal lines print
kill "$JOURNAL_PID" 2>/dev/null || true
wait "$JOURNAL_PID" 2>/dev/null || true
trap - INT

if [[ "$idle" -lt 2 ]]; then
    LOG "Still running after 30 minutes — detaching. Check: systemctl status vcm-deploy vcm-update"
    exit 3
fi

# master is started once vcm-update finishes
for _ in $(seq 1 15); do
    systemctl is-active --quiet master.service && break
    sleep 1
done

echo
summary=() failed=()
for u in "${CHAIN[@]}"; do
    systemctl cat "$u" &>/dev/null || continue
    if [[ "$(systemctl show -p ActiveState --value "$u")" == "failed" ]]; then
        summary+=("${u%.service} FAILED"); failed+=("$u")
    else
        summary+=("${u%.service} ok")
    fi
done
if systemctl is-active --quiet master.service; then
    summary+=("master running")
else
    summary+=("master NOT running"); failed+=(master.service)
fi
LOG "Finished: $(printf "%s, " "${summary[@]}" | sed "s/, $//")"
if [[ "${#failed[@]}" -gt 0 ]]; then
    LOG "Check: journalctl -b -u ${failed[*]}"
    exit 1
fi
