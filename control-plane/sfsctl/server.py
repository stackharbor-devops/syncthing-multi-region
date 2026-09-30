"""Control-plane HTTPS server: API (ARCHITECTURE section 5), SSO, nginx auth check, UI.

Run: python3 -m sfsctl.server --config /etc/sfsctl/config.json
"""

import argparse
import importlib
import json
import logging
import mimetypes
import os
import re
import socket
import ssl
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit

from . import __version__
from . import auth
from . import config as config_mod
from .db import Database
from .jobs import JobRunner

log = logging.getLogger("sfsctl")

MAX_BODY = 1024 * 1024
UI_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "ui")
API_TOKEN_MAX_DAYS = 366

CSP = ("default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
       "img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; "
       "base-uri 'none'; form-action 'self'")


def M(name):
    """Lazy import of sibling modules (lets tests substitute ops modules)."""
    return importlib.import_module("sfsctl." + name)


class HttpError(Exception):
    def __init__(self, status, message):
        Exception.__init__(self, message)
        self.status = status
        self.message = message


class App(object):
    """Shared state for all request threads."""

    def __init__(self, cfg, db, runner, ui_dir=UI_DIR):
        self.cfg = cfg
        self.db = db
        self.runner = runner
        self.ui_dir = os.path.realpath(ui_dir)
        self.routes = []
        self._build_routes()

    # -- routing table ---------------------------------------------------------
    def route(self, method, pattern, role, handler, audit=None):
        self.routes.append((method, re.compile("^" + pattern + "$"), role, handler, audit))

    def _build_routes(self):
        r = self.route
        A = "/api/v1"
        r("GET", A + "/health", "viewer", self.h_health)
        r("GET", A + "/cluster", "viewer", self.h_cluster)
        r("GET", A + "/regions", "viewer", self.h_regions)
        r("POST", A + "/regions", "admin", self.h_region_add, "region.add")
        r("DELETE", A + "/regions/(?P<id>[^/]+)", "admin", self.h_region_delete, "region.delete")
        r("GET", A + "/nodes", "viewer", self.h_nodes)
        r("POST", A + "/nodes/enroll-token", "admin", self.h_enroll_token)  # enroll audits it
        # TODO(sfs): per-IP rate limit for the unauthenticated /api/v1/enroll and /sso endpoints
        # (tokens are HMAC-signed and one-time, so this is DoS hardening, not auth).
        r("POST", A + "/enroll", None, self.h_enroll, None)  # audited by enroll.handle_enroll
        r("GET", A + "/ca", None, self.h_ca)
        r("POST", A + "/nodes/(?P<id>[^/]+)/heartbeat", "node", self.h_heartbeat)
        r("POST", A + "/nodes/(?P<id>[^/]+)/drain", "operator", self.h_drain, "node.drain")
        r("DELETE", A + "/nodes/(?P<id>[^/]+)", "operator", self.h_node_delete, "node.remove")
        r("POST", A + "/ops/rebalance", "operator", self.h_rebalance, "ops.rebalance")
        r("POST", A + "/ops/heal", "operator", self.h_heal, "ops.heal")
        r("GET", A + "/jobs", "viewer", self.h_jobs)
        r("GET", A + "/jobs/(?P<id>[^/]+)", "viewer", self.h_job)
        r("GET", A + "/replication", "viewer", self.h_replication)
        r("GET", A + "/backups", "viewer", self.h_backups)
        r("POST", A + "/backups", "operator", self.h_backup_now, "backup.run")
        r("GET", A + "/backups/policy", "viewer", self.h_policy_get)
        r("PUT", A + "/backups/policy", "admin", self.h_policy_put, "backup.policy")
        r("POST", A + "/backups/(?P<id>[^/]+)/restore", "admin", self.h_restore, "backup.restore")
        r("GET", A + "/audit", "viewer", self.h_audit)
        r("GET", A + "/me", "viewer", self.h_me)
        r("GET", A + "/tokens", "admin", self.h_tokens)
        r("POST", A + "/tokens", "admin", self.h_token_add, "token.create")
        r("DELETE", A + "/tokens/(?P<id>[^/]+)", "admin", self.h_token_delete, "token.delete")

    # -- helpers -----------------------------------------------------------------
    def job(self, type, actor, fn):
        job_id = self.runner.submit(type, actor, fn)
        return 202, self.db.get_job(job_id)

    @staticmethod
    def need(body, *keys):
        missing = [k for k in keys if body.get(k) in (None, "", [])]
        if missing:
            raise HttpError(400, "missing field(s): %s" % ", ".join(missing))

    # -- handlers: each gets (req) and returns (status, payload) ------------------
    def h_health(self, req):
        return 200, M("health").current(self.cfg, self.db)

    def h_cluster(self, req):
        out = M("topology").cluster_summary(self.cfg, self.db)
        out.setdefault("version", "")
        out["controlPlaneVersion"] = __version__
        return 200, out

    def h_regions(self, req):
        return 200, M("topology").list_regions(self.cfg, self.db)

    def h_region_add(self, req):
        b = req.body
        self.need(b, "name", "envName")
        name = str(b["name"]).strip()
        if not re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$", name):
            raise HttpError(400, "invalid region name")
        existing = self.db.get_region(name)
        region = self.db.upsert_region({
            "id": name, "name": name, "envName": str(b["envName"]).strip(),
            "status": (existing or {}).get("status") or "pending",
            "masters": (existing or {}).get("masters") or [],
            "filers": (existing or {}).get("filers") or []})
        req.audit_target = name
        return (200 if existing else 201), region

    def h_region_delete(self, req):
        rid = req.params["id"]
        req.audit_target = rid
        if self.db.get_region(rid) is None:
            raise HttpError(404, "no such region")
        if rid == self.cfg.get("primaryRegion"):
            raise HttpError(409, "the primary region cannot be removed")
        live = [n["id"] for n in self.db.list_nodes()
                if n.get("region") == rid and n.get("status") not in ("removed",)]
        if live:
            raise HttpError(409, "region still has nodes: %s (drain and remove them first)"
                            % ", ".join(live))
        cfg, db = self.cfg, self.db

        def run(job):
            db.upsert_region({"id": rid, "status": "removing"})
            db.delete_region(rid)
            job.log("region %s removed from the control plane" % rid)
            try:
                M("replication").ensure_sync(cfg, db)
                job.log("replication pairs reconciled")
            except Exception as exc:  # removal itself succeeded
                job.log("replication reconcile failed: %s" % exc)
            return {"region": rid}
        return self.job("region.delete", req.actor, run)

    def h_nodes(self, req):
        return 200, M("topology").list_nodes(self.cfg, self.db)

    def h_enroll_token(self, req):
        b = req.body
        self.need(b, "region", "nodeId", "roles", "ip")
        roles = b["roles"]
        if isinstance(roles, str):
            roles = [x.strip() for x in roles.split(",") if x.strip()]
        enroll = M("enroll")
        try:
            return 200, enroll.issue_enroll_token(self.cfg, self.db, str(b["region"]),
                                                  str(b["nodeId"]), roles, str(b["ip"]),
                                                  actor=req.actor)
        except enroll.EnrollError as exc:
            self.db.audit(req.actor, "node.enroll-token", "%s-%s" % (b["region"], b["nodeId"]),
                          "error", getattr(exc, "message", str(exc)))
            raise HttpError(getattr(exc, "status", 400) or 400, getattr(exc, "message", str(exc)))

    def h_enroll(self, req):
        enroll = M("enroll")
        try:
            return 200, enroll.handle_enroll(self.cfg, self.db, req.body, req.client_ip)
        except enroll.EnrollError as exc:
            raise HttpError(getattr(exc, "status", 400) or 400,
                            getattr(exc, "message", str(exc)) or str(exc))

    def h_ca(self, req):
        ca_pem, fp = M("enroll").ensure_ca(self.cfg["stateDir"])
        return 200, {"ca": ca_pem, "fingerprint": fp}

    def h_heartbeat(self, req):
        node_id = req.params["id"]
        node = self.db.get_node(node_id)
        if node is None:
            raise HttpError(404, "unknown node")
        p = req.principal
        if p.get("via") == "cert":
            want = "node%s.%s" % (node.get("nodeId"), node.get("region"))
            if p.get("cn") != want:
                raise HttpError(403, "certificate does not belong to this node")
        elif not auth.has_role(p, "operator"):
            raise HttpError(403, "forbidden")
        b = req.body if isinstance(req.body, dict) else {}
        # lastSeen is epoch seconds (int): topology/health/ops compare it numerically.
        upd = {"id": node_id, "lastSeen": int(time.time())}
        if b.get("diskTotal") is not None or b.get("diskUsed") is not None:
            total = int(b.get("diskTotal") or 0)
            used = int(b.get("diskUsed") or 0)
            upd["capacity"] = {"totalBytes": total, "usedBytes": used,
                               "freeBytes": max(total - used, 0)}
        for src, dst in (("services", "services"), ("weedVersion", "weedVersion")):
            if b.get(src) is not None:
                upd[dst] = b[src]
        if node.get("status") in (None, "", "joining", "offline"):
            upd["status"] = "online"
        self.db.upsert_node(upd)
        return 200, {"ok": True}

    def h_drain(self, req):
        node_id = req.params["id"]
        req.audit_target = node_id
        if self.db.get_node(node_id) is None:
            raise HttpError(404, "unknown node")
        cfg, db = self.cfg, self.db
        return self.job("node.drain", req.actor,
                        lambda job: M("ops").drain_node(cfg, db, job, node_id))

    def h_node_delete(self, req):
        node_id = req.params["id"]
        req.audit_target = node_id
        if self.db.get_node(node_id) is None:
            raise HttpError(404, "unknown node")
        force = (req.query.get("force") or ["0"])[0] in ("1", "true", "yes")
        try:
            res = M("ops").remove_node(self.cfg, self.db, node_id, force=force)
        except ValueError as exc:
            raise HttpError(409, str(exc))
        out = {"ok": True}
        if isinstance(res, dict):
            out.update(res)
        return 200, out

    def _exclusive(self, type):
        if self.runner.running(type):
            raise HttpError(409, "a %s job is already running" % type)

    def h_rebalance(self, req):
        self._exclusive("ops.rebalance")
        cfg, db = self.cfg, self.db
        return self.job("ops.rebalance", req.actor, lambda job: M("ops").rebalance(cfg, db, job))

    def h_heal(self, req):
        self._exclusive("ops.heal")
        cfg, db = self.cfg, self.db
        return self.job("ops.heal", req.actor, lambda job: M("ops").heal(cfg, db, job))

    def h_jobs(self, req):
        limit = _int((req.query.get("limit") or ["50"])[0], 50)
        return 200, self.db.list_jobs(limit)

    def h_job(self, req):
        job = self.db.get_job(req.params["id"])
        if job is None:
            raise HttpError(404, "unknown job")
        return 200, job

    def h_replication(self, req):
        return 200, M("replication").status(self.cfg, self.db)

    def h_backups(self, req):
        return 200, M("backups").list_backups(self.cfg, self.db)

    def h_backup_now(self, req):
        self._exclusive("backup.run")
        cfg, db = self.cfg, self.db
        return self.job("backup.run", req.actor, lambda job: M("backups").run_backup(cfg, db, job))

    def h_restore(self, req):
        b = req.body
        self.need(b, "path", "targetPath")
        bid = req.params["id"]
        req.audit_target = "%s %s -> %s" % (bid, b["path"], b["targetPath"])
        cfg, db = self.cfg, self.db
        path, target = str(b["path"]), str(b["targetPath"])
        return self.job("backup.restore", req.actor,
                        lambda job: M("backups").restore(cfg, db, job, bid, path, target))

    def h_policy_get(self, req):
        return 200, M("backups").get_policy(self.cfg, self.db)

    def h_policy_put(self, req):
        if not isinstance(req.body, dict):
            raise HttpError(400, "policy must be an object")
        try:
            return 200, M("backups").set_policy(self.cfg, self.db, req.body)
        except ValueError as exc:
            raise HttpError(400, str(exc))

    def h_audit(self, req):
        limit = _int((req.query.get("limit") or ["100"])[0], 100)
        return 200, self.db.list_audit(limit)

    def h_me(self, req):
        p = req.principal
        return 200, {"sub": p.get("sub"), "email": p.get("email") or "", "role": p.get("role"),
                     "via": p.get("via")}

    def h_tokens(self, req):
        return 200, self.db.list_api_tokens()

    def h_token_add(self, req):
        b = req.body
        self.need(b, "name", "role")
        role = str(b["role"])
        if role not in auth.ROLES:
            raise HttpError(400, "role must be one of %s" % ", ".join(auth.ROLES))
        days = _int(b.get("ttlDays", b.get("expiresInDays", 90)), 90)
        if days < 1 or days > API_TOKEN_MAX_DAYS:
            raise HttpError(400, "ttlDays must be 1..%d" % API_TOKEN_MAX_DAYS)
        import secrets as _s
        tid = "t" + _s.token_hex(8)
        ttl = days * 86400
        token = M("tokens").mint(config_mod.secret_bytes(self.cfg),
                                 {"typ": "api", "tid": tid, "role": role}, ttl)
        exp = int(time.time()) + ttl
        self.db.add_api_token(tid, role, str(b["name"])[:100], exp)
        req.audit_target = tid
        out = dict(self.db.get_api_token(tid))
        out["token"] = token  # shown once, never stored
        return 201, out

    def h_token_delete(self, req):
        tid = req.params["id"]
        req.audit_target = tid
        if not self.db.delete_api_token(tid):
            raise HttpError(404, "unknown token")
        return 200, {"ok": True}


