"""sfsctl CLI (runs as root on the control-plane node).

Every command prints one JSON document on stdout and exits non-zero on failure.
It talks to the local API over https://127.0.0.1:<port> with the local admin token,
verifying the server certificate against the cluster CA. sso-grant is minted locally.
"""

import argparse
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request

from . import config as config_mod

SSO_TTL = 60


class CliError(Exception):
    pass


def _ca_pem(cfg):
    path = os.path.join(cfg["stateDir"], "ca.pem")
    try:
        with open(path) as fh:
            return fh.read()
    except OSError:
        from . import enroll
        return enroll.ensure_ca(cfg["stateDir"])[0]


def _api_base(cfg):
    _, port = config_mod.listen_addr(cfg)
    return os.environ.get("SFSCTL_API") or "https://127.0.0.1:%d" % port


def api(cfg, method, path, body=None, timeout=60):
    token = ""
    try:
        with open(cfg["localTokenPath"]) as fh:
            token = fh.read().strip()
    except OSError as exc:
        raise CliError("cannot read local token %s: %s" % (cfg["localTokenPath"], exc))
    base = _api_base(cfg)
    ctx = None
    if base.startswith("https://"):
        ctx = ssl.create_default_context(cadata=_ca_pem(cfg))
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            msg = json.loads(raw.decode()).get("error") or raw.decode()
        except Exception:
            msg = raw.decode("utf-8", "replace")
        raise CliError("HTTP %d: %s" % (exc.code, msg))
    except (urllib.error.URLError, OSError) as exc:
        raise CliError("control plane unreachable at %s: %s" % (base, getattr(exc, "reason", exc)))
    return json.loads(raw.decode() or "null")


def wait_job(cfg, job, timeout):
    deadline = time.time() + timeout
    while job.get("status") in ("queued", "running") and time.time() < deadline:
        time.sleep(2)
        job = api(cfg, "GET", "/api/v1/jobs/%s" % job["id"])
    return job


def _job_cmd(cfg, args, method, path, body=None):
    job = api(cfg, method, path, body)
    if getattr(args, "wait", False):
        job = wait_job(cfg, job, args.timeout)
        if job.get("status") != "succeeded":
            print(json.dumps(job, sort_keys=True))
            raise SystemExit(1)
    return job


def cmd_status(cfg, args):
    out = {"cluster": api(cfg, "GET", "/api/v1/cluster"),
           "health": api(cfg, "GET", "/api/v1/health"),
           "regions": api(cfg, "GET", "/api/v1/regions"),
           "nodes": api(cfg, "GET", "/api/v1/nodes")}
    return out


def cmd_enroll_token(cfg, args):
    roles = [r.strip() for r in args.roles.split(",") if r.strip()]
    return api(cfg, "POST", "/api/v1/nodes/enroll-token",
               {"region": args.region, "nodeId": args.node_id, "roles": roles, "ip": args.ip})


def cmd_sso_grant(cfg, args):
    from . import tokens
    from .db import Database
    if args.role not in ("admin", "operator", "viewer"):
        raise CliError("role must be admin, operator or viewer")
    grant = tokens.mint(config_mod.secret_bytes(cfg),
                        {"typ": "sso", "sub": args.sub, "email": args.email or "",
                         "role": args.role, "cid": cfg["clusterId"]}, SSO_TTL)
    domain = args.domain or cfg.get("envDomain")
    if not domain:
        raise CliError("envDomain is not configured")
    try:
        Database(config_mod.db_path(cfg)).audit(
            "%s <%s>" % (args.sub, args.email) if args.email else args.sub,
            "sso.grant", args.role, "ok", "60 s one-time grant minted")
    except Exception:
        pass  # audit is best effort here; the login itself is audited by the server
    return {"url": "https://%s/sso?grant=%s" % (domain, grant), "expiresIn": SSO_TTL}


def cmd_node(cfg, args):
    if args.node_cmd == "drain":
        return _job_cmd(cfg, args, "POST", "/api/v1/nodes/%s/drain" % args.id)
    if args.node_cmd == "remove":
        q = "?force=1" if args.force else ""
        return api(cfg, "DELETE", "/api/v1/nodes/%s%s" % (args.id, q))
    if args.node_cmd == "list":
        return api(cfg, "GET", "/api/v1/nodes")
    raise CliError("unknown node command")


