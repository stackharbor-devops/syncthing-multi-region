#!/bin/bash
# sfs-node - storage node runner (docs/ARCHITECTURE.md sections 2, 4, 7).
# Installed as /usr/local/sbin/sfs-node, run as root by JPS ExecCmd.
#
#   sfs-node install --version 4.48 [--tarball FILE]
#   sfs-node enroll --cp https://IP:8480 --token T --ca-fingerprint sha256:HEX \
#                   --region R --node-id N --ip IP --roles volume,filer[,master] [--no-start]
#   sfs-node start | stop | status | drain-check | remove [--force] [--purge]
#   sfs-node heartbeat                     (sfs-agent.timer: POST status to the control plane, mTLS)
#   sfs-node run master|volume|filer       (ExecStart of the systemd units; execs weed)
#   sfs-node render-units DIR              (writes the systemd unit files into DIR)
#
# Machine output: SFS_RESULT=ok|failed, SFS_MESSAGE=<line>, SFS_JSON=<one-line JSON>.
# Exit 0 only with SFS_RESULT=ok.
# Test mode without systemd: SFS_NO_SYSTEMD=1 (weed runs in the background, pid files in /run/sfs).
set -Eeuo pipefail
umask 077

WEED_VERSION_PIN="4.48"
SHA256_AMD64="4a7d108384d044d95212d1342cdda9533fa55842c1c9b41f606ca3c8a9561124"
SHA256_ARM64="557e92c38c5c7d180748eb8e2b2b45e426f8e5282a4caca8e098a90d09f03a07"
RELEASE_URL="https://github.com/seaweedfs/seaweedfs/releases/download"

ETC=/etc/sfs
LIB=/var/lib/sfs
RUN=/run/sfs
WEED=/usr/local/bin/weed
SELF=/usr/local/sbin/sfs-node
UNIT_DIR=/etc/systemd/system
REDEPLOY_CONF=/etc/jelastic/redeploy.conf
ALL_ROLES="master volume filer"

say()  { printf '%s\n' "$*"; }
ok()   { say "SFS_MESSAGE=$*"; say "SFS_RESULT=ok"; exit 0; }
die()  { say "SFS_MESSAGE=$*"; say "SFS_RESULT=failed"; exit 1; }
trap 'rc=$?; if [ $rc -ne 0 ]; then say "SFS_MESSAGE=command failed (line $LINENO, exit $rc)"; say "SFS_RESULT=failed"; fi' ERR

need_root() { [ "$(id -u)" = 0 ] || die "must run as root"; }
use_systemd() { [ "${SFS_NO_SYSTEMD:-0}" != 1 ] && command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; }
load_env() { [ -f "$ETC/node.env" ] || die "node not enrolled ($ETC/node.env missing)"; set -a; . "$ETC/node.env"; set +a; }
has_role() { case ",${SFS_ROLES:-}," in *",$1,"*) return 0;; esac; return 1; }

