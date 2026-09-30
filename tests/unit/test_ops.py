"""Unit tests for seaweed/topology/health/ops/replication/backups.

Run: PYTHONPATH=control-plane python3 -m unittest tests.unit.test_ops -v
Master responses are real SeaweedFS 4.48 outputs (tests/fixtures/seaweed/); a fake in-process
master serves them, and a fake in-memory filer implements the 4.48 JSON listing + GET + multipart POST.
"""
import email.parser
import email.policy
import json
import os
import shutil
import tempfile
import threading
import time
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from sfsctl import backups, health, ops, replication, seaweed, topology
from sfsctl.db import Database

FIX = os.path.join(os.path.dirname(__file__), "..", "fixtures", "seaweed")


def fixture(name):
    with open(os.path.join(FIX, name)) as f:
        return json.load(f)


class _Srv(object):
    def __init__(self, handler):
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.addr = "127.0.0.1:%d" % self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


def master_handler(overrides):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            name = {"/cluster/status": "cluster_status.json", "/dir/status": "dir_status.json",
                    "/vol/status": "vol_status.json"}.get(self.path.split("?")[0])
            if not name:
                self.send_response(404)
                self.end_headers()
                return
            body = json.dumps(overrides.get(name) or fixture(name)).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
    return H


def filer_handler(files):
    """files: {"/a/b.txt": b"..."}; directories are implied."""
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            u = urllib.parse.urlparse(self.path)
            path = urllib.parse.unquote(u.path)
            if path in files:
                self.send_response(200)
                self.end_headers()
                self.wfile.write(files[path])
                return
            base = path.rstrip("/")
            kids = {}
            for p in files:
                if p.startswith(base + "/"):
                    rest = p[len(base) + 1:].split("/")
                    full = base + "/" + rest[0]
                    kids[full] = (len(rest) > 1, len(files[p]) if len(rest) == 1 else 0)
            q = urllib.parse.parse_qs(u.query)
            limit = int(q.get("limit", ["1000"])[0])
            last = q.get("lastFileName", [""])[0]
            names = sorted(k for k in kids if k.rsplit("/", 1)[1] > last)
            page = names[:limit]
            ents = [{"FullPath": k, "Mode": (1 << 31 | 0o755) if kids[k][0] else 0o644, "FileSize": kids[k][1]} for k in page]
            body = json.dumps({"Path": base, "Entries": ents, "Limit": limit,
                               "LastFileName": page[-1].rsplit("/", 1)[1] if page else "",
                               "ShouldDisplayLoadMore": len(names) > limit}).encode()
            self.send_response(200)
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            n = int(self.headers["Content-Length"])
            raw = b"Content-Type: " + self.headers["Content-Type"].encode() + b"\r\n\r\n" + self.rfile.read(n)
            msg = email.parser.BytesParser(policy=email.policy.HTTP).parsebytes(raw)
            part = next(msg.iter_parts())
            files[urllib.parse.unquote(self.path)] = part.get_payload(decode=True)
            self.send_response(201)
            self.end_headers()
            self.wfile.write(b'{"name":"x","size":1}')
    return H


class FakeJob(object):
    def __init__(self):
        self.id = "job-1"
        self.lines = []

    def log(self, line):
        self.lines.append(line)


class FakeRunner(object):
    def __init__(self):
        self.submitted = []

    def submit(self, type, actor, fn):
        self.submitted.append((type, actor))
        return "j%d" % len(self.submitted)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.db = Database(os.path.join(self.tmp, "t.db"))
        self.overrides = {}
        self.master = _Srv(master_handler(self.overrides))
        self.cfg = {"clusterId": "c1", "clusterName": "demo", "primaryRegion": "r1", "replication": "010",
                    "stateDir": self.tmp, "weedBin": "/nonexistent/weed", "weedConfigDir": self.tmp}
        self.db.upsert_region({"id": "r1", "name": "r1", "envName": "sfs-1", "status": "online",
                               "masters": [self.master.addr], "filers": []})
        now = int(time.time())
        for i in (1, 2, 3):
            self.db.upsert_node({"id": "r1-n%d" % i, "region": "r1", "envName": "sfs-1", "nodeId": i, "ip": "127.0.0.1" if i < 3 else "10.0.0.%d" % i,
                                 "roles": ["volume", "filer"], "status": "online",
                                 "capacity": {"totalBytes": 100, "usedBytes": 10 * i}, "volumes": 0, "lastSeen": now})

    def tearDown(self):
        self.master.close()
        shutil.rmtree(self.tmp, ignore_errors=True)