def cmd_region(cfg, args):
    if args.region_cmd == "add":
        return api(cfg, "POST", "/api/v1/regions", {"name": args.name, "envName": args.env})
    if args.region_cmd == "remove":
        return _job_cmd(cfg, args, "DELETE", "/api/v1/regions/%s" % args.name)
    if args.region_cmd == "list":
        return api(cfg, "GET", "/api/v1/regions")
    raise CliError("unknown region command")


def cmd_backup(cfg, args):
    if args.backup_cmd == "now":
        return _job_cmd(cfg, args, "POST", "/api/v1/backups")
    if args.backup_cmd == "list":
        return api(cfg, "GET", "/api/v1/backups")
    raise CliError("unknown backup command")


def cmd_job(cfg, args):
    job = api(cfg, "GET", "/api/v1/jobs/%s" % args.id)
    if args.wait:
        job = wait_job(cfg, job, args.timeout)
    return job


class JsonArgumentParser(argparse.ArgumentParser):
    """Usage errors still print one JSON document on stdout (JPS parses stdout)."""

    def error(self, message):
        self.print_usage(sys.stderr)
        print(json.dumps({"error": "usage: %s" % message}))
        raise SystemExit(2)


def parser():
    ap = JsonArgumentParser(prog="sfsctl", description="SeaweedFS platform control plane CLI")
    ap.add_argument("--config", default=os.environ.get("SFSCTL_CONFIG", config_mod.DEFAULT_PATH))
    sub = ap.add_subparsers(dest="cmd")

    def waitable(p):
        p.add_argument("--wait", action="store_true", help="wait for the job to finish")
        p.add_argument("--timeout", type=int, default=3000, help="seconds to wait (default 3000)")
        return p

    p = sub.add_parser("status")
    p.add_argument("--json", action="store_true", help="accepted for compatibility (output is always JSON)")
    p.set_defaults(fn=cmd_status)

    p = sub.add_parser("enroll-token")
    p.add_argument("--region", required=True)
    p.add_argument("--node-id", required=True)
    p.add_argument("--roles", required=True, help="comma list: volume,filer[,master]")
    p.add_argument("--ip", required=True)
    p.set_defaults(fn=cmd_enroll_token)

    p = sub.add_parser("sso-grant")
    p.add_argument("--sub", required=True)
    p.add_argument("--email", default="")
    p.add_argument("--role", default="admin")
    p.add_argument("--domain", default="", help="override envDomain from the config")
    p.set_defaults(fn=cmd_sso_grant)

    p = sub.add_parser("node")
    nsub = p.add_subparsers(dest="node_cmd")
    waitable(nsub.add_parser("drain")).add_argument("id")
    r = nsub.add_parser("remove")
    r.add_argument("id")
    r.add_argument("--force", action="store_true")
    nsub.add_parser("list")
    p.set_defaults(fn=cmd_node)

    waitable(sub.add_parser("rebalance")).set_defaults(
        fn=lambda cfg, a: _job_cmd(cfg, a, "POST", "/api/v1/ops/rebalance"))
    waitable(sub.add_parser("heal")).set_defaults(
        fn=lambda cfg, a: _job_cmd(cfg, a, "POST", "/api/v1/ops/heal"))

    p = sub.add_parser("region")
    rsub = p.add_subparsers(dest="region_cmd")
    r = rsub.add_parser("add")
    r.add_argument("--name", required=True)
    r.add_argument("--env", required=True)
    waitable(rsub.add_parser("remove")).add_argument("--name", required=True)
    rsub.add_parser("list")
    p.set_defaults(fn=cmd_region)

    p = sub.add_parser("backup")
    bsub = p.add_subparsers(dest="backup_cmd")
    waitable(bsub.add_parser("now"))
    bsub.add_parser("list")
    p.set_defaults(fn=cmd_backup)

    p = waitable(sub.add_parser("job"))
    p.add_argument("id")
    p.set_defaults(fn=cmd_job)
    return ap


def main(argv=None):
    ap = parser()
    try:
        args = ap.parse_args(argv)
    except SystemExit as exc:
        return int(exc.code or 0)
    if not getattr(args, "fn", None):
        ap.print_help(sys.stderr)
        print(json.dumps({"error": "no command given"}))
        return 2
    try:
        cfg = config_mod.load(args.config)
        out = args.fn(cfg, args)
    except (CliError, config_mod.ConfigError) as exc:
        print(json.dumps({"error": str(exc)}))
        return 1
    except SystemExit as exc:
        return int(exc.code or 0)
    print(json.dumps(out, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
