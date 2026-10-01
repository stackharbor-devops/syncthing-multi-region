#!/bin/bash
# =============================================================================
# Node-runner tests: scripts/stsync.sh for real, in systemd containers.
# =============================================================================
# Usage:  tests/node/run.sh            exit status 0 only when every check passed
#
# Needs Docker and python3 on the host, and an AlmaLinux 9 image that boots
# systemd and has glusterfs-server + glusterfs-fuse (for a real FUSE mount in
# the refusal test), curl, python3, procps-ng and iproute.
#
# Environment:
#   STSYNC_TEST_IMAGE     the image (default r3e-node)
#   STSYNC_TEST_TARBALLS  a directory with the real Syncthing release tarball
#                         for the Docker architecture; without it the tarball
#                         is downloaded from GitHub once into
#                         ~/.cache/stsync-test. The nodes download it from a
#                         local HTTP server through STSYNC_DOWNLOAD_BASE, so
#                         the runner's sha256 check runs for real.
#   STSYNC_TEST_PREFIX    name prefix of every container/network/image
#                         (default sta-runner)
#   KEEP=1                leave the containers running at the end
#
# What it covers: refusals (bad path, real FUSE mount, lsyncd running, bad
# checksum), prepare on 3 nodes (install, unit, env, redeploy.conf, identity,
# bound, private listen address, idempotence), the file count for the seed
# check, guard, ignore, api plans that build a 3-node mesh like the platform
# does, safe join of an empty node and of a node with different content - both
# holding a file the seed lacks, one restarted during its join (the join
# resumes at boot and runs after the other's revert) - propagation, status
# JSON, rescan, a simulated redeploy, a cloned container (guard blocks it,
# prepare resets its identity, it joins safely and only against a send-receive
# node of its --from list), remove (files under the path stay), prepare
# --fresh (leftover state reset, versions kept), and remove during a join (the
# join's conflict copies leave the webroot).
# =============================================================================
set -u -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
RUNNER_SRC=$REPO/scripts/stsync.sh
IMAGE=${STSYNC_TEST_IMAGE:-r3e-node}
PFX=${STSYNC_TEST_PREFIX:-sta-runner}
NET=$PFX-net
FILES=$PFX-files
P=/var/www/webroot/ROOT
WEBUSER=litespeed
VER=2.1.5
PASS=0
FAIL=0
FAILED=()

# ---- helpers ----------------------------------------------------------------

say()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); say "  PASS  $1"; }
bad()  { FAIL=$((FAIL + 1)); FAILED+=("$1"); say "  FAIL  $1${2:+ -- $2}"; }
# check NAME COMMAND... - pass when the command succeeds.
check() { local n=$1; shift; if "$@" > /dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
# expect NAME EXPECTED ACTUAL
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi; }
# val KEY TEXT - value of a STSYNC_KEY= line.
val() { printf '%s\n' "$2" | sed -n "s/^STSYNC_$1=//p" | tail -n 1; }
section() { say ""; say "== $*"; }

dx() { docker exec "$@"; }
c() { printf '%s-%s' "$PFX" "$1"; }
ipof() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(c "$1")"; }
b64() { base64 | tr -d '\n'; }
# Device IDs per node (bash 3.2 on macOS: no associative arrays).
setdev() { eval "DEV_$1=\$2"; }
dev() { eval "printf '%s' \"\${DEV_$1:-}\""; }

# st NODE ARGS... - run the runner; output in OUT, exit status in RC.
st() {
    local n=$1; shift
    OUT=$(docker exec -e STSYNC_DOWNLOAD_BASE="${DL_BASE:-http://$FILES:8000/good}" "$(c "$n")" stsync "$@" 2>&1)
    RC=$?
}

# wait_until SECONDS COMMAND... - poll every second.
wait_until() {
    local end=$(( $(date +%s) + $1 )); shift
    while :; do
        "$@" > /dev/null 2>&1 && return 0
        [ "$(date +%s)" -ge "$end" ] && return 1
        sleep 1
    done
}

start_node() { # start_node NAME [IMAGE]
    docker rm -f "$(c "$1")" > /dev/null 2>&1
    docker run -d --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /tmp \
        --hostname "$1" --name "$(c "$1")" --network "$NET" "${2:-$IMAGE}" /usr/sbin/init > /dev/null || return 1
    wait_until 60 sh -c "docker exec $(c "$1") systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded'"
}

# setup_node NAME - web user, webroot, a Jelastic-like redeploy.conf, the runner.
setup_node() {
    dx "$(c "$1")" bash -c "useradd -u 1001 -m $WEBUSER && mkdir -p $P && chown $WEBUSER: $P /var/www/webroot \
        && mkdir -p /etc/jelastic && printf '/etc/sysconfig/iptables\n/var/spool/cron' > /etc/jelastic/redeploy.conf" \
        && install_runner "$1"
}
install_runner() {
    docker cp "$RUNNER_SRC" "$(c "$1"):/usr/local/sbin/stsync" > /dev/null && dx "$(c "$1")" chmod 0755 /usr/local/sbin/stsync
}

