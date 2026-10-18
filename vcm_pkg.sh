#!/usr/bin/env bash
# vcm_pkg.sh — package installs that survive venue networks.
#
#   vcm_pkg.sh apt <repos> -- <apt-get args>    repos: comma list of debian,security,raspberrypi
#   vcm_pkg.sh pip -- <pip3 args>
#
# Venue firewalls block or *replace* package traffic (a Sonicwall served its block page
# in place of apt's files). For each repository this tries, over Wi-Fi/Ethernet: the
# source that worked last time, the default, the default over HTTPS (content can't be
# replaced without breaking TLS), then known mirrors — and only then the same over LTE,
# by routing just that mirror's addresses via wwan0 for the duration of the run.
#
# A source counts as working only if apt's own checks pass: every index is signed by the
# repository's key and every file is checked against it, so a substituted page fails
# verification instead of being used — and any mirror is as safe as the default. apt only
# *warns* about such failures (and keeps old lists), so its output is checked, not just
# its exit code. pip is HTTPS-only: a replaced response fails certificate checks.
set -uo pipefail

LOG() { echo "[vcm-pkg $(date -Is)] $*"; }

STATE="/var/lib/vcm/pkg-sources"      # repo=url that last worked
WORK="$(mktemp -d /tmp/vcm-pkg.XXXXXX)"
LTE_ROUTES=()                          # /32 routes added via wwan0 this run
mkdir -p "$(dirname "$STATE")"

cleanup() {
    local r
    for r in "${LTE_ROUTES[@]+"${LTE_ROUTES[@]}"}"; do ip route del "$r" dev wwan0 2>/dev/null || true; done
    rm -rf "$WORK"
}
trap cleanup EXIT

CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-bookworm}")"
ARCH="$(dpkg --print-architecture)"
COMPONENTS="main contrib non-free non-free-firmware"

# Candidate sources, in order (the default first). Mirrors checked from Perth 2026-10-18:
# all serve the signed bookworm indexes over HTTPS.
repo_candidates() {
    case "$1" in
        debian)      echo "http://deb.debian.org/debian https://deb.debian.org/debian https://mirror.aarnet.edu.au/debian https://mirror.linux.org.au/debian https://debian.mirror.digitalpacific.com.au/debian" ;;
        security)    echo "http://deb.debian.org/debian-security https://deb.debian.org/debian-security https://security.debian.org/debian-security https://mirror.aarnet.edu.au/debian-security" ;;
        raspberrypi) echo "http://archive.raspberrypi.com/debian https://archive.raspberrypi.com/debian" ;;
    esac
}
repo_line() {   # repo url -> one sources.list line
    case "$1" in
        debian)      echo "deb [arch=$ARCH] $2 $CODENAME $COMPONENTS"$'\n'"deb [arch=$ARCH] $2 $CODENAME-updates $COMPONENTS" ;;
        security)    echo "deb [arch=$ARCH] $2 $CODENAME-security $COMPONENTS" ;;
        raspberrypi) echo "deb [arch=$ARCH] $2 $CODENAME main" ;;
    esac
}

# Why an apt-get update output failed, or empty if it didn't
apt_failure() {
    local out="$1" rc="$2"
    if grep -qE "Clearsigned file isn't valid|NOSPLIT|Hash Sum mismatch|File has unexpected size|GPG error|is not signed|NO_PUBKEY|BADSIG" <<<"$out"; then
        echo "response failed verification (replaced by a firewall?)"
    elif grep -qE "^(W|E): (Failed to fetch|Some index files failed)" <<<"$out"; then
        local why
        why="$(grep -m1 -oiE "(could not connect to [^ ]+|connection failed|connection timed out|could not resolve [^ ]+|temporary failure resolving [^ ]+|[0-9]{3} +[A-Za-z][A-Za-z ]+)" <<<"$out" | head -1)" || true
        echo "unreachable (${why:-fetch failed})"
    elif [[ "$rc" -ne 0 ]]; then
        echo "apt-get update exit $rc"
    fi
}

apt_try() {   # repo url -> 0 if usable; sets LAST_WHY
    local repo="$1" url="$2" list="$WORK/try.list" out rc
    repo_line "$repo" "$url" > "$list"
    out="$(DEBIAN_FRONTEND=noninteractive apt-get update \
        -o Dir::Etc::SourceList="$list" -o Dir::Etc::SourceParts=- \
        -o APT::Get::List-Cleanup=0 -o Acquire::Languages=none \
        -o Acquire::ForceIPv4=true -o Acquire::http::Timeout=15 -o Acquire::https::Timeout=15 \
        -o Acquire::Retries=0 2>&1)"; rc=$?
    LAST_WHY="$(apt_failure "$out" "$rc" | head -1)"
    [[ -z "$LAST_WHY" ]]
}

lte_gateway() { ip route show default dev wwan0 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}'; }

