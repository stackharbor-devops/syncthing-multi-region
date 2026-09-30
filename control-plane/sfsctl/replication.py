"""Cross-region async replication: supervises one `weed filer.sync -a A -b B` per region pair.

Pairs: primary region <-> each other region (filer.sync is bidirectional unless -isActivePassive).
Flags verified with `weed filer.sync -h` (4.48): -a, -b, -a.security/-b.security, -isActivePassive.
The process runs with cwd = cfg["weedConfigDir"] (/etc/sfs) so security.toml is picked up.
Exits are restarted with exponential backoff (5 s .. 300 s). State is written to db kv
"replication.<a>~<b>" so status() can be served from any thread.
"""
import calendar
import os
import re
import subprocess
import threading
import time

_lock = threading.Lock()
_procs = {}  # key -> {"proc", "fails", "nextStart", "startedAt", "a", "b", "log"}


def _pairs(cfg, db):
    regions = {r["id"]: r for r in db.list_regions() if r.get("status") not in ("removing", "removed")}
    primary = regions.get(cfg.get("primaryRegion"))
    if not primary or not primary.get("filers"):
        return []
    out = []
    for rid, r in sorted(regions.items()):
        if rid == primary["id"] or not r.get("filers"):
            continue
        out.append((primary["id"], rid, primary["filers"][0], r["filers"][0]))
    return out


def _key(a, b):
    return "%s~%s" % (a, b)


def _tail(path, n=1):
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            f.seek(max(f.tell() - 65536, 0))
            lines = [ln for ln in f.read().decode("utf-8", "replace").splitlines() if ln.strip()]
            return "\n".join(lines[-n:])
    except OSError:
        return ""


def _record(db, key, **fields):
    cur = db.kv_get("replication." + key, {}) or {}
    cur.update(fields)
    db.kv_set("replication." + key, cur)


def _start(cfg, db, key, a_id, b_id, fa, fb):
    log_path = os.path.join(cfg.get("stateDir", "/var/lib/sfsctl"), "filer-sync-%s.log" % key.replace("~", "-"))
    cwd = cfg.get("weedConfigDir", "/etc/sfs")
    cmd = [cfg.get("weedBin", "/usr/local/bin/weed"), "filer.sync", "-a", fa, "-b", fb]
    logf = open(log_path, "ab")
    try:
        proc = subprocess.Popen(cmd, stdout=logf, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                cwd=cwd if os.path.isdir(cwd) else None)
    finally:
        logf.close()
    st = _procs.setdefault(key, {"fails": 0})
    st.update({"proc": proc, "startedAt": time.time(), "a": fa, "b": fb, "log": log_path, "from": a_id, "to": b_id})
    _record(db, key, **{"from": a_id, "to": b_id, "status": "running", "pid": proc.pid, "startedAt": int(time.time())})


def ensure_sync(cfg, db):
    """Idempotent: start missing pairs, restart exited ones (with backoff), stop pairs no longer wanted."""
    now = time.time()
    with _lock:
        wanted = {}
        for a_id, b_id, fa, fb in _pairs(cfg, db):
            wanted[_key(a_id, b_id)] = (a_id, b_id, fa, fb)
        for key in list(_procs):
            st = _procs[key]
            if key not in wanted or (wanted[key][2], wanted[key][3]) != (st.get("a"), st.get("b")):
                p = st.get("proc")
                if p and p.poll() is None:
                    p.terminate()
                    try:
                        p.wait(10)
                    except subprocess.TimeoutExpired:
                        p.kill()
                del _procs[key]
                _record(db, key, status="stopped")
        for key, (a_id, b_id, fa, fb) in wanted.items():
            st = _procs.get(key)
            p = st.get("proc") if st else None
            if p is not None and p.poll() is None:
                if now - st["startedAt"] > 300 and st["fails"]:
                    st["fails"] = 0  # healthy for 5 min: reset backoff
                    _record(db, key, restarts=0)
                continue
            if p is not None:  # exited
                st["fails"] += 1
                delay = min(300, 5 * (2 ** min(st["fails"] - 1, 6)))
                st["nextStart"] = now + delay
                st["proc"] = None
                _record(db, key, status="restarting", lastError="exit %s: %s" % (p.returncode, _tail(st["log"])),
                        lastExitAt=int(now), restarts=st["fails"], nextStartAt=int(now + delay))
                continue
            if st and now < st.get("nextStart", 0):
                continue
            try:
                _start(cfg, db, key, a_id, b_id, fa, fb)
            except OSError as e:
                st = _procs.setdefault(key, {"fails": 0})
                st["fails"] += 1
                st["nextStart"] = now + min(300, 5 * (2 ** min(st["fails"] - 1, 6)))
                _record(db, key, **{"from": a_id, "to": b_id, "status": "error", "lastError": str(e)})


def stop_all():
    with _lock:
        for st in _procs.values():
            p = st.get("proc")
            if p and p.poll() is None:
                p.terminate()
        _procs.clear()


_PROGRESS_RE = re.compile(r"^I(\d{2})(\d{2}) (\d{2}:\d{2}:\d{2})\.\d+ .*? sync (\S+) to (\S+) progressed to "
                          r"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})")


def parse_progress(text, year=None):
    """filer.sync 4.48 log -> {(fromFiler, toFiler): lagSeconds} from the latest
    'sync A to B progressed to <event ts>' line per direction (lag = log time - event time)."""
    year = year or time.gmtime().tm_year
    out = {}
    for ln in (text or "").splitlines():
        m = _PROGRESS_RE.match(ln.strip())
        if not m:
            continue
        mo, dd, hms, a, b, ev = m.groups()
        logged = calendar.timegm(time.strptime("%d-%s-%s %s" % (year, mo, dd, hms), "%Y-%m-%d %H:%M:%S"))
        event = calendar.timegm(time.strptime(ev, "%Y-%m-%d %H:%M:%S"))
        out[(a, b)] = max(0, logged - event)
    return out


def status(cfg, db):
    out = []
    for a_id, b_id, _fa, _fb in _pairs(cfg, db):
        rec = db.kv_get("replication." + _key(a_id, b_id), {}) or {}
        st = rec.get("status", "pending")
        # lagSeconds = delay of the newest event at filer.sync's last progress report (it only reports
        # when events flow; None until then). TODO(sfs): use -metricsPort counters for idle-time lag.
        log_path = os.path.join(cfg.get("stateDir", "/var/lib/sfsctl"), "filer-sync-%s-%s.log" % (a_id, b_id))
        prog = parse_progress(_tail(log_path, 200))
        for frm, to, ff, ft in ((a_id, b_id, _fa, _fb), (b_id, a_id, _fb, _fa)):
            lag = prog.get((ff, ft))
            out.append({"from": frm, "to": to, "mode": "async", "status": st, "lagSeconds": lag,
                        "lastError": rec.get("lastError", ""), "restarts": rec.get("restarts", 0)})
    return out