# ---------------------------------------------------------------- install
cmd_install() {
  local version="" tarball=""
  while [ $# -gt 0 ]; do case "$1" in
    --version) version="$2"; shift 2;;
    --tarball) tarball="$2"; shift 2;;
    *) die "install: unknown argument $1";; esac; done
  [ -n "$version" ] || version="$WEED_VERSION_PIN"
  [ "$version" = "$WEED_VERSION_PIN" ] || die "only SeaweedFS $WEED_VERSION_PIN is pinned in this runner (asked $version)"
  need_root
  local arch sum
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64; sum="$SHA256_AMD64";;
    aarch64|arm64) arch=arm64; sum="$SHA256_ARM64";;
    *) die "unsupported architecture $(uname -m)";; esac

  mkdir -p "$ETC" "$LIB/master" "$LIB/volume" "$LIB/filer" "$RUN" /usr/local/bin /usr/local/sbin
  chmod 0700 "$ETC"

  if [ -x "$WEED" ] && "$WEED" version 2>/dev/null | grep -q " $WEED_VERSION_PIN "; then
    say "weed $WEED_VERSION_PIN already installed"
  else
    local tmp; tmp="$(mktemp -d)"
    if [ -z "$tarball" ]; then
      tarball="$tmp/linux_$arch.tar.gz"
      curl -fsSL --retry 3 --connect-timeout 20 -o "$tarball" "$RELEASE_URL/$version/linux_$arch.tar.gz" \
        || { rm -rf "$tmp"; die "download of weed $version ($arch) failed"; }
    fi
    local got; got="$(sha256sum "$tarball" | awk '{print $1}')"
    [ "$got" = "$sum" ] || { rm -rf "$tmp"; die "sha256 mismatch for linux_$arch.tar.gz: got $got"; }
    tar -xzf "$tarball" -C "$tmp" weed
    install -m 0755 "$tmp/weed" "$WEED.new" && mv -f "$WEED.new" "$WEED"
    rm -rf "$tmp"
    say "installed weed $("$WEED" version 2>/dev/null | grep -o 'version.*' | head -1)"
  fi

  # the runner installs itself so units and later ExecCmds use a stable path
  local me; me="$(readlink -f "$0")"
  if [ "$me" != "$SELF" ]; then install -m 0755 "$me" "$SELF"; fi

  # weed reads security.toml / master.toml from ".", ~/.seaweedfs, /etc/seaweedfs:
  # point /etc/seaweedfs at /etc/sfs so `weed shell` and tools work from any cwd.
  if [ ! -e /etc/seaweedfs ]; then ln -s "$ETC" /etc/seaweedfs; fi

  # keep identity and data across container redeploys
  mkdir -p "$(dirname "$REDEPLOY_CONF")"; touch "$REDEPLOY_CONF"
  local p; for p in "$ETC" "$LIB" "$SELF"; do grep -qxF "$p" "$REDEPLOY_CONF" || echo "$p" >> "$REDEPLOY_CONF"; done

  if use_systemd; then render_units "$UNIT_DIR"; systemctl daemon-reload; fi
  ok "weed $WEED_VERSION_PIN ($arch) installed"
}

# ---------------------------------------------------------------- units
render_units() {
  local dir="$1" role after
  mkdir -p "$dir"
  for role in $ALL_ROLES; do
    after="network-online.target"
    [ "$role" != master ] && after="$after sfs-master.service"
    cat > "$dir/sfs-$role.service" <<EOF
[Unit]
Description=SeaweedFS $role (sfs)
Wants=network-online.target
After=$after
ConditionPathExists=/etc/sfs/node.env

[Service]
Type=simple
WorkingDirectory=/etc/sfs
ExecStart=/usr/local/sbin/sfs-node run $role
Restart=always
RestartSec=5
LimitNOFILE=1048576
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$dir/sfs-$role.service"
  done
  cat > "$dir/sfs-agent.service" <<'EOF'
[Unit]
Description=sfs node heartbeat to the control plane
ConditionPathExists=/etc/sfs/node.env

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sfs-node heartbeat
EOF
  cat > "$dir/sfs-agent.timer" <<'EOF'
[Unit]
Description=sfs node heartbeat every 30 s

[Timer]
OnBootSec=30
OnUnitActiveSec=30
AccuracySec=5

[Install]
WantedBy=timers.target
EOF
  chmod 0644 "$dir/sfs-agent.service" "$dir/sfs-agent.timer"
}

# the one place where weed flags live (used by systemd units and by the no-systemd mode)
# TODO(sfs): changing the master set (1 -> 3 masters when a region grows) rewrites -peers on
#   re-enroll, but existing raft state in /var/lib/sfs/master is not migrated; needs an ordered
#   procedure (control plane) before masters are added/removed.
# TODO(sfs): security.toml [guard] white_list (private subnet) is not set; master /dir/assign
#   hands out write JWTs to any host that reaches 9333 - relies on network isolation/firewall.
weed_args() {
  local role="$1"
  case "$role" in
    master) printf '%s\n' master -ip="$SFS_IP" -ip.bind="$SFS_IP" -port=9333 -port.grpc=19333 \
              -mdir="$LIB/master" -peers="$SFS_PEERS" -defaultReplication="$SFS_REPLICATION" \
              -volumeSizeLimitMB="${SFS_VOLUME_SIZE_MB:-1024}";;
    volume) printf '%s\n' volume -ip="$SFS_IP" -ip.bind="$SFS_IP" -port=8080 -port.grpc=18080 \
              -dir="$LIB/volume" -max=0 -master="$SFS_MASTERS" -dataCenter="$SFS_DC" -rack="$SFS_RACK" \
              -index=leveldb -minFreeSpace=5;;
    filer)  printf '%s\n' filer -ip="$SFS_IP" -ip.bind="$SFS_IP" -port=8888 -port.grpc=18888 \
              -master="$SFS_MASTERS" -defaultStoreDir="$LIB/filer" -dataCenter="$SFS_DC" -rack="$SFS_RACK";;
    *) die "unknown role $role";; esac
}

