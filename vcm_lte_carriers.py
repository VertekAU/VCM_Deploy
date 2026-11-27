#!/usr/bin/env python3
"""VCM LTE carrier ranking — installed as /usr/local/sbin/vcm_lte_carriers.

The Twilio Super SIM can use every Australian carrier, and the modem picks one by
itself. Left alone it can settle on one that refuses the SIM (Criterion, Nov 2026:
Vodafone, reject cause 15, LTE down for days while Telstra worked). This keeps a
ranked list of the carriers that work at this site and steers the modem along it:

  survey    Try each carrier the modem can see (signal, latency, loss) and rank
            them. Takes LTE down for a few minutes, so it only runs at night after
            maintenance, or (trial mode) while another connection carries the Core.
  nightly   Run by vcm-lte-carriers.timer. After the maintenance reboot: a survey
            when one is due, otherwise move back to the top carrier if the Core
            failed over to another one during the day.
  failover  Run by the LTE watchdog when LTE is down for a network reason. A carrier
            that drops sits out for an hour; LTE moves to the best carrier that
            isn't sitting out. A working connection is never moved during the day:
            while connected, the modem can't measure other carriers.
  report    Write /run/vertek/lte-status.json (carrier, signal, cell, ranking) for VCM.
  status    Print the ranking and what the Core is on.
  abort     Hand carrier choice back to the modem and reconnect (watchdog clean-up).

Every move is: take vertek-lte down, register on the carrier, at once hand selection
back to the modem (automatic), bring vertek-lte up. The modem stays where it was put
but is never pinned, so if our choice fails the modem can still find another carrier
by itself, exactly as without this tool.

/etc/vertek/lte-carriers.conf: mode=off (default) | trial | on.
  off    report only.
  trial  survey every 4 hours, only while Wi-Fi/Ethernet carries the Core; failover on.
  on     survey weekly at night (sooner if the top carrier keeps dropping); failover on.
"""
import datetime
import fcntl
import json
import os
import re
import signal as sig
import subprocess
import sys
import time

CONF = "/etc/vertek/lte-carriers.conf"
STATE = "/var/lib/vertek/lte-carriers.json"
STATUS = "/run/vertek/lte-status.json"
MARKER = "/run/vertek/lte-survey.active"   # the watchdog leaves LTE alone while it exists
LOCK = "/run/vertek/lte-carriers.lock"
CORE_CONF = "/home/pi/vcm/config/core.conf"
NM_CONN = "vertek-lte"
QMI = ["qmicli", "-p", "-d", "/dev/cdc-wdm0"]
BUSY_UNITS = ["vcm-modem-reconnect.service", "vcm-deploy.service", "vcm-update.service",
              "vcm-lte-watchdog.service"]

COOLDOWN = 3600                 # a carrier that dropped or failed sits out this long
SURVEY_EVERY = 7 * 86400
REST = SURVEY_EVERY - 12 * 3600  # a carrier that refused the SIM waits for the next weekly survey
TRIAL_SURVEY_EVERY = 4 * 3600
SURVEY_BUDGET = 15 * 60
MARGIN = 3.0                    # a new top carrier must beat the old one by this many points
DROP_WINDOW = 7 * 86400
DROP_PENALTY, DROP_PENALTY_MAX = 2.0, 10.0
RESURVEY_DROPS = 3              # top carrier dropped this often since the last survey: re-survey
REGISTER_TIMEOUT = 60
FAILOVER_EVERY = 10 * 60
FAILOVER_TRIES = 3
NIGHT_FROM, NIGHT_TO = 30 * 60, 3 * 3600   # after maintenance_time
REPORT_EVERY = 9 * 60


def log(msg):
    print(f"[vcm-lte-carriers {datetime.datetime.now().astimezone().isoformat(timespec='seconds')}] {msg}",
          flush=True)


def run(cmd, timeout=30):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired:
        return 124, "timed out"
    except OSError as e:
        return 127, str(e)


def last_line(out):
    lines = [l.strip() for l in out.strip().splitlines() if l.strip()]
    return lines[-1][:160] if lines else ""


# ---------------------------------------------------------------- config and state

def mode():
    try:
        with open(CONF) as f:
            for line in f:
                k, _, v = line.partition("=")
                if k.strip() == "mode" and v.strip() in ("off", "trial", "on"):
                    return v.strip()
    except OSError:
        pass
    return "off"


