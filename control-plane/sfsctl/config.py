"""Control-plane configuration (/etc/sfsctl/config.json, mode 0600)."""

import json
import os
import re

DEFAULT_PATH = "/etc/sfsctl/config.json"

DEFAULTS = {
    "clusterId": "",
    "clusterName": "",
    "primaryRegion": "",
    "envDomain": "",
    "listen": "0.0.0.0:8480",
    "stateDir": "/var/lib/sfsctl",
    "secret": "",
    "weedBin": "/usr/local/bin/weed",
    "replication": "010",
    "cpIp": "",
    "localTokenPath": "/etc/sfsctl/local.token",
}

_HEX64 = re.compile(r"^[0-9a-f]{64}$")


class ConfigError(Exception):
    pass


def load(path=DEFAULT_PATH):
    """Read the JSON config, fill defaults and validate the fields everything relies on."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError) as exc:
        raise ConfigError("cannot read config %s: %s" % (path, exc))
    if not isinstance(data, dict):
        raise ConfigError("config %s is not a JSON object" % path)
    cfg = dict(DEFAULTS)
    cfg.update(data)
    cfg["secret"] = str(cfg.get("secret") or "").strip().lower()
    if not _HEX64.match(cfg["secret"]):
        raise ConfigError("config secret must be 64 hex characters")
    if not cfg.get("clusterId"):
        raise ConfigError("config clusterId is empty")
    cfg["_path"] = os.path.abspath(path)
    return cfg


def secret_bytes(cfg):
    """HMAC key used by tokens.mint / tokens.verify."""
    return bytes.fromhex(cfg["secret"])


def listen_addr(cfg):
    """'host:port' -> (host, port)."""
    value = str(cfg.get("listen") or DEFAULTS["listen"])
    host, _, port = value.rpartition(":")
    return (host.strip("[]") or "0.0.0.0", int(port))


def db_path(cfg):
    return os.path.join(cfg["stateDir"], "sfsctl.db")
