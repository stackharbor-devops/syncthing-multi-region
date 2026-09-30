"""SQLite state store. One connection shared by all threads, serialised by a lock."""

import hashlib
import json
import os
import secrets
import sqlite3
import threading
import time

SCHEMA = """
CREATE TABLE IF NOT EXISTS used_jti (jti TEXT PRIMARY KEY, exp INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS audit (
  id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, actor TEXT, action TEXT,
  target TEXT, result TEXT, detail TEXT);
CREATE TABLE IF NOT EXISTS nodes (id TEXT PRIMARY KEY, data TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS regions (id TEXT PRIMARY KEY, data TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS sessions (
  sid_hash TEXT PRIMARY KEY, sub TEXT, email TEXT, role TEXT,
  created REAL NOT NULL, expires_abs REAL NOT NULL, ttl_idle REAL NOT NULL,
  last_seen REAL NOT NULL);
CREATE TABLE IF NOT EXISTS jobs (
  id TEXT PRIMARY KEY, type TEXT, status TEXT, actor TEXT, created REAL,
  started REAL, finished REAL, result TEXT, message TEXT, log TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS api_tokens (
  id TEXT PRIMARY KEY, role TEXT NOT NULL, name TEXT, exp INTEGER NOT NULL, created REAL);
CREATE INDEX IF NOT EXISTS jobs_created ON jobs(created);
"""

MAX_JOB_LOG = 256 * 1024  # bytes kept per job log (tail)


def iso(ts):
    if ts is None:
        return None
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))


def _hash_sid(sid):
    return hashlib.sha256(sid.encode("utf-8")).hexdigest()