class TestParsers(unittest.TestCase):
    def test_dir_status(self):
        nodes = seaweed.parse_dir_status(fixture("dir_status.json"))
        self.assertEqual(len(nodes), 3)
        self.assertEqual(nodes[0]["dataCenter"], "r1")
        self.assertEqual({n["rack"] for n in nodes}, {"node1", "node2", "node3"})
        self.assertEqual(nodes[0]["max"], 10)

    def test_vol_status_and_placement(self):
        reps = seaweed.parse_vol_status(fixture("vol_status.json"))
        self.assertTrue(reps)
        self.assertTrue(all(r["replication"] == "010" for r in reps))
        self.assertEqual(seaweed.under_replicated(reps), [])  # healthy 3-node 010 cluster
        self.assertEqual(seaweed.placement_str({}), "000")
        self.assertEqual(seaweed.expected_copies("010"), 2)

    def test_under_replicated_detected(self):
        reps = [r for r in seaweed.parse_vol_status(fixture("vol_status.json")) if r["server"] != "127.0.0.1:8083"]
        bad = seaweed.under_replicated(reps)
        self.assertTrue(bad)
        self.assertTrue(all(b["actual"] == 1 and b["expected"] == 2 for b in bad))

    def test_volume_id_ranges(self):
        self.assertEqual(seaweed.parse_volume_ids(" 1 3 5-6"), [1, 3, 5, 6])
        nodes = seaweed.parse_dir_status(fixture("dir_status_ranges.json"))
        self.assertTrue(all(len(n["volumeIds"]) == n["volumes"] for n in nodes))

    def test_version_and_shell_errors(self):
        self.assertEqual(seaweed.parse_version(fixture("dir_status.json")["Version"]), "4.48")
        self.assertEqual(seaweed.shell_errors("ok\nerror: failed to move volume 1\n"), ["error: failed to move volume 1"])

    def test_shell_missing_binary(self):
        rc, out = seaweed.shell({"weedBin": "/nonexistent/weed"}, "127.0.0.1:9333", ["volume.list"])
        self.assertEqual(rc, 127)


