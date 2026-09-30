"""Cluster CA, node enrollment (CSR signing) and the control plane's own TLS cert.

Uses the openssl CLI via subprocess (OpenSSL 3 on AlmaLinux 9; LibreSSL works too).
Standard library only. See ARCHITECTURE.md sections 3 and 4.
"""
import datetime
import hashlib
import hmac
import ipaddress
import json
import os
import re
import secrets
import ssl
import subprocess
import tempfile
import threading
import time

from sfsctl import tokens

OPENSSL = os.environ.get("SFS_OPENSSL", "openssl")
ENROLL_TTL = 15 * 60
CERT_DAYS = 365
CA_DAYS = 3650
SERVER_RENEW_BEFORE = 30 * 86400
ALLOWED_ROLES = ("master", "volume", "filer", "client")
# "client" = app node that only mounts the filesystem: gets a cluster-CA cert for
# filer mTLS, no JWT keys, and is not recorded as a storage node.
MAX_CSR_LEN = 16384
SERVER_DNS = ("sfsctl", "localhost")  # nginx on bl verifies proxy_ssl_name "sfsctl"
_RE_REGION = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$")
_RE_NODE_ID = re.compile(r"^[0-9]{1,12}$")
_RE_HOST = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$")
_lock = threading.RLock()


class EnrollError(Exception):
    def __init__(self, status, message):
        Exception.__init__(self, message)
        self.status = int(status)
        self.message = str(message)