cmd_run() {
  local role="${1:-}"; load_env
  has_role "$role" || die "role $role not assigned to this node"
  mkdir -p "$LIB/$role"; cd "$ETC"
  local -a args; mapfile -t args < <(weed_args "$role")
  exec "$WEED" "${args[@]}"
}

# ---------------------------------------------------------------- enroll
json_get() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1]));
for k in sys.argv[2].split("."): d=d[k]
print(",".join(map(str,d)) if isinstance(d,list) else d)' "$1" "$2"; }

norm_fp() { printf '%s' "$1" | sed 's/^sha256://I' | tr -d ':' | tr 'A-F' 'a-f'; }

cmd_enroll() {
  local cp="" token="" fp="" region="" nodeid="" ip="" roles="" start=1
  while [ $# -gt 0 ]; do case "$1" in
    --cp) cp="${2%/}"; shift 2;; --token) token="$2"; shift 2;;
    --ca-fingerprint) fp="$2"; shift 2;; --region) region="$2"; shift 2;;
    --node-id) nodeid="$2"; shift 2;; --ip) ip="$2"; shift 2;;
    --roles) roles="$2"; shift 2;; --no-start) start=0; shift;;
    *) die "enroll: unknown argument $1";; esac; done
  for v in cp token fp region nodeid ip roles; do [ -n "${!v}" ] || die "enroll: --${v} is required"; done
  need_root
  [ -x "$WEED" ] || die "weed not installed (run: sfs-node install --version $WEED_VERSION_PIN)"
  mkdir -p "$ETC"; chmod 0700 "$ETC"
  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

  # 1. CA: fetched without trust, accepted only if its fingerprint matches the pin from JPS
  curl -fsS -k --connect-timeout 15 -o "$tmp/ca.json" "$cp/api/v1/ca" || die "cannot fetch CA from $cp"
  json_get "$tmp/ca.json" ca > "$tmp/ca.pem"
  local got want
  got="$(openssl x509 -in "$tmp/ca.pem" -noout -fingerprint -sha256 | cut -d= -f2)"
  got="$(norm_fp "$got")"; want="$(norm_fp "$fp")"
  [ -n "$want" ] && [ "$got" = "$want" ] || die "CA fingerprint mismatch (got sha256:$got)"

  # 2. key stays on the node (kept across re-enrollment), CSR CN=node<N>.<region>, SAN IP
  if [ ! -s "$ETC/node.key" ]; then
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$tmp/node.key"
    install -m 0600 "$tmp/node.key" "$ETC/node.key"
  fi
  openssl req -new -key "$ETC/node.key" -subj "/CN=node${nodeid}.${region}" \
    -addext "subjectAltName=IP:${ip}" -out "$tmp/node.csr"

  # 3. enroll over TLS pinned to that CA
  python3 - "$tmp/node.csr" "$token" "$(hostname)" "$ip" "$roles" > "$tmp/req.json" <<'PY'
import json, sys
csr, token, host, ip, roles = sys.argv[1:6]
print(json.dumps({"token": token, "csr": open(csr).read(), "hostname": host, "ip": ip,
                  "roles": [r for r in roles.split(",") if r]}))
PY
  local code
  code="$(curl -sS --cacert "$tmp/ca.pem" --connect-timeout 15 -o "$tmp/resp.json" -w '%{http_code}' \
    -H 'Content-Type: application/json' --data-binary @"$tmp/req.json" "$cp/api/v1/enroll")" \
    || die "enroll request to $cp failed (TLS or network)"
  [ "$code" = 200 ] || [ "$code" = 201 ] || die "enroll rejected: HTTP $code $(head -c 300 "$tmp/resp.json" | tr '\n' ' ')"

  # 4. write /etc/sfs/*
  python3 - "$tmp/resp.json" "$tmp" "$region" "$nodeid" "$ip" "$roles" "$cp" <<'PY'