def load():
    st = {}
    try:
        with open(STATE) as f:
            st = json.load(f)
    except (OSError, ValueError):
        pass
    st.setdefault("carriers", {})
    st.setdefault("ranking", [])
    st.setdefault("surveys", [])
    for k in ("current", "night_done"):
        st.setdefault(k, None)
    for k in ("last_survey", "last_failover"):
        st.setdefault(k, 0)
    return st


def save(st):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(st, f, indent=1, sort_keys=True)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, STATE)


def car(st, plmn):
    c = st["carriers"].setdefault(plmn, {})
    for k, v in (("name", plmn), ("score", None), ("last_ok", 0), ("cooldown_until", 0),
                 ("rested_until", 0), ("drops", []), ("last", None), ("note", "")):
        c.setdefault(k, v)
    return c


KNOWN = {"50501": "Telstra", "50502": "Optus", "50503": "Vodafone"}


def name(st, plmn):
    n = st["carriers"].get(plmn, {}).get("name")
    return (n if n and n != plmn else KNOWN.get(plmn)) or plmn or "?"


def hhmm(t):
    return datetime.datetime.fromtimestamp(t).strftime("%H:%M")


# ---------------------------------------------------------------- modem

def modem():
    rc, out = run(["mmcli", "-m", "any", "--output-keyvalue"], 20)
    kv = {}
    if rc == 0:
        for line in out.splitlines():
            k, sep, v = line.partition(":")
            if sep:
                kv[k.strip()] = v.strip()
    clean = lambda v: None if v in (None, "", "--") else v
    return {
        "present": rc == 0,
        "state": clean(kv.get("modem.generic.state")),
        "operator": clean(kv.get("modem.3gpp.operator-code")),
        "reg": clean(kv.get("modem.3gpp.registration-state")),
        "access": clean(kv.get("modem.generic.access-technologies.value[1]")),
        "modes": clean(kv.get("modem.generic.current-modes")) or "",
        "supported": [v for k, v in kv.items() if k.startswith("modem.generic.supported-modes.value")],
    }


def registered(m):
    return m["reg"] in ("home", "roaming") and m["operator"] is not None


def signal():
    """One-shot LTE signal (no ModemManager polling left running)."""
    rc, out = run(QMI + ["--nas-get-signal-info"], 20)
    s = {}
    if rc == 0 and "LTE:" in out:
        lte = out.split("LTE:", 1)[1]
        for k, v in re.findall(r"(RSSI|RSRQ|RSRP|SNR): '(-?[\d.]+)", lte):
            s.setdefault(k.lower(), float(v))
    return s


def cell():
    rc, out = run(QMI + ["--nas-get-cell-location-info"], 20)
    c = {}
    if rc == 0:
        intra = out.split("Interfrequency", 1)[0]
        for key, pat in (("plmn", r"PLMN: '(\d+)'"), ("tac", r"Tracking Area Code: '(\d+)'"),
                         ("cell_id", r"Global Cell ID: '(\d+)'"),
                         ("earfcn", r"Absolute RF Channel Number: '(\d+)'"),
                         ("band", r"\(E-UTRA band (\d+)")):
            mt = re.search(pat, intra)
            if mt:
                c[key] = mt.group(1)
    return c


def wwan_ip():
    rc, out = run(["ip", "-4", "-o", "addr", "show", "wwan0"], 10)
    mt = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", out)
    return mt.group(1) if mt and not mt.group(1).startswith("169.254.") else None


def data_check():
    """Latency and loss over wwan0 (~1 kB)."""
    for host in ("8.8.8.8", "1.1.1.1"):
        rc, out = run(["ping", "-I", "wwan0", "-c", "5", "-i", "0.4", "-W", "3", "-q", host], 30)
        loss = re.search(r"([\d.]+)% packet loss", out)
        rtt = re.search(r"= [\d.]+/([\d.]+)/", out)
        if loss and float(loss.group(1)) < 100:
            return {"ok": True, "loss_pct": float(loss.group(1)),
                    "rtt_ms": float(rtt.group(1)) if rtt else None}
    rc, out = run(["curl", "-s", "--interface", "wwan0", "--max-time", "10", "-o", "/dev/null",
                   "-w", "%{http_code} %{time_total}",
                   "http://connectivitycheck.gstatic.com/generate_204"], 15)
    parts = out.split()
    if rc == 0 and parts and parts[0] == "204":
        return {"ok": True, "loss_pct": None, "rtt_ms": round(float(parts[1]) * 1000, 1)}
    return {"ok": False, "loss_pct": 100.0, "rtt_ms": None}


