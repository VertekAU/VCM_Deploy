#!/usr/bin/env bash
set -euo pipefail

LOG()  { echo "[vcm-deploy $(date -Is)] $*"; }
FAIL() { LOG "FATAL: $*"; exit 1; }

VERTEK_DIR="/etc/vertek"
ICCID_FILE="$VERTEK_DIR/iccid"
HOSTNAME_FILE="$VERTEK_DIR/hostname"
AUTH_KEY_FILE="$VERTEK_DIR/rpc_auth_key"
SSH_KEY_FILE="/home/pi/.ssh/vertekgithub"
VCM_UPDATE_DIR="/home/pi/vcm_update"
VCM_UPDATE_REPO="git@github.com:VertekAU/VCM_Update.git"
PROVISIONING_URL="https://ywnjbeqoowlqyngmzkpc.supabase.co/functions/v1/rpi-connect-provisioning"
PI_USER="pi"
GIT_SSH="ssh -i $SSH_KEY_FILE -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

mkdir -p "$VERTEK_DIR"
chmod 755 "$VERTEK_DIR"

# --- ICCID Detection ---
detect_iccid() {
    if [[ -f "$ICCID_FILE" && -s "$ICCID_FILE" ]]; then
        ICCID="$(cat "$ICCID_FILE")"
        LOG "ICCID from cache: $ICCID"
        return 0
    fi

    local iccid=""

    # ModemManager holds ttyUSB port locks when active — query through it first.
    # Use dynamic modem index (not hardcoded 0) — index increments on each MM restart.
    # || true prevents set -euo pipefail from killing the script if mmcli fails.
    if systemctl is-active --quiet ModemManager 2>/dev/null && command -v mmcli &>/dev/null; then
        LOG "ModemManager is active — querying ICCID via mmcli..."
        # MM may have just restarted (e.g. after stale PDP recovery) — poll up to 20s
        # for the modem index to appear before falling back to the direct AT probe.
        local modem_idx
        for _mm_wait in $(seq 1 20); do
            modem_idx="$(mmcli -L 2>/dev/null | grep -o 'Modem/[0-9]*' | grep -o '[0-9]*' | tail -1)" || true
            [[ -n "${modem_idx:-}" ]] && break
            sleep 1
        done
        if [[ -n "${modem_idx:-}" ]]; then
            iccid="$(mmcli -m "$modem_idx" --timeout=15 --command="AT+CCID" 2>/dev/null \
                | grep '+CCID:' | awk -F': ' '{print $2}' | tr -d '\r\n ')" || true
            [[ -n "${iccid:-}" ]] && LOG "ICCID from ModemManager (modem $modem_idx): $iccid"
        else
            LOG "ModemManager active but no modem detected after 20s — falling back to AT probe"
        fi
    fi

    # Direct AT probe — stop ModemManager first to release port locks
    if [[ -z "${iccid:-}" ]]; then
        LOG "Probing modem directly for ICCID (ttyUSB2, 3, 1, 0)..."
        if systemctl is-active --quiet ModemManager 2>/dev/null; then
            LOG "Stopping ModemManager to release port locks..."
            systemctl stop ModemManager 2>/dev/null || true
            sleep 1
        fi

        for port in ttyUSB2 ttyUSB3 ttyUSB1 ttyUSB0; do
            [[ -e "/dev/$port" ]] || continue
            local response
            response="$(
                exec 3<>"/dev/$port"
                printf 'AT+CCID\r' >&3
                sleep 1
                timeout 2 cat <&3 2>/dev/null || true
            )" 2>/dev/null || continue
            iccid="$(echo "$response" | grep '+CCID:' | awk -F': ' '{print $2}' | tr -d '\r\n ')" || true
            if [[ -n "${iccid:-}" ]]; then
                LOG "ICCID detected via /dev/$port: $iccid"
                break
            fi
        done
        # Restart ModemManager — stopped to release port locks for the AT probe.
        # Without this, NM cannot manage the LTE bearer after ICCID is cached.
        systemctl start ModemManager 2>/dev/null || true
    fi

    if [[ -z "${iccid:-}" ]]; then
        # Already-provisioned devices only need ICCID for identity caching — don't let
        # a dead modem block VCM_Update from running
        if [[ -f "$SSH_KEY_FILE" ]]; then
            LOG "WARNING: Could not detect ICCID — SSH key present, continuing without it"
            ICCID=""
            return 0
        fi
        FAIL "Could not detect ICCID — check modem hardware and connectivity"
    fi

    if [[ -f "$ICCID_FILE" ]]; then
        local cached
        cached="$(cat "$ICCID_FILE")"
        if [[ "$cached" != "$iccid" ]]; then
            LOG "ICCID changed ($cached → $iccid) — updating cache"
            echo "$iccid" > "$ICCID_FILE"
        fi
    else
        echo "$iccid" > "$ICCID_FILE"
    fi

    ICCID="$iccid"
}