class TestTopologyHealth(Base):
    def test_cluster_and_nodes(self):
        s = topology.cluster_summary(self.cfg, self.db)
        self.assertEqual(s["counts"], {"regions": 1, "nodes": 3, "volumes": 6})
        self.assertEqual(s["version"], "4.48")
        self.assertEqual(s["capacity"]["totalBytes"], 300)
        nodes = {n["id"]: n for n in topology.list_nodes(self.cfg, self.db)}
        self.assertEqual(nodes["r1-n1"]["status"], "online")
        self.assertEqual(nodes["r1-n3"]["status"], "offline")  # 10.0.0.3 not a registered volume server
        regions = topology.list_regions(self.cfg, self.db)
        self.assertEqual(regions[0]["status"], "online")
        self.assertEqual(regions[0]["nodes"], 3)

    def test_health_checks(self):
        h = health.current(self.cfg, self.db)
        checks = {c["name"]: c for c in h["checks"]}
        self.assertEqual(checks["masters"]["status"], "ok")
        self.assertEqual(checks["volume_servers"]["status"], "degraded")
        self.assertEqual(checks["replication_local"]["status"], "ok")
        self.assertEqual(h["status"], "degraded")
        self.assertIn("updatedAt", h)

    def test_master_down_is_critical(self):
        self.master.close()
        h = health.current(self.cfg, self.db)
        self.assertEqual(h["status"], "critical")

    def test_disk_thresholds_and_skew_rebalance(self):
        n = self.db.get_node("r1-n2")
        n["capacity"] = {"totalBytes": 100, "usedBytes": 95}
        self.db.upsert_node(n)
        res = health.compute(self.cfg, self.db)
        self.assertEqual({c["name"]: c for c in res["checks"]}["disk_usage"]["status"], "critical")
        runner = FakeRunner()
        self.assertEqual(health.tick(self.cfg, self.db, runner), ["ops.rebalance"])  # 95 vs 10 -> skew 85
        self.assertEqual(health.tick(self.cfg, self.db, runner), [])  # cooldown
        self.assertTrue(any(a["action"] == "ops.rebalance.auto" for a in self.db.list_audit()))

    def test_heal_after_five_minutes(self):
        vs = fixture("vol_status.json")
        vs["Volumes"]["DataCenters"]["r1"].pop("node3")
        self.overrides["vol_status.json"] = vs
        runner = FakeRunner()
        t0 = time.time()
        self.assertEqual(health.tick(self.cfg, self.db, runner, now=t0), [])
        self.assertEqual(health.tick(self.cfg, self.db, runner, now=t0 + 120), [])
        self.assertEqual(health.tick(self.cfg, self.db, runner, now=t0 + 301), ["ops.heal"])
        self.assertEqual(runner.submitted[0], ("ops.heal", "system:monitor"))


class TestOps(Base):
    def test_remove_requires_drained(self):
        with self.assertRaises(ops.OpsError) as cm:
            ops.remove_node(self.cfg, self.db, "r1-n1")
        self.assertEqual(cm.exception.status, 409)
        n = self.db.get_node("r1-n1")
        n["status"] = "drained"
        self.db.upsert_node(n)
        self.assertTrue(ops.remove_node(self.cfg, self.db, "r1-n1")["ok"])
        self.assertIsNone(self.db.get_node("r1-n1"))

    def test_remove_forced_offline(self):
        n = self.db.get_node("r1-n3")
        n["lastSeen"] = int(time.time()) - 25 * 3600
        self.db.upsert_node(n)
        with self.assertRaises(ops.OpsError):
            ops.remove_node(self.cfg, self.db, "r1-n3")
        self.assertTrue(ops.remove_node(self.cfg, self.db, "r1-n3", force=True)["healRecommended"])

    def test_drain_node_without_volume_server(self):
        res = ops.drain_node(self.cfg, self.db, FakeJob(), "r1-n3")
        self.assertEqual(res["status"], "drained")
        self.assertEqual(self.db.get_node("r1-n3")["status"], "drained")

    def test_drain_failure_restores_status(self):
        # weed binary missing -> evacuate fails, volumes remain -> status restored
        orig = ops.time.sleep
        ops.time.sleep = lambda s: None
        try:
            with self.assertRaises(ops.OpsError):
                ops.drain_node(self.cfg, self.db, FakeJob(), "r1-n1")
        finally:
            ops.time.sleep = orig
        self.assertEqual(self.db.get_node("r1-n1")["status"], "online")

    def test_rebalance_reports_shell_failure(self):
        with self.assertRaises(ops.OpsError):
            ops.rebalance(self.cfg, self.db, FakeJob())