def other_route_ok():
    """Is the Core online without LTE (Wi-Fi or Ethernet passes traffic)?"""
    rc, out = run(["ip", "-4", "route", "show", "default"], 10)
    for dev in re.findall(r"dev (\S+)", out):
        if dev == "wwan0":
            continue
        rc, code = run(["curl", "-s", "--interface", dev, "--max-time", "8", "-o", "/dev/null",
                        "-w", "%{http_code}", "http://connectivitycheck.gstatic.com/generate_204"], 12)
        if code.strip() == "204":
            return True
    return False


def wait_for(pred, secs, step=2):
    end = time.time() + secs
    while time.time() < end:
        if pred():
            return True
        time.sleep(step)
    return pred()


def nm_down():
    run(["nmcli", "connection", "down", NM_CONN], 40)
    wait_for(lambda: modem()["state"] not in ("connected", "disconnecting"), 15)


def nm_up():
    run(["nmcli", "--wait", "90", "connection", "up", NM_CONN], 100)
    return wait_for(lambda: wwan_ip() is not None, 30)


def release():
    """Automatic network selection again. Needs the modem disconnected. The modem stays
    on its current carrier (bench, Nov 2026) — it just isn't held there any more."""
    for _ in range(3):
        rc, out = run(["mmcli", "-m", "any", "--3gpp-register-home", "--timeout=30"], 45)
        if rc == 0:
            return True
        time.sleep(5)
    log(f"WARNING: couldn't hand carrier choice back to the modem: {last_line(out)}")
    return False


def move(st, plmn):
    """Register on plmn, release to automatic, reconnect. (ok, reason)."""
    nm_down()
    rc, out = run(["mmcli", "-m", "any", f"--3gpp-register-in-operator={plmn}",
                   f"--timeout={REGISTER_TIMEOUT}"], REGISTER_TIMEOUT + 20)
    on = wait_for(lambda: (lambda m: registered(m) and m["operator"] == plmn)(modem()),
                  # mmcli reports success at once while the modem is still on the old
                  # carrier; the switch itself takes 15-25 s (bench, 26 Nov 2026)
                  60 if rc == 0 else 3)
    why = "" if on else (last_line(out) if rc != 0 else "registration didn't hold")
    release()
    up = nm_up()
    if not on:
        return False, why or "not registered"
    if not up:
        return False, "registered but no LTE address"
    # Released to automatic, a carrier that accepted the registration but won't give
    # service hands the modem on to another one (Rink46, 27 Nov 2026: Vodafone accepted,
    # then the modem was on Optus and Optus's numbers were filed as Vodafone's).
    now_on = modem()["operator"]
    if now_on != plmn:
        return False, f"didn't stay on it (moved to {KNOWN.get(now_on, now_on or 'nothing')})"
    return True, ""


def ensure_4g_only():
    """3G is switched off in Australia; a modem allowed 3G wastes time looking for it.
    Stored in the modem, so this only acts once. Briefly drops the data session."""
    m = modem()
    if not m["present"] or m["modes"].startswith("allowed: 4g;"):
        return
    if not any(s.startswith("allowed: 4g; preferred: none") for s in m["supported"]):
        return
    rc, out = run(["mmcli", "-m", "any", "--set-allowed-modes=4g"], 30)
    if rc == 0:
        log(f"Modem set to 4G only (was: {m['modes'] or 'unknown'})")
    else:
        log(f"WARNING: couldn't set the modem to 4G only: {last_line(out)}")
    if not wait_for(lambda: wwan_ip() is not None, 30):
        nm_up()


def scan():
    """Carriers the modem can see. ~2 minutes; the data session stays up. ModemManager's
    own scan (mmcli --3gpp-scan) fails on the EG25-G with 'unknown error'."""
    rc, out = run(QMI + ["--nas-network-scan"], 220)
    if rc != 0 or "Network scan result: success" not in out:
        log(f"Network scan failed: {last_line(out)}")
        return None
    nets = {}
    for body in re.split(r"\nNetwork \[\d+\]:", out)[1:]:
        f = dict(re.findall(r"\n\s*([A-Za-z ]+): '([^']*)'", "\n" + body))
        if "MCC" not in f or "MNC" not in f:
            continue
        n = nets.setdefault((f["MCC"], f["MNC"]), {"rats": set()})
        if "Status" in f:
            n["status"] = [s.strip() for s in f["Status"].split(",")]
        if "Description" in f:
            n["name"] = f["Description"]
        if "RAT" in f:
            n["rats"].add(f["RAT"])
        if "MCC with PCS digit" in f:
            n["pcs"] = f["MCC with PCS digit"] == "yes"
    result = []
    for (mcc, mnc), n in nets.items():
        plmn = mcc + mnc.zfill(3 if n.get("pcs") else 2)
        result.append({"plmn": plmn, "name": n.get("name", plmn),
                       "lte": "lte" in n["rats"] or not n["rats"],
                       "forbidden": "forbidden" in n.get("status", [])})
    return result