# plan NODE TYPE NEW NODES... - the API plan the platform sends to NODE:
# private options, the device list (every node incl. itself), then the folder
# (POST when NEW=1, else PATCH). Mirrors docs/DESIGN.md section 4 step 4.
plan() {
    local n=$1 type=$2 new=$3 x spec=
    shift 3
    for x in "$@"; do spec="$spec $x,$(dev "$x"),$(ipof "$x")"; done
    python3 - "$(ipof "$n")" "$type" "$new" "$P" $spec <<'PY'
import base64, json, sys
ip, ftype, new, path = sys.argv[1:5]
nodes = [s.split(",") for s in sys.argv[5:]]
b = lambda o: base64.b64encode(json.dumps(o).encode()).decode()
opts = {"listenAddresses": ["tcp://%s:22000" % ip], "globalAnnounceEnabled": False,
        "localAnnounceEnabled": False, "relaysEnabled": False, "natEnabled": False,
        "urAccepted": -1, "crashReportingEnabled": False, "autoUpgradeIntervalH": 0,
        "startBrowser": False}
devs = [{"deviceID": d, "name": "node" + name, "addresses": ["tcp://%s:22000" % a]} for name, d, a in nodes]
fdevs = [{"deviceID": d} for _, d, _ in nodes]
vers = {"type": "trashcan", "params": {"cleanoutDays": "14"}, "fsPath": "/var/lib/stsync/versions/webroot"}
lines = ["PATCH /rest/config/options " + b(opts), "PUT /rest/config/devices " + b(devs)]
if new == "1":
    lines.append("POST /rest/config/folders " + b({"id": "webroot", "label": "webroot", "path": path, "type": ftype,
                                                   "fsWatcherDelayS": 2, "devices": fdevs, "versioning": vers}))
else:
    lines.append("PATCH /rest/config/folders/webroot " + b({"devices": fdevs, "fsWatcherDelayS": 2, "versioning": vers}))
print(base64.b64encode(("\n".join(lines) + "\n").encode()).decode())
PY
}

# tree NODE - checksums of the synced files (what every node must agree on):
# no Syncthing markers, no ignored paths.
tree() {
    dx "$(c "$1")" bash -c "cd $P && find . -type f ! -path './.stfolder/*' ! -name .stignore \
        ! -path './wp-content/cache/*' ! -path './wp-content/upgrade/*' ! -name '*.log' -print0 | sort -z | xargs -0 -r md5sum" 2>/dev/null
}
same_tree() { [ "$(tree "$1")" = "$(tree "$2")" ]; }

join_done() { dx "$(c "$1")" grep -qx state=done /var/lib/stsync/join.state; }
folder_type_is() { st "$1" status --folder webroot --path $P; [ "$(json_field "$(val JSON "$OUT")" folderType)" = "$2" ]; }
json_field() { printf '%s' "$1" | python3 -c "import json,sys; v=json.load(sys.stdin).get(sys.argv[1]); print('null' if v is None else v)" "$2" 2>/dev/null; }
conflicts_on() { dx "$(c "$1")" bash -c "find $P -name '*.sync-conflict-*' | wc -l"; }
# global_of NODE - the folder's global state from the status JSON.
global_of() {
    st "$1" status --folder webroot --path $P
    val JSON "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("%s/%s/%s/%s" % (d["globalFiles"], d["globalDirectories"], d["globalDeleted"], d["globalBytes"]))'
}
same_global() { local n ref; ref=$(global_of "$1") || return 1; for n in "$@"; do [ "$(global_of "$n")" = "$ref" ] || return 1; done; }

teardown() {
    local ids
    ids=$(docker ps -aq --filter "name=^$PFX-")
    [ -n "$ids" ] && docker rm -f $ids > /dev/null 2>&1
    docker network rm "$NET" > /dev/null 2>&1
    docker rmi -f "$PFX-clone-img" > /dev/null 2>&1
}
cleanup() {
    if [ "${KEEP:-0}" = 1 ]; then say "KEEP=1: containers left running (prefix $PFX)"; else teardown; fi
}
trap cleanup EXIT

# ---- setup ------------------------------------------------------------------

section "setup"
case $(docker info -f '{{.Architecture}}' 2>/dev/null) in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) say "cannot tell the Docker architecture"; exit 2 ;;
esac
TARBALL=syncthing-linux-$ARCH-v$VER.tar.gz
TDIR=${STSYNC_TEST_TARBALLS:-$HOME/.cache/stsync-test}
if [ ! -f "$TDIR/$TARBALL" ]; then
    mkdir -p "$TDIR" && curl -fsSL -o "$TDIR/$TARBALL" \
        "https://github.com/syncthing/syncthing/releases/download/v$VER/$TARBALL" \
        || { say "cannot get $TARBALL"; exit 2; }
fi
teardown
docker network create "$NET" > /dev/null || exit 2
# The tarball server: /good has the real tarball, /bad a corrupted copy.
docker run -d --name "$FILES" --network "$NET" --entrypoint python3 "$IMAGE" -m http.server 8000 --directory /srv > /dev/null || exit 2
dx "$FILES" mkdir -p /srv/good /srv/bad
docker cp "$TDIR/$TARBALL" "$FILES:/srv/good/$TARBALL" > /dev/null || exit 2
dx "$FILES" bash -c "cp /srv/good/$TARBALL /srv/bad/$TARBALL && printf x >> /srv/bad/$TARBALL"
for n in n1 n2 n3 x; do
    start_node "$n" && setup_node "$n" || { say "cannot start node $n"; exit 2; }
done
say "  nodes up: n1 $(ipof n1), n2 $(ipof n2), n3 $(ipof n3), x $(ipof x)"
check "runner passes bash -n" bash -n "$RUNNER_SRC"

# ---- refusals (node x) ------------------------------------------------------

section "refusals"
st x prepare --ip "$(ipof x)"
expect "no --path: failed" failed "$(val RESULT "$OUT")"
expect "no --path: exit 1" 1 "$RC"
st x prepare --path var/www --ip "$(ipof x)"
check "relative path refused" grep -q "is not absolute" <<< "$OUT"
st x prepare --path /nope --ip "$(ipof x)"
check "missing directory refused" grep -q "not an existing directory" <<< "$OUT"

# A real FUSE filesystem: a one-brick GlusterFS volume mounted on x.
dx "$(c x)" bash -c 'systemctl start glusterd && sleep 2 && mkdir -p /bricks/tv \
    && gluster --mode=script volume create tv $(hostname):/bricks/tv force \
    && gluster --mode=script volume start tv && mkdir -p /mnt/gv \
    && mount -t glusterfs $(hostname):/tv /mnt/gv && mkdir -p /mnt/gv/ROOT' > /dev/null 2>&1
