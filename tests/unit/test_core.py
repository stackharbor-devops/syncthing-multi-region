"""Unit tests for sfsctl.config, sfsctl.db and sfsctl.jobs.

Run: PYTHONPATH=control-plane python3 -m unittest discover -s tests/unit -v
"""

import json
import os
import shutil
import tempfile
import threading
import time
import unittest

from sfsctl import config, db as dbmod, jobs


class ConfigTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "config.json")

    def tearDown(self):
        shutil.rmtree(self.dir)

    def write(self, data):
        with open(self.path, "w") as fh:
            json.dump(data, fh)

    def test_defaults_and_secret(self):
        self.write({"clusterId": "c1", "secret": "AB" * 32, "primaryRegion": "r1"})
        cfg = config.load(self.path)
        self.assertEqual(cfg["listen"], "0.0.0.0:8480")
        self.assertEqual(cfg["replication"], "010")
        self.assertEqual(cfg["secret"], "ab" * 32)
        self.assertEqual(config.secret_bytes(cfg), bytes.fromhex("ab" * 32))
        self.assertEqual(config.listen_addr(cfg), ("0.0.0.0", 8480))
        self.assertEqual(config.db_path(cfg), "/var/lib/sfsctl/sfsctl.db")

    def test_rejects_bad_secret_and_missing_file(self):
        self.write({"clusterId": "c1", "secret": "short"})
        with self.assertRaises(config.ConfigError):
            config.load(self.path)
        with self.assertRaises(config.ConfigError):
            config.load(os.path.join(self.dir, "missing.json"))
        self.write({"secret": "00" * 32})
        with self.assertRaises(config.ConfigError):
            config.load(self.path)


class DatabaseTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.db = dbmod.Database(os.path.join(self.dir, "state", "sfsctl.db"))

    def tearDown(self):
        self.db.close()
        shutil.rmtree(self.dir)

    def test_db_file_private(self):
        self.assertEqual(os.stat(self.db.path).st_mode & 0o777, 0o600)

    def test_jti_single_use(self):
        exp = int(time.time()) + 60
        self.assertTrue(self.db.use_jti("abc", exp))
        self.assertFalse(self.db.use_jti("abc", exp))
        self.assertFalse(self.db.use_jti("", exp))
        self.assertTrue(self.db.use_jti("def", exp))

    def test_audit(self):
        self.db.audit("alice", "ops.heal", "cluster", "ok", "job j1")
        self.db.audit("bob", "node.drain", "r1-5", "error", "x" * 5000)
        rows = self.db.list_audit(10)
        self.assertEqual([r["actor"] for r in rows], ["bob", "alice"])
        self.assertEqual(set(rows[0]), {"ts", "actor", "action", "target", "result", "detail"})
        self.assertTrue(rows[0]["ts"].endswith("Z"))
        self.assertEqual(len(rows[0]["detail"]), 4000)
        self.assertEqual(len(self.db.list_audit(1)), 1)

    def test_nodes_merge_and_delete(self):
        self.db.upsert_node({"id": "r1-5", "region": "r1", "nodeId": "5", "ip": "10.0.0.5",
                             "roles": ["volume", "filer"], "status": "joining",
                             "capacity": {}, "volumes": 0, "lastSeen": None})
        self.db.upsert_node({"id": "r1-5", "status": "online", "volumes": 3})
        n = self.db.get_node("r1-5")
        self.assertEqual(n["status"], "online")
        self.assertEqual(n["roles"], ["volume", "filer"])
        self.assertEqual(n["volumes"], 3)
        self.db.upsert_node({"id": "r1-6", "region": "r1"})
        self.assertEqual([x["id"] for x in self.db.list_nodes()], ["r1-5", "r1-6"])
        self.db.delete_node("r1-5")
        self.assertIsNone(self.db.get_node("r1-5"))
        with self.assertRaises(ValueError):
            self.db.upsert_node({"region": "r1"})

    def test_regions_and_kv(self):
        self.db.upsert_region({"id": "r1", "name": "r1", "envName": "c-1", "status": "online",
                               "masters": ["10.0.0.1:9333"], "filers": []})
        self.assertEqual(self.db.list_regions()[0]["masters"], ["10.0.0.1:9333"])
        self.db.delete_region("r1")
        self.assertEqual(self.db.list_regions(), [])
        self.assertEqual(self.db.kv_get("nope", {"d": 1}), {"d": 1})
        self.db.kv_set("policy", {"enabled": True, "n": [1, 2]})
        self.assertEqual(self.db.kv_get("policy"), {"enabled": True, "n": [1, 2]})

    def test_sessions(self):
        sid = self.db.create_session("u1", "u1@example.com", "admin", 3600, 1800)
        self.assertGreaterEqual(len(sid), 43)
        s = self.db.get_session(sid)
        self.assertEqual((s["sub"], s["email"], s["role"]), ("u1", "u1@example.com", "admin"))
        self.assertIsNone(self.db.get_session("forged"))
        # the raw sid is never stored
        raw = self.db._all("SELECT sid_hash FROM sessions")
        self.assertNotIn(sid, [r["sid_hash"] for r in raw])
        self.db.delete_session(sid)
        self.assertIsNone(self.db.get_session(sid))
        # idle and absolute expiry
        idle = self.db.create_session("u2", "", "viewer", 3600, 0.05)
        absolute = self.db.create_session("u3", "", "viewer", 0.05, 3600)
        time.sleep(0.1)
        self.assertIsNone(self.db.get_session(idle))
        self.assertIsNone(self.db.get_session(absolute))

    def test_jobs(self):
        jid = self.db.create_job("ops.heal", "alice")
        j = self.db.get_job(jid)
        self.assertEqual((j["status"], j["type"], j["actor"]), ("queued", "ops.heal", "alice"))
        self.db.update_job(jid, status="running", started=time.time())
        self.db.append_job_log(jid, "line one")
        self.db.append_job_log(jid, "line two\n")
        self.db.update_job(jid, status="succeeded", finished=time.time(), result={"fixed": 2})
        j = self.db.get_job(jid)
        self.assertEqual(j["log"], "line one\nline two\n")
        self.assertEqual(j["result"], {"fixed": 2})
        self.assertTrue(j["startedAt"] and j["finishedAt"])
        self.assertEqual(self.db.list_jobs(5)[0]["id"], jid)
        with self.assertRaises(ValueError):
            self.db.update_job(jid, bogus=1)
        j2 = self.db.create_job("ops.rebalance", "bob")
        self.assertEqual([x["id"] for x in self.db.active_jobs()], [j2])
        self.db.fail_stale_jobs()
        self.assertEqual(self.db.get_job(j2)["status"], "failed")

    def test_api_tokens(self):
        exp = int(time.time()) + 100
        self.db.add_api_token("t1", "operator", "ci", exp)
        t = self.db.get_api_token("t1")
        self.assertEqual((t["role"], t["name"], t["exp"]), ("operator", "ci", exp))
        self.assertEqual(len(self.db.list_api_tokens()), 1)
        self.assertTrue(self.db.delete_api_token("t1"))
        self.assertFalse(self.db.delete_api_token("t1"))
        self.assertIsNone(self.db.get_api_token("t1"))

    def test_thread_safety(self):
        jid = self.db.create_job("x", "y")

        def worker(n):
            for i in range(50):
                self.db.append_job_log(jid, "%d-%d" % (n, i))
                self.db.audit("w%d" % n, "a", "t", "ok")
        ts = [threading.Thread(target=worker, args=(n,)) for n in range(8)]
        for t in ts:
            t.start()
        for t in ts:
            t.join()
        self.assertEqual(len(self.db.get_job(jid)["log"].splitlines()), 400)
        self.assertEqual(len(self.db.list_audit(1000)), 400)


class JobRunnerTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.db = dbmod.Database(os.path.join(self.dir, "sfsctl.db"))
        self.runner = jobs.JobRunner(self.db)

    def tearDown(self):
        self.db.close()
        shutil.rmtree(self.dir)

    def test_success(self):
        def fn(job):
            job.log("working on %s" % job.id)
            return {"moved": 3, "message": "done"}
        jid = self.runner.submit("ops.rebalance", "alice", fn)
        j = self.runner.wait(jid, 5)
        self.assertEqual(j["status"], "succeeded")
        self.assertEqual(j["result"], {"moved": 3, "message": "done"})
        self.assertEqual(j["message"], "done")
        self.assertIn("working on %s" % jid, j["log"])

    def test_failure(self):
        def fn(job):
            job.log("about to fail")
            raise RuntimeError("master unreachable")
        jid = self.runner.submit("ops.heal", "bob", fn)
        j = self.runner.wait(jid, 5)
        self.assertEqual(j["status"], "failed")
        self.assertEqual(j["message"], "RuntimeError: master unreachable")
        self.assertIn("ERROR RuntimeError: master unreachable", j["log"])

    def test_running_and_non_dict_result(self):
        gate = threading.Event()

        def fn(job):
            gate.wait(5)
            return 42
        jid = self.runner.submit("backup.run", "sys", fn)
        time.sleep(0.05)
        self.assertEqual([x["id"] for x in self.runner.running("backup.run")], [jid])
        self.assertEqual(self.runner.running("ops.heal"), [])
        gate.set()
        j = self.runner.wait(jid, 5)
        self.assertEqual(j["result"], {"value": 42})
        self.assertEqual(self.runner.running(), [])


if __name__ == "__main__":
    unittest.main()