def _int(value, default):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


class Request(object):
    pass


class Handler(BaseHTTPRequestHandler):
    server_version = "sfsctl"
    sys_version = ""
    protocol_version = "HTTP/1.1"
    timeout = 30

    @property
    def app(self):
        return self.server.app

    def log_message(self, fmt, *args):
        log.info("%s %s", self.client_address[0], fmt % args)

    # -- response helpers -----------------------------------------------------------
    def _common_headers(self):
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Strict-Transport-Security", "max-age=31536000")

    def send_json(self, status, payload, headers=None):
        data = json.dumps(payload, sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self._common_headers()
        for k, v in (headers or []):
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def send_error_json(self, status, message):
        self.send_json(status, {"error": message}, [("Connection", "close")])

    def send_redirect(self, location, headers=None):
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store")
        self._common_headers()
        for k, v in (headers or []):
            self.send_header(k, v)
        self.end_headers()

    # -- request plumbing -------------------------------------------------------------
    def _read_body(self):
        length = self.headers.get("Content-Length")
        if self.headers.get("Transfer-Encoding"):
            raise HttpError(411, "chunked bodies are not supported")
        if not length:
            return {}
        n = _int(length, -1)
        if n < 0 or n > MAX_BODY:
            raise HttpError(413, "body too large")
        raw = self.rfile.read(n)
        if not raw.strip():
            return {}
        try:
            return json.loads(raw.decode("utf-8"))
        except ValueError:
            raise HttpError(400, "body is not valid JSON")

    def _peer_cn(self):
        try:
            cert = self.connection.getpeercert()
        except (AttributeError, ValueError):
            return None
        if not cert:
            return None
        for rdn in cert.get("subject", ()):
            for key, value in rdn:
                if key == "commonName":
                    return value
        return None

    def do_GET(self):
        self._dispatch("GET")

    def do_HEAD(self):
        self._dispatch("HEAD")

    def do_POST(self):
        self._dispatch("POST")

    def do_PUT(self):
        self._dispatch("PUT")

    def do_DELETE(self):
        self._dispatch("DELETE")

    def _dispatch(self, method):
        app = self.app
        url = urlsplit(self.path)
        path = url.path
        client_ip = self.client_address[0]
        try:
            decoded = unquote(path)
            if "\x00" in decoded or "\\" in decoded or ".." in decoded.split("/"):
                raise HttpError(400, "bad path")
            if path in ("/", "/ui") and method in ("GET", "HEAD"):
                return self.send_redirect("/ui/")
            if path == "/sso" and method == "GET":
                return self._sso(parse_qs(url.query))
            try:
                principal = auth.authenticate(app.cfg, app.db, self.headers, client_ip)
            except auth.AuthError as exc:
                if path == "/auth/check":
                    return self.send_error_json(401, exc.message)
                raise HttpError(exc.status, exc.message)
            if path == "/auth/check":
                return self._auth_check(principal)
            if path == "/auth/logout" and method == "POST":
                return self._logout(principal)
            if path == "/ui" or path.startswith("/ui/"):
                if method not in ("GET", "HEAD"):
                    raise HttpError(405, "method not allowed")
                if not principal:
                    raise HttpError(401, "login required: open Advanced Management from the dashboard")
                return self._static(path)
            if not path.startswith("/api/"):
                raise HttpError(404, "not found")
            self._api(method, path, url.query, principal, client_ip)
        except (BrokenPipeError, ConnectionResetError, socket.timeout, ssl.SSLError):
            self.close_connection = True
        except HttpError as exc:
            self._safe_error(exc.status, exc.message)
        except Exception as exc:
            log.exception("unhandled error on %s %s", method, path)
            self._safe_error(500, "internal error: %s" % type(exc).__name__)

    def _safe_error(self, status, message):
        # The request body may be unread: never reuse this connection.
        self.close_connection = True
        try:
            self.send_error_json(status, message)
        except (OSError, ssl.SSLError):
            self.close_connection = True

    def _api(self, method, path, query, principal, client_ip):
        app = self.app
        lookup = "GET" if method == "HEAD" else method
        matched, allowed = None, []
        for rmethod, rx, role, handler, action in app.routes:
            m = rx.match(path)
            if m:
                allowed.append(rmethod)
                if rmethod == lookup:
                    matched = (m, role, handler, action)
                    break
        if matched is None:
            if allowed:
                raise HttpError(405, "method not allowed")
            raise HttpError(404, "not found")
        m, role, handler, action = matched
        req = Request()
        req.params = {k: unquote(v) for k, v in m.groupdict().items()}
        req.query = parse_qs(query)
        req.client_ip = client_ip
        req.audit_target = req.params.get("id", "")
        if role == "node":
            cn = self._peer_cn()
            if cn:
                principal = {"sub": "cert:" + cn, "email": "", "role": "node", "via": "cert",
                             "cn": cn}
            elif not principal:
                raise HttpError(401, "node certificate or token required")
        elif role is not None:
            if not principal:
                raise HttpError(401, "authentication required")
            if not auth.has_role(principal, role):
                raise HttpError(403, "role %s required" % role)
        if not auth.csrf_ok(principal, method, self.headers):
            raise HttpError(403, "missing %s header" % auth.CSRF_HEADER)
        req.principal = principal or {}
        req.actor = auth.actor_name(principal)
        req.body = self._read_body() if method in ("POST", "PUT", "DELETE") else {}
        if method in ("POST", "PUT") and not isinstance(req.body, dict):
            raise HttpError(400, "body must be a JSON object")
        try:
            status, payload = handler(req)
        except HttpError as exc:
            if action:
                app.db.audit(req.actor, action, req.audit_target, "denied" if exc.status in (401, 403, 409) else "error",
                             "%d %s" % (exc.status, exc.message))
            raise
        except Exception as exc:
            if action:
                app.db.audit(req.actor, action, req.audit_target, "error", "%s: %s" % (type(exc).__name__, exc))
            raise
        if action:
            detail = ""
            if isinstance(payload, dict) and payload.get("id") and payload.get("type"):
                detail = "job %s" % payload["id"]
            app.db.audit(req.actor, action, req.audit_target, "ok", detail)
        self.send_json(status, payload)

    # -- SSO / sessions -------------------------------------------------------------------
    def _sso(self, qs):
        app = self.app
        grant = (qs.get("grant") or [""])[0]
        if not grant:
            raise HttpError(400, "missing grant")
        tk = M("tokens")
        try:
            claims = tk.verify(config_mod.secret_bytes(app.cfg), grant, "sso")
        except tk.TokenError as exc:
            app.db.audit("anonymous", "sso.login", "", "denied", str(exc))
            raise HttpError(401, "invalid or expired sign-in link: %s" % exc)
        cid = claims.get("cid")
        if cid and cid != app.cfg.get("clusterId"):
            raise HttpError(401, "sign-in link belongs to another cluster")
        role = claims.get("role")
        if role not in auth.ROLES or not claims.get("sub"):
            raise HttpError(401, "sign-in link has no valid subject/role")
        if not app.db.use_jti(claims.get("jti"), int(claims.get("exp") or 0)):
            app.db.audit(claims.get("sub"), "sso.login", "", "denied", "grant already used")
            raise HttpError(401, "sign-in link was already used; open Advanced Management again")
        sid = app.db.create_session(claims["sub"], claims.get("email") or "", role,
                                    auth.SESSION_TTL_ABS, auth.SESSION_TTL_IDLE)
        app.db.audit(auth.actor_name({"sub": claims["sub"], "email": claims.get("email")}),
                     "sso.login", role, "ok", "")
        self.send_redirect("/ui/", [("Set-Cookie", auth.session_cookie(sid))])

    def _auth_check(self, principal):
        if not principal:
            return self.send_error_json(401, "authentication required")
        self.send_json(200, {"ok": True}, [("X-SFS-User", principal.get("email") or principal.get("sub") or ""),
                                           ("X-SFS-Role", principal.get("role") or "")])

    def _logout(self, principal):
        if principal and principal.get("via") == "session":
            if not auth.csrf_ok(principal, "POST", self.headers):
                raise HttpError(403, "missing %s header" % auth.CSRF_HEADER)
            self.app.db.delete_session(principal.get("sid"))
            self.app.db.audit(auth.actor_name(principal), "sso.logout", "", "ok", "")
        self.send_json(200, {"ok": True}, [("Set-Cookie", auth.clear_cookie())])

    # -- static UI ----------------------------------------------------------------------------
    def _static(self, path):
        root = self.app.ui_dir
        rel = unquote(path[len("/ui"):]).lstrip("/")
        if not rel or rel.endswith("/"):
            rel += "index.html"
        full = os.path.realpath(os.path.join(root, rel))
        if not (full == root or full.startswith(root + os.sep)):
            raise HttpError(404, "not found")
        if not os.path.isfile(full):
            raise HttpError(404, "not found")
        ctype = mimetypes.guess_type(full)[0] or "application/octet-stream"
        if ctype.startswith("text/") or ctype in ("application/javascript", "application/json"):
            ctype += "; charset=utf-8"
        with open(full, "rb") as fh:
            data = fh.read()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Security-Policy", CSP)
        self._common_headers()
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64

    def __init__(self, addr, app, ssl_context=None):
        self.app = app
        self.ssl_context = ssl_context
        ThreadingHTTPServer.__init__(self, addr, Handler)

    def handle_error(self, request, client_address):
        exc = sys.exc_info()[1]
        if isinstance(exc, (OSError, ssl.SSLError)):
            log.debug("connection from %s ended: %s", client_address[0], exc)
            return
        log.exception("request from %s failed", client_address[0])

    def get_request(self):
        sock, addr = self.socket.accept()
        if self.ssl_context is not None:
            # Handshake happens on first read, inside the request thread.
            sock = self.ssl_context.wrap_socket(sock, server_side=True, do_handshake_on_connect=False)
        return sock, addr


def make_ssl_context(cert_path, key_path, ca_pem=None):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(cert_path, key_path)
    if ca_pem:
        # Optional client certificates (nodes use their enrolled cert for heartbeats).
        ctx.load_verify_locations(cadata=ca_pem)
        ctx.verify_mode = ssl.CERT_OPTIONAL
    return ctx


def build(cfg, db=None, runner=None, ssl_context=None, ui_dir=UI_DIR, addr=None):
    db = db or Database(config_mod.db_path(cfg))
    runner = runner or JobRunner(db)
    app = App(cfg, db, runner, ui_dir)
    return Server(addr or config_mod.listen_addr(cfg), app, ssl_context)


def _loop(name, fn, interval):
    def run():
        while True:
            try:
                fn()
            except Exception:
                log.exception("%s failed", name)
            time.sleep(interval)
    t = threading.Thread(target=run, name=name)
    t.daemon = True
    t.start()
    return t


def start_background(cfg, db, runner):
    """Health monitor, backup scheduler and filer.sync supervisor (each optional)."""
    for mod, fn in (("health", "start_monitor"), ("backups", "start_scheduler")):
        try:
            getattr(M(mod), fn)(cfg, db, runner)
        except Exception:
            log.exception("could not start %s.%s", mod, fn)
    _loop("replication", lambda: M("replication").ensure_sync(cfg, db), 30)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="sfsctl-server")
    ap.add_argument("--config", default=config_mod.DEFAULT_PATH)
    ap.add_argument("--no-background", action="store_true", help="do not start monitors/sync")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, stream=sys.stderr,
                        format="%(asctime)s %(levelname)s %(threadName)s %(message)s")
    cfg = config_mod.load(args.config)
    os.makedirs(cfg["stateDir"], mode=0o700, exist_ok=True)
    db = Database(config_mod.db_path(cfg))
    db.fail_stale_jobs()
    runner = JobRunner(db)
    enroll = M("enroll")
    ca_pem, fp = enroll.ensure_ca(cfg["stateDir"])
    ips = [ip for ip in (cfg.get("cpIp"), "127.0.0.1") if ip]
    hosts = [h for h in ("localhost", socket.gethostname()) if h]
    cert, key = enroll.ensure_server_cert(cfg["stateDir"], ips, hosts)
    ctx = make_ssl_context(cert, key, ca_pem)
    srv = build(cfg, db, runner, ctx)
    if not args.no_background:
        start_background(cfg, db, runner)
    log.info("sfsctl %s listening on %s (CA %s)", __version__, cfg["listen"], fp)
    db.audit("system", "server.start", cfg["listen"], "ok", __version__)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