if [ "$(dx "$(c x)" findmnt -rn -o FSTYPE --target /mnt/gv/ROOT 2>/dev/null | tail -n 1)" = fuse.glusterfs ]; then
    st x prepare --path /mnt/gv/ROOT --ip "$(ipof x)"
    check "path on a FUSE mount (fuse.glusterfs) refused" grep -q "network or FUSE filesystem (fuse.glusterfs)" <<< "$OUT"
    expect "FUSE refusal: exit 1" 1 "$RC"
    dx "$(c x)" umount /mnt/gv
else
    bad "could not mount a GlusterFS volume for the FUSE refusal test"
fi

# A process named lsyncd (what the File Synchronization add-on runs).
dx "$(c x)" bash -c 'cp /usr/bin/sleep /usr/local/bin/lsyncd && setsid /usr/local/bin/lsyncd 600 > /dev/null 2>&1 < /dev/null &'
sleep 1
st x prepare --path $P --ip "$(ipof x)"
check "lsyncd running refused" grep -q "remove the File Synchronization add-on first" <<< "$OUT"
dx "$(c x)" pkill -x lsyncd

DL_BASE=http://$FILES:8000/bad st x prepare --path $P --ip "$(ipof x)"
check "corrupted tarball refused (sha256)" grep -q "checksum mismatch" <<< "$OUT"
check "corrupted tarball: no binary installed" test "$(dx "$(c x)" bash -c 'ls /usr/local/bin/syncthing* 2>/dev/null | wc -l')" = 0
st x frobnicate
expect "unknown command: failed" failed "$(val RESULT "$OUT")"

# ---- prepare on 3 nodes ------------------------------------------------------

section "prepare"
for n in n1 n2 n3; do
    st "$n" prepare --path $P/ --ip "$(ipof "$n")" --folder webroot
    expect "$n prepare ok" ok "$(val RESULT "$OUT")"
    [ "$RC" = 0 ] || say "$OUT"
    setdev "$n" "$(val DEVICE "$OUT")"
    check "$n device id format" grep -qE '^([A-Z2-7]{7}-){7}[A-Z2-7]{7}$' <<< "$(dev "$n")"
    expect "$n run user" $WEBUSER "$(val USER "$OUT")"
    expect "$n folder type before the plan" none "$(val FOLDER_TYPE "$OUT")"
    expect "$n join state" none "$(val JOIN "$OUT")"
done
N1=$(c n1)
expect "binary version" "syncthing v$VER" "$(dx "$N1" /usr/local/bin/syncthing --version | cut -d ' ' -f 1-2)"
check "unit: User, guard, ExecStart, join resumed at start" dx "$N1" bash -c "grep -qx 'User=$WEBUSER' /etc/systemd/system/stsync.service \
    && grep -qx 'ExecStartPre=+/usr/local/sbin/stsync guard' /etc/systemd/system/stsync.service \
    && grep -qx 'ExecStart=/usr/local/bin/syncthing serve --home=/var/lib/stsync --no-browser --no-restart --log-file=/var/lib/stsync/syncthing.log --log-max-size=10485760 --log-max-old-files=3' /etc/systemd/system/stsync.service \
    && grep -qx 'LimitNOFILE=65536' /etc/systemd/system/stsync.service \
    && grep -qx 'ExecStartPost=-+/usr/local/sbin/stsync join --folder webroot' /etc/systemd/system/stsync.service"
expect "env file mode/owner" "600 root" "$(dx "$N1" stat -c '%a %U' /etc/stsync.env)"
check "env file content" dx "$N1" bash -c "grep -qx 'STGUIADDRESS=127.0.0.1:8384' /etc/stsync.env && grep -qx \"STGUIAPIKEY=\$(cat /var/lib/stsync/apikey)\" /etc/stsync.env \
    && grep -qx STNOUPGRADE=1 /etc/stsync.env && grep -qx STDBDELETERETENTIONINTERVAL=0 /etc/stsync.env"
check "apikey is 32 chars" dx "$N1" bash -c '[ $(tr -d "\n" < /var/lib/stsync/apikey | wc -c) = 32 ]'
expect "redeploy.conf keeps its lines and lists /var/lib/stsync" "/etc/sysconfig/iptables|/var/spool/cron|/var/lib/stsync" \
    "$(dx "$N1" cat /etc/jelastic/redeploy.conf | paste -sd '|' -)"
expect "home owned by the run user" "$WEBUSER 700" "$(dx "$N1" stat -c '%U %a' /var/lib/stsync)"
expect "bound = hostname" n1 "$(dx "$N1" cat /var/lib/stsync/bound)"
expect "service active and enabled" "active enabled" "$(dx "$N1" systemctl is-active stsync) $(dx "$N1" systemctl is-enabled stsync)"
expect "syncthing runs as the run user" $WEBUSER "$(dx "$N1" ps -o user= -C syncthing | sort -u | paste -sd, -)"
check "listens on the private IP only (TCP 22000) and GUI on 127.0.0.1" dx "$N1" bash -c \
    "ss -ltnH | awk '{print \$4}' | grep -qx '$(ipof n1):22000' && ss -ltnH | awk '{print \$4}' | grep -qx '127.0.0.1:8384' \
     && ! ss -ltnH | awk '{print \$4}' | grep -qE '^(\\*|0\\.0\\.0\\.0|\\[::\\]):(22000|8384)$'"
check "fresh config is private before the first start" dx "$N1" bash -c \
    "grep -q '<globalAnnounceEnabled>false<' /var/lib/stsync/config.xml && grep -q '<relaysEnabled>false<' /var/lib/stsync/config.xml \
     && grep -q '<urAccepted>-1<' /var/lib/stsync/config.xml"
PID1=$(dx "$N1" systemctl show -p MainPID --value stsync)
st n1 prepare --path $P --ip "$(ipof n1)" --folder webroot
expect "prepare again: same device" "$(dev n1)" "$(val DEVICE "$OUT")"
expect "prepare again: no restart" "$PID1" "$(dx "$N1" systemctl show -p MainPID --value stsync)"
expect "redeploy.conf entry not duplicated" 1 "$(dx "$N1" grep -cx /var/lib/stsync /etc/jelastic/redeploy.conf)"