# --- Network Quality Verification ---
# Raises the route metric on any wired/WiFi interface that has an IP but fails
# internet reachability, so the LTE modem (metric 700) takes precedence.
verify_networks() {
    local check_url="http://connectivitycheck.gstatic.com/generate_204"
    for iface in eth0 wlan0; do
        [[ -e "/sys/class/net/$iface" ]] || continue
        local ip gw
        ip="$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)" || true
        gw="$(ip route show default dev "$iface" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')" || true
        [[ -n "${ip:-}" && -n "${gw:-}" ]] || continue

        local code
        code="$(curl -s --max-time 5 --interface "$iface" -o /dev/null -w "%{http_code}" "$check_url" 2>/dev/null || echo "000")"
        if [[ "$code" == "204" ]]; then
            LOG "$iface ($ip) connectivity OK"
        else
            LOG "$iface ($ip) has route but failed connectivity check (HTTP $code) — raising metric to 800"
            ip route del default dev "$iface" 2>/dev/null || true
            ip route add default via "$gw" dev "$iface" metric 800 \
                || LOG "WARNING: could not re-add $iface default route at metric 800"
        fi
    done
}

# --- Provisioning API ---
call_provisioning_api() {
    local iccid="$1"
    LOG "Calling provisioning API for ICCID $iccid..."

    local raw_response
    raw_response="$(curl -s --max-time 30 \
        -w '\n%{http_code}' \
        -X POST \
        -H "Content-Type: application/json" \
        -d "{\"iccid\":\"$iccid\"}" \
        "$PROVISIONING_URL")" \
        || FAIL "Provisioning API request failed (network error)"

    local http_code body
    http_code="$(echo "$raw_response" | tail -1)"
    body="$(echo "$raw_response" | head -n -1)"
    [[ "$http_code" == "200" ]] || FAIL "Provisioning API returned HTTP $http_code: $body"

    PROV_AUTH_KEY="$(echo "$body" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d['auth_key'])")" \
        || FAIL "Provisioning API response missing auth_key"
    PROV_SSH_KEY="$(echo "$body" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d['ssh_key'])")" \
        || FAIL "Provisioning API response missing ssh_key"
    PROV_DEVICE_NAME="$(echo "$body" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d['device_name'])")" \
        || FAIL "Provisioning API response missing device_name"
}

# True only when GitHub explicitly refuses the key — network/DNS errors return false
key_rejected() {
    local err
    err="$(GIT_SSH_COMMAND="$GIT_SSH" timeout 30 sudo -u "$PI_USER" \
        git ls-remote "$VCM_UPDATE_REPO" HEAD 2>&1 >/dev/null)" && return 1
    grep -qiE "permission denied|repository not found|access denied" <<<"$err"
}