# ---------------------------------------------------------------- ranking

def measure():
    time.sleep(5)   # let the radio settle on the new cell
    m = {"at": int(time.time())}
    m.update(signal())
    m["cell"] = cell()
    d = data_check()
    m.update(data_ok=d["ok"], rtt_ms=d["rtt_ms"], loss_pct=d["loss_pct"])
    return m


def score(m):
    """Signal quality first (SNR dominates throughput), then strength, latency and loss.
    The Super SIM's traffic goes back through Twilio's core, so ~500 ms is normal on every
    carrier (bench, Nov 2026); latency only costs up to 6 points, 1 per 100 ms over 150.
    Bench Telstra: SNR 3.8 dB, RSRP -116 dBm, 513 ms -> 3.8 + 6 - 3.6 = 6.2."""
    if not m or not m.get("data_ok"):
        return None
    clamp = lambda v, lo, hi: max(lo, min(hi, v))
    snr = m.get("snr")
    rsrp = m.get("rsrp")
    pts = clamp(snr if snr is not None else -10, -10, 30)
    pts += (clamp(rsrp if rsrp is not None else -140, -140, -60) + 140) / 4
    if m.get("rtt_ms"):
        pts -= min(6.0, max(0.0, m["rtt_ms"] - 150) / 100)
    if m.get("loss_pct"):
        pts -= m["loss_pct"] / 10
    return round(pts, 1)


def recent_drops(c, now, since=None):
    lo = max(now - DROP_WINDOW, since or 0)
    return [d for d in c["drops"] if d >= lo]


def effective(st, plmn, now):
    c = car(st, plmn)
    if c["score"] is None:
        return None
    return round(c["score"] - min(DROP_PENALTY_MAX, DROP_PENALTY * len(recent_drops(c, now))), 1)


def rank(st, now):
    prev_top = st["ranking"][0] if st["ranking"] else None
    usable = [p for p in st["carriers"]
              if car(st, p)["score"] is not None and car(st, p)["rested_until"] <= now]
    usable.sort(key=lambda p: effective(st, p, now), reverse=True)
    # Hysteresis: don't hand the top spot over for a marginal difference
    if prev_top in usable and usable[0] != prev_top \
            and effective(st, usable[0], now) < effective(st, prev_top, now) + MARGIN:
        usable.remove(prev_top)
        usable.insert(0, prev_top)
    st["ranking"] = usable


def ranking_text(st, now):
    parts = [f"{name(st, p)} {effective(st, p, now)}" for p in st["ranking"]]
    rested = [f"{name(st, p)} (until {datetime.datetime.fromtimestamp(c['rested_until']):%d %b}: {c['note']})"
              for p, c in st["carriers"].items() if c.get("rested_until", 0) > now]
    txt = ", ".join(parts) or "none"
    return txt + (f"; resting {', '.join(rested)}" if rested else "")


def record(st, plmn, m, now):
    c = car(st, plmn)
    c["last"] = m
    c["score"] = score(m)
    if m.get("data_ok"):
        c["last_ok"] = now
        c["note"] = ""
    else:
        c["note"] = "no data"


def settle(st, now):
    """End on the top carrier that works; failing that, wherever the modem gets data."""
    cur = modem()["operator"]
    for p in st["ranking"]:
        if p == cur and wwan_ip() and data_check()["ok"]:
            return p
        ok, why = move(st, p)
        if ok and data_check()["ok"]:
            return p
        log(f"{name(st, p)}: {why or 'no data'}")
        car(st, p)["cooldown_until"] = now + COOLDOWN
    release()
    if not wwan_ip():
        nm_up()
    return modem()["operator"]


