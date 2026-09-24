v1.1.2 (unreleased)
- install.sh: wait up to 2 minutes for running apt/dpkg processes before apt-get — Sixfab agent or unattended-upgrades may hold the lock (checks processes, since apt's fcntl locks are invisible to flock)
- install.sh: restart the provisioning units instead of start — they are RemainAfterExit oneshots, so start was a no-op when they had already run that boot and re-running the installer did nothing; units currently mid-run are left alone
- install.sh: --refresh mode reinstalls scripts/units from the existing checkout without apt, git or service changes (called by VCM_Update on every boot)
- install.sh: scripts replaced via atomic rename so a copy currently executing is not corrupted mid-run
- install.sh: full run logged to /var/log/vcm-install.log (persists across the shell dropping or a reboot, unlike /tmp)
- vcm_deploy.sh: always run VCM_Update install.sh (idempotent) — previously only after a fresh clone, so a run that died between clone and install left vcm-update.service missing permanently
- vcm_deploy.sh: validate an existing SSH key with git ls-remote; if GitHub rejects it (e.g. legacy deploy_core.sh key) move it aside and re-provision from the API
- vcm_deploy.sh: fleet password, hostnamectl and route re-add failures are logged instead of killing the script under set -e
- install.sh: run dpkg --configure -a before apt-get — a previously interrupted apt run leaves packages half-configured and apt-get install refuses to proceed
- vcm_deploy.sh: fix silent exit in direct AT ICCID probe — a port with no +CCID response made grep return 1 and set -e killed the script before trying remaining ports or logging FATAL
- vcm_deploy.sh: ICCID detection failure is non-fatal when the SSH deploy key is already present — ICCID is only needed for first provisioning, so a dead modem no longer blocks VCM_Update on already-provisioned devices
- vcm_deploy.sh: verify_networks skips interfaces that don't exist — on a device with no eth0, the failing `ip` pipeline killed the script under set -e with no log
- install.sh: only follow logs when a controlling terminal exists — allows unattended runs (`vcm update`) to return instead of tailing journalctl forever
- vcm-failure-reboot.service: only reboot devices without the deploy key — OnFailure also fires on a manual `systemctl stop` mid-run, and on already-provisioned devices a reboot only produced a reboot loop
- vcm_modem_reconnect.sh: allow usbguard-blocked USB hub (0424:2514) and Quectel modem (2c7c:*) before probing the modem — VCM < v1.0.4 decal loop null-matches the hub against decals with empty hardware_id and blocks it, hiding the modem
- install.sh: stop master.service and core-diagnostics.service before starting the provisioning chain so an old decal loop cannot re-block the hub mid-provision; vcm_update.sh restarts them

v1.1.1
2026-06-17
- install.sh: mask Sixfab services without stopping — stopping the agent drops the ECM route and kills any SSH session running the installer; mask-only keeps the agent running and ECM up through install.sh; the actual stop happens inside vcm_modem_migrate.sh which runs as a detached systemd service

v1.1.0
2026-05-26
- vcm_modem_reconnect.sh: replaced qmicli/WDS/dhcpcd with ModemManager + NetworkManager for LTE management
- vcm_modem_reconnect.sh: stale PDP context recovery (AT+CFUN=1,1 + modem reset) when NM activation fails after ECM→QMI flip
- vcm_modem_reconnect.sh: legacy dhcpcd artefact cleanup (allowinterfaces wwan* / nohook resolv.conf)
- vcm_modem_reconnect.sh: NM autoconnect race fix — wait for autoconnect to settle after profile creation before checking IP
- vcm_modem_reconnect.sh: check wwan0 IP directly (not NM connection state) to determine if activation is needed
- vcm_modem_reconnect.sh: service restart policy (StartLimitBurst=5, RestartSec=30, Restart=on-failure)
- vcm_modem_reconnect.sh: wwan0 IP wait extended to 3 minutes to cover fresh ECM→QMI flip timing
- vcm_deploy.sh: MM restart after direct AT ICCID probe (prevents LTE loss when MM was stopped for port access)
- vcm_deploy.sh: mmcli -L polling loop (up to 20s) before falling back to direct AT probe — avoids unnecessary MM stop/restart
- vcm_modem_migrate.sh: reordered to mask Sixfab services before MM install, preventing agent from removing MM mid-install
- install.sh: mask Sixfab services before modemmanager apt install for same reason
- install.sh: modemmanager added to apt dependencies (ensures MM present before ECM→QMI flip, not after)
- install.sh: DEBIAN_FRONTEND=noninteractive + --force-confold to prevent dpkg prompts during apt install
- install.sh: VCM_BRANCH env var support for dev branch installs; re-runs preserve current branch
- vcm-deploy.service: OnFailure=vcm-failure-reboot.service added; StartLimitBurst raised to 10
- vcm-failure-reboot.service: new unit — triggers reboot if vcm-deploy hits restart limit
- Tested on: fresh Sixfab ECM device (full migration + flip + stale PDP recovery); already-QMI no-Sixfab device (clean NM+MM handoff from udhcpc)

v1.0.0
2026-05-22
- Initial release of VCM_Deploy provisioning chain
- install.sh: terminal-safe curl-pipeable installer, starts provisioning chain via systemd
- vcm_modem_reconnect.sh: Sixfab migration, ECM→QMI flip, stale PDP context recovery, QMI/WDS setup via qmicli, wwan0 route metric management
- vcm_deploy.sh: ICCID detection, network verification, fleet password, credential provisioning via Supabase API, hostname assignment, VCM_Update bootstrap
- vcm_modem_migrate.sh: standalone Sixfab uninstall and cleanup called during migration path
- Fully terminal-safe, no reboots required, idempotent on re-run against both fresh and existing fleet devices