import json, sys, os
resp, out, region, nodeid, ip, roles, cp = sys.argv[1:8]
d = json.load(open(resp)); c = d["config"]
open(os.path.join(out, "node.pem"), "w").write(d["cert"])
open(os.path.join(out, "ca.pem"), "w").write(d.get("ca") or open(os.path.join(out, "ca.pem")).read())
masters = [m for m in c["masters"] if m]
if not masters: raise SystemExit("config.masters is empty")
peers = ",".join(masters) if len(masters) > 1 else "none"
def q(v):
    v = str(v)
    if any(ch in v for ch in "'\n"): raise SystemExit("bad value in config: %r" % v)
    return "'" + v + "'"
env = {
  "SFS_CLUSTER_ID": c.get("clusterId", ""), "SFS_REGION": c.get("region", region),
  "SFS_NODE_ID": nodeid, "SFS_IP": ip, "SFS_ROLES": roles, "SFS_CP": cp,
  "SFS_MASTERS": ",".join(masters), "SFS_PEERS": peers,
  "SFS_REPLICATION": c.get("replication", "000"),
  "SFS_DC": c.get("dataCenter", region), "SFS_RACK": c.get("rack", "node" + nodeid),
  "SFS_FILER_PEERS": ",".join(c.get("filerPeers", []) or []),
  "SFS_VOLUME_SIZE_MB": c.get("volumeSizeLimitMB", 1024),
  # control-plane record id for /api/v1/nodes/{id}/heartbeat (falls back to the Jelastic node id)
  "SFS_CP_NODE_ID": (d.get("node") or {}).get("id") or d.get("nodeRecordId") or c.get("nodeRecordId") or nodeid,
}
with open(os.path.join(out, "node.env"), "w") as f:
    for k, v in env.items(): f.write("%s=%s\n" % (k, q(v)))
def t(v):
    return '"' + str(v).replace("\\", "\\\\").replace('"', '\\"') + '"'
sec = ["# generated by sfs-node enroll - do not edit", "[jwt.signing]", "key = " + t(c["jwtSigningKey"]),
       "expires_after_seconds = 10", "", "[jwt.signing.read]", "key = " + t(c["jwtReadKey"]),
       "expires_after_seconds = 10", "", "[grpc]", 'ca = "/etc/sfs/ca.pem"', ""]
for sect in ("volume", "master", "filer", "client"):
    sec += ["[grpc.%s]" % sect, 'cert = "/etc/sfs/node.pem"', 'key = "/etc/sfs/node.key"', ""]
open(os.path.join(out, "security.toml"), "w").write("\n".join(sec))
PY
  cat > "$tmp/master.toml" <<'EOF'
# generated by sfs-node enroll (SeaweedFS 4.48 syntax: -apply)
[master.maintenance]
scripts = """
  lock
  volume.deleteEmpty -quietFor=24h -apply
  volume.balance -apply
  volume.fix.replication -apply
  unlock
"""
sleep_minutes = 17
EOF
  local f
  for f in node.pem ca.pem node.env security.toml master.toml; do install -m 0600 "$tmp/$f" "$ETC/$f"; done
  openssl verify -CAfile "$ETC/ca.pem" "$ETC/node.pem" >/dev/null || die "issued certificate does not chain to the pinned CA"

  if use_systemd; then
    render_units "$UNIT_DIR"; systemctl daemon-reload
    local r; for r in $ALL_ROLES; do
      if has_role_in "$r" "$roles"; then systemctl enable "sfs-$r" >/dev/null 2>&1; else systemctl disable --now "sfs-$r" >/dev/null 2>&1 || true; fi
    done
    if [ "$roles" = client ]; then
      # mount-only client: certificate for filer mTLS, no heartbeat to the control plane
      systemctl disable --now sfs-agent.timer >/dev/null 2>&1 || true
    else
      systemctl enable --now sfs-agent.timer >/dev/null 2>&1 || say "warning: could not enable sfs-agent.timer"
    fi
  fi
  if [ "$start" = 1 ]; then ( cmd_start_inner ) || die "enrolled but services failed to start"; fi
  ok "enrolled node${nodeid}.${region} roles=${roles}"
}
has_role_in() { case ",$2," in *",$1,"*) return 0;; esac; return 1; }

