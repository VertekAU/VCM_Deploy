v1.1.8
2026-10-26
- vcm_modem_reconnect.sh / vcm_lte_watchdog.sh: a modem that hangs on USB is now reset in place instead of waiting for a Core reboot. At Roundhouse UNSW (Oct 2026) the modem's control port stopped answering ("cdc-wdm0 timed out 10 consecutive times, marking modem as invalid"), ModemManager dropped it while it stayed on USB, and the watchdog's reconnect only replayed udev and gave up, 7 times out of 7; only a Core reboot recovered it, up to 31 hours later under core_diagnostics' backoff. Now, when ModemManager can't see a modem that is on USB, or reports it "failed" for a non-SIM reason (e.g. "Failed to load current capabilities: QMI … Transaction timed out" after a warm reboot), the modem is reset: AT+CFUN=1,1, or a USB port reset (usbreset) if it doesn't go down, then ModemManager restarts and re-detects it. The stale-data-session recovery uses the same reset (and gains the USB-reset fallback). A modem failed for a SIM reason is left alone. A modem with no ports at all (no cdc-wdm0, no ttyUSB) is no longer mistaken for ECM mode: it gets the USB reset, and is re-authorized on USB if the reset doesn't bring its ports back; a deauthorized modem is authorized first. The ECM→QMI flip's exits no longer leave ModemManager stopped. Bench-tested (VERTEK-TEST-CORE02), each from LTE down to "LTE restored" by the watchdog with no Core reboot: ModemManager releasing a modem that stays on USB (AT reset, ~1.5 min); modem deauthorized (9 s); modem's drivers detached (USB reset + re-authorize, 30 s)
- vcm-modem-reconnect.service TimeoutStartSec 600 → 900 s and vcm-lte-watchdog.service 900 → 1200 s — a reset with the full waits can take ~10 minutes

