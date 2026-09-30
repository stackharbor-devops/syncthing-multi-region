"""Enrollment tests with the real openssl CLI.

Run: PYTHONPATH=control-plane python3 -m unittest discover -s tests/unit
"""
import os
import shutil
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import unittest
from unittest import mock

from sfsctl import enroll, tokens

try:
    from sfsctl.db import Database
except Exception:  # pragma: no cover - db.py owned by another component
    Database = None

OPENSSL = enroll.OPENSSL


def make_csr(workdir, cn, ips, dns=()):
    key = os.path.join(workdir, "node.key")
    cnf = os.path.join(workdir, "csr.cnf")
    san = ",".join(["IP:%s" % i for i in ips] + ["DNS:%s" % d for d in dns])
    with open(cnf, "w") as f:
        f.write("[req]\ndistinguished_name=dn\nprompt=no\nreq_extensions=ext\n"
                "[dn]\nCN=%s\n[ext]\n%s\n" % (cn, ("subjectAltName=" + san) if san else ""))
    subprocess.run([OPENSSL, "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key],
                   check=True, capture_output=True)
    out = subprocess.run([OPENSSL, "req", "-new", "-config", cnf, "-key", key, "-sha256"],
                         check=True, capture_output=True)
    return out.stdout.decode(), key


class FakeDB(object):
    def __init__(self):
        self.jti, self.audits, self.nodes, self.regions, self.kv = set(), [], {}, {}, {}

    def use_jti(self, jti, exp):
        if jti in self.jti:
            return False
        self.jti.add(jti)
        return True

    def audit(self, actor, action, target, result, detail=""):
        self.audits.append((actor, action, target, result, detail))

    def upsert_node(self, n):
        self.nodes.setdefault(n["id"], {}).update(n)

    def get_node(self, i):
        return self.nodes.get(i)

    def list_nodes(self):
        return list(self.nodes.values())

    def upsert_region(self, r):
        self.regions.setdefault(r["id"], {}).update(r)

    def list_regions(self):
        return list(self.regions.values())

    def kv_get(self, k, default=None):
        return self.kv.get(k, default)

    def kv_set(self, k, v):
        self.kv[k] = v


class EnrollTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="sfs-enroll-")
        self.state = os.path.join(self.dir, "state")
        self.cfg = {"clusterId": "c1", "secret": "11" * 32, "stateDir": self.state,
                    "replication": "010"}
        self.db = FakeDB()

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def _token(self, ip="10.1.0.5", roles="volume,filer,master", node="12", region="r1"):
        return enroll.issue_enroll_token(self.cfg, self.db, region, node, roles, ip)

    def test_ca_created_once_key_private(self):
        pem, fp = enroll.ensure_ca(self.state)
        self.assertTrue(pem.startswith("-----BEGIN CERTIFICATE-----"))
        self.assertTrue(fp.startswith("sha256:") and len(fp) == 71)
        self.assertEqual(os.stat(os.path.join(self.state, "ca.key")).st_mode & 0o777, 0o600)
        der = subprocess.run([OPENSSL, "x509", "-in", os.path.join(self.state, "ca.pem"),
                              "-outform", "DER"], check=True, capture_output=True).stdout
        import hashlib
        self.assertEqual(fp, "sha256:" + hashlib.sha256(der).hexdigest())
        self.assertEqual(enroll.ensure_ca(self.state), (pem, fp))

    def test_full_round_trip(self):
        t = self._token()
        self.assertEqual(t["caFingerprint"], enroll.ensure_ca(self.state)[1])
        csr, _key = make_csr(self.dir, "node12.r1", ["10.1.0.5"])
        # roles in the request are ignored: the token decides
        res = enroll.handle_enroll(self.cfg, self.db, {"token": t["token"], "csr": csr,
                                                       "hostname": "node12-env", "ip": "10.1.0.5",
                                                       "roles": ["volume"]}, "10.1.0.5")
        cert = os.path.join(self.dir, "node.pem")
        ca = os.path.join(self.dir, "ca.pem")
        with open(cert, "w") as f:
            f.write(res["cert"])
        with open(ca, "w") as f:
            f.write(res["ca"])
        v = subprocess.run([OPENSSL, "verify", "-CAfile", ca, cert], capture_output=True)
        self.assertEqual(v.returncode, 0, v.stdout + v.stderr)
        text = subprocess.run([OPENSSL, "x509", "-in", cert, "-noout", "-text"],
                              check=True, capture_output=True).stdout.decode()
        self.assertIn("IP Address:10.1.0.5", text)
        self.assertIn("TLS Web Client Authentication", text)
        c = res["config"]
        self.assertEqual(c["masters"], ["10.1.0.5:9333"])
        self.assertEqual((c["dataCenter"], c["rack"], c["region"]), ("r1", "node12", "r1"))
        self.assertEqual(len(c["jwtSigningKey"]), 64)
        self.assertNotEqual(c["jwtSigningKey"], c["jwtReadKey"])
        node = self.db.nodes["r1-12"]
        self.assertEqual(node["status"], "joining")
        self.assertEqual(node["roles"], ["filer", "master", "volume"])
        self.assertTrue(any(a[1] == "node.enroll" and a[3] == "ok" for a in self.db.audits))
        # second node sees the first as master and filer peer
        t2 = self._token(ip="10.1.0.6", node="13", roles="volume,filer")
        csr2, _ = make_csr(self.dir, "node13.r1", ["10.1.0.6"])
        res2 = enroll.handle_enroll(self.cfg, self.db, {"token": t2["token"], "csr": csr2}, "10.1.0.6")
        self.assertEqual(res2["config"]["masters"], ["10.1.0.5:9333"])
        self.assertEqual(res2["config"]["filerPeers"], ["10.1.0.5:8888"])

    def test_client_role_cert_only(self):
        with self.assertRaises(enroll.EnrollError) as cm:
            self._token(roles="client,volume")
        self.assertEqual(cm.exception.status, 400)
        t = self._token(ip="10.1.0.9", roles="client", node="30")
        csr, _ = make_csr(self.dir, "node30.r1", ["10.1.0.9"])
        r = enroll.handle_enroll(self.cfg, self.db, {"token": t["token"], "csr": csr}, "10.1.0.9")
        self.assertTrue(r["cert"].startswith("-----BEGIN CERTIFICATE-----"))
        self.assertEqual(r["config"]["jwtSigningKey"], "")
        self.assertEqual(r["config"]["jwtReadKey"], "")
        self.assertEqual(self.db.nodes, {})            # not a storage node
        self.assertIn("r1-30", self.db.kv["clients"])

    def test_replay_rejected(self):
        t = self._token()
        csr, _ = make_csr(self.dir, "node12.r1", ["10.1.0.5"])
        enroll.handle_enroll(self.cfg, self.db, {"token": t["token"], "csr": csr}, "10.1.0.5")
        with self.assertRaises(enroll.EnrollError) as cm:
            enroll.handle_enroll(self.cfg, self.db, {"token": t["token"], "csr": csr}, "10.1.0.5")
        self.assertEqual(cm.exception.status, 401)
        self.assertTrue(any(a[3] == "denied" for a in self.db.audits))

    def test_wrong_ip_in_csr(self):
        t = self._token()
        csr, _ = make_csr(self.dir, "node12.r1", ["10.1.0.99"])
        with self.assertRaises(enroll.EnrollError) as cm:
            enroll.handle_enroll(self.cfg, self.db, {"token": t["token"], "csr": csr}, "10.1.0.5")
        self.assertEqual(cm.exception.status, 403)

    def test_extra_ip_in_csr(self):
        t = self._token()
        csr, _ = make_csr(self.dir, "node12.r1", ["10.1.0.5", "10.9.9.9"])
        with self.assertRaises(enroll.EnrollError) as cm:
            enroll.handle_enroll(self.cfg, self.db, {"token": t["token"], "csr": csr}, "10.1.0.5")
        self.assertEqual(cm.exception.status, 403)

    def test_wrong_source_ip_and_body_ip(self):
        t = self._token()
        csr, _ = make_csr(self.dir, "node12.r1", ["10.1.0.5"])
        with self.assertRaises(enroll.EnrollError) as cm:
            enroll.handle_enroll(self.cfg, self.db, {"token": t["token"], "csr": csr}, "10.1.0.77")
        self.assertEqual(cm.exception.status, 403)
        with self.assertRaises(enroll.EnrollError) as cm:
            enroll.handle_enroll(self.cfg, self.db, {"token": t["token"], "csr": csr,
                                                     "ip": "10.1.0.8"}, "10.1.0.5")
        self.assertEqual(cm.exception.status, 403)
        # the token was not burned by the rejected attempts
        enroll.handle_enroll(self.cfg, self.db, {"token": t["token"], "csr": csr}, "10.1.0.5")

    def test_ipv4_mapped_source_accepted(self):
        t = self._token()
        csr, _ = make_csr(self.dir, "node12.r1", ["10.1.0.5"])
        res = enroll.handle_enroll(self.cfg, self.db, {"token": t["token"], "csr": csr}, "::ffff:10.1.0.5")
        self.assertEqual(res["node"]["id"], "r1-12")

    def test_wrong_cn(self):
        t = self._token()
        csr, _ = make_csr(self.dir, "node1.r1", ["10.1.0.5"])
        with self.assertRaises(enroll.EnrollError) as cm:
            enroll.handle_enroll(self.cfg, self.db, {"token": t["token"], "csr": csr}, "10.1.0.5")
        self.assertEqual(cm.exception.status, 400)

    def test_bad_tokens(self):
        csr, _ = make_csr(self.dir, "node12.r1", ["10.1.0.5"])
        sso = tokens.mint(self.cfg["secret"], {"typ": "sso", "ip": "10.1.0.5"}, 60)
        for tok in ["", "garbage", sso]:
            with self.assertRaises(enroll.EnrollError) as cm:
                enroll.handle_enroll(self.cfg, self.db, {"token": tok, "csr": csr}, "10.1.0.5")
            self.assertEqual(cm.exception.status, 401)
        t = self._token()
        with mock.patch("time.time", return_value=time.time() + enroll.ENROLL_TTL + 1):
            with self.assertRaises(enroll.EnrollError) as cm:
                enroll.handle_enroll(self.cfg, self.db, {"token": t["token"], "csr": csr}, "10.1.0.5")
        self.assertEqual(cm.exception.status, 401)
        other = dict(self.cfg, clusterId="c2")
        with self.assertRaises(enroll.EnrollError):
            enroll.handle_enroll(other, self.db, {"token": t["token"], "csr": csr}, "10.1.0.5")

    def test_bad_csr_does_not_burn_token(self):
        t = self._token()
        for bad in ["nope", "-----BEGIN CERTIFICATE REQUEST-----\nAAAA\n-----END CERTIFICATE REQUEST-----"]:
            with self.assertRaises(enroll.EnrollError) as cm:
                enroll.handle_enroll(self.cfg, self.db, {"token": t["token"], "csr": bad}, "10.1.0.5")
            self.assertEqual(cm.exception.status, 400)

    def test_issue_validation(self):
        for args in [("r 1", "1", "volume", "10.0.0.1"), ("r1", "x", "volume", "10.0.0.1"),
                     ("r1", "1", "admin", "10.0.0.1"), ("r1", "1", "", "10.0.0.1"),
                     ("r1", "1", "volume", "127.0.0.1"), ("r1", "1", "volume", "nope")]:
            with self.assertRaises(enroll.EnrollError):
                enroll.issue_enroll_token(self.cfg, self.db, *args)

    def test_server_cert_tls_handshake(self):
        crt, key = enroll.ensure_server_cert(self.state, ["10.1.0.5"], ["cp.example"])
        self.assertEqual(os.stat(key).st_mode & 0o777, 0o600)
        mtime = os.stat(crt).st_mtime
        self.assertEqual(enroll.ensure_server_cert(self.state, ["10.1.0.5"], ["cp.example"]), (crt, key))
        self.assertEqual(os.stat(crt).st_mtime, mtime)
        sctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        sctx.load_cert_chain(crt, key)
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        port = srv.getsockname()[1]

        def serve():
            conn, _ = srv.accept()
            try:
                with sctx.wrap_socket(conn, server_side=True) as s:
                    s.sendall(b"ok")
            except Exception:
                pass
        th = threading.Thread(target=serve, daemon=True)
        th.start()
        cctx = ssl.create_default_context(cafile=os.path.join(self.state, "ca.pem"))
        with socket.create_connection(("127.0.0.1", port)) as raw:
            with cctx.wrap_socket(raw, server_hostname="sfsctl") as s:
                self.assertEqual(s.recv(2), b"ok")
        th.join(5)
        srv.close()

    @unittest.skipIf(Database is None, "sfsctl.db not available")
    def test_with_real_database(self):
        db = Database(os.path.join(self.dir, "t.db"))
        t = enroll.issue_enroll_token(self.cfg, db, "r2", "40", ["volume", "filer"], "10.2.0.4")
        csr, _ = make_csr(self.dir, "node40.r2", ["10.2.0.4"])
        res = enroll.handle_enroll(self.cfg, db, {"token": t["token"], "csr": csr}, "10.2.0.4")
        self.assertEqual(db.get_node("r2-40")["status"], "joining")
        self.assertEqual(res["node"]["id"], "r2-40")
        with self.assertRaises(enroll.EnrollError):
            enroll.handle_enroll(self.cfg, db, {"token": t["token"], "csr": csr}, "10.2.0.4")


if __name__ == "__main__":
    unittest.main()