def survey(st, why):
    now = int(time.time())
    start = modem()
    if not start["present"]:
        log("Survey skipped: no modem")
        return
    log(f"Carrier survey ({why}) — LTE drops for a few minutes")
    with open(MARKER, "w") as f:
        f.write(f"{now} {start['operator'] or '-'}\n")
    try:
        ensure_4g_only()
        orig = modem()["operator"]
        nets = scan()
        if nets is None:
            # The scan needs the radio idle; a Core on LTE alone rarely is ("abort", bench
            # with Wi-Fi off). Try the carriers we know of instead — one that isn't here
            # just fails to register.
            cands = list(dict.fromkeys(([orig] if orig else []) + st["ranking"]
                                       + list(st["carriers"]) + list(KNOWN)))
        else:
            for n in nets:
                car(st, n["plmn"])["name"] = n["name"]
            cands = [n["plmn"] for n in nets if n["lte"] and not n["forbidden"]]
            seen = ", ".join(f"{n['name']}{'' if n['lte'] else ' (no 4G)'}{' (forbidden)' if n['forbidden'] else ''}"
                             for n in nets)
            log(f"Visible: {seen or 'none'}")
        results = {}
        if orig and orig in cands and wwan_ip():
            results[orig] = measure()        # no move needed for the carrier we're on
        deadline = now + SURVEY_BUDGET - 180
        for p in cands:
            if p in results:
                continue
            c = car(st, p)
            if c["rested_until"] > now:
                log(f"{c['name']}: skipped, resting ({c['note']})")
                continue
            if time.time() > deadline:
                log(f"Out of time — {c['name']} not tried")
                continue
            ok, why_not = move(st, p)
            if not ok:
                c["score"] = None
                c["last"] = {"at": int(time.time()), "data_ok": False, "error": why_not}
                if why_not.startswith("registered"):
                    c["note"] = why_not
                else:
                    c["note"] = f"refused: {why_not}"
                    c["rested_until"] = now + REST
                log(f"{c['name']}: {c['note']}")
                continue
            m = measure()
            seen_on = m["cell"].get("plmn")
            if seen_on and seen_on != p:
                # Moved off during the measurement: these numbers are another carrier's
                c["score"] = None
                c["last"] = {"at": int(time.time()), "data_ok": False, "error": "moved off"}
                c["note"] = f"refused: didn't stay on it (moved to {KNOWN.get(seen_on, seen_on)})"
                c["rested_until"] = now + REST
                log(f"{c['name']}: {c['note']}")
                continue
            results[p] = m
        for p, m in results.items():
            record(st, p, m, now)
            m2 = st["carriers"][p]
            log(f"{m2['name']}: score {m2['score']} (SNR {m.get('snr')} dB, RSRP {m.get('rsrp')} dBm, "
                f"{m.get('rtt_ms')} ms, {m.get('loss_pct')}% loss, band {m['cell'].get('band', '?')})")
        rank(st, now)
        st["last_survey"] = now
        st["surveys"] = (st["surveys"] + [{"at": now, "why": why, "results": results}])[-10:]
        final = settle(st, now)
        st["current"] = final
        save(st)
        log(f"Ranking: {ranking_text(st, now)} — now on {name(st, final)}")
    finally:
        try:
            os.remove(MARKER)
        except OSError:
            pass
        if not wwan_ip():
            nm_up()


def back_to_top(st):
    """After maintenance: if the day's fail-over left us below the top carrier, try it."""
    now = int(time.time())
    cur = modem()["operator"]
    top = next((p for p in st["ranking"] if car(st, p)["rested_until"] <= now), None)
    if not top or not cur or top == cur or not wwan_ip():
        return
    log(f"After maintenance: on {name(st, cur)}, trying {name(st, top)} again")
    with open(MARKER, "w") as f:
        f.write(f"{now} {cur}\n")
    try:
        here = measure()
        record(st, cur, here, now)
        ok, why = move(st, top)
        there = measure() if ok else {"at": now, "data_ok": False, "error": why}
        record(st, top, there, now)
        s_top, s_cur = score(there), score(here)
        if s_top is None or (s_cur is not None and s_top < s_cur):
            log(f"{name(st, top)} {s_top} vs {name(st, cur)} {s_cur} — back to {name(st, cur)}")
            if modem()["operator"] != cur or not wwan_ip():
                move(st, cur)
            car(st, top)["cooldown_until"] = now + COOLDOWN
        else:
            log(f"Back on {name(st, top)} ({s_top} vs {s_cur} on {name(st, cur)})")
        rank(st, now)
        st["current"] = modem()["operator"]
        save(st)
    finally:
        try:
            os.remove(MARKER)
        except OSError:
            pass
        if not wwan_ip():
            nm_up()