# -- openssl helpers --------------------------------------------------------------
def _run(args, input_data=None, timeout=60):
    try:
        proc = subprocess.run([OPENSSL] + list(args), input=input_data,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    except FileNotFoundError:
        raise EnrollError(500, "openssl CLI not found")
    if proc.returncode != 0:
        err = proc.stderr.decode("utf-8", "replace").strip().splitlines()
        raise EnrollError(500, "openssl %s failed: %s" % (args[0], err[-1] if err else proc.returncode))
    return proc.stdout


def _write_private(path, data):
    """Atomically write a file readable only by the owner (0600)."""
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(data if isinstance(data, bytes) else data.encode("utf-8"))
        os.replace(tmp, path)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def _write_public(path, data):
    _write_private(path, data)
    os.chmod(path, 0o644)


def _gen_ec_key(path):
    old = os.umask(0o077)
    try:
        tmp = path + ".new"
        _run(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", tmp])
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    finally:
        os.umask(old)


def fingerprint(cert_pem):
    """'sha256:<lowercase hex>' of the certificate DER (no colons)."""
    der = ssl.PEM_cert_to_DER_cert(cert_pem.strip() + "\n")
    return "sha256:" + hashlib.sha256(der).hexdigest()


def _serial():
    return "0x" + secrets.token_hex(16)


def _san_line(ips, dns):
    items = ["DNS:%s" % d for d in dns] + ["IP:%s" % i for i in ips]
    return ",".join(items)


def _ensure_dir(state_dir):
    os.makedirs(state_dir, mode=0o700, exist_ok=True)


# -- CA -------------------------------------------------------------------------
def ensure_ca(state_dir):
    """Create (once) the cluster CA. Returns (ca_pem, "sha256:<hex>")."""
    key = os.path.join(state_dir, "ca.key")
    crt = os.path.join(state_dir, "ca.pem")
    with _lock:
        _ensure_dir(state_dir)
        if not (os.path.exists(key) and os.path.exists(crt)):
            _gen_ec_key(key)
            with tempfile.TemporaryDirectory(dir=state_dir) as tmp:
                cnf = os.path.join(tmp, "ca.cnf")
                with open(cnf, "w") as f:
                    f.write("[req]\ndistinguished_name=dn\nprompt=no\nx509_extensions=v3\n"
                            "[dn]\nCN=sfs-cluster-ca\nO=sfs\n"
                            "[v3]\nbasicConstraints=critical,CA:TRUE,pathlen:0\n"
                            "keyUsage=critical,keyCertSign,cRLSign\n"
                            "subjectKeyIdentifier=hash\n")
                out = os.path.join(tmp, "ca.pem")
                _run(["req", "-new", "-x509", "-config", cnf, "-key", key, "-sha256",
                      "-days", str(CA_DAYS), "-set_serial", _serial(), "-out", out])
                with open(out) as f:
                    _write_public(crt, f.read())
        os.chmod(key, 0o600)
        with open(crt) as f:
            pem = f.read()
    return pem, fingerprint(pem)


def _sign(state_dir, csr_path, out_path, ips, dns, eku):
    ensure_ca(state_dir)
    with tempfile.TemporaryDirectory(dir=state_dir) as tmp:
        ext = os.path.join(tmp, "ext.cnf")
        with open(ext, "w") as f:
            f.write("[v3]\nbasicConstraints=critical,CA:FALSE\n"
                    "keyUsage=critical,digitalSignature,keyEncipherment\n"
                    "extendedKeyUsage=%s\nsubjectAltName=%s\n"
                    "authorityKeyIdentifier=keyid\n" % (eku, _san_line(ips, dns)))
        _run(["x509", "-req", "-in", csr_path, "-CA", os.path.join(state_dir, "ca.pem"),
              "-CAkey", os.path.join(state_dir, "ca.key"), "-set_serial", _serial(),
              "-days", str(CERT_DAYS), "-sha256", "-extfile", ext, "-extensions", "v3",
              "-out", out_path])


# -- control plane server certificate ---------------------------------------------
def ensure_server_cert(state_dir, ips, hostnames):
    """TLS cert for the control plane listener (8480), signed by the cluster CA.

    SANs: the given ips + 127.0.0.1, hostnames + "sfsctl" + "localhost". Reissued when
    the SAN set changes or less than 30 days remain. Returns (cert_path, key_path).
    """
    ips = sorted(set([str(ipaddress.ip_address(str(i).strip())) for i in (ips or []) if str(i).strip()]
                     + ["127.0.0.1"]))
    dns = sorted(set([h.strip() for h in (hostnames or []) if h and _RE_HOST.match(h.strip())]
                     + list(SERVER_DNS)))
    crt = os.path.join(state_dir, "server.pem")
    key = os.path.join(state_dir, "server.key")
    meta = os.path.join(state_dir, "server.meta.json")
    want = {"ips": ips, "dns": dns}
    with _lock:
        ensure_ca(state_dir)
        fresh = False
        if os.path.exists(crt) and os.path.exists(key) and os.path.exists(meta):
            try:
                with open(meta) as f:
                    have = json.load(f)
                fresh = (have.get("ips") == ips and have.get("dns") == dns
                         and have.get("notAfter", 0) - time.time() > SERVER_RENEW_BEFORE)
            except (ValueError, OSError):
                fresh = False
        if not fresh:
            _gen_ec_key(key)
            with tempfile.TemporaryDirectory(dir=state_dir) as tmp:
                cnf = os.path.join(tmp, "req.cnf")
                with open(cnf, "w") as f:
                    f.write("[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nCN=sfsctl\nO=sfs\n")
                csr = os.path.join(tmp, "server.csr")
                _run(["req", "-new", "-config", cnf, "-key", key, "-sha256", "-out", csr])
                out = os.path.join(tmp, "server.pem")
                _sign(state_dir, csr, out, ips, dns, "serverAuth,clientAuth")
                with open(out) as f:
                    _write_public(crt, f.read())
            want["notAfter"] = int(time.time()) + CERT_DAYS * 86400
            _write_private(meta, json.dumps(want))
    return crt, key


# -- CSR signing ------------------------------------------------------------------
def _csr_info(csr_path):
    text = _run(["req", "-in", csr_path, "-noout", "-text"]).decode("utf-8", "replace")
    subj = _run(["req", "-in", csr_path, "-noout", "-subject", "-nameopt", "RFC2253"])
    subj = subj.decode("utf-8", "replace").strip()
    m = re.search(r"CN=([^,/+]+)", subj)
    cn = m.group(1).strip() if m else ""
    csr_ips = re.findall(r"IP Address:([0-9A-Fa-f:.]+)", text)
    csr_dns = re.findall(r"DNS:([^,\s]+)", text)
    if "id-ecPublicKey" in text:
        key_ok = "prime256v1" in text or "P-256" in text or "secp384r1" in text or "P-384" in text
    elif "rsaEncryption" in text:
        m = re.search(r"Public-Key: \((\d+) bit\)", text)
        key_ok = bool(m and int(m.group(1)) >= 2048)
    else:
        key_ok = False
    return cn, [str(ipaddress.ip_address(i)) for i in csr_ips], csr_dns, key_ok


def _check_csr(csr, cn, allowed):
    try:
        _run(["req", "-in", csr, "-noout", "-verify"])
    except EnrollError:
        raise EnrollError(400, "csr signature invalid or malformed")
    csr_cn, csr_ips, _dns, key_ok = _csr_info(csr)
    if not key_ok:
        raise EnrollError(400, "csr key must be EC P-256/P-384 or RSA >= 2048")
    if csr_cn != cn:
        raise EnrollError(400, "csr CN %r does not match expected %r" % (csr_cn, cn))
    if not csr_ips or not (set(csr_ips) & allowed):
        raise EnrollError(403, "csr SAN IP does not match the token ip")
    extra = set(csr_ips) - allowed - {"127.0.0.1"}
    if extra:
        raise EnrollError(403, "csr SAN IP %s not allowed by the token" % ",".join(sorted(extra)))


def sign_csr(state_dir, csr_pem, cn, ips, check_only=False):
    """Validate a node CSR and sign it (365 d, clientAuth+serverAuth).

    The CSR must be self-signature valid, CN == cn, every SAN IP in `ips` (plus
    127.0.0.1) and at least one of `ips` present. The issued cert carries OUR SANs:
    ips + 127.0.0.1, DNS cn + localhost; CSR extensions are never copied.
    check_only=True validates without signing (returns "").
    """
    if not isinstance(csr_pem, str) or len(csr_pem) > MAX_CSR_LEN or \
            "-----BEGIN CERTIFICATE REQUEST-----" not in csr_pem:
        raise EnrollError(400, "csr must be a PEM certificate request")
    allowed = set(str(ipaddress.ip_address(str(i))) for i in ips)
    with _lock:
        ensure_ca(state_dir)
        with tempfile.TemporaryDirectory(dir=state_dir) as tmp:
            csr = os.path.join(tmp, "node.csr")
            with open(csr, "w") as f:
                f.write(csr_pem.strip() + "\n")
            _check_csr(csr, cn, allowed)
            if check_only:
                return ""
            out = os.path.join(tmp, "node.pem")
            _sign(state_dir, csr, out, sorted(allowed | {"127.0.0.1"}), [cn, "localhost"],
                  "serverAuth,clientAuth")
            with open(out) as f:
                return f.read()


# -- tokens -----------------------------------------------------------------------
def _norm_roles(roles):
    if isinstance(roles, str):
        roles = roles.split(",")
    if not isinstance(roles, (list, tuple)):
        raise EnrollError(400, "roles must be a list")
    out = []
    for r in roles:
        r = str(r).strip().lower()
        if not r:
            continue
        if r not in ALLOWED_ROLES:
            raise EnrollError(400, "unknown role %r" % r)
        if r not in out:
            out.append(r)
    if not out:
        raise EnrollError(400, "at least one role is required")
    if "client" in out and len(out) > 1:
        raise EnrollError(400, "role 'client' cannot be combined with storage roles")
    return sorted(out)


def _norm_ip(ip):
    try:
        addr = ipaddress.ip_address(str(ip).strip())
    except ValueError:
        raise EnrollError(400, "invalid ip %r" % (ip,))
    if addr.is_loopback or addr.is_unspecified or addr.is_multicast or addr.is_link_local:
        raise EnrollError(400, "ip %s is not a usable node address" % addr)
    return str(addr)


def _iso(ts):
    return datetime.datetime.utcfromtimestamp(ts).strftime("%Y-%m-%dT%H:%M:%SZ")


def _secret(cfg):
    return tokens.key_bytes(cfg["secret"])


def issue_enroll_token(cfg, db, region, node_id, roles, ip, actor="system"):
    """Mint a one-time enroll token (15 min). -> {token, expiresAt, caFingerprint}."""
    region = str(region or "").strip()
    if not _RE_REGION.match(region):
        raise EnrollError(400, "invalid region %r" % region)
    node_id = str(node_id if node_id is not None else "").strip()
    if not _RE_NODE_ID.match(node_id):
        raise EnrollError(400, "invalid node id %r" % node_id)
    roles = _norm_roles(roles)
    ip = _norm_ip(ip)
    _pem, fp = ensure_ca(cfg["stateDir"])
    claims = {"typ": "enroll", "cid": cfg.get("clusterId", ""), "region": region,
              "nodeId": node_id, "roles": roles, "ip": ip}
    tok = tokens.mint(_secret(cfg), claims, ENROLL_TTL)
    exp = tokens.verify(_secret(cfg), tok, "enroll")["exp"]
    db.audit(actor, "node.enroll-token", "%s-%s" % (region, node_id), "ok",
             "roles=%s ip=%s" % (",".join(roles), ip))
    return {"token": tok, "expiresAt": _iso(exp), "caFingerprint": fp}


def node_key(region, node_id):
    """Primary key of a node record: '<region>-<jelastic node id>'."""
    return "%s-%s" % (region, node_id)


def jwt_keys(cfg):
    """SeaweedFS volume JWT keys, derived one-way from the cluster secret."""
    k = _secret(cfg)
    w = hmac.new(k, b"sfs/jwt-signing/v1", hashlib.sha256).hexdigest()
    r = hmac.new(k, b"sfs/jwt-read/v1", hashlib.sha256).hexdigest()
    return w, r


def _region_peers(db, region, me):
    masters, filers = set(), set()
    reg = None
    try:
        reg = db.get_region(region) if hasattr(db, "get_region") else None
    except Exception:
        reg = None
    if reg is None:
        reg = next((r for r in db.list_regions() if r.get("id") == region), None)
    for m in (reg or {}).get("masters") or []:
        masters.add(m if ":" in m else m + ":9333")
    for n in db.list_nodes():
        if n.get("region") != region or n.get("status") == "removed" or n.get("id") == me["id"]:
            continue
        if "master" in (n.get("roles") or []):
            masters.add("%s:9333" % n.get("ip"))
        if "filer" in (n.get("roles") or []):
            filers.add("%s:8888" % n.get("ip"))
    if "master" in me["roles"]:
        masters.add("%s:9333" % me["ip"])
    return reg, sorted(masters), sorted(filers)


def handle_enroll(cfg, db, body, remote_ip):
    """POST /api/v1/enroll. Returns the section 4 response or raises EnrollError."""
    state_dir = cfg["stateDir"]
    target = "unknown"
    try:
        if not isinstance(body, dict):
            raise EnrollError(400, "body must be a JSON object")
        try:
            claims = tokens.verify(_secret(cfg), body.get("token") or "", "enroll")
        except tokens.TokenError as e:
            raise EnrollError(401, "invalid enroll token: %s" % e)
        if claims.get("cid", cfg.get("clusterId", "")) != cfg.get("clusterId", ""):
            raise EnrollError(401, "enroll token belongs to another cluster")
        region, nid = str(claims.get("region")), str(claims.get("nodeId"))
        roles = _norm_roles(claims.get("roles") or [])  # roles come from the token only
        ip = _norm_ip(claims.get("ip"))
        target = node_key(region, nid)
        if body.get("ip") and _norm_ip(body.get("ip")) != ip:
            raise EnrollError(403, "ip %s does not match the token ip" % body.get("ip"))
        if cfg.get("enrollCheckSourceIp", True) and remote_ip:
            try:
                src_addr = ipaddress.ip_address(str(remote_ip))
                mapped = getattr(src_addr, "ipv4_mapped", None)  # ::ffff:10.0.0.5 on dual-stack
                src = str(mapped or src_addr)
            except ValueError:
                src = str(remote_ip)
            if src != ip:
                raise EnrollError(403, "request source %s does not match the token ip %s" % (src, ip))
        hostname = str(body.get("hostname") or "")[:253]
        if hostname and not _RE_HOST.match(hostname):
            hostname = ""
        cn = "node%s.%s" % (nid, region)
        csr = body.get("csr")
        # Validate the CSR before burning the jti so a malformed CSR does not waste
        # the token; burn right before signing so concurrent replays lose the race.
        sign_csr(state_dir, csr, cn, [ip], check_only=True)
        if not db.use_jti(claims["jti"], claims["exp"]):
            raise EnrollError(401, "enroll token already used")
        cert = sign_csr(state_dir, csr, cn, [ip])
        ca_pem, fp = ensure_ca(state_dir)
        me = {"id": target, "ip": ip, "roles": roles}
        reg, masters, filers = _region_peers(db, region, me)
        if roles == ["client"]:
            clients = db.kv_get("clients", {}) or {}
            clients[target] = {"ip": ip, "region": region, "nodeId": nid, "hostname": hostname,
                               "certFingerprint": fingerprint(cert), "enrolledAt": _iso(time.time())}
            db.kv_set("clients", clients)
            db.audit("node:" + target, "client.enroll", target, "ok",
                     "ip=%s fp=%s" % (ip, fingerprint(cert)))
            return {
                "cert": cert, "ca": ca_pem, "node": {"id": target, "cn": cn},
                "config": {"clusterId": cfg.get("clusterId", ""), "region": region,
                           "masters": masters, "replication": "", "jwtSigningKey": "",
                           "jwtReadKey": "", "dataCenter": region, "rack": "node%s" % nid,
                           "filerPeers": filers, "caFingerprint": fp},
            }
        prev = db.get_node(target) or {}
        db.upsert_node({
            "id": target, "region": region, "envName": prev.get("envName") or (reg or {}).get("envName", ""),
            "nodeId": nid, "ip": ip, "roles": roles, "status": "joining", "hostname": hostname,
            "capacity": prev.get("capacity") or {"totalBytes": 0, "usedBytes": 0},
            "volumes": prev.get("volumes") or 0, "lastSeen": prev.get("lastSeen"),
            "certFingerprint": fingerprint(cert), "enrolledAt": _iso(time.time()),
        })
        region_doc = {"id": region, "masters": masters,
                      "filers": sorted(set(filers) | ({"%s:8888" % ip} if "filer" in roles else set()))}
        if reg is None:
            region_doc.update({"name": region, "envName": "", "status": "active"})
        db.upsert_region(region_doc)
        jwt_w, jwt_r = jwt_keys(cfg)
        replication = db.kv_get("replication", None) or cfg.get("replication", "010")
        db.audit("node:" + target, "node.enroll", target, "ok",
                 "roles=%s ip=%s fp=%s" % (",".join(roles), ip, fingerprint(cert)))
        return {
            "cert": cert,
            "ca": ca_pem,
            "node": {"id": target, "cn": cn},
            "config": {
                "clusterId": cfg.get("clusterId", ""),
                "region": region,
                "masters": masters,
                "replication": replication,
                "jwtSigningKey": jwt_w,
                "jwtReadKey": jwt_r,
                "dataCenter": region,
                "rack": "node%s" % nid,
                "filerPeers": filers,
                "caFingerprint": fp,
            },
        }
    except EnrollError as e:
        try:
            db.audit("remote:%s" % remote_ip, "node.enroll", target, "denied", e.message)
        except Exception:
            pass
        raise