# Route one host's addresses over LTE for the rest of this run
route_host_via_lte() {
    local host="$1" gw ip
    gw="$(lte_gateway)"; [[ -n "$gw" ]] || return 1
    for ip in $(getent ahostsv4 "$host" | awk '{print $1}' | sort -u); do
        case "$ip" in 127.*|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|169.254.*) continue ;; esac
        ip route replace "$ip/32" via "$gw" dev wwan0 2>/dev/null && LTE_ROUTES+=("$ip/32")
    done
    [[ "${#LTE_ROUTES[@]}" -gt 0 ]]
}
host_of() { sed -E 's#^[a-z]+://([^/:]+).*#\1#' <<<"$1"; }

remembered() { sed -n "s#^$1=##p" "$STATE" 2>/dev/null | head -1; }
remember() {
    { grep -v "^$1=" "$STATE" 2>/dev/null || true; echo "$1=$2"; } > "$STATE.new" && mv -f "$STATE.new" "$STATE"
}

# Pick a working source for one repository; prints the url
select_source() {
    local repo="$1" last cands url tried=()
    last="$(remembered "$repo")"
    cands="$last $(repo_candidates "$repo")"
    for url in $cands; do
        [[ " ${tried[*]-} " == *" $url "* ]] && continue; tried+=("$url")
        if apt_try "$repo" "$url"; then
            [[ "$url" != "$last" ]] && LOG "apt $repo: using $url (over Wi-Fi/Ethernet)" >&2
            remember "$repo" "$url"; echo "$url"; return 0
        fi
        LOG "apt $repo: $url — ${LAST_WHY}" >&2
    done
    # Last resort: LTE, HTTPS sources first (at most two — every attempt costs LTE data)
    if [[ -n "$(lte_gateway)" ]]; then
        local n=0
        for url in $(tr ' ' '\n' <<<"${tried[*]}" | grep '^https://'); do
            (( n++ >= 2 )) && break
            route_host_via_lte "$(host_of "$url")" || continue
            if apt_try "$repo" "$url"; then
                LOG "apt $repo: using $url over LTE — no source worked over Wi-Fi/Ethernet" >&2
                echo "$url"; return 0
            fi
            LOG "apt $repo: $url over LTE — ${LAST_WHY}" >&2
        done
    fi
    LOG "WARNING: apt $repo: no working source — using the lists already on the core" >&2
    return 1
}

cmd_apt() {
    local repos="$1"; shift; [[ "${1:-}" == "--" ]] && shift
    local active="$WORK/active.list" repo url failed=0
    : > "$active"
    for repo in ${repos//,/ }; do
        if url="$(select_source "$repo")"; then
            repo_line "$repo" "$url" >> "$active"
        else
            failed=1
            # Keep whatever this repo's lists on disk came from, so installs can still try
            url="$(remembered "$repo")"; url="${url:-$(repo_candidates "$repo" | awk '{print $1}')}"
            repo_line "$repo" "$url" >> "$active"
        fi
    done
    DEBIAN_FRONTEND=noninteractive apt-get "$@" \
        -o Dir::Etc::SourceList="$active" -o Dir::Etc::SourceParts=- \
        -o Acquire::ForceIPv4=true -o Dpkg::Options::="--force-confold"
    local rc=$?
    [[ "$rc" -eq 0 && "$failed" -eq 1 ]] && rc=2   # installed, but a repo couldn't be refreshed
    return "$rc"
}

cmd_pip() {
    [[ "${1:-}" == "--" ]] && shift
    local how out rc
    # default config (PyPI + piwheels), then each index alone (ignoring pip's config)
    for how in "default" "https://www.piwheels.org/simple" "https://pypi.org/simple"; do
        if [[ "$how" == "default" ]]; then
            out="$(pip3 "$@" --timeout 20 --retries 0 2>&1)"; rc=$?
        else
            out="$(pip3 "$@" --isolated --index-url "$how" --timeout 20 --retries 0 2>&1)"; rc=$?
        fi
        if [[ "$rc" -eq 0 ]]; then
            [[ "$how" != "default" ]] && LOG "pip: used $how (over Wi-Fi/Ethernet)"
            return 0
        fi
        LOG "pip: $how failed — $(grep -m1 -oE "(SSLError|CERTIFICATE_VERIFY_FAILED|ConnectTimeout|Connection to [^ ]+ timed out|NewConnectionError|No matching distribution[^.]*|HTTP error [0-9]+)" <<<"$out" || tail -1 <<<"$out")"
    done
    if [[ -n "$(lte_gateway)" ]]; then
        local h
        for h in pypi.org files.pythonhosted.org www.piwheels.org archive1.piwheels.org; do route_host_via_lte "$h" || true; done
        out="$(pip3 "$@" --timeout 20 --retries 0 2>&1)"; rc=$?
        if [[ "$rc" -eq 0 ]]; then LOG "pip: installed over LTE — no index worked over Wi-Fi/Ethernet"; return 0; fi
        LOG "pip: failed over LTE too — $(tail -1 <<<"$out")"
    fi
    return 1
}

case "${1:-}" in
    apt) shift; cmd_apt "$@" ;;
    pip) shift; cmd_pip "$@" ;;
    *)   echo "usage: vcm_pkg.sh apt <debian,security,raspberrypi> -- <apt-get args> | pip -- <pip3 args>" >&2; exit 64 ;;
esac