class TestReplication(Base):
    def test_supervisor_restarts_with_backoff(self):
        fake = os.path.join(self.tmp, "weed")
        with open(fake, "w") as f:
            f.write("#!/bin/sh\necho \"sync $*\"; echo boom >&2; exit 3\n")
        os.chmod(fake, 0o755)
        self.cfg["weedBin"] = fake
        self.db.upsert_region({"id": "r1", "name": "r1", "envName": "e1", "status": "online",
                               "masters": [self.master.addr], "filers": ["10.0.0.1:8888"]})
        self.db.upsert_region({"id": "r2", "name": "r2", "envName": "e2", "status": "online",
                               "masters": [], "filers": ["10.1.0.1:8888"]})
        try:
            replication.ensure_sync(self.cfg, self.db)
            st = replication.status(self.cfg, self.db)
            self.assertEqual([(s["from"], s["to"]) for s in st], [("r1", "r2"), ("r2", "r1")])
            self.assertEqual(st[0]["status"], "running")
            time.sleep(0.5)
            replication.ensure_sync(self.cfg, self.db)
            st = replication.status(self.cfg, self.db)
            self.assertEqual(st[0]["status"], "restarting")
            self.assertIn("exit 3", st[0]["lastError"])
            with open(os.path.join(self.tmp, "filer-sync-r1-r2.log")) as f:
                self.assertIn("filer.sync -a 10.0.0.1:8888 -b 10.1.0.1:8888", f.read())
        finally:
            replication.stop_all()


class TestReplicationLag(unittest.TestCase):
    def test_parse_progress_real_log_line(self):
        log = ("I0930 05:34:26.590693 filer_sync.go:351 start sync 172.17.0.4:8888(-7) => 172.17.0.4:8889(2) from 1970\n"
               "I0930 05:34:34.499045 filer_sync.go:443 sync 172.17.0.4:8888 to 172.17.0.4:8889 progressed to "
               "2026-09-30 05:30:09.126167222 +0000 UTC 1.01/sec\n")
        self.assertEqual(replication.parse_progress(log, 2026), {("172.17.0.4:8888", "172.17.0.4:8889"): 265})


class TestBackups(Base):
    def test_policy_validation(self):
        with self.assertRaises(backups.BackupError):
            backups.set_policy(self.cfg, self.db, {"target": "s3://bucket"})
        p = backups.set_policy(self.cfg, self.db, {"enabled": True, "intervalMinutes": 60, "target": self.tmp + "/bk"})
        self.assertEqual(backups.get_policy(self.cfg, self.db)["intervalMinutes"], 60)
        self.assertTrue(p["enabled"])

    def test_snapshot_list_restore_and_schedule(self):
        files = {"/data/a.txt": b"alpha", "/data/sub/b.bin": b"\x00\x01beta", "/top.txt": b"top"}
        filer = _Srv(filer_handler(files))
        try:
            self.db.upsert_region({"id": "r1", "name": "r1", "envName": "e1", "status": "online",
                                   "masters": [self.master.addr], "filers": [filer.addr]})
            backups.set_policy(self.cfg, self.db, {"enabled": True, "intervalMinutes": 60, "target": self.tmp + "/bk"})
            res = backups.run_backup(self.cfg, self.db, FakeJob())
            self.assertEqual(res["files"], 3)
            lst = backups.list_backups(self.cfg, self.db)
            self.assertEqual(lst[0]["id"], res["id"])
            self.assertEqual(lst[0]["status"], "complete")
            self.assertEqual(lst[0]["sizeBytes"], 5 + 6 + 3)
            r = backups.restore(self.cfg, self.db, FakeJob(), res["id"], "/data", "/restored")
            self.assertEqual(r["files"], 2)
            self.assertEqual(files["/restored/sub/b.bin"], b"\x00\x01beta")
            self.assertEqual(files["/restored/a.txt"], b"alpha")
            with self.assertRaises(backups.BackupError):
                backups.restore(self.cfg, self.db, FakeJob(), res["id"], "/../etc", "/x")
            runner = FakeRunner()
            self.assertFalse(backups.scheduler_tick(self.cfg, self.db, runner))  # just ran
            self.assertTrue(backups.scheduler_tick(self.cfg, self.db, runner, now=time.time() + 3601))
        finally:
            filer.close()


if __name__ == "__main__":
    unittest.main()
