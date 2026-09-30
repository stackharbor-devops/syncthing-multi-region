"""Health checks + monitor loop with self-heal.

Monitor (every 30 s): masters reachable, volume servers vs enrolled nodes, under-replicated volumes,
disk usage (80 % warn / 90 % critical), heartbeat staleness, filer.sync status.
Self-heal: `heal` job after 5 min of continuous under-replication; `rebalance` job when disk-usage
skew between nodes of a region > 20 points (at most once per hour), only when no ops job is active.
"""
import threading
import time

from sfsctl import replication, topology

POLL_SECONDS = 30
HEAL_AFTER = 300
SKEW_POINTS = 20
REBALANCE_COOLDOWN = 3600
HEARTBEAT_WARN, HEARTBEAT_CRIT = 180, 900
OPS_JOB_TYPES = ("ops.heal", "ops.rebalance", "node.drain", "region.delete")  # server.py job types
_RANK = {"ok": 0, "degraded": 1, "critical": 2}


def _iso(ts):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))


def _pct(cap):
    total = int((cap or {}).get("totalBytes", 0) or 0)
    return 100.0 * int(cap.get("usedBytes", 0) or 0) / total if total else None


def compute(cfg, db, live=None, now=None):
    now = now or time.time()
    live = live if live is not None else topology.live_all(cfg, db)
    nodes = topology.list_nodes(cfg, db, live)
    checks = []

    regions = db.list_regions()
    down = [r["id"] for r in regions if not live.get(r["id"])]
    checks.append({"name": "masters", "status": "critical" if down else "ok",
                   "detail": ("no reachable master in: " + ", ".join(down)) if down else "%d region(s) reachable" % len(regions)})

    vol_nodes = [n for n in nodes if "volume" in (n.get("roles") or []) and n.get("status") not in ("removed", "drained", "joining")]
    offline = [n["id"] for n in vol_nodes if n.get("status") == "offline"]
    st = "ok" if not offline else ("critical" if len(offline) * 2 >= max(len(vol_nodes), 1) else "degraded")
    checks.append({"name": "volume_servers", "status": st,
                   "detail": "%d/%d volume servers registered%s" % (len(vol_nodes) - len(offline), len(vol_nodes),
                                                                    ("; offline: " + ", ".join(offline)) if offline else "")})

    under = {rid: v["underReplicated"] for rid, v in live.items() if v and v["underReplicated"]}
    n_under = sum(len(x) for x in under.values())
    lost = sum(1 for x in under.values() for v in x if v["actual"] == 0)
    checks.append({"name": "replication_local", "status": "ok" if not n_under else ("critical" if lost else "degraded"),
                   "detail": "%d under-replicated volume(s)" % n_under if n_under else "all volumes fully replicated"})

    warn, crit = [], []
    for n in nodes:
        p = _pct(n.get("capacity") or {})
        if p is None or n.get("status") == "removed":
            continue
        (crit if p >= 90 else warn if p >= 80 else []).append("%s %.0f%%" % (n["id"], p))
    checks.append({"name": "disk_usage", "status": "critical" if crit else ("degraded" if warn else "ok"),
                   "detail": ", ".join(crit + warn) or "all nodes below 80%"})

    stale_w, stale_c = [], []
    for n in nodes:
        if n.get("status") in ("removed", "joining") or not n.get("lastSeen"):
            continue
        age = now - int(n["lastSeen"])
        if age > HEARTBEAT_CRIT:
            stale_c.append("%s %ds" % (n["id"], age))
        elif age > HEARTBEAT_WARN:
            stale_w.append("%s %ds" % (n["id"], age))
    checks.append({"name": "heartbeats", "status": "critical" if stale_c else ("degraded" if stale_w else "ok"),
                   "detail": ", ".join(stale_c + stale_w) or "all heartbeats fresh"})

    rep = replication.status(cfg, db)
    bad = sorted({"%s<->%s: %s" % (r["from"], r["to"], r["status"]) for r in rep if r["status"] != "running" and r["from"] < r["to"]})
    checks.append({"name": "filer_sync", "status": "degraded" if bad else "ok",
                   "detail": "; ".join(bad) or ("%d pair(s) running" % (len(rep) // 2) if rep else "single region")})

    overall = max((c["status"] for c in checks), key=lambda s: _RANK[s]) if checks else "ok"
    return {"status": overall, "checks": checks, "updatedAt": _iso(now), "_underReplicated": n_under,
            "_skew": _skew(nodes)}


def _skew(nodes):
    """Max disk-usage spread (percentage points) between online nodes of the same region."""
    by_region = {}
    for n in nodes:
        p = _pct(n.get("capacity") or {})
        if p is not None and n.get("status") == "online" and "volume" in (n.get("roles") or []):
            by_region.setdefault(n.get("region"), []).append(p)
    return max([max(v) - min(v) for v in by_region.values() if len(v) >= 2] or [0.0])


def current(cfg, db):
    res = compute(cfg, db)
    db.kv_set("health.last", res)
    return {k: v for k, v in res.items() if not k.startswith("_")}


def _ops_job_active(db):
    return any(j.get("status") in ("queued", "running") and j.get("type") in OPS_JOB_TYPES for j in db.list_jobs(limit=50))


def tick(cfg, db, runner, now=None):
    """One monitor iteration; returns the job types submitted (for tests)."""
    from sfsctl import ops  # local import: ops imports topology
    now = now or time.time()
    submitted = []
    try:
        replication.ensure_sync(cfg, db)
    except Exception as e:  # never kill the monitor
        db.kv_set("health.syncError", str(e))
    res = compute(cfg, db, now=now)
    db.kv_set("health.last", res)
    since = db.kv_get("health.underReplicatedSince")
    if res["_underReplicated"]:
        if not since:
            db.kv_set("health.underReplicatedSince", now)
        elif now - since >= HEAL_AFTER and not _ops_job_active(db):
            runner.submit("ops.heal", "system:monitor", lambda job: ops.heal(cfg, db, job))
            db.audit("system:monitor", "ops.heal.auto", "cluster", "submitted",
                     "%d under-replicated volume(s) for %ds" % (res["_underReplicated"], now - since))
            db.kv_set("health.underReplicatedSince", now)  # next attempt after another HEAL_AFTER
            submitted.append("ops.heal")
    elif since:
        db.kv_set("health.underReplicatedSince", None)
    last_rb = db.kv_get("health.lastAutoRebalance", 0) or 0
    if res["_skew"] > SKEW_POINTS and now - last_rb >= REBALANCE_COOLDOWN and not submitted and not _ops_job_active(db):
        runner.submit("ops.rebalance", "system:monitor", lambda job: ops.rebalance(cfg, db, job))
        db.audit("system:monitor", "ops.rebalance.auto", "cluster", "submitted", "disk usage skew %.0f points" % res["_skew"])
        db.kv_set("health.lastAutoRebalance", now)
        submitted.append("ops.rebalance")
    return submitted


def start_monitor(cfg, db, runner, interval=POLL_SECONDS):
    def loop():
        while True:
            try:
                tick(cfg, db, runner)
            except Exception as e:
                try:
                    db.kv_set("health.monitorError", "%s: %s" % (type(e).__name__, e))
                except Exception:
                    pass
            time.sleep(interval)
    t = threading.Thread(target=loop, name="sfs-health-monitor", daemon=True)
    t.start()
    return t
