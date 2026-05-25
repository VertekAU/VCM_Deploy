v1.0.0
2026-05-22
- Initial release of VCM_Deploy provisioning chain
- install.sh: terminal-safe curl-pipeable installer, starts provisioning chain via systemd
- vcm_modem_reconnect.sh: Sixfab migration, ECM→QMI flip, stale PDP context recovery, QMI/WDS setup via qmicli, wwan0 route metric management
- vcm_deploy.sh: ICCID detection, network verification, fleet password, credential provisioning via Supabase API, hostname assignment, VCM_Update bootstrap
- vcm_modem_migrate.sh: standalone Sixfab uninstall and cleanup called during migration path
- Fully terminal-safe, no reboots required, idempotent on re-run against both fresh and existing fleet devices