section "guard"
st n1 guard
expect "guard on its own node: ok" "ok 0" "$(val RESULT "$OUT") $RC"

# ---- content, ignore, api plans ----------------------------------------------

section "content and ignore rules"
# n1 = seed (the site). n2 = empty. n3 = a stale copy with different content.
dx "$N1" runuser -u $WEBUSER -- bash -c "cd $P && mkdir -p wp-content/uploads wp-content/cache \
    && for i in \$(seq 1 50); do echo \"upload \$i\" > wp-content/uploads/f\$i.txt; done \
    && echo v1 > index.php && echo cfg > wp-config.php && echo page > wp-content/cache/page.html && echo n1 > debug.log"
dx "$(c n3)" runuser -u $WEBUSER -- bash -c "cd $P && mkdir -p wp-content/uploads wp-content/cache \
    && for i in \$(seq 1 30); do echo \"upload \$i\" > wp-content/uploads/f\$i.txt; done \
    && echo 'stale upload' > wp-content/uploads/f7.txt && echo stale > index.php && echo mine > local-only.txt \
    && echo n3cache > wp-content/cache/n3.html && echo n3 > debug.log \
    && find . -type f -exec touch -d '3 hours ago' {} +"
# A file and a directory both joiners have and the seed lacks (what a broken
# lsyncd setup leaves behind).
for n in n2 n3; do
    dx "$(c "$n")" runuser -u $WEBUSER -- bash -c "cd $P && echo 'on two joiners' > common-extra.txt && mkdir -p extra-dir && echo x > extra-dir/x.txt"
done
RULES='// Caches, logs and temporary files: each node keeps its own
(?d)/wp-content/cache
(?d)/wp-content/upgrade
(?d)*.log
(?d).DS_Store
(?d)Thumbs.db'
RULES_B64=$(printf '%s\n' "$RULES" | b64)
for n in n1 n2 n3; do
    st "$n" ignore --path $P --b64 "$RULES_B64"
    expect "$n ignore ok" ok "$(val RESULT "$OUT")"
done
expect ".stignore content" "$RULES" "$(dx "$N1" cat $P/.stignore)"
expect ".stignore owner and mode" "$WEBUSER 644" "$(dx "$N1" stat -c '%U %a' $P/.stignore)"
check "no temporary file left" test "$(dx "$N1" bash -c "ls -a $P | grep -c syncthing")" = 0
# 54 files on n1: 50 uploads, index.php, wp-config.php, the cache page and
# debug.log; the default rules leave out the last two (and .stignore).
st n1 prepare --path $P --ip "$(ipof n1)" --folder webroot --count-b64 "$RULES_B64"
expect "prepare --count-b64: files that replicate (ignored cache page and log left out)" "ok 52" "$(val RESULT "$OUT") $(val FILES "$OUT")"
check "prepare --count-b64: bytes reported" grep -qE '^STSYNC_BYTES=[1-9][0-9]*$' <<< "$OUT"
st n1 prepare --path $P --ip "$(ipof n1)" --folder webroot --count-b64 -
expect "prepare --count-b64 - (no rules): every file" "ok 54" "$(val RESULT "$OUT") $(val FILES "$OUT")"
st n1 prepare --path $P --ip "$(ipof n1)" --folder webroot
check "prepare without --count-b64: no count" test -z "$(val FILES "$OUT")"
st n2 ignore --path $P --b64 -
expect "ignore - writes an empty file" "ok 0" "$(val RESULT "$OUT") $(dx "$(c n2)" stat -c %s $P/.stignore)"
st n2 ignore --path $P
expect "ignore without --b64: failed" failed "$(val RESULT "$OUT")"
st n2 ignore --path $P --b64 '%%%'
expect "ignore with bad base64: failed" failed "$(val RESULT "$OUT")"
st n2 ignore --path $P --b64 "$RULES_B64"

section "api plans (3-node mesh)"
st n1 api --plan-b64 "$(plan n1 sendreceive 1 n1 n2 n3)"
expect "n1 plan ok" "ok 200 200 200" "$(val RESULT "$OUT") $(val API_1 "$OUT") $(val API_2 "$OUT") $(val API_3 "$OUT")"
for n in n2 n3; do
    st "$n" api --plan-b64 "$(plan "$n" receiveonly 1 n1 n2 n3)"
    expect "$n plan ok (receive-only)" "ok 200 200 200" "$(val RESULT "$OUT") $(val API_1 "$OUT") $(val API_2 "$OUT") $(val API_3 "$OUT")"
done
# A failing step stops the plan: step 2 (404) must keep step 3 from running.
BAD=$(printf 'GET /rest/system/ping -\nGET /rest/config/folders/nope -\nPOST /rest/config/folders %s\n' \
    "$(printf '{"id":"mustnot","path":"/tmp/mustnot"}' | b64)" | b64)
st n1 api --plan-b64 "$BAD"
expect "failing plan: result, statuses, exit" "failed 200 404  1" \
    "$(val RESULT "$OUT") $(val API_1 "$OUT") $(val API_2 "$OUT") $(val API_3 "$OUT") $RC"
st n1 status --folder mustnot --path /tmp
expect "failing plan: later steps not run" none "$(json_field "$(val JSON "$OUT")" folderType)"
st n1 api --plan-b64 "$(printf 'FETCH /rest/system/ping -\n' | b64)"
expect "bad method refused" failed "$(val RESULT "$OUT")"
check "options applied (listen address)" dx "$N1" grep -q "<listenAddress>tcp://$(ipof n1):22000</listenAddress>" /var/lib/stsync/config.xml
st n1 prepare --path $P --ip "$(ipof n1)" --folder webroot
expect "prepare reports the folder type" sendreceive "$(val FOLDER_TYPE "$OUT")"

