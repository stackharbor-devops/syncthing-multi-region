#!/bin/bash
# Install (or upgrade in place) the sfsctl control plane on the primary storage master.
#
#   install.sh --cluster-id ID --cluster-name NAME --primary-region R --env-domain D \
#              --cp-ip IP [--replication 010] [--listen 0.0.0.0:8480] \
#              [--src DIR | --tarball URL]
#
# Every option can also come from the environment: SFS_CLUSTER_ID, SFS_CLUSTER_NAME,
# SFS_PRIMARY_REGION, SFS_ENV_DOMAIN, SFS_CP_IP, SFS_REPLICATION, SFS_LISTEN,
# SFS_SRC, SFS_TARBALL.
# Re-running keeps the existing secret, local token, CA and database.
# Output contract: machine lines SFS_RESULT=ok|failed, SFS_MESSAGE=..., SFS_JSON=...
set -euo pipefail
umask 077

PREFIX=/opt/sfsctl
ETC=/etc/sfsctl
STATE=/var/lib/sfsctl
CONFIG=$ETC/config.json
TOKEN=$ETC/local.token
UNIT=/etc/systemd/system/sfsctl.service

CLUSTER_ID=${SFS_CLUSTER_ID:-}
CLUSTER_NAME=${SFS_CLUSTER_NAME:-}
PRIMARY_REGION=${SFS_PRIMARY_REGION:-}
ENV_DOMAIN=${SFS_ENV_DOMAIN:-}
CP_IP=${SFS_CP_IP:-}
REPLICATION=${SFS_REPLICATION:-}
LISTEN=${SFS_LISTEN:-}
SRC=${SFS_SRC:-}
TARBALL=${SFS_TARBALL:-}

fail() {
  echo "ERROR: $*" >&2
  echo "SFS_RESULT=failed"
  echo "SFS_MESSAGE=$*"
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cluster-id) CLUSTER_ID=$2; shift 2 ;;
    --cluster-name) CLUSTER_NAME=$2; shift 2 ;;
    --primary-region) PRIMARY_REGION=$2; shift 2 ;;
    --env-domain) ENV_DOMAIN=$2; shift 2 ;;
    --cp-ip) CP_IP=$2; shift 2 ;;
    --replication) REPLICATION=$2; shift 2 ;;
    --listen) LISTEN=$2; shift 2 ;;
    --src) SRC=$2; shift 2 ;;
    --tarball) TARBALL=$2; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) fail "unknown option $1" ;;
  esac
done

[ "$(id -u)" = 0 ] || fail "must run as root"

need_pkgs=""
command -v python3 >/dev/null 2>&1 || need_pkgs="$need_pkgs python3"
command -v openssl >/dev/null 2>&1 || need_pkgs="$need_pkgs openssl"
command -v curl >/dev/null 2>&1 || need_pkgs="$need_pkgs curl"
if [ -n "$need_pkgs" ]; then
  echo "installing:$need_pkgs"
  dnf -y -q install $need_pkgs >/dev/null || yum -y -q install $need_pkgs >/dev/null || fail "cannot install$need_pkgs"
fi
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' || fail "python >= 3.9 required"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# -- locate the source tree (the control-plane directory) ------------------------------
if [ -n "$TARBALL" ]; then
  curl -fsSL --retry 3 -o "$WORK/src.tar.gz" "$TARBALL" || fail "download failed: $TARBALL"
  tar -xzf "$WORK/src.tar.gz" -C "$WORK" || fail "bad tarball"
  SRC=$(dirname "$(find "$WORK" -path '*/control-plane/sfsctl/server.py' | head -n 1)")
  SRC=$(dirname "$SRC")
fi
if [ -z "$SRC" ]; then
  SRC=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
fi
[ -f "$SRC/sfsctl/server.py" ] || fail "control-plane source not found in $SRC"

# -- code -------------------------------------------------------------------------------
rm -rf "$PREFIX.new"
mkdir -p "$PREFIX.new"
cp -a "$SRC/." "$PREFIX.new/"
find "$PREFIX.new" -name '__pycache__' -type d -prune -exec rm -rf {} +
chmod -R go-w "$PREFIX.new"
chmod 755 "$PREFIX.new"
find "$PREFIX.new" -type d -exec chmod 755 {} +
find "$PREFIX.new" -type f -exec chmod 644 {} +
chmod 755 "$PREFIX.new/bin/sfsctl" "$PREFIX.new/install.sh"
rm -rf "$PREFIX.old"
[ -d "$PREFIX" ] && mv "$PREFIX" "$PREFIX.old"
mv "$PREFIX.new" "$PREFIX"
rm -rf "$PREFIX.old"
install -m 0755 "$PREFIX/bin/sfsctl" /usr/local/bin/sfsctl

