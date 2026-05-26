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