# ---- safe join ---------------------------------------------------------------

section "join"
st n1 join --folder webroot
expect "join on the send-receive seed does nothing" "ok none" "$(val RESULT "$OUT") $(val JOIN "$OUT")"
st n2 join --folder webroot --from "$(dev n2),x"
expect "join --from with a bad device id: failed" failed "$(val RESULT "$OUT")"
for n in n2 n3; do
    st "$n" join --folder webroot --from "$(dev n1)"
    expect "$n join started" "ok running" "$(val RESULT "$OUT") $(val JOIN "$OUT")"
done
expect "join.from lists the send-receive node" "$(dev n1)" "$(dx "$(c n3)" cat /var/lib/stsync/join.from)"
st n3 join --folder webroot
check "second join call: already running" grep -q "already running" <<< "$OUT"
st n3 prepare --path $P --ip "$(ipof n3)" --folder webroot
expect "prepare during the join" "receiveonly running" "$(val FOLDER_TYPE "$OUT") $(val JOIN "$OUT")"
# A node restart during the join: the join resumes when the service starts
# (ExecStartPost), with its saved --from list. n3 then reverts after n2 did,
# which is the order that used to keep the joiners' common file on n3.
docker restart "$(c n3)" > /dev/null
if wait_until 90 sh -c "docker exec $(c n3) stsync status --folder webroot --path $P | grep -q '\"join\":\"running\"'"; then
    ok "restart during the join: the join resumed at boot"
else
    bad "restart during the join: the join resumed at boot" "$(dx "$(c n3)" tail -n 3 /var/lib/stsync/join.log)"
fi
expect "the resumed join started twice in the log" 2 "$(dx "$(c n3)" grep -c 'join of folder webroot started' /var/lib/stsync/join.log)"
T0=$(date +%s)
if wait_until 300 join_done n2 && wait_until 300 join_done n3; then
    ok "joins done in $(( $(date +%s) - T0 )) s"
else
    bad "joins done" "$(dx "$(c n3)" tail -n 5 /var/lib/stsync/join.log)"
fi
for n in n2 n3; do check "$n folder is send-receive" folder_type_is "$n" sendreceive; done
st n3 join --folder webroot
expect "join after done: nothing to do" "ok done" "$(val RESULT "$OUT") $(val JOIN "$OUT")"
sleep 3
check "n2 has the cluster content" same_tree n1 n2
check "n3 has the cluster content" same_tree n1 n3
expect "seed kept its index.php" v1 "$(dx "$N1" cat $P/index.php)"
expect "n3 stale index.php replaced" v1 "$(dx "$(c n3)" cat $P/index.php)"
check "n3's local-only file did not reach the cluster" dx "$N1" test ! -e $P/local-only.txt
for n in n1 n2 n3; do
    check "$n: the joiners' common file and directory are not in the webroot" dx "$(c "$n")" bash -c "[ ! -e $P/common-extra.txt ] && [ ! -e $P/extra-dir ]"
done
for n in n2 n3; do
    check "$n: its copy of the common file is in its version store" dx "$(c "$n")" bash -c \
        "grep -qx 'on two joiners' /var/lib/stsync/versions/webroot/common-extra.txt && test -f /var/lib/stsync/versions/webroot/extra-dir/x.txt"
done
check "n2 and n3 set aside files themselves (join log)" sh -c "docker exec $(c n2) grep -q 'set aside [1-9]' /var/lib/stsync/join.log && docker exec $(c n3) grep -q 'set aside [1-9]' /var/lib/stsync/join.log"
if wait_until 30 same_global n1 n2 n3; then ok "same global state (files, directories, deletes, bytes) on n1, n2, n3: $(global_of n1)"
else bad "same global state on n1, n2, n3" "$(global_of n1) / $(global_of n2) / $(global_of n3)"; fi
check "n3's local-only file left the webroot" dx "$(c n3)" test ! -e $P/local-only.txt
VERS=$(dx "$(c n3)" bash -c 'cd /var/lib/stsync/versions/webroot 2>/dev/null && find . -type f | sort | paste -sd " " -')
check "n3's differences are in its version store (local-only.txt, index.php, f7.txt)" \
    sh -c "echo '$VERS' | grep -q 'local-only' && echo '$VERS' | grep -q 'index' && echo '$VERS' | grep -q 'f7'"
expect "n3 versions: stale content kept" "stale" "$(dx "$(c n3)" bash -c 'cat /var/lib/stsync/versions/webroot/index*.php')"
expect "no conflict copies anywhere" "0 0 0" "$(conflicts_on n1) $(conflicts_on n2) $(conflicts_on n3)"
check "ignored files not sent (n1 cache not on n2)" dx "$(c n2)" test ! -e $P/wp-content/cache/page.html
expect "ignored files kept locally (n3 cache + log)" "n3cache n3" \
    "$(dx "$(c n3)" cat $P/wp-content/cache/n3.html) $(dx "$(c n3)" cat $P/debug.log)"
expect "n1 log untouched" n1 "$(dx "$N1" cat $P/debug.log)"
check "join log written" dx "$(c n3)" grep -q "now send-receive" /var/lib/stsync/join.log

section "propagation"
dx "$(c n3)" runuser -u $WEBUSER -- bash -c "echo v2 > $P/index.php && echo new > $P/new.txt"
check "edit on n3 reaches n1 and n2" wait_until 30 sh -c \
    "docker exec $N1 grep -qx v2 $P/index.php && docker exec $(c n2) test -f $P/new.txt"
dx "$(c n2)" rm -f $P/new.txt
check "delete on n2 reaches n1 and n3" wait_until 30 sh -c \
    "docker exec $N1 test ! -e $P/new.txt && docker exec $(c n3) test ! -e $P/new.txt"
check "the seed's old index.php went to its version store" dx "$N1" bash -c 'grep -qx v1 /var/lib/stsync/versions/webroot/index*.php'

# ---- status and rescan --------------------------------------------------------