# -- config, secret, local token ------------------------------------------------------------
mkdir -p "$ETC" "$STATE"
chmod 700 "$ETC" "$STATE"
if [ ! -s "$TOKEN" ]; then
  openssl rand -hex 32 > "$TOKEN.tmp"
  chmod 600 "$TOKEN.tmp"
  mv "$TOKEN.tmp" "$TOKEN"
fi
chmod 600 "$TOKEN"

NEW_SECRET=$(openssl rand -hex 32)
export CONFIG CLUSTER_ID CLUSTER_NAME PRIMARY_REGION ENV_DOMAIN CP_IP REPLICATION LISTEN NEW_SECRET TOKEN STATE
python3 - <<'PY' || fail "cannot write config"
import json, os
path = os.environ["CONFIG"]
cfg = {}
if os.path.exists(path):
    with open(path) as fh:
        cfg = json.load(fh)
defaults = {"listen": "0.0.0.0:8480", "stateDir": os.environ["STATE"],
            "weedBin": "/usr/local/bin/weed", "replication": "010",
            "localTokenPath": os.environ["TOKEN"], "clusterName": "", "envDomain": "",
            "primaryRegion": "", "cpIp": ""}
for k, v in defaults.items():
    cfg.setdefault(k, v)
if not cfg.get("secret"):
    cfg["secret"] = os.environ["NEW_SECRET"]  # never rotated by a re-install
for env, key in (("CLUSTER_ID", "clusterId"), ("CLUSTER_NAME", "clusterName"),
                 ("PRIMARY_REGION", "primaryRegion"), ("ENV_DOMAIN", "envDomain"),
                 ("CP_IP", "cpIp"), ("REPLICATION", "replication"), ("LISTEN", "listen")):
    if os.environ.get(env):
        cfg[key] = os.environ[env]
missing = [k for k in ("clusterId", "primaryRegion", "envDomain", "cpIp") if not cfg.get(k)]
if missing:
    raise SystemExit("missing settings: " + ", ".join(missing))
tmp = path + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as fh:
    json.dump(cfg, fh, indent=2, sort_keys=True)
    fh.write("\n")
os.replace(tmp, path)
PY
chmod 600 "$CONFIG"

# -- redeploy persistence (Jelastic keeps listed paths across container redeploys) -----------
if [ -d /etc/jelastic ]; then
  touch /etc/jelastic/redeploy.conf
  for p in /etc/sfsctl /var/lib/sfsctl /opt/sfsctl /usr/local/bin/sfsctl /etc/systemd/system/sfsctl.service; do
    grep -qxF "$p" /etc/jelastic/redeploy.conf || echo "$p" >> /etc/jelastic/redeploy.conf
  done
fi

# -- service ---------------------------------------------------------------------------------------
install -m 0644 "$PREFIX/systemd/sfsctl.service" "$UNIT"
systemctl daemon-reload
systemctl enable sfsctl.service >/dev/null 2>&1
systemctl restart sfsctl.service

PORT=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["listen"].rsplit(":",1)[1])' "$CONFIG")
ok=""
for _ in $(seq 1 30); do
  if curl -fsk --max-time 3 "https://127.0.0.1:$PORT/api/v1/ca" -o "$WORK/ca.json" 2>/dev/null; then
    ok=1
    break
  fi
  sleep 1
done
if [ -z "$ok" ]; then
  journalctl -u sfsctl --no-pager -n 30 2>/dev/null || true
  fail "sfsctl did not become ready on port $PORT"
fi
FP=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["fingerprint"])' "$WORK/ca.json")
echo "SFS_RESULT=ok"
echo "SFS_MESSAGE=sfsctl running on port $PORT"
echo "SFS_JSON={\"caFingerprint\": \"$FP\", \"cpUrl\": \"https://$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["cpIp"])' "$CONFIG"):$PORT\"}"
