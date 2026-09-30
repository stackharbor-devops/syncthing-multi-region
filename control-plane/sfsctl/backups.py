"""Backups: periodic full snapshots of the primary region's filer namespace.

Honest scope (v0): this is NOT continuous point-in-time recovery. Each run walks the filer tree over
the filer HTTP API and copies every file into <target>/<id>/data/, writes <target>/<id>/manifest.json,
and the run is published atomically (rename from <id>.partial). Recovery points = snapshot times,
so RPO = policy intervalMinutes. `weed filer.backup` / `weed filer.meta.backup` (4.48) are continuous
replicators configured via replication.toml / backup_filer.toml, not snapshotters; wiring them in for
real PITR is a follow-up.
TODO(sfs): S3 targets ("s3://bucket/prefix") and incremental snapshots (hard-link unchanged files).
"""
import calendar
import json
import os
import re
import shutil
import threading
import time

from sfsctl import seaweed

DEFAULT_POLICY = {"enabled": False, "intervalMinutes": 1440, "retentionDays": 7, "target": "/var/lib/sfsctl/backups"}
ID_RE = re.compile(r"^bk-\d{8}T\d{6}Z-[0-9a-f]{4}$")


class BackupError(ValueError):  # ValueError: server.py maps it to 400
    def __init__(self, status, message):
        ValueError.__init__(self, message)
        self.status = status
        self.message = message


def get_policy(cfg, db):
    p = dict(DEFAULT_POLICY)
    p.update(db.kv_get("backup.policy", {}) or {})
    return p


def set_policy(cfg, db, policy):
    p = get_policy(cfg, db)
    for k in ("enabled", "intervalMinutes", "retentionDays", "target"):
        if k in (policy or {}):
            p[k] = policy[k]
    try:
        p["enabled"] = bool(p["enabled"])
        p["intervalMinutes"] = int(p["intervalMinutes"])
        p["retentionDays"] = int(p["retentionDays"])
    except (TypeError, ValueError):
        raise BackupError(400, "intervalMinutes and retentionDays must be integers")
    if p["intervalMinutes"] < 15 or p["retentionDays"] < 1:
        raise BackupError(400, "intervalMinutes >= 15 and retentionDays >= 1 required")
    t = str(p["target"])
    if not t.startswith("/") or ".." in t.split("/"):
        raise BackupError(400, "target must be an absolute directory path (S3 targets are not supported yet)")
    db.kv_set("backup.policy", p)
    return p


def _safe_rel(path):
    parts = [x for x in (path or "/").split("/") if x not in ("", ".")]
    if ".." in parts:
        raise BackupError(400, "path must not contain '..'")
    return "/".join(parts)


def _filer(cfg, db):
    r = next((r for r in db.list_regions() if r["id"] == cfg.get("primaryRegion")), None)
    if not r or not r.get("filers"):
        raise BackupError(503, "primary region has no filer registered")
    return r["filers"][0]


def list_backups(cfg, db):
    target = get_policy(cfg, db)["target"]
    out = []
    try:
        names = sorted(os.listdir(target), reverse=True)
    except OSError:
        return out
    for name in names:
        if not ID_RE.match(name):
            continue
        try:
            with open(os.path.join(target, name, "manifest.json")) as f:
                m = json.load(f)
        except (OSError, ValueError):
            continue
        out.append({k: m.get(k) for k in ("id", "createdAt", "kind", "status", "sizeBytes", "target", "files")})
    return out


def _walk(filer, path):
    stack = [path]
    while stack:
        d = stack.pop()
        for e in seaweed.filer_list(filer, d):
            if e["isDir"]:
                stack.append(e["path"])
            else:
                yield e