v1.1.7
2026-10-19
- vcm_lte_watchdog.sh: a modem switched off locally (ModemManager state "disabled") is recovered by bringing vertek-lte up, which enables it — previously treated like "not registered" and waited for forever (found while prototyping a clean modem detach at shutdown; tested: back in 7 s)
- New vcm_pkg.sh (installed to /usr/local/sbin): package installs that survive venue networks. Per repository (Debian, Debian security, Raspberry Pi) it tries over Wi-Fi/Ethernet the source that last worked, the default, the default over HTTPS (content can't be replaced without breaking TLS), then mirrors (AARNet, linux.org.au, Digital Pacific — verified to serve the signed bookworm indexes), and only then the same list over LTE (every source — a failed one costs almost nothing) by routing just its addresses via wwan0 for the run. A source counts only if apt's signature/checksum verification passes — a firewall's substituted page ("response failed verification") is detected and skipped, never used — and apt's warnings are checked, not just its exit code. pip the same across PyPI/piwheels (HTTPS), with a 6 s reachability probe so a blocked index is skipped in seconds (pip alone took ~5 min to give up). The installer's package step uses it when present. Tested with UniFi blocks and a simulated SonicWall block page: Debian via AARNet over Wi-Fi; Raspberry Pi and pip via LTE only when every Wi-Fi path was blocked (7 kB / 22 kB)
- vcm_deploy.sh: GitHub host keys pinned — the published keys (api.github.com/meta, checked against ssh.github.com:443) go in a managed ~/.ssh/known_hosts_github and the SSH config requires a match (StrictHostKeyChecking yes) instead of trusting a venue network on first use. Tested: a tampered key is refused ("REMOTE HOST IDENTIFICATION HAS CHANGED")
- NetworkManager connectivity check (90-vertek-connectivity.conf, installed with the scripts; effective from the next boot): every 5 minutes NetworkManager fetches Google's check page (connectivitycheck.gstatic.com, HTTP 204) on each connection — not Debian's network-test.debian.org, which shares CDN addresses with deb.debian.org so a venue blocking Debian mirrors forced a needless failover to LTE (UniFi test 2026-10-18); one without internet has its default route pushed behind LTE and is promoted again when the internet returns — automatic failover and failback, no reboot, DNS order moves with it. Tested with a UniFi internet block: failover within seconds, failback within one check. ~1 KB per check per connection (~9 MB/month on LTE)
- vcm_deploy.sh: the boot-time Wi-Fi/Ethernet check only reports now (OK / HTTP failed but ping works / no internet path). It used to demote a failing interface to metric 800 with a hand-made route, which (a) blocked NetworkManager's failback, so one venue outage kept a core on LTE until the next reboot, and (b) on sites whose DNS servers sit behind the router on another subnet (Carina) sent DNS out over LTE and killed it — CORE05 dropped off the internet after a single failed check during a full update
- vcm_deploy.sh: GitHub over port 443 — the pi SSH config (rewritten every boot, not only at provisioning) sends github.com to ssh.github.com:443 with a 15 s connect timeout. Venues blocking port 22 made every pull time out (~7 min for three attempts at boot, delaying VCM's start and never updating); remotes are unchanged. A core on a port-22-blocked site receives this via the nightly VCM_Deploy refresh (HTTPS) and pulls over 443 from the following boot
- vcm_deploy.sh: 15 s connect timeout on git's SSH; fix the doubled HTTP code in the check's log ('000000')
- install.sh: the summary's journalctl hint lists each failed unit once

v1.1.6
2026-10-13
- vcm_deploy.sh, install.sh: remove a broken ORIG_HEAD before pulling — an update cut off mid-pull (power loss) leaves it empty and git then refuses every later pull ('cannot lock ref ORIG_HEAD: reference broken'); ArchiveBB had silently stopped updating on 24 June this way
- vcm_deploy.sh: VCM_Update pull retries 3 times 10 s apart (site internet can drop for seconds) and logs git's actual error instead of discarding it
- install.sh: the final summary reports failed repo pulls ('N repo pull(s) FAILED — still on old code') and exits 1, instead of 'ok' while the core stays on old code; its "Check:" hint now puts -u before each unit (journalctl rejected the old form when more than one unit failed)

v1.1.5
2026-10-12
- vcm_modem_reconnect.sh: LTE profile is IPv4 only (ipv6.method disabled), on new and existing profiles — NM asked for a dual-stack data call and the network refused the IPv6 half on every connect (pdn-ipv6-call-disallowed); the old QMI script only ever asked for IPv4. Existing profiles pick it up at their next connection; the modem's attach settings are unchanged
- vcm_modem_reconnect.sh: remove the April QMI tooling (Sixfab-Removal-and-QMI-Flip) where present — vcm-qmi-reconnect.service and vcm-migrate-sixfab-ecm-to-qmi.service plus their scripts. Superseded by this script and NetworkManager/ModemManager, the reconnect service still ran at boot and, when wwan0 had no address yet, opened its own qmicli data session and ran udhcpc while NM was connecting — on the test core NM lost the modem mid-activation and modem detection was delayed ~35s. The migration marker file is left in place
- New LTE watchdog (vcm_lte_watchdog.sh, vcm-lte-watchdog.timer): every 2 minutes, from 2 minutes after boot, if wwan0 has no address while the modem is registered (or ModemManager has lost the modem, or the vertek-lte profile is missing), re-runs vcm-modem-reconnect and its modem-reset recovery — LTE that comes back after boot (SIM re-enabled, signal returned) no longer waits for the next reboot (seen on Bullseye Birdies). Never touches a working connection; skips while boot provisioning runs; backs off 30/60/120/240 minutes after failed attempts; logs only on status changes, and systemd's per-run start/finish lines are kept out of the journal. The 2-minute check matters when the modem drops while the Pi stays up: NetworkManager spends its retries in about a second and then waits 5 minutes (measured on a modem reset: LTE back 2m46s after the modem had re-registered). Installed by --refresh (active from the following boot) and by the installer (active immediately)
- vcm_modem_reconnect.sh: create the vertek-lte NetworkManager profile before waiting for LTE registration — it was only created after a successful 60s wait, so a core that couldn't register at boot (weak signal) was left with no profile and LTE never came up even once signal returned (seen on Bullseye Birdies after migration). With autoconnect, NM now connects whenever the modem registers
- install.sh, vcm_modem_migrate.sh: stop installing udhcpc and busybox — vestigial from the old QMI/Sixfab setup; NetworkManager + ModemManager own LTE, and with the April QMI tooling removed (below) nothing calls udhcpc. Existing installs are left in place (busybox may be used by initramfs-tools)
- install.sh: usage comments use curl -fsSL (fail on HTTP errors instead of piping an error page to bash)

v1.1.4
2026-09-29
- install.sh: flag the provisioning run as a full update (/run/vertek/patch-now) so VCM_Update v1.1.4+ applies the Patch Tuesday package upgrades now rather than waiting for Tuesday

v1.1.3
2026-09-29
- install.sh: detaching (Ctrl+C after provisioning starts, or the 30-minute ceiling) exits with code 3 so 'vcm update full' can tell a detach from a finished run
- install.sh: Ctrl+C before the provisioning chain starts now reports the update was cancelled (and restarts master/core-diagnostics if this run had stopped them); after the chain is queued, Ctrl+C only detaches. The install-log tee ignores Ctrl+C — previously it died with the process group and the cancel message was lost (installer killed by SIGPIPE)
- install.sh: follow the provisioning logs only until the chain finishes, then print a one-line result (each unit ok/FAILED, master running) and return to the prompt — previously it tailed the journal until Ctrl+C. Exits 1 if a unit failed or master is not running; Ctrl+C still detaches early; 30-minute ceiling

v1.1.2
2026-09-24
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
- vcm_modem_reconnect.sh: retire dhcpcd so NetworkManager is the only network manager — dhcpcd alongside NM grabbed wwan0 before ModemManager switched it to raw-ip, added duplicate wlan0 addresses, and removed NM's wlan0 default route (leaving LTE preferred over working WiFi). Disabled+masked only when NM manages every addressed interface, effective next boot; denyinterfaces wwan* added for the remainder of the current boot
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