# ---------------------------------------------------------------- commands

def lock(block=False):
    os.makedirs(os.path.dirname(LOCK), exist_ok=True)
    fd = open(LOCK, "w")
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | (0 if block else fcntl.LOCK_NB))
    except OSError:
        fd.close()
        return None
    return fd


def busy():
    for u in BUSY_UNITS:
        rc, out = run(["systemctl", "show", "-p", "ActiveState", "--value", u], 10)
        if out.strip() == "activating":
            return u
    return None


def night_key(now):
    """Date of tonight's maintenance if we're in the window after it, else None."""
    hm = "01:30"
    try:
        with open(CORE_CONF) as f:
            hm = json.load(f).get("maintenance_time") or hm
    except (OSError, ValueError):
        pass
    try:
        h, m = map(int, hm.split(":"))
    except ValueError:
        h, m = 1, 30
    t = datetime.datetime.fromtimestamp(now)
    for days in (0, 1):
        mt = (t - datetime.timedelta(days=days)).replace(hour=h, minute=m, second=0, microsecond=0)
        if NIGHT_FROM <= (t - mt).total_seconds() <= NIGHT_TO:
            return mt.strftime("%Y-%m-%d")
    return None


def cmd_nightly(st):
    md = mode()
    u = busy()
    if u:
        return 0
    cmd_report(st, ok=False)
    if md == "off":
        return 0
    now = int(time.time())
    if md == "trial":
        if now - st["last_survey"] < TRIAL_SURVEY_EVERY:
            return 0
        if not other_route_ok():
            return 0        # trial never takes LTE down on a Core that depends on it
        survey(st, "trial")
        return 0
    key = night_key(now)
    if not key or st["night_done"] == key:
        return 0
    st["night_done"] = key
    save(st)
    top = st["ranking"][0] if st["ranking"] else None
    if not st["last_survey"]:
        why = "first survey"
    elif now - st["last_survey"] >= SURVEY_EVERY:
        why = "weekly"
    elif top and len(recent_drops(car(st, top), now, st["last_survey"])) >= RESURVEY_DROPS:
        why = f"{name(st, top)} dropped {len(recent_drops(car(st, top), now, st['last_survey']))} times"
    elif not st["ranking"]:
        why = "no carrier ranked"
    else:
        why = None
    if why:
        survey(st, why)
    else:
        back_to_top(st)
    return 0


def cmd_failover(st, reason):
    """0: LTE restored on another carrier; 1: none worked or none available;
    3: not enabled; 4: tried within the last FAILOVER_EVERY."""
    if mode() == "off":
        return 3
    now = int(time.time())
    if now - st["last_failover"] < FAILOVER_EVERY:
        return 4
    st["last_failover"] = now
    dropped = st["current"]
    if dropped:
        c = car(st, dropped)
        c["cooldown_until"] = now + COOLDOWN
        c["drops"] = recent_drops(c, now) + [now]
    order = st["ranking"] or sorted((p for p in st["carriers"] if car(st, p)["last_ok"]),
                                    key=lambda p: car(st, p)["last_ok"], reverse=True)
    cands = [p for p in order if car(st, p)["cooldown_until"] <= now and car(st, p)["rested_until"] <= now]
    if not cands:
        waiting = [(car(st, p)["cooldown_until"], p) for p in order if car(st, p)["rested_until"] <= now]
        nxt = f"; next try {name(st, min(waiting)[1])} at {hhmm(min(waiting)[0])}" if waiting else ""
        on = f" on {name(st, dropped)}" if dropped else ""
        log(f"LTE down{on} ({reason}) — no other carrier to try, the modem chooses{nxt}")
        save(st)
        return 1
    log(f"LTE down on {name(st, dropped)} ({reason}) — {name(st, dropped)} sits out until "
        f"{hhmm(now + COOLDOWN)}; trying {', '.join(name(st, p) for p in cands[:FAILOVER_TRIES])}"
        if dropped else f"LTE down ({reason}) — trying {', '.join(name(st, p) for p in cands[:FAILOVER_TRIES])}")
    for p in cands[:FAILOVER_TRIES]:
        ok, why = move(st, p)
        if ok and data_check()["ok"]:
            st["current"] = p
            car(st, p)["last_ok"] = int(time.time())
            save(st)
            log(f"LTE restored on {name(st, p)}")
            return 0
        car(st, p)["cooldown_until"] = int(time.time()) + COOLDOWN
        log(f"{name(st, p)}: {why or 'no data'} — sits out until {hhmm(int(time.time()) + COOLDOWN)}")
    save(st)
    return 1