# ---------------------------------------------------------------- start / stop
pid_alive() { [ -f "$RUN/$1.pid" ] && kill -0 "$(cat "$RUN/$1.pid")" 2>/dev/null; }
pid_kill() {
  local p i; p="$(cat "$RUN/$1.pid")"; kill -- "-$p" 2>/dev/null || kill "$p" 2>/dev/null || true; rm -f "$RUN/$1.pid"
  # weed shuts down gracefully; wait so a following start does not hit the leveldb lock
  for i in $(seq 1 30); do weed_alive "$1" || return 0; sleep 1; done
}
# no-systemd mode reports the weed child, not just the supervisor loop
weed_alive() { local c; for c in /proc/[0-9]*/cmdline; do
  case "$(tr '\0' ' ' < "$c" 2>/dev/null)" in "$WEED $1 -ip="*) return 0;; esac; done; return 1; }

cmd_start_inner() {
  load_env; mkdir -p "$RUN"
  local r
  for r in $ALL_ROLES; do
    has_role "$r" || continue
    if use_systemd; then
      systemctl enable "sfs-$r" >/dev/null 2>&1 || true
      systemctl restart "sfs-$r"
    else
      pid_alive "$r" && continue
      # supervise like systemd Restart=always (a fresh filer exits if its peers are not up yet)
      setsid bash -c 'while :; do "$0" run "$1" >> "$2" 2>&1; sleep 5; done' "$SELF" "$r" "$RUN/$r.log" </dev/null >/dev/null 2>&1 &
      echo $! > "$RUN/$r.pid"
    fi
    # masters first: give the raft leader a moment before volume/filer register
    [ "$r" = master ] && wait_port "$SFS_IP" 9333 60 || true
  done
}
wait_port() { local i; for i in $(seq 1 "$3"); do curl -fsS -o /dev/null "http://$1:$2/cluster/status" 2>/dev/null && return 0; sleep 1; done; return 1; }

cmd_start() { need_root; cmd_start_inner; ok "started roles ${SFS_ROLES}"; }

cmd_stop() {
  need_root; local r
  for r in filer volume master; do
    if use_systemd; then systemctl stop "sfs-$r" 2>/dev/null || true
    elif pid_alive "$r"; then pid_kill "$r"; fi
  done
  ok "stopped"
}

# ---------------------------------------------------------------- status
svc_state() {
  if use_systemd; then systemctl is-active "sfs-$1" 2>/dev/null || true
  elif pid_alive "$1" && weed_alive "$1"; then echo active
  elif pid_alive "$1"; then echo activating; else echo inactive; fi
}

cmd_status() {
  load_env
  local m v f ver total used
  if has_role master; then m="$(svc_state master)"; else m="none"; fi
  if has_role volume; then v="$(svc_state volume)"; else v="none"; fi
  if has_role filer;  then f="$(svc_state filer)";  else f="none"; fi
  ver="$("$WEED" version 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="version"){print $(i+2); exit}}')" || ver=""
  read -r total used < <(df -B1 --output=size,used "$LIB" | tail -1)
  local json
  json="$(python3 -c 'import json,sys; a=sys.argv[1:]
print(json.dumps({"roles":[r for r in a[0].split(",") if r],"services":{"master":a[1],"volume":a[2],"filer":a[3]},
 "weedVersion":a[4],"diskTotal":int(a[5] or 0),"diskUsed":int(a[6] or 0),"region":a[7],"nodeId":a[8],
 "ip":a[9],"clusterId":a[10]}, separators=(",",":")))' \
    "$SFS_ROLES" "$m" "$v" "$f" "$ver" "$total" "$used" "$SFS_REGION" "$SFS_NODE_ID" "$SFS_IP" "$SFS_CLUSTER_ID")"
  say "SFS_JSON=$json"
  local bad=0 s; for s in "$m" "$v" "$f"; do [ "$s" = none ] || [ "$s" = active ] || bad=1; done
  [ "$bad" = 0 ] || die "not all services active (master=$m volume=$v filer=$f)"
  ok "master=$m volume=$v filer=$f"
}