# --- Credential Setup ---
ensure_credentials() {
    # A key file alone doesn't prove provisioning — legacy deploy_core.sh wrote its
    # own key to the same path. If GitHub rejects it, re-provision (needs ICCID).
    if [[ -f "$SSH_KEY_FILE" ]] && key_rejected; then
        if [[ -n "${ICCID:-}" ]]; then
            LOG "SSH key rejected by GitHub — moving aside to $SSH_KEY_FILE.rejected and re-provisioning"
            mv -f "$SSH_KEY_FILE" "$SSH_KEY_FILE.rejected"
            [[ -f "$SSH_KEY_FILE.pub" ]] && mv -f "$SSH_KEY_FILE.pub" "$SSH_KEY_FILE.rejected.pub"
        else
            LOG "WARNING: SSH key rejected by GitHub and no ICCID to re-provision with — keeping it"
        fi
    fi

    if [[ ! -f "$SSH_KEY_FILE" ]]; then
        LOG "SSH key absent — running full provisioning"
        call_provisioning_api "$ICCID"

        mkdir -p "/home/$PI_USER/.ssh"
        chmod 700 "/home/$PI_USER/.ssh"

        # Write SSH private key (Python print preserves embedded newlines;
        # command substitution strips trailing newlines, so we add one back)
        printf '%s\n' "$PROV_SSH_KEY" > "$SSH_KEY_FILE"
        chmod 600 "$SSH_KEY_FILE"

        cat > "/home/$PI_USER/.ssh/config" <<EOF
Host github.com
    IdentityFile $SSH_KEY_FILE
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
EOF
        chmod 600 "/home/$PI_USER/.ssh/config"
        ssh-keyscan -H github.com >> "/home/$PI_USER/.ssh/known_hosts" 2>/dev/null || true
        chown -R "$PI_USER:$PI_USER" "/home/$PI_USER/.ssh"

        # Root known_hosts for sudo git operations
        mkdir -p /root/.ssh
        ssh-keyscan -H github.com >> /root/.ssh/known_hosts 2>/dev/null || true

        # Cache auth_key for VCM_Update to use for RPi Connect signin
        printf '%s\n' "$PROV_AUTH_KEY" > "$AUTH_KEY_FILE"
        chmod 600 "$AUTH_KEY_FILE"

        # Set hostname from provisioning payload
        printf '%s\n' "$PROV_DEVICE_NAME" > "$HOSTNAME_FILE"
        local current_hn
        current_hn="$(hostname)"
        if [[ "$current_hn" != "$PROV_DEVICE_NAME" ]]; then
            LOG "Setting hostname to $PROV_DEVICE_NAME"
            hostnamectl set-hostname "$PROV_DEVICE_NAME" \
                || LOG "WARNING: hostnamectl failed — hostname unchanged"
            sed -i "s/^127\.0\.1\.1\s.*/127.0.1.1\t$PROV_DEVICE_NAME/" /etc/hosts || true
        fi
    else
        LOG "SSH key present — skipping credential provisioning"
        # Fleet migration: populate hostname cache from system if missing
        if [[ ! -f "$HOSTNAME_FILE" ]]; then
            hostname > "$HOSTNAME_FILE"
            LOG "Wrote hostname cache: $(cat "$HOSTNAME_FILE")"
        fi
    fi
}

# --- VCM_Update: clone or pull, (re)install its unit ---
setup_vcm_update() {
    # If VCM_Update has a partial .git (mid-clone power loss), remove so we re-clone cleanly
    if [[ -d "$VCM_UPDATE_DIR/.git" ]]; then
        sudo -u "$PI_USER" git -C "$VCM_UPDATE_DIR" rev-parse --git-dir &>/dev/null \
            || { LOG "VCM_Update repo corrupt — removing for fresh clone"; rm -rf "$VCM_UPDATE_DIR"; }
    fi

    if [[ ! -d "$VCM_UPDATE_DIR/.git" ]]; then
        LOG "Cloning VCM_Update to $VCM_UPDATE_DIR"
        GIT_SSH_COMMAND="$GIT_SSH" sudo -u "$PI_USER" \
            git clone "$VCM_UPDATE_REPO" "$VCM_UPDATE_DIR" \
            || FAIL "Failed to clone VCM_Update — check SSH key and network"
        chown -R "$PI_USER:$PI_USER" "$VCM_UPDATE_DIR"
    else
        LOG "Pulling VCM_Update..."
        GIT_SSH_COMMAND="$GIT_SSH" sudo -u "$PI_USER" \
            git -C "$VCM_UPDATE_DIR" pull --ff-only 2>/dev/null \
            || LOG "VCM_Update pull failed — continuing with existing code"
    fi

    # Always (re)install — install.sh is idempotent, and a run that died between
    # clone and install would otherwise leave vcm-update.service missing for good.
    local had_unit=0
    systemctl cat vcm-update.service &>/dev/null && had_unit=1
    LOG "Running VCM_Update install.sh"
    bash "$VCM_UPDATE_DIR/install.sh"

    if [[ "$had_unit" -eq 0 ]]; then
        # Newly installed units aren't part of this boot's transaction — start it now.
        # --no-block avoids deadlock: vcm-update has After=vcm-deploy.service.
        LOG "Starting vcm-update.service..."
        systemctl start --no-block vcm-update.service 2>/dev/null || true
    fi
}

# --- Fleet Password ---
set_fleet_password() {
    if echo "pi:GreenHorseNoodleSalad33#" | chpasswd; then
        LOG "Fleet password set for pi user"
    else
        LOG "WARNING: could not set fleet password (does the pi user exist?)"
    fi
}

# === Main ===
LOG "=== VCM Deploy starting ==="
loginctl enable-linger "$PI_USER" 2>/dev/null || true
detect_iccid
verify_networks
set_fleet_password
ensure_credentials
setup_vcm_update
LOG "=== VCM Deploy complete ==="