def cmd_report(st, ok=False, force=False):
    try:
        if not force and time.time() - os.path.getmtime(STATUS) < REPORT_EVERY:
            return 0
    except OSError:
        pass
    now = int(time.time())
    m = modem()
    out = {"at": now, "mode": mode(), "modem": m["state"], "operator": m["operator"],
           "operator_name": name(st, m["operator"]) if m["operator"] else None,
           "access": m["access"], "modes": m["modes"], "lte_ip": bool(wwan_ip())}
    if m["present"]:
        out.update(signal())
        out["cell"] = cell()
    if ok and m["operator"] and out["lte_ip"]:
        # Remember the carrier that works (a fail-over starts from it). Saved when it
        # changes or hourly, not every report — spares the SD card
        c = car(st, m["operator"])
        if st["current"] != m["operator"] or now - c["last_ok"] >= 3600:
            c["last_ok"] = now
            st["current"] = m["operator"]
            save(st)
    out["ranking"] = [{"plmn": p, "name": name(st, p), "score": car(st, p)["score"],
                       "effective": effective(st, p, now),
                       "cooldown_until": car(st, p)["cooldown_until"] or None,
                       "drops_7d": len(recent_drops(car(st, p), now))} for p in st["ranking"]]
    out["resting"] = [{"plmn": p, "name": c["name"], "until": c["rested_until"], "note": c["note"]}
                      for p, c in st["carriers"].items() if c.get("rested_until", 0) > now]
    out["last_survey"] = st["last_survey"] or None
    os.makedirs(os.path.dirname(STATUS), exist_ok=True)
    tmp = STATUS + ".tmp"
    with open(tmp, "w") as f:
        json.dump(out, f, sort_keys=True)
    os.replace(tmp, STATUS)
    return 0


def cmd_status(st):
    now = int(time.time())
    m = modem()
    s = signal() if m["present"] else {}
    print(f"mode {mode()}; modem {m['state']} on {name(st, m['operator']) if m['operator'] else '-'}"
          f" ({m['modes'] or '?'}); RSRP {s.get('rsrp')} dBm, SNR {s.get('snr')} dB")
    print(f"ranking: {ranking_text(st, now)}")
    for p, c in sorted(st["carriers"].items()):
        cd = f", sits out until {hhmm(c['cooldown_until'])}" if c["cooldown_until"] > now else ""
        print(f"  {c['name']:<10} {p}  score {c['score']}  drops(7d) {len(recent_drops(c, now))}{cd}"
              f"{'  ' + c['note'] if c['note'] else ''}")
    if st["last_survey"]:
        print(f"last survey {datetime.datetime.fromtimestamp(st['last_survey']):%d %b %H:%M}")
    return 0


def cmd_abort():
    try:
        os.remove(MARKER)
    except OSError:
        pass
    nm_down()
    release()
    nm_up()
    return 0


def main(argv):
    if len(argv) < 2 or argv[1] not in ("survey", "nightly", "failover", "report", "status", "abort"):
        print(__doc__)
        return 2
    cmd = argv[1]
    # systemd's stop/timeout sends SIGTERM: unwind so the survey marker is removed and LTE reconnected
    sig.signal(sig.SIGTERM, lambda *_: sys.exit(143))
    if cmd == "status":
        return cmd_status(load())
    fd = lock(block=False)
    if fd is None:
        return 2            # a survey or another fail-over is running
    st = load()
    if cmd == "report":
        return cmd_report(st, ok="--ok" in argv, force="--force" in argv)
    if cmd == "abort":
        return cmd_abort()
    if cmd == "failover":
        reason = argv[argv.index("--reason") + 1] if "--reason" in argv[:-1] else "watchdog"
        return cmd_failover(st, reason)
    if cmd == "nightly":
        return cmd_nightly(st)
    if cmd == "survey":
        if mode() == "off" and "--force" not in argv:
            print("mode is off (/etc/vertek/lte-carriers.conf); use --force to survey anyway")
            return 3
        survey(st, "by hand")
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
