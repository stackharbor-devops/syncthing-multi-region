"""End-to-end tests of sfsctl.server (real TLS, real tokens/enroll, stubbed SeaweedFS ops).

Run: PYTHONPATH=control-plane python3 -m unittest discover -s tests/unit -v
Needs the openssl CLI (the CA and server certificate are real).
"""

import http.client
import io
import json
import os
import shutil
import ssl
import sys
import tempfile
import threading
import time
import types
import unittest
from contextlib import redirect_stderr, redirect_stdout
from urllib.parse import quote

from sfsctl import cli, config as config_mod, server, tokens
from sfsctl.db import Database
from sfsctl.jobs import JobRunner

SECRET = "5e" * 32
STUBBED = ("topology", "health", "ops", "replication", "backups")


def make_stubs(calls):
    topo = types.ModuleType("sfsctl.topology")
    topo.cluster_summary = lambda cfg, db: {
        "clusterId": cfg["clusterId"], "name": cfg["clusterName"],
        "primaryRegion": cfg["primaryRegion"], "replication": cfg["replication"],
        "capacity": {"totalBytes": 100, "usedBytes": 10, "freeBytes": 90},
        "counts": {"regions": len(db.list_regions()), "nodes": len(db.list_nodes()), "volumes": 0}}
    topo.list_regions = lambda cfg, db: db.list_regions()
    topo.list_nodes = lambda cfg, db: db.list_nodes()

    health = types.ModuleType("sfsctl.health")
    health.current = lambda cfg, db: {"status": "ok", "checks": [], "updatedAt": "now"}
    health.start_monitor = lambda cfg, db, runner: None

    ops = types.ModuleType("sfsctl.ops")

    def rebalance(cfg, db, job):
        job.log("volume.balance -force")
        calls.append("rebalance")
        return {"moved": 1}

    def heal(cfg, db, job):
        calls.append("heal")
        raise RuntimeError("volume.fix.replication failed")

    def drain_node(cfg, db, job, node_id):
        calls.append("drain:" + node_id)
        db.upsert_node({"id": node_id, "status": "drained"})
        return {"node": node_id}

    def remove_node(cfg, db, node_id, force=False):
        node = db.get_node(node_id)
        if node.get("status") != "drained" and not force:
            raise ValueError("node is not drained")
        db.upsert_node({"id": node_id, "status": "removed"})
        return {"node": node_id}
    ops.rebalance, ops.heal, ops.drain_node, ops.remove_node = rebalance, heal, drain_node, remove_node

    repl = types.ModuleType("sfsctl.replication")
    repl.status = lambda cfg, db: [{"from": "r1", "to": "r2", "mode": "async", "status": "ok",
                                    "lagSeconds": 1, "lastError": ""}]
    repl.ensure_sync = lambda cfg, db: calls.append("ensure_sync")

    bk = types.ModuleType("sfsctl.backups")
    bk.list_backups = lambda cfg, db: [{"id": "b1", "createdAt": "x", "kind": "full",
                                        "status": "ok", "sizeBytes": 1, "target": "/b"}]
    bk.run_backup = lambda cfg, db, job: {"id": "b2"}

    def restore(cfg, db, job, backup_id, path, target_path):
        calls.append("restore:%s:%s:%s" % (backup_id, path, target_path))
        return {"restored": path}
    bk.restore = restore
    bk.get_policy = lambda cfg, db: db.kv_get("policy", {"enabled": False, "intervalMinutes": 60,
                                                         "retentionDays": 7, "target": ""})

    def set_policy(cfg, db, policy):
        if "intervalMinutes" in policy and int(policy["intervalMinutes"]) < 5:
            raise ValueError("intervalMinutes must be >= 5")
        db.kv_set("policy", policy)
        return policy
    bk.set_policy = set_policy
    bk.start_scheduler = lambda cfg, db, runner: None
    return {"topology": topo, "health": health, "ops": ops, "replication": repl, "backups": bk}


class ServerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp()
        cls.calls = []
        cls._saved = {}
        for name, mod in make_stubs(cls.calls).items():
            key = "sfsctl." + name
            cls._saved[key] = sys.modules.get(key)
            sys.modules[key] = mod
        state = os.path.join(cls.dir, "state")
        os.makedirs(state, mode=0o700)
        token_path = os.path.join(cls.dir, "local.token")
        with open(token_path, "w") as fh:
            fh.write("f0" * 32 + "\n")
        cls.cfg_path = os.path.join(cls.dir, "config.json")
        with open(cls.cfg_path, "w") as fh:
            json.dump({"clusterId": "c-test", "clusterName": "test", "primaryRegion": "r1",
                       "envDomain": "cp.example.test", "listen": "127.0.0.1:0",
                       "stateDir": state, "secret": SECRET, "cpIp": "127.0.0.1",
                       "localTokenPath": token_path}, fh)
        cls.cfg = config_mod.load(cls.cfg_path)
        cls.local_token = "f0" * 32
        ui = os.path.join(cls.dir, "ui")
        os.makedirs(ui)
        with open(os.path.join(ui, "index.html"), "w") as fh:
            fh.write("<!doctype html><title>sfs</title>")
        with open(os.path.join(cls.dir, "secret.txt"), "w") as fh:
            fh.write("do not serve")
        enroll = __import__("sfsctl.enroll", fromlist=["x"])
        cls.ca_pem, cls.fp = enroll.ensure_ca(state)
        cert, key = enroll.ensure_server_cert(state, ["127.0.0.1"], ["localhost"])
        ctx = server.make_ssl_context(cert, key, cls.ca_pem)
        cls.db = Database(config_mod.db_path(cls.cfg))
        cls.runner = JobRunner(cls.db)
        cls.srv = server.build(cls.cfg, cls.db, cls.runner, ctx, ui_dir=ui, addr=("127.0.0.1", 0))
        cls.port = cls.srv.server_address[1]
        cls.thread = threading.Thread(target=cls.srv.serve_forever)
        cls.thread.daemon = True
        cls.thread.start()
        cls.client_ctx = ssl.create_default_context(cadata=cls.ca_pem)

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.srv.server_close()
        for key, mod in cls._saved.items():
            if mod is None:
                sys.modules.pop(key, None)
            else:
                sys.modules[key] = mod
        shutil.rmtree(cls.dir)

    # -- helpers -------------------------------------------------------------------------
    def req(self, method, path, body=None, token=None, cookie=None, csrf=False, headers=None):
        conn = http.client.HTTPSConnection("127.0.0.1", self.port, context=self.client_ctx, timeout=10)
        h = dict(headers or {})
        if token:
            h["Authorization"] = "Bearer " + token
        if cookie:
            h["Cookie"] = "sfs_session=" + cookie
        if csrf:
            h["X-SFS-CSRF"] = "1"
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            h["Content-Type"] = "application/json"
        conn.request(method, path, body=data, headers=h)
        resp = conn.getresponse()
        raw = resp.read()
        conn.close()
        try:
            payload = json.loads(raw.decode()) if raw else None
        except ValueError:
            payload = raw.decode("utf-8", "replace")
        return resp.status, payload, resp

    def admin(self, method, path, body=None):
        return self.req(method, path, body, token=self.local_token)

    def login(self, role="admin", sub="u1", email="u1@example.com"):
        grant = tokens.mint(bytes.fromhex(SECRET), {"typ": "sso", "sub": sub, "email": email,
                                                    "role": role, "cid": "c-test"}, 60)
        st, _, resp = self.req("GET", "/sso?grant=" + quote(grant))
        self.assertEqual(st, 302)
        cookie = resp.getheader("Set-Cookie")
        sid = cookie.split(";")[0].split("=", 1)[1]
        return sid, grant, cookie, resp

    def wait_job(self, job_id):
        for _ in range(100):
            st, job, _ = self.admin("GET", "/api/v1/jobs/" + job_id)
            if job["status"] not in ("queued", "running"):
                return job
            time.sleep(0.05)
        self.fail("job did not finish")

    # -- tests ---------------------------------------------------------------------------------
    def test_ca_is_public_and_tls_verifies(self):
        st, body, _ = self.req("GET", "/api/v1/ca")
        self.assertEqual(st, 200)
        self.assertEqual(body["fingerprint"], self.fp)
        self.assertIn("BEGIN CERTIFICATE", body["ca"])

    def test_auth_required(self):
        for path in ("/api/v1/cluster", "/api/v1/nodes", "/api/v1/me", "/ui/"):
            st, body, _ = self.req("GET", path)
            self.assertEqual(st, 401, path)
            self.assertIn("error", body)
        st, _, _ = self.req("GET", "/api/v1/cluster", token="garbage")
        self.assertEqual(st, 401)
        st, _, _ = self.req("GET", "/api/v1/cluster", headers={"Authorization": "Basic eDp5"})
        self.assertEqual(st, 401)
        st, _, _ = self.req("GET", "/api/v1/nope", token=self.local_token)
        self.assertEqual(st, 404)
        st, _, _ = self.req("PUT", "/api/v1/cluster", body={}, token=self.local_token)
        self.assertEqual(st, 405)

    def test_local_token_reads(self):
        st, body, resp = self.admin("GET", "/api/v1/cluster")
        self.assertEqual(st, 200)
        self.assertEqual(body["clusterId"], "c-test")
        self.assertIn("version", body)
        self.assertTrue(body["controlPlaneVersion"])
        self.assertEqual(resp.getheader("Cache-Control"), "no-store")
        st, me, _ = self.admin("GET", "/api/v1/me")
        self.assertEqual((me["role"], me["via"]), ("admin", "local"))
        for path in ("/api/v1/health", "/api/v1/regions", "/api/v1/nodes", "/api/v1/replication",
                     "/api/v1/backups", "/api/v1/backups/policy", "/api/v1/jobs",
                     "/api/v1/audit?limit=5", "/api/v1/tokens"):
            st, _, _ = self.admin("GET", path)
            self.assertEqual(st, 200, path)

    def test_sso_session_csrf_and_logout(self):
        sid, grant, cookie, resp = self.login()
        self.assertEqual(resp.getheader("Location"), "/ui/")
        for attr in ("Secure", "HttpOnly", "SameSite=Strict", "Path=/"):
            self.assertIn(attr, cookie)
        # grant is single use
        st, body, _ = self.req("GET", "/sso?grant=" + quote(grant))
        self.assertEqual(st, 401)
        self.assertIn("already used", body["error"])
        st, me, _ = self.req("GET", "/api/v1/me", cookie=sid)
        self.assertEqual((st, me["sub"], me["email"], me["role"]), (200, "u1", "u1@example.com", "admin"))
        # nginx auth_request
        st, _, r = self.req("GET", "/auth/check", cookie=sid)
        self.assertEqual(st, 200)
        self.assertEqual(r.getheader("X-SFS-User"), "u1@example.com")
        self.assertEqual(r.getheader("X-SFS-Role"), "admin")
        st, _, _ = self.req("GET", "/auth/check")
        self.assertEqual(st, 401)
        st, _, _ = self.req("GET", "/auth/check", cookie="bogus")
        self.assertEqual(st, 401)
        # CSRF header is required for cookie-authenticated changes
        st, body, _ = self.req("POST", "/api/v1/ops/rebalance", cookie=sid)
        self.assertEqual(st, 403)
        self.assertIn("X-SFS-CSRF", body["error"])
        st, job, _ = self.req("POST", "/api/v1/ops/rebalance", cookie=sid, csrf=True)
        self.assertEqual(st, 202)
        job = self.wait_job(job["id"])
        self.assertEqual(job["status"], "succeeded")
        self.assertEqual(job["result"], {"moved": 1})
        self.assertIn("volume.balance -force", job["log"])
        self.assertEqual(job["actor"], "u1 <u1@example.com>")
        # static UI with the session
        st, html, r = self.req("GET", "/ui/", cookie=sid)
        self.assertEqual(st, 200)
        self.assertIn("<title>sfs</title>", html)
        self.assertIn("frame-ancestors 'none'", r.getheader("Content-Security-Policy"))
        # logout
        st, _, r = self.req("POST", "/auth/logout", cookie=sid)
        self.assertEqual(st, 403)
        st, _, r = self.req("POST", "/auth/logout", cookie=sid, csrf=True)
        self.assertEqual(st, 200)
        self.assertIn("Max-Age=0", r.getheader("Set-Cookie"))
        st, _, _ = self.req("GET", "/api/v1/me", cookie=sid)
        self.assertEqual(st, 401)

    def test_sso_rejects_bad_grants(self):
        key = bytes.fromhex(SECRET)
        bad = [tokens.mint(key, {"typ": "api", "sub": "x", "role": "admin"}, 60),
               tokens.mint(b"\x01" * 32, {"typ": "sso", "sub": "x", "role": "admin"}, 60),
               tokens.mint(key, {"typ": "sso", "sub": "x", "role": "admin", "cid": "other"}, 60),
               tokens.mint(key, {"typ": "sso", "sub": "x", "role": "root", "cid": "c-test"}, 60),
               "not-a-token"]
        for g in bad:
            st, _, _ = self.req("GET", "/sso?grant=" + quote(g))
            self.assertEqual(st, 401, g)
        st, _, _ = self.req("GET", "/sso")
        self.assertEqual(st, 400)

    def test_viewer_role(self):
        sid, _, _, _ = self.login(role="viewer", sub="v1", email="")
        st, _, _ = self.req("GET", "/api/v1/nodes", cookie=sid)
        self.assertEqual(st, 200)
        st, body, _ = self.req("POST", "/api/v1/ops/heal", cookie=sid, csrf=True)
        self.assertEqual(st, 403)
        st, _, _ = self.req("GET", "/api/v1/tokens", cookie=sid)
        self.assertEqual(st, 403)

    def test_api_tokens(self):
        st, tok, _ = self.admin("POST", "/api/v1/tokens", {"name": "ci", "role": "operator", "ttlDays": 1})
        self.assertEqual(st, 201)
        self.assertTrue(tok["token"])
        bearer = tok["token"]
        st, lst, _ = self.admin("GET", "/api/v1/tokens")
        self.assertIn(tok["id"], [t["id"] for t in lst])
        self.assertNotIn("token", lst[0])
        # operator: can run ops (no CSRF needed for bearer), cannot manage tokens
        st, job, _ = self.req("POST", "/api/v1/ops/heal", token=bearer)
        self.assertEqual(st, 202)
        job = self.wait_job(job["id"])
        self.assertEqual(job["status"], "failed")
        self.assertIn("volume.fix.replication failed", job["message"])
        st, _, _ = self.req("GET", "/api/v1/tokens", token=bearer)
        self.assertEqual(st, 403)
        st, me, _ = self.req("GET", "/api/v1/me", token=bearer)
        self.assertEqual((me["role"], me["via"]), ("operator", "token"))
        # an API token does not work as an SSO grant, and vice versa
        st, _, _ = self.req("GET", "/sso?grant=" + quote(bearer))
        self.assertEqual(st, 401)
        # revoke
        st, _, _ = self.admin("DELETE", "/api/v1/tokens/" + tok["id"])
        self.assertEqual(st, 200)
        st, _, _ = self.req("GET", "/api/v1/me", token=bearer)
        self.assertEqual(st, 401)
        for bad in ({"name": "x", "role": "root"}, {"name": "x", "role": "admin", "ttlDays": 9999}, {}):
            st, _, _ = self.admin("POST", "/api/v1/tokens", bad)
            self.assertEqual(st, 400, bad)
        audit = self.admin("GET", "/api/v1/audit?limit=200")[1]
        actions = [a["action"] for a in audit]
        self.assertIn("token.create", actions)
        self.assertIn("token.delete", actions)

    def test_regions(self):
        st, reg, _ = self.admin("POST", "/api/v1/regions", {"name": "r2", "envName": "c-2"})
        self.assertEqual(st, 201)
        self.assertEqual((reg["id"], reg["status"]), ("r2", "pending"))
        st, _, _ = self.admin("POST", "/api/v1/regions", {"name": "../x", "envName": "c-2"})
        self.assertEqual(st, 400)
        st, _, _ = self.admin("POST", "/api/v1/regions", {"name": "r3"})
        self.assertEqual(st, 400)
        self.db.upsert_region({"id": "r1", "name": "r1", "envName": "c-1", "status": "online"})
        st, _, _ = self.admin("DELETE", "/api/v1/regions/r1")
        self.assertEqual(st, 409)
        st, _, _ = self.admin("DELETE", "/api/v1/regions/nope")
        self.assertEqual(st, 404)
        st, job, _ = self.admin("DELETE", "/api/v1/regions/r2")
        self.assertEqual(st, 202)
        self.assertEqual(self.wait_job(job["id"])["status"], "succeeded")
        self.assertIsNone(self.db.get_region("r2"))
        self.assertIn("ensure_sync", self.calls)

    def test_nodes_heartbeat_drain_remove(self):
        self.db.upsert_node({"id": "r1-7", "region": "r1", "nodeId": "7", "ip": "10.0.0.7",
                             "roles": ["volume"], "status": "joining"})
        st, _, _ = self.req("POST", "/api/v1/nodes/r1-7/heartbeat", {"diskTotal": 100})
        self.assertEqual(st, 401)
        st, _, _ = self.admin("POST", "/api/v1/nodes/r1-7/heartbeat",
                              {"diskTotal": 1000, "diskUsed": 250, "weedVersion": "4.48",
                               "services": {"volume": "active"}})
        self.assertEqual(st, 200)
        n = self.db.get_node("r1-7")
        self.assertEqual(n["status"], "online")
        self.assertEqual(n["capacity"], {"totalBytes": 1000, "usedBytes": 250, "freeBytes": 750})
        self.assertEqual(n["weedVersion"], "4.48")
        self.assertIsInstance(n["lastSeen"], int)
        self.assertLessEqual(abs(n["lastSeen"] - time.time()), 5)
        st, _, _ = self.admin("POST", "/api/v1/nodes/nope/heartbeat", {})
        self.assertEqual(st, 404)
        st, body, _ = self.admin("DELETE", "/api/v1/nodes/r1-7")
        self.assertEqual(st, 409)
        self.assertIn("not drained", body["error"])
        st, job, _ = self.admin("POST", "/api/v1/nodes/r1-7/drain")
        self.assertEqual(st, 202)
        self.assertEqual(self.wait_job(job["id"])["status"], "succeeded")
        st, body, _ = self.admin("DELETE", "/api/v1/nodes/r1-7")
        self.assertEqual((st, body["ok"]), (200, True))
        st, _, _ = self.admin("POST", "/api/v1/nodes/nope/drain")
        self.assertEqual(st, 404)

    def test_heartbeat_with_node_certificate(self):
        import subprocess
        enroll = __import__("sfsctl.enroll", fromlist=["x"])
        d = tempfile.mkdtemp(dir=self.dir)
        key, csr = os.path.join(d, "node.key"), os.path.join(d, "node.csr")
        subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key],
                       check=True, capture_output=True)
        subprocess.run(["openssl", "req", "-new", "-key", key, "-subj", "/CN=node9.r1",
                        "-addext", "subjectAltName=IP:127.0.0.1", "-out", csr],
                       check=True, capture_output=True)
        with open(csr) as fh:
            cert_pem = enroll.sign_csr(self.cfg["stateDir"], fh.read(), "node9.r1", ["127.0.0.1"])
        cert = os.path.join(d, "node.pem")
        with open(cert, "w") as fh:
            fh.write(cert_pem)
        self.db.upsert_node({"id": "r1-9", "region": "r1", "nodeId": "9", "status": "joining"})
        self.db.upsert_node({"id": "r1-10", "region": "r1", "nodeId": "10", "status": "joining"})
        ctx = ssl.create_default_context(cadata=self.ca_pem)
        ctx.load_cert_chain(cert, key)

        def hb(node_id):
            conn = http.client.HTTPSConnection("127.0.0.1", self.port, context=ctx, timeout=10)
            conn.request("POST", "/api/v1/nodes/%s/heartbeat" % node_id, body=b'{"diskTotal": 5}',
                         headers={"Content-Type": "application/json"})
            st = conn.getresponse().status
            conn.close()
            return st
        self.assertEqual(hb("r1-9"), 200)
        self.assertEqual(self.db.get_node("r1-9")["status"], "online")
        self.assertEqual(hb("r1-10"), 403)  # a node cannot report for another node
        self.assertEqual(self.db.get_node("r1-10")["status"], "joining")
        # the node certificate grants nothing else
        conn = http.client.HTTPSConnection("127.0.0.1", self.port, context=ctx, timeout=10)
        conn.request("GET", "/api/v1/nodes")
        self.assertEqual(conn.getresponse().status, 401)
        conn.close()

    def test_enroll_token_and_enroll_errors(self):
        st, out, _ = self.admin("POST", "/api/v1/nodes/enroll-token",
                                {"region": "r1", "nodeId": "12", "roles": "volume,filer", "ip": "10.0.0.12"})
        self.assertEqual(st, 200)
        self.assertEqual(out["caFingerprint"], self.fp)
        claims = tokens.verify(bytes.fromhex(SECRET), out["token"], "enroll")
        self.assertEqual(claims["nodeId"], "12")
        st, _, _ = self.admin("POST", "/api/v1/nodes/enroll-token",
                              {"region": "r 1", "nodeId": "12", "roles": "volume", "ip": "10.0.0.12"})
        self.assertEqual(st, 400)
        # enroll with a garbage token is rejected with a JSON error (no auth needed to reach it)
        st, body, _ = self.req("POST", "/api/v1/enroll", {"token": "x.y", "csr": "nope"})
        self.assertIn(st, (400, 401, 403))
        self.assertIn("error", body)

    def test_backups(self):
        st, job, _ = self.admin("POST", "/api/v1/backups")
        self.assertEqual(st, 202)
        self.assertEqual(self.wait_job(job["id"])["result"], {"id": "b2"})
        st, job, _ = self.admin("POST", "/api/v1/backups/b1/restore", {"path": "/data", "targetPath": "/restore"})
        self.assertEqual(st, 202)
        self.wait_job(job["id"])
        self.assertIn("restore:b1:/data:/restore", self.calls)
        st, _, _ = self.admin("POST", "/api/v1/backups/b1/restore", {"path": "/data"})
        self.assertEqual(st, 400)
        pol = {"enabled": True, "intervalMinutes": 60, "retentionDays": 7, "target": "/backup"}
        st, out, _ = self.admin("PUT", "/api/v1/backups/policy", pol)
        self.assertEqual((st, out), (200, pol))
        st, _, _ = self.admin("PUT", "/api/v1/backups/policy", dict(pol, intervalMinutes=1))
        self.assertEqual(st, 400)
        self.assertEqual(self.admin("GET", "/api/v1/backups/policy")[1], pol)

    def test_static_ui_path_safety(self):
        sid, _, _, _ = self.login()
        for path in ("/ui/../secret.txt", "/ui/%2e%2e/secret.txt", "/ui/..%2fsecret.txt",
                     "/ui/nope.js", "/ui/%00"):
            st, _, _ = self.req("GET", path, cookie=sid)
            self.assertIn(st, (400, 404), path)
        st, _, r = self.req("GET", "/")
        self.assertEqual((st, r.getheader("Location")), (302, "/ui/"))

    def test_bad_bodies(self):
        for raw in (b"[1,2]", b"{bad json", b"\xff\xfe"):
            conn = http.client.HTTPSConnection("127.0.0.1", self.port, context=self.client_ctx, timeout=10)
            conn.request("POST", "/api/v1/regions", body=raw, headers={
                "Authorization": "Bearer " + self.local_token, "Content-Type": "application/json"})
            self.assertEqual(conn.getresponse().status, 400, raw)
            conn.close()
        conn = http.client.HTTPSConnection("127.0.0.1", self.port, context=self.client_ctx, timeout=10)
        conn.putrequest("POST", "/api/v1/regions")
        conn.putheader("Authorization", "Bearer " + self.local_token)
        conn.putheader("Content-Length", str(2 * 1024 * 1024))
        conn.endheaders()
        self.assertEqual(conn.getresponse().status, 413)
        conn.close()

    def test_cli_against_server(self):
        os.environ["SFSCTL_API"] = "https://127.0.0.1:%d" % self.port
        try:
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = cli.main(["--config", self.cfg_path, "status", "--json"])
            self.assertEqual(rc, 0, buf.getvalue())
            out = json.loads(buf.getvalue())
            self.assertEqual(out["cluster"]["clusterId"], "c-test")
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = cli.main(["--config", self.cfg_path, "rebalance", "--wait", "--timeout", "30"])
            self.assertEqual(rc, 0, buf.getvalue())
            self.assertEqual(json.loads(buf.getvalue())["status"], "succeeded")
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = cli.main(["--config", self.cfg_path, "heal", "--wait", "--timeout", "30"])
            self.assertEqual(rc, 1)
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = cli.main(["--config", self.cfg_path, "sso-grant", "--sub", "42",
                               "--email", "a@b.c", "--role", "admin"])
            self.assertEqual(rc, 0)
            url = json.loads(buf.getvalue())["url"]
            self.assertTrue(url.startswith("https://cp.example.test/sso?grant="))
            st, _, resp = self.req("GET", url[len("https://cp.example.test"):])
            self.assertEqual(st, 302)
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = cli.main(["--config", self.cfg_path, "node", "remove", "missing"])
            self.assertEqual(rc, 1)
            self.assertIn("HTTP 404", json.loads(buf.getvalue())["error"])
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = cli.main(["--config", self.cfg_path, "enroll-token", "--region", "r1",
                               "--node-id", "33", "--roles", "volume,filer,master", "--ip", "10.0.0.33"])
            self.assertEqual(rc, 0, buf.getvalue())
            self.assertIn("token", json.loads(buf.getvalue()))
            buf = io.StringIO()
            with redirect_stdout(buf), redirect_stderr(io.StringIO()):
                rc = cli.main(["--config", self.cfg_path, "no-such-command"])
            self.assertEqual(rc, 2)
            self.assertIn("usage", json.loads(buf.getvalue())["error"])
        finally:
            os.environ.pop("SFSCTL_API", None)


if __name__ == "__main__":
    unittest.main()