section "status"
wait_until 30 sh -c "docker exec $(c n2) stsync status --folder webroot --path $P | grep -q '\"state\":\"idle\"'"
st n2 status --folder webroot --path $P
J=$(val JSON "$OUT")
say "  $J"
expect "status ok" "ok 0" "$(val RESULT "$OUT") $RC"
check "status is one line of valid JSON with every field" python3 -c "
import json, sys
d = json.loads(sys.argv[1])
need = 'service version device user folderType state needItems needBytes globalFiles globalDirectories globalDeleted globalBytes localFiles errors connectedPeers totalPeers conflicts join joinPhase lastScan inotifyLimit'.split()
sys.exit(0 if all(k in d for k in need) else 1)" "$J"
expect "status values" "active v$VER $(dev n2) $WEBUSER sendreceive idle 0 2 2 0 done" \
    "$(for k in service version device user folderType state needItems connectedPeers totalPeers conflicts join; do printf '%s ' "$(json_field "$J" $k)"; done | sed 's/ $//')"
check "status: numbers are numbers" python3 -c "
import json, sys
d = json.loads(sys.argv[1])
sys.exit(0 if all(isinstance(d[k], int) for k in ('needItems','needBytes','globalFiles','globalDirectories','globalDeleted','globalBytes','localFiles','errors','inotifyLimit')) else 1)" "$J"
# Under an ignored directory, so the fake conflict copy stays on n2.
dx "$(c n2)" runuser -u $WEBUSER -- bash -c "mkdir -p $P/wp-content/cache && echo x > '$P/wp-content/cache/a.sync-conflict-20260930-000000-ABCDEFG.txt'"
st n2 status --folder webroot --path $P
expect "status counts conflict copies" 1 "$(json_field "$(val JSON "$OUT")" conflicts)"
dx "$(c n2)" rm -f "$P/wp-content/cache/a.sync-conflict-20260930-000000-ABCDEFG.txt"
st n1 status --folder webroot --path $P
expect "seed join state" none "$(json_field "$(val JSON "$OUT")" join)"
dx "$(c n3)" bash -c 'cp /var/lib/stsync/join.state /var/tmp/js && sed -i s/^state=done/state=failed/ /var/lib/stsync/join.state'
st n3 status --folder webroot --path $P
J=$(val JSON "$OUT")
st n3 prepare --path $P --ip "$(ipof n3)" --folder webroot
expect "failed join: status says failed, prepare says none" "failed none" "$(json_field "$J" join) $(val JOIN "$OUT")"
dx "$(c n3)" cp /var/tmp/js /var/lib/stsync/join.state
dx "$(c n2)" systemctl stop stsync
st n2 status --folder webroot --path $P
J=$(val JSON "$OUT")
expect "status with the service stopped: ok, from the files" "ok inactive v$VER $(dev n2) null" \
    "$(val RESULT "$OUT") $(json_field "$J" service) $(json_field "$J" version) $(json_field "$J" device) $(json_field "$J" folderType)"
dx "$(c n2)" systemctl start stsync

section "rescan"
st n1 rescan --folder webroot
expect "rescan ok" "ok 0" "$(val RESULT "$OUT") $RC"
st n1 rescan --folder nope
expect "rescan of an unknown folder: failed" failed "$(val RESULT "$OUT")"

# ---- simulated redeploy ---------------------------------------------------------

section "redeploy (binary, unit and env gone; /var/lib/stsync kept)"
dx "$N1" bash -c 'systemctl stop stsync; rm -f /usr/local/bin/syncthing /etc/systemd/system/stsync.service /etc/stsync.env; systemctl daemon-reload'
st n1 prepare --path $P --ip "$(ipof n1)" --folder webroot
expect "redeploy: prepare ok, same device, folder kept" "ok $(dev n1) sendreceive" \
    "$(val RESULT "$OUT") $(val DEVICE "$OUT") $(val FOLDER_TYPE "$OUT")"
check "redeploy: n1 back in the mesh" wait_until 30 sh -c \
    "docker exec $N1 stsync status --folder webroot --path $P | grep -q '\"connectedPeers\":2'"

section "another Syncthing version installed"
# mv, not a write in place: the running binary is busy (ETXTBSY).
dx "$(c n2)" bash -c 'printf "#!/bin/sh\necho \"syncthing v2.1.4 fake\"\n" > /var/tmp/fake && chmod +x /var/tmp/fake && mv -f /var/tmp/fake /usr/local/bin/syncthing'
st n2 prepare --path $P --ip "$(ipof n2)" --folder webroot
expect "pinned version reinstalled, same device" "ok syncthing v$VER $(dev n2)" \
    "$(val RESULT "$OUT") $(dx "$(c n2)" /usr/local/bin/syncthing --version | cut -d ' ' -f 1-2) $(val DEVICE "$OUT")"
check "service restarted on the pinned binary" dx "$(c n2)" bash -c \
    'readlink /proc/$(systemctl show -p MainPID --value stsync)/exe | grep -qx /usr/local/bin/syncthing'

# ---- clone -------------------------------------------------------------------

section "clone (docker commit of n3, started as n4)"
docker commit "$(c n3)" "$PFX-clone-img" > /dev/null
start_node n4 "$PFX-clone-img" || bad "clone container started"
N4=$(c n4)
sleep 3
check "clone: guard blocks the service" sh -c "[ \"\$(docker exec $N4 systemctl is-active stsync)\" != active ]"
check "clone: no syncthing process" sh -c "! docker exec $N4 pgrep -x syncthing"
st n4 guard
expect "clone: guard fails" "failed 1" "$(val RESULT "$OUT") $RC"
check "clone: guard names the original" grep -q "copy of n3" <<< "$OUT"
check "clone: the unit gives up instead of looping (start limit)" wait_until 60 sh -c \
    "[ \"\$(docker exec $N4 systemctl show -p ActiveState --value stsync)\" = failed ]"