class Database(object):
    def __init__(self, path):
        self.path = path
        parent = os.path.dirname(os.path.abspath(path))
        if not os.path.isdir(parent):
            os.makedirs(parent, mode=0o700)
        self._lock = threading.RLock()
        self._conn = sqlite3.connect(path, check_same_thread=False, timeout=30,
                                     isolation_level=None)
        self._conn.row_factory = sqlite3.Row
        with self._lock:
            self._conn.execute("PRAGMA journal_mode=WAL")
            self._conn.execute("PRAGMA busy_timeout=30000")
            self._conn.executescript(SCHEMA)
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass

    # -- helpers ---------------------------------------------------------------
    def _exec(self, sql, args=()):
        with self._lock:
            return self._conn.execute(sql, args)

    def _all(self, sql, args=()):
        with self._lock:
            return [dict(r) for r in self._conn.execute(sql, args).fetchall()]

    def _one(self, sql, args=()):
        with self._lock:
            row = self._conn.execute(sql, args).fetchone()
            return dict(row) if row is not None else None

    def close(self):
        with self._lock:
            self._conn.close()

    # -- one-time token ids ----------------------------------------------------
    def use_jti(self, jti, exp):
        """Record a token id. False when it was already used (replay)."""
        if not jti:
            return False
        now = int(time.time())
        with self._lock:
            self._conn.execute("DELETE FROM used_jti WHERE exp < ?", (now - 3600,))
            try:
                self._conn.execute("INSERT INTO used_jti (jti, exp) VALUES (?, ?)",
                                   (str(jti), int(exp)))
            except sqlite3.IntegrityError:
                return False
        return True

    # -- audit -----------------------------------------------------------------
    def audit(self, actor, action, target, result, detail=""):
        self._exec("INSERT INTO audit (ts, actor, action, target, result, detail) "
                   "VALUES (?, ?, ?, ?, ?, ?)",
                   (time.time(), str(actor or ""), str(action or ""), str(target or ""),
                    str(result or ""), str(detail or "")[:4000]))

    def list_audit(self, limit=100):
        limit = max(1, min(int(limit), 1000))
        rows = self._all("SELECT * FROM audit ORDER BY id DESC LIMIT ?", (limit,))
        return [{"ts": iso(r["ts"]), "actor": r["actor"], "action": r["action"],
                 "target": r["target"], "result": r["result"], "detail": r["detail"]}
                for r in rows]

    # -- JSON document tables --------------------------------------------------
    def _upsert_doc(self, table, doc):
        if not doc.get("id"):
            raise ValueError("%s record needs an id" % table)
        with self._lock:
            row = self._conn.execute("SELECT data FROM %s WHERE id = ?" % table,
                                     (str(doc["id"]),)).fetchone()
            merged = json.loads(row["data"]) if row else {}
            merged.update(doc)
            self._conn.execute("INSERT OR REPLACE INTO %s (id, data) VALUES (?, ?)" % table,
                               (str(doc["id"]), json.dumps(merged, sort_keys=True)))
        return merged

    def _get_doc(self, table, doc_id):
        row = self._one("SELECT data FROM %s WHERE id = ?" % table, (str(doc_id),))
        return json.loads(row["data"]) if row else None

    def _list_docs(self, table):
        return [json.loads(r["data"]) for r in self._all("SELECT data FROM %s ORDER BY id" % table)]

    def upsert_node(self, node):
        """Insert or merge a node: {id, region, envName, nodeId, ip, roles, status,
        capacity, volumes, lastSeen} (+ any extra keys)."""
        return self._upsert_doc("nodes", node)

    def get_node(self, node_id):
        return self._get_doc("nodes", node_id)

    def list_nodes(self):
        return self._list_docs("nodes")

    def delete_node(self, node_id):
        self._exec("DELETE FROM nodes WHERE id = ?", (str(node_id),))

    def upsert_region(self, region):
        """{id, name, envName, status, masters, filers}."""
        return self._upsert_doc("regions", region)

    def get_region(self, region_id):
        return self._get_doc("regions", region_id)

    def list_regions(self):
        return self._list_docs("regions")

    def delete_region(self, region_id):
        self._exec("DELETE FROM regions WHERE id = ?", (str(region_id),))

    # -- key/value (JSON values) -----------------------------------------------
    def kv_get(self, key, default=None):
        row = self._one("SELECT value FROM kv WHERE key = ?", (str(key),))
        if row is None:
            return default
        return json.loads(row["value"])

    def kv_set(self, key, value):
        self._exec("INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
                   (str(key), json.dumps(value, sort_keys=True)))

    # -- sessions --------------------------------------------------------------
    def create_session(self, sub, email, role, ttl_abs, ttl_idle):
        """Random 256-bit session id; only its sha256 is stored."""
        sid = secrets.token_urlsafe(32)
        now = time.time()
        with self._lock:
            self._conn.execute("DELETE FROM sessions WHERE expires_abs < ? OR last_seen + ttl_idle < ?",
                               (now, now))
            self._conn.execute(
                "INSERT INTO sessions (sid_hash, sub, email, role, created, expires_abs, ttl_idle, last_seen) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (_hash_sid(sid), str(sub), str(email or ""), str(role), now, now + float(ttl_abs),
                 float(ttl_idle), now))
        return sid

    def get_session(self, sid):
        """Valid session dict (and refresh its idle timer) or None."""
        if not sid:
            return None
        h = _hash_sid(sid)
        now = time.time()
        with self._lock:
            row = self._conn.execute("SELECT * FROM sessions WHERE sid_hash = ?", (h,)).fetchone()
            if row is None:
                return None
            if row["expires_abs"] < now or row["last_seen"] + row["ttl_idle"] < now:
                self._conn.execute("DELETE FROM sessions WHERE sid_hash = ?", (h,))
                return None
            self._conn.execute("UPDATE sessions SET last_seen = ? WHERE sid_hash = ?", (now, h))
            return {"sub": row["sub"], "email": row["email"], "role": row["role"],
                    "createdAt": iso(row["created"]), "expiresAt": iso(row["expires_abs"])}

    def delete_session(self, sid):
        if sid:
            self._exec("DELETE FROM sessions WHERE sid_hash = ?", (_hash_sid(sid),))

    # -- jobs ------------------------------------------------------------------
    def create_job(self, type, actor):
        job_id = "j" + time.strftime("%Y%m%d%H%M%S", time.gmtime()) + "-" + secrets.token_hex(3)
        self._exec("INSERT INTO jobs (id, type, status, actor, created, log) VALUES (?, ?, 'queued', ?, ?, '')",
                   (job_id, str(type), str(actor or ""), time.time()))
        return job_id

    _JOB_FIELDS = {"status": "status", "startedAt": "started", "finishedAt": "finished",
                   "started": "started", "finished": "finished", "result": "result",
                   "message": "message", "type": "type", "actor": "actor"}

    def update_job(self, job_id, **fields):
        sets, args = [], []
        for key, value in fields.items():
            col = self._JOB_FIELDS.get(key)
            if col is None:
                raise ValueError("unknown job field %s" % key)
            if col == "result":
                value = json.dumps(value, sort_keys=True)
            sets.append("%s = ?" % col)
            args.append(value)
        if not sets:
            return
        args.append(str(job_id))
        self._exec("UPDATE jobs SET %s WHERE id = ?" % ", ".join(sets), args)

    def append_job_log(self, job_id, line):
        line = str(line).rstrip("\n") + "\n"
        with self._lock:
            row = self._conn.execute("SELECT log FROM jobs WHERE id = ?", (str(job_id),)).fetchone()
            if row is None:
                return
            log = (row["log"] or "") + line
            if len(log) > MAX_JOB_LOG:
                log = "...(truncated)\n" + log[-MAX_JOB_LOG:]
            self._conn.execute("UPDATE jobs SET log = ? WHERE id = ?", (log, str(job_id)))

    @staticmethod
    def _job_out(r):
        return {"id": r["id"], "type": r["type"], "status": r["status"], "actor": r["actor"],
                "createdAt": iso(r["created"]), "startedAt": iso(r["started"]),
                "finishedAt": iso(r["finished"]),
                "result": json.loads(r["result"]) if r["result"] else None,
                "message": r["message"] or "", "log": r["log"] or ""}

    def get_job(self, job_id):
        row = self._one("SELECT * FROM jobs WHERE id = ?", (str(job_id),))
        return self._job_out(row) if row else None

    def list_jobs(self, limit=50):
        limit = max(1, min(int(limit), 500))
        return [self._job_out(r) for r in
                self._all("SELECT * FROM jobs ORDER BY created DESC LIMIT ?", (limit,))]

    def active_jobs(self, type=None):
        sql = "SELECT * FROM jobs WHERE status IN ('queued', 'running')"
        args = ()
        if type:
            sql += " AND type = ?"
            args = (str(type),)
        return [self._job_out(r) for r in self._all(sql, args)]

    def fail_stale_jobs(self, message="interrupted: control plane restarted"):
        """At startup: jobs a previous process left queued/running can never finish."""
        self._exec("UPDATE jobs SET status = 'failed', finished = ?, message = ? "
                   "WHERE status IN ('queued', 'running')", (time.time(), message))

    # -- API tokens ------------------------------------------------------------
    def add_api_token(self, id, role, name, exp):
        self._exec("INSERT INTO api_tokens (id, role, name, exp, created) VALUES (?, ?, ?, ?, ?)",
                   (str(id), str(role), str(name or ""), int(exp), time.time()))

    @staticmethod
    def _token_out(r):
        return {"id": r["id"], "role": r["role"], "name": r["name"], "exp": r["exp"],
                "expiresAt": iso(r["exp"]), "createdAt": iso(r["created"])}

    def get_api_token(self, id):
        row = self._one("SELECT * FROM api_tokens WHERE id = ?", (str(id),))
        return self._token_out(row) if row else None

    def list_api_tokens(self):
        return [self._token_out(r) for r in self._all("SELECT * FROM api_tokens ORDER BY created DESC")]

    def delete_api_token(self, id):
        cur = self._exec("DELETE FROM api_tokens WHERE id = ?", (str(id),))
        return cur.rowcount > 0