def run_backup(cfg, db, job):
    pol = get_policy(cfg, db)
    target = pol["target"]
    os.makedirs(target, mode=0o700, exist_ok=True)
    filer = _filer(cfg, db)
    now = time.time()
    bid = "bk-%s-%s" % (time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(now)), os.urandom(2).hex())
    part = os.path.join(target, bid + ".partial")
    data = os.path.join(part, "data")
    os.makedirs(data, mode=0o700)
    files = size = 0
    job.log("snapshot %s of filer %s -> %s" % (bid, filer, target))
    try:
        for e in _walk(filer, "/"):
            if e["path"].startswith("/topics/.system") or e["path"].startswith("/etc/"):
                continue  # filer-internal metadata/config, not user data
            dst = os.path.join(data, _safe_rel(e["path"]))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with seaweed.filer_open(filer, e["path"]) as src, open(dst, "wb") as out:
                shutil.copyfileobj(src, out, 1 << 20)
            files += 1
            size += os.path.getsize(dst)
            if files % 500 == 0:
                job.log("%d files, %d bytes" % (files, size))
        manifest = {"id": bid, "createdAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)), "kind": "snapshot",
                    "status": "complete", "sizeBytes": size, "files": files, "target": target, "filer": filer,
                    "source": "/"}
        with open(os.path.join(part, "manifest.json"), "w") as f:
            json.dump(manifest, f, indent=1)
        os.rename(part, os.path.join(target, bid))
    except Exception:
        shutil.rmtree(part, ignore_errors=True)
        raise
    job.log("snapshot %s complete: %d files, %d bytes" % (bid, files, size))
    pruned = _prune(target, pol["retentionDays"], keep=bid)
    if pruned:
        job.log("retention: removed " + ", ".join(pruned))
    db.kv_set("backup.lastRun", {"id": bid, "at": int(now)})
    return {"id": bid, "files": files, "sizeBytes": size, "pruned": pruned}


def _prune(target, days, keep):
    cutoff = time.time() - days * 86400
    removed = []
    for b in list_backups({}, _Kv(target)):
        if b["id"] == keep:
            continue
        ts = calendar.timegm(time.strptime(b["createdAt"], "%Y-%m-%dT%H:%M:%SZ"))
        if ts < cutoff:
            shutil.rmtree(os.path.join(target, b["id"]), ignore_errors=True)
            removed.append(b["id"])
    return removed


class _Kv(object):
    """Minimal db stand-in so list_backups can be pointed at an explicit target."""
    def __init__(self, target):
        self.target = target

    def kv_get(self, key, default=None):
        return {"target": self.target} if key == "backup.policy" else default


def restore(cfg, db, job, backup_id, path, target_path):
    if not ID_RE.match(backup_id or ""):
        raise BackupError(400, "invalid backup id")
    target = get_policy(cfg, db)["target"]
    root = os.path.join(target, backup_id, "data")
    if not os.path.isdir(root):
        raise BackupError(404, "backup %s not found in %s" % (backup_id, target))
    rel = _safe_rel(path)
    src = os.path.join(root, rel) if rel else root
    dest = "/" + _safe_rel(target_path or path)
    if not os.path.exists(src):
        raise BackupError(404, "path %s not in backup %s" % (path, backup_id))
    filer = _filer(cfg, db)
    count = size = 0
    items = [(src, dest)] if os.path.isfile(src) else [
        (os.path.join(dp, fn), dest.rstrip("/") + "/" + os.path.relpath(os.path.join(dp, fn), src).replace(os.sep, "/"))
        for dp, _dn, fns in os.walk(src) for fn in fns]
    for local, remote in items:
        with open(local, "rb") as f:
            seaweed.filer_upload(filer, remote, f)
        count += 1
        size += os.path.getsize(local)
    job.log("restored %d file(s), %d bytes from %s:%s to %s" % (count, size, backup_id, path, dest))
    return {"backup": backup_id, "files": count, "sizeBytes": size, "targetPath": dest}


def _backup_job_active(db):
    return any(j.get("type") == "backup.run" and j.get("status") in ("queued", "running") for j in db.list_jobs(limit=50))


def scheduler_tick(cfg, db, runner, now=None):
    now = now or time.time()
    pol = get_policy(cfg, db)
    if not pol["enabled"]:
        return False
    last = (db.kv_get("backup.lastRun", {}) or {}).get("at", 0)
    if now - last < pol["intervalMinutes"] * 60 or _backup_job_active(db):
        return False
    db.kv_set("backup.lastRun", {"id": None, "at": int(now)})  # avoid re-submitting while it runs
    runner.submit("backup.run", "system:scheduler", lambda job: run_backup(cfg, db, job))
    db.audit("system:scheduler", "backup.scheduled", "cluster", "submitted")
    return True


def start_scheduler(cfg, db, runner, interval=60):
    def loop():
        while True:
            try:
                scheduler_tick(cfg, db, runner)
            except Exception as e:
                try:
                    db.kv_set("backup.schedulerError", str(e))
                except Exception:
                    pass
            time.sleep(interval)
    t = threading.Thread(target=loop, name="sfs-backup-scheduler", daemon=True)
    t.start()
    return t