st n4 prepare --path $P --ip "$(ipof n4)" --folder webroot
expect "clone: prepare ok and STSYNC_CLONED=1" "ok 1" "$(val RESULT "$OUT") $(val CLONED "$OUT")"
setdev n4 "$(val DEVICE "$OUT")"
check "clone: new device id" test -n "$(dev n4)" -a "$(dev n4)" != "$(dev n3)"
expect "clone: fresh config (no folder) and no join" "none none" "$(val FOLDER_TYPE "$OUT") $(val JOIN "$OUT")"
expect "clone: bound = new hostname" n4 "$(dx "$N4" cat /var/lib/stsync/bound)"
check "clone: service active" dx "$N4" systemctl is-active -q stsync
st n4 prepare --path $P --ip "$(ipof n4)" --folder webroot
expect "clone: second prepare does not reset again" "$(dev n4) " "$(val DEVICE "$OUT") $(val CLONED "$OUT")"
# The platform then adds it like any new node: receive-only + join, with the
# send-receive nodes as --from. Here the new node is configured and joins
# FIRST, and n1 only learns its device (no folder share yet): the join must
# wait for a connected node of its --from list that shares the folder, and
# must not revert anything meanwhile.
dx "$N4" runuser -u $WEBUSER -- bash -c "echo clone-only > $P/clone-only.txt"
st n4 ignore --path $P --b64 "$RULES_B64"
st n4 api --plan-b64 "$(plan n4 receiveonly 1 n1 n2 n3 n4)"
expect "clone: plan ok" ok "$(val RESULT "$OUT")"
st n1 api --plan-b64 "$(plan n1 sendreceive 0 n1 n2 n3 n4 | base64 -d | head -n 2 | b64)"
expect "n1 knows the clone's device (no folder share yet)" "ok 200 200" "$(val RESULT "$OUT") $(val API_1 "$OUT") $(val API_2 "$OUT")"
check "clone: the copied join.from went with the reset" dx "$N4" test ! -e /var/lib/stsync/join.from
st n4 join --folder webroot --from "$(dev n1)"
# A worker that dies reads as no join; the next join call starts a new one.
dx "$N4" bash -c 'kill -9 $(sed -n "s/^pid=//p" /var/lib/stsync/join.state)'
st n4 prepare --path $P --ip "$(ipof n4)" --folder webroot
expect "killed join worker reads as none" "receiveonly none" "$(val FOLDER_TYPE "$OUT") $(val JOIN "$OUT")"
st n4 join --folder webroot
expect "join restarted, with the saved --from list" "ok running $(dev n1)" "$(val RESULT "$OUT") $(val JOIN "$OUT") $(dx "$N4" cat /var/lib/stsync/join.from)"
check "clone: connected to n1 before any folder share" wait_until 30 sh -c \
    "docker exec $N4 stsync status --folder webroot --path $P | grep -q '\"connectedPeers\":1'"
# n2 and n3 share the folder with n4 now, but only n1 is in its --from list:
# the join may only sync against a listed (send-receive) node.
for n in n2 n3; do st "$n" api --plan-b64 "$(plan "$n" sendreceive 0 n1 n2 n3 n4)"; done
check "clone: connected to n2 and n3 too, which share the folder" wait_until 30 sh -c \
    "docker exec $N4 stsync status --folder webroot --path $P | grep -q '\"connectedPeers\":3'"
sleep 20
check "clone: join waits (the only listed node, n1, does not share the folder yet)" dx "$N4" bash -c \
    "grep -q 'waiting for a connected send-receive node' /var/lib/stsync/join.log && ! grep -q -e 'a send-receive node is connected' -e reverted /var/lib/stsync/join.log"
check "clone: status shows the join's phase" sh -c "docker exec $N4 stsync status --folder webroot --path $P | grep -q '\"joinPhase\":\"waiting for a send-receive node\"'"
check "clone: its local-only file is untouched meanwhile" dx "$N4" test -f $P/clone-only.txt
st n1 api --plan-b64 "$(plan n1 sendreceive 0 n1 n2 n3 n4)"
if wait_until 300 join_done n4; then ok "clone: join done"; else bad "clone: join done" "$(dx "$N4" tail -n 5 /var/lib/stsync/join.log)"; fi
sleep 3
check "clone: same content as the cluster" same_tree n1 n4
check "cluster unchanged by the clone" same_tree n1 n3
check "clone: its local-only file did not reach the cluster" dx "$N1" test ! -e $P/clone-only.txt
check "clone: its local-only file is in its version store" dx "$N4" bash -c 'ls /var/lib/stsync/versions/webroot/ | grep -q clone-only'
expect "clone: no conflict copies" "0 0" "$(conflicts_on n1) $(conflicts_on n4)"
st n1 status --folder webroot --path $P
expect "n1 sees 3 peers" "3 3" "$(json_field "$(val JSON "$OUT")" connectedPeers) $(json_field "$(val JSON "$OUT")" totalPeers)"

# ---- remove --------------------------------------------------------------------

section "remove (n4)"
BEFORE=$(tree n4)
# A conflict copy of a send-receive folder is the user's to review: remove
# leaves it (under an ignored directory, so it stays on n4 only).
dx "$N4" runuser -u $WEBUSER -- bash -c "mkdir -p $P/wp-content/cache && echo mine > '$P/wp-content/cache/b.sync-conflict-20260930-000000-ABCDEFG.txt'"
st n4 remove --path $P
expect "remove ok" "ok 0" "$(val RESULT "$OUT") $RC"
KEPT=$(val VERSIONS_KEPT "$OUT")
check "remove: files under the path unchanged" test "$BEFORE" = "$(tree n4)"
check "remove: ignored local files kept" dx "$N4" test -f $P/debug.log
check "remove: a send-receive folder's conflict copy stays" dx "$N4" test -f "$P/wp-content/cache/b.sync-conflict-20260930-000000-ABCDEFG.txt"
check "remove: .stfolder and .stignore gone" dx "$N4" bash -c "[ ! -e $P/.stfolder ] && [ ! -e $P/.stignore ]"
check "remove: unit, env, binary, runner, home gone" dx "$N4" bash -c \
    '! ls /etc/systemd/system/stsync.service /etc/stsync.env /usr/local/bin/syncthing /usr/local/sbin/stsync /var/lib/stsync 2>/dev/null | grep -q .'