# ---------------------------------------------------------------- drain-check / remove
drain_count() {
  # number of volumes (normal + EC shards) this volume server still holds
  curl -fsS --connect-timeout 5 "http://$SFS_IP:8080/status" 2>/dev/null | python3 -c 'import json,sys
d=json.load(sys.stdin); print(len(d.get("Volumes") or []) + len(d.get("EcVolumes") or []))'
}

# ---------------------------------------------------------------- heartbeat (sfs-agent.timer)
cmd_heartbeat() {
  load_env
  local out json code
  out="$("$SELF" status 2>/dev/null || true)"
  json="$(printf '%s\n' "$out" | sed -n 's/^SFS_JSON=//p' | head -1)"
  [ -n "$json" ] || die "status produced no SFS_JSON"
  code="$(printf '%s' "$json" | curl -sS --connect-timeout 10 --max-time 20 -o /dev/null -w '%{http_code}' \
    --cacert "$ETC/ca.pem" --cert "$ETC/node.pem" --key "$ETC/node.key" \
    -H 'Content-Type: application/json' --data-binary @- "$SFS_CP/api/v1/nodes/$SFS_CP_NODE_ID/heartbeat")" \
    || die "heartbeat to $SFS_CP failed (network/TLS)"
  [ "$code" = 200 ] || die "heartbeat rejected: HTTP $code"
  ok "heartbeat sent"
}

cmd_drain_check() {
  load_env
  has_role volume || { say 'SFS_JSON={"volumes":0}'; ok "no volume role"; }
  local n
  if [ "$(svc_state volume)" != active ]; then
    n="$(find "$LIB/volume" -maxdepth 1 \( -name '*.dat' -o -name '*.ec[0-9][0-9]' \) 2>/dev/null | wc -l | tr -d ' ')"
  else
    n="$(drain_count)" || die "volume server not answering on $SFS_IP:8080"
  fi
  say "SFS_JSON={\"volumes\":$n}"
  [ "$n" = 0 ] || die "node still holds $n volume(s)"
  ok "drained"
}

cmd_remove() {
  local force=0 purge=0
  while [ $# -gt 0 ]; do case "$1" in --force) force=1; shift;; --purge) purge=1; shift;; *) die "remove: unknown argument $1";; esac; done
  need_root
  if [ -f "$ETC/node.env" ] && [ "$force" = 0 ]; then
    ( cmd_drain_check >/dev/null ) || die "node is not drained (use --force to override)"
  fi
  local r
  for r in filer volume master; do
    if use_systemd; then systemctl disable --now "sfs-$r" >/dev/null 2>&1 || true; rm -f "$UNIT_DIR/sfs-$r.service"
    elif pid_alive "$r"; then pid_kill "$r"; fi
  done
  if use_systemd; then
    systemctl disable --now sfs-agent.timer >/dev/null 2>&1 || true
    rm -f "$UNIT_DIR/sfs-agent.service" "$UNIT_DIR/sfs-agent.timer"; systemctl daemon-reload
  fi
  if [ "$purge" = 1 ]; then rm -rf "$ETC" "$LIB"; [ -L /etc/seaweedfs ] && rm -f /etc/seaweedfs; fi
  ok "removed (purge=$purge)"
}

# ---------------------------------------------------------------- main
sub="${1:-}"; [ $# -gt 0 ] && shift
case "$sub" in
  install) cmd_install "$@";;
  enroll) cmd_enroll "$@";;
  start) cmd_start;;
  stop) cmd_stop;;
  status) cmd_status;;
  drain-check) cmd_drain_check;;
  remove) cmd_remove "$@";;
  heartbeat) cmd_heartbeat;;
  run) cmd_run "$@";;
  render-units) render_units "${1:?dir}"; ok "units written to $1";;
  *) die "usage: sfs-node install|enroll|start|stop|status|drain-check|remove|run|render-units";;
esac