check "remove: no syncthing process" sh -c "! docker exec $N4 pgrep -x syncthing"
check "remove: old versions moved to /root (STSYNC_VERSIONS_KEPT)" dx "$N4" bash -c "case '$KEPT' in /root/stsync-versions-*) [ -n \"\$(find '$KEPT' -type f)\" ] ;; *) false ;; esac"
expect "remove: redeploy.conf entry removed, other lines kept" "/etc/sysconfig/iptables|/var/spool/cron" \
    "$(dx "$N4" cat /etc/jelastic/redeploy.conf | paste -sd '|' -)"
install_runner n4
st n4 remove --path $P
expect "remove again: ok" "ok 0" "$(val RESULT "$OUT") $RC"
st n1 status --folder webroot --path $P
expect "the cluster sees n4 disconnected" "2 3" "$(json_field "$(val JSON "$OUT")" connectedPeers) $(json_field "$(val JSON "$OUT")" totalPeers)"

# ---- prepare --fresh, remove during a join (node x) ------------------------------

section "prepare --fresh (a first install finds state from an earlier one)"
X=$(c x)
st x prepare --path $P --ip "$(ipof x)" --folder webroot
setdev x "$(val DEVICE "$OUT")"
dx "$X" bash -c 'mkdir -p /var/lib/stsync/versions/webroot && echo kept > /var/lib/stsync/versions/webroot/old.txt \
    && printf "state=failed\nfolder=webroot\n" > /var/lib/stsync/join.state && echo AAAAAAA > /var/lib/stsync/join.from'
st x prepare --path $P --ip "$(ipof x)" --folder webroot --fresh
expect "prepare --fresh: ok, STSYNC_RESET=1, no folder, no join" "ok 1 none none" "$(val RESULT "$OUT") $(val RESET "$OUT") $(val FOLDER_TYPE "$OUT") $(val JOIN "$OUT")"
check "prepare --fresh: new device id" test -n "$(val DEVICE "$OUT")" -a "$(val DEVICE "$OUT")" != "$(dev x)"
setdev x "$(val DEVICE "$OUT")"
check "prepare --fresh: versions kept, join state gone" dx "$X" bash -c \
    "grep -qx kept /var/lib/stsync/versions/webroot/old.txt && [ ! -e /var/lib/stsync/join.state ] && [ ! -e /var/lib/stsync/join.from ]"
check "prepare --fresh: service active" dx "$X" systemctl is-active -q stsync

section "remove during a join (node x joins n1, the join held)"
# x holds an older copy: files that differ from the cluster's become conflict
# copies in the webroot while it joins. A long idle time keeps the join from
# finishing, like a join that is cut short by an uninstall.
dx "$X" runuser -u $WEBUSER -- bash -c "cd $P && mkdir -p wp-content/uploads && echo 'old index' > index.php \
    && for i in 1 2 3; do echo 'old upload' > wp-content/uploads/f\$i.txt; done && echo mine > x-only.txt && find . -type f -exec touch -d '5 hours ago' {} +"
st x ignore --path $P --b64 "$RULES_B64"
st x api --plan-b64 "$(plan x receiveonly 1 n1 x)"
expect "x: plan ok" ok "$(val RESULT "$OUT")"
st n1 api --plan-b64 "$(plan n1 sendreceive 0 n1 n2 n3 n4 x)"
OUT=$(docker exec -e STSYNC_JOIN_IDLE_S=900 "$X" stsync join --folder webroot --from "$(dev n1)" 2>&1)
expect "x: join started" "ok running" "$(val RESULT "$OUT") $(val JOIN "$OUT")"
if wait_until 90 sh -c "[ \$(docker exec $X bash -c \"find $P -name '*.sync-conflict-*' | wc -l\") -ge 4 ]"; then
    ok "x: the join made conflict copies in the webroot ($(conflicts_on x))"
else
    bad "x: the join made conflict copies in the webroot" "$(conflicts_on x) found"
fi
check "x: pulled everything, the join still holds" wait_until 60 sh -c \
    "docker exec $X stsync status --folder webroot --path $P | grep -q '\"state\":\"idle\",\"needItems\":0,'"
BEFORE=$(dx "$X" bash -c "cd $P && find . -type f ! -name '*.sync-conflict-*' ! -path './.stfolder/*' ! -name .stignore | sort | xargs md5sum")
st x remove --path $P
expect "x: remove ok" "ok 0" "$(val RESULT "$OUT") $RC"
check "x: remove says it moved the join's conflict copies" grep -q "conflict copies of the unfinished join moved" <<< "$OUT"
KEPT=$(val VERSIONS_KEPT "$OUT")
expect "x: no conflict copy left in the webroot" 0 "$(conflicts_on x)"
check "x: they are in the kept versions, same paths (index.php's old content)" dx "$X" bash -c \
    "grep -qx 'old index' $KEPT/webroot/index.sync-conflict-*.php && ls $KEPT/webroot/wp-content/uploads/ | grep -q 'f1.sync-conflict-'"
check "x: every other file under the path unchanged" test "$BEFORE" = "$(dx "$X" bash -c "cd $P && find . -type f ! -path './.stfolder/*' ! -name .stignore | sort | xargs md5sum")"
check "x: the earlier versions are kept too" dx "$X" grep -qx kept "$KEPT/webroot/old.txt"

# ---- summary --------------------------------------------------------------------

section "summary"
say "  $PASS passed, $FAIL failed"
for f in "${FAILED[@]+"${FAILED[@]}"}"; do say "  failed: $f"; done
[ "$FAIL" = 0 ]
