#!/bin/bash
# =============================================================================
# End-to-end test of the add-on (docs/DESIGN.md section 6)
# =============================================================================
# The real scripts/manage.js runs in the Nashorn harness (tests/harness, DOCKER
# mode: the stub `jelastic` runs node commands with `docker exec`) against
# systemd containers that run the real node runner (scripts/stsync.sh) and the
# real pinned Syncthing, on a WordPress-like tree (tests/e2e/wp_tree.py).
#
# Usage:  tests/e2e/run.sh
# Exit status: 0 every check passed, 1 a check failed, 2 the setup failed.
#
# Needs Docker, python3 with PyYAML on the host, the eclipse-temurin:11-jdk
# image (or a local JDK 11 jjs) and an AlmaLinux 9 image that boots systemd
# and has curl, python3 and procps-ng.
#
# Environment:
#   E2E_IMAGE             node image (default r3e-node)
#   E2E_PREFIX            prefix of every container, network and image
#                         (default sta-e2e); leftovers with it are removed first
#   STSYNC_TEST_TARBALLS  directory with the real release tarball
#                         syncthing-linux-<arch>-v2.1.5.tar.gz (default
#                         ~/.cache/stsync-test, downloaded from GitHub once).
#                         Nodes get it from a local HTTP container through
#                         STSYNC_DOWNLOAD_BASE; the runner still checks the
#                         pinned sha256.
#   KEEP=1                leave the containers and the work directory
#
# Scenario (node ids 101-104, 101 is the master):
#   0. install refused while the master's directory is empty (the others hold
#      the site): nothing installed, nothing moved
#   1. install on 3 nodes that already hold different content: the master's
#      copy wins everywhere, every differing file of the others is in their
#      version store - including files both joiners have and the master lacks,
#      which must not survive on either - ignored files stay, all folders end
#      send-receive, every node has the same global state
#   2. an edit, a new file and a delete propagate; ignored paths stay local
#   3. Configure: new ignore rules and delay on every node, the path is kept
#   4. simulated redeploy of node 102: same device, catches up, rules intact
#   5. scale out with a clone of node 101 (docker commit): the guard blocks
#      it, apply gives it a new identity, it joins safely, the cluster's files
#      are unchanged (a file deleted after the copy stays deleted)
#   6. scale in (node 103 removed): its device is dropped everywhere
#   7. Status lists every node in sync (after 1, 5 and 6); Rescan
#   8. uninstall: services gone, files in place, markers removed, old
#      versions kept under /root; a second uninstall is harmless
# Logs of every platform call (node commands and output) are kept in the work
# directory when a check fails.
# =============================================================================
set -u -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
TREE_PY=$HERE/wp_tree.py
IMAGE=${E2E_IMAGE:-r3e-node}
PFX=${E2E_PREFIX:-sta-e2e}
NET=$PFX-net
FILES=$PFX-files
CLONE_IMG=$PFX-img:clone
ENVNAME=$PFX-env
ROOT=/var/www/webroot/ROOT
WEBUSER=litespeed
VER=2.1.5
VSTORE=/var/lib/stsync/versions/webroot
PASS=0
FAIL=0
FAILED=()
T0=$(date +%s)

# ---- helpers ----------------------------------------------------------------

say()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); say "  PASS  $1"; }
bad()  { FAIL=$((FAIL + 1)); FAILED+=("$1"); say "  FAIL  $1${2:+ -- $2}"; }
check() { local n=$1; shift; if "$@" > /dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi; }
section() { say ""; say "== $* ($(( $(date +%s) - T0 )) s)"; }

c() { printf '%s-%s' "$PFX" "$1"; }
dx() { docker exec "$@"; }
# on NODE CMD - a shell command on a node, as root.
on() { dx "$(c "$1")" bash -c "$2"; }
# as_web NODE CMD - a shell command in the webroot, as the web user (like a
# PHP site or an SFTP upload would change files).
as_web() { dx "$(c "$1")" runuser -u $WEBUSER -- bash -c "cd $ROOT && $2"; }

wait_until() { # wait_until SECONDS COMMAND...
    local end=$(( $(date +%s) + $1 )); shift
    while :; do
        "$@" > /dev/null 2>&1 && return 0
        [ "$(date +%s)" -ge "$end" ] && return 1
        sleep 2
    done
}

# tree NODE shared|all - the listing of wp_tree.py.
tree() { dx -i "$(c "$1")" python3 - list $ROOT "$2" < "$TREE_PY"; }
# sha NODE PATH - sha256 of a file (relative to the webroot or absolute), or "missing".
sha() {
    local p=$2
    case $p in /*) ;; *) p=$ROOT/$p ;; esac
    dx "$(c "$1")" sha256sum "$p" 2>/dev/null | cut -d ' ' -f 1 | grep . || echo missing
}
# api NODE PATH - GET on the node's Syncthing API.
api() { on "$1" "curl -s -m 10 -H \"X-API-Key: \$(cat /var/lib/stsync/apikey)\" http://127.0.0.1:8384$2"; }
# pyj EXPR - a Python expression over the JSON on stdin (as d).
pyj() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
device() { api "$1" /rest/system/status | pyj 'd["myID"]'; }

# node_ok NODE - the runner's status: active, send-receive, idle, nothing to
# pull, no join running, every peer connected.
node_ok() {
    on "$1" "stsync status --folder webroot --path $ROOT" | sed -n 's/^STSYNC_JSON=//p' | python3 -c '
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if (d["service"], d["folderType"], d["state"], d["needItems"], d["join"] != "running",
               d["connectedPeers"] == d["totalPeers"], d["errors"]) == ("active", "sendreceive", "idle", 0, True, True, 0) else 1)'
}
# in_sync NODE... - every node ok and the same shared tree on all of them.
in_sync() {
    local n ref='' t
    for n in "$@"; do node_ok "$n" || return 1; done
    for n in "$@"; do
        t=$(tree "$n" shared) || return 1
        [ -n "$ref" ] || ref=$t
        [ "$t" = "$ref" ] || return 1
    done
    for n in "$@"; do node_ok "$n" || return 1; done
}
# converge SECONDS NODE... - wait for in_sync; says how long it took.
converge() {
    local t=$1 s n; shift
    s=$(date +%s)
    if wait_until "$t" in_sync "$@"; then ok "nodes $* in sync after $(( $(date +%s) - s )) s"; return 0; fi
    bad "nodes $* not in sync after $t s"
    for n in "$@"; do say "        $n: $(on "$n" "stsync status --folder webroot --path $ROOT" | grep MESSAGE)"; done
    return 1
}
no_conflicts() { [ -z "$(on "$1" "find $ROOT -name '*.sync-conflict-*' | head -n 3")" ]; }
# global_of NODE - the folder's global state (files/directories/deleted/bytes):
# the same on every node once they agree on the content.
global_of() { api "$1" "/rest/db/status?folder=webroot" | pyj '"%s/%s/%s/%s" % (d["globalFiles"], d["globalDirectories"], d["globalDeleted"], d["globalBytes"])'; }
same_global() { local n ref; ref=$(global_of "$1") || return 1; for n in "$@"; do [ "$(global_of "$n")" = "$ref" ] || return 1; done; }

# The platform: manage NAME key=value... runs scripts/manage.js through the
# harness (op=uninstall: the manifest's inline onUninstall). The script's
# message and result are in $LOGS/NAME.out (OUTPUT), node commands and their
# output in $LOGS/NAME.log; MRC is the harness exit status (0 result 0 or
# info, 2 warning, 1 error).
NODES=
manage() {
    local name=$1; shift
    "$REPO/tests/harness/manage.sh" "$STATE" "env=$ENVNAME" "nodes=$NODES" "base=http://$FILES:8000" \
        "dockerenv=STSYNC_DOWNLOAD_BASE=http://$FILES:8000/dl" "log=$LOGS/$name.log" "$@" > "$LOGS/$name.out" 2>&1
    MRC=$?
    OUTPUT=$(cat "$LOGS/$name.out")
}
has() { grep -qF -- "$1" <<< "$OUTPUT"; }
show() { say "$OUTPUT" | sed 's/^/        | /' | cut -c1-240; }
# setting EXPR - a Python expression over the saved settings (as s).
setting() {
    python3 - "$STATE" "$ENVNAME" "$1" <<'PY'
import json, os, sys
st = json.load(open(sys.argv[1]))
raw = st["envs"][sys.argv[2]]["groups"]["cp"].get("stSync", "")
s = json.loads(raw) if raw else None
print(eval(sys.argv[3]))
PY
}
# status_check N IDS... - the Status popup: the overall line and every node.
status_check() {
    local count=$1 id; shift
    manage "status-$count" op=status
    expect "Status: result info" 0 "$MRC"
    check "Status: overall 'in sync on all $count node(s)'" has "Overall: in sync on all $count node(s)"
    for id in "$@"; do
        check "Status: node $id in sync" grep -qE "^Node $id( \(master\))?: in sync$" <<< "$OUTPUT"
    done
    has "Overall: in sync" || show
}

# kept_in_versions NODE BEFORE SEED [STORE] - every file of the NODE listing
# BEFORE that the seed listing SEED does not have with the same content is now
# in NODE's version store (default $VSTORE), unchanged - under its own name or
# as a conflict copy of it. Prints what wp_tree.py kept says.
kept_in_versions() {
    local list
    list=$(python3 - "$2" "$3" <<'PY'
import sys
def files(p):
    out = {}
    for line in open(p, encoding="utf-8"):
        if line.startswith("F "):
            _, sha, _, rel = line.rstrip("\n").split(" ", 3)
            out[rel] = sha
    return out
node, seed = files(sys.argv[1]), files(sys.argv[2])
for rel in sorted(node):
    if seed.get(rel) != node[rel]:
        print("%s  %s" % (node[rel], rel))
PY
)
    [ -n "$list" ] || { echo "no differing files: the scenario is wrong"; return 1; }
    kept_check "$1" "${4:-$VSTORE}" "$list"
}
# kept_check NODE STORE LINES - wp_tree.py kept.
kept_check() { dx -i "$(c "$1")" python3 - kept "$2" "$(printf '%s\n' "$3" | base64 | tr -d '\n')" < "$TREE_PY"; }

start_node() { # start_node NAME HOSTNAME [IMAGE]
    docker run -d --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /tmp \
        --hostname "$2" --name "$(c "$1")" --network "$NET" "${3:-$IMAGE}" /usr/sbin/init > /dev/null || return 1
    wait_until 60 sh -c "docker exec $(c "$1") systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded'"
}
# A Jelastic-like app node: web user, webroot, redeploy.conf with other lines.
setup_node() {
    on "$1" "useradd -u 1001 -m $WEBUSER && mkdir -p $ROOT && chown $WEBUSER: /var/www/webroot $ROOT \
        && mkdir -p /etc/jelastic && printf '/etc/sysconfig/iptables\n/var/spool/cron\n' > /etc/jelastic/redeploy.conf"
}
make_tree() { # make_tree NODE VARIANT
    dx -i "$(c "$1")" python3 - make $ROOT "$2" < "$TREE_PY" && on "$1" "chown -R $WEBUSER: $ROOT"
}

teardown() {
    local ids
    ids=$(docker ps -aq --filter "name=^$PFX-")
    [ -n "$ids" ] && docker rm -f $ids > /dev/null 2>&1
    docker network rm "$NET" > /dev/null 2>&1
    docker rmi -f "$CLONE_IMG" > /dev/null 2>&1
    return 0
}
finish() {
    if [ "${KEEP:-0}" = 1 ]; then
        say "KEEP=1: containers ($PFX-*) and $WORK left in place"
    else
        teardown
        if [ "$FAIL" = 0 ] && [ "$SETUP_OK" = 1 ]; then rm -rf "$WORK"; else say "logs kept in $WORK/state"; fi
    fi
}

# ---- setup ------------------------------------------------------------------

section "setup ($PFX, image $IMAGE)"
SETUP_OK=0
WORK=$(mktemp -d "${TMPDIR:-/tmp}/stsync-e2e.XXXXXX") || exit 2
STATE=$WORK/state/platform.json
LOGS=$WORK/state
mkdir -p "$LOGS"
trap finish EXIT
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
# What the nodes download: the runner from the add-on's base URL, Syncthing
# from STSYNC_DOWNLOAD_BASE.
docker run -d --name "$FILES" --network "$NET" --entrypoint python3 "$IMAGE" -m http.server 8000 --directory /srv > /dev/null || exit 2
dx "$FILES" mkdir -p /srv/scripts /srv/dl
docker cp "$REPO/scripts/stsync.sh" "$FILES:/srv/scripts/stsync.sh" > /dev/null || exit 2
docker cp "$TDIR/$TARBALL" "$FILES:/srv/dl/$TARBALL" > /dev/null || exit 2
for n in n1 n2 n3; do
    start_node $n "node10${n#n}-$PFX" && setup_node $n || { say "cannot start node $n"; exit 2; }
done
make_tree n1 site && make_tree n2 stale && make_tree n3 other || { say "cannot write the test trees"; exit 2; }
for n in n1 n2 n3; do
    tree $n shared > "$WORK/before-$n.txt" && tree $n all > "$WORK/before-all-$n.txt" || exit 2
done
say "  n1 $(grep -c '^F' "$WORK/before-n1.txt") files (master), n2 $(grep -c '^F' "$WORK/before-n2.txt") (stale copy), n3 $(grep -c '^F' "$WORK/before-n3.txt") (partial copy, newer style.css)"
SETUP_OK=1
NODES=101:$(c n1):master,102:$(c n2),103:$(c n3)

# ---- 0. install refused: empty master -------------------------------------------

section "0. install refused while the master's directory is empty"
on n1 "mv $ROOT $ROOT.hold && mkdir $ROOT && chown $WEBUSER: $ROOT"
manage install-refused op=apply phase=install path=$ROOT delay=1 versionsDays=0
expect "install: refused (result error)" 1 "$MRC"
check "install: names the empty master and the fuller node" has "Node 101 (master) would be the starting copy, but it holds 0 file(s)"
check "install: says nothing was installed" has "Nothing was installed."
has "would be the starting copy" || show
for n in n1 n2 n3; do
    check "$n: no Syncthing left (service, home, runner)" on $n "! systemctl cat stsync.service > /dev/null 2>&1 && ! test -e /var/lib/stsync && ! test -e /usr/local/sbin/stsync"
done
for n in n2 n3; do check "$n: its files untouched" [ "$(tree $n all)" = "$(cat "$WORK/before-all-$n.txt")" ]; done
expect "no settings saved" "None" "$(setting 's')"
on n1 "rm -rf $ROOT && mv $ROOT.hold $ROOT"

# ---- 1. install ---------------------------------------------------------------

section "1. install on 3 nodes with different content"
manage install op=apply phase=install path=$ROOT delay=1 versionsDays=14 firewall=1
expect "install: result 0" 0 "$MRC"
[ "$MRC" = 0 ] || show
check "install: node 101 (master) is the seed" has "Node 101 is the seed"
check "install: nodes 102 and 103 join receive-only" has "Joining: nodes 102, 103"
check "install: firewall rule added (account firewall on)" has "Firewall: allowed TCP 22000"
expect "settings saved: path, seed, 3 nodes" "$ROOT 101 3" "$(setting '" ".join(map(str, (s["path"], s["seedNodeId"], len(s["nodes"]))))')"
converge 180 n1 n2 n3
expect "the master's copy is unchanged" "$(cat "$WORK/before-n1.txt")" "$(tree n1 shared)"
for n in n2 n3; do
    check "$n has exactly the master's copy" [ "$(tree $n shared)" = "$(cat "$WORK/before-n1.txt")" ]
    if r=$(kept_in_versions $n "$WORK/before-$n.txt" "$WORK/before-n1.txt"); then
        ok "$n: its differing files are in its version store, unchanged: $r"
    else bad "$n: its differing files in the version store" "$r"; fi
done
check "n2: wp-config.php has the master's mode (0640), not its own" \
    [ "$(tree n2 shared | grep ' wp-config.php$')" = "$(grep ' wp-config.php$' "$WORK/before-n1.txt")" ]
STYLE=wp-content/themes/twentytwentysix/style.css
check "n3: its LATER edit of style.css did not win" [ "$(sha n3 $STYLE)" = "$(sha n1 $STYLE)" ]
check "n3: its later style.css is in its version store" kept_check n3 $VSTORE "$(grep " $STYLE\$" "$WORK/before-n3.txt" | cut -d ' ' -f 2)  $STYLE"
check "the other nodes' own files never reached the master" on n1 "! test -e $ROOT/notes-only-here.txt && ! test -e $ROOT/wp-content/plugins/old-plugin"
# Both joiners had these and the master not: set aside on both, on no node
# in the webroot (one joiner used to keep them after the other's revert).
for n in n1 n2 n3; do
    check "$n: the joiners' common files are not in the webroot" on $n "! test -e $ROOT/wp-content/uploads/2026/06/on-two-nodes.jpg && ! test -e $ROOT/wp-content/plugins/extra-plugin"
done
for n in n2 n3; do
    check "$n: its copy of the common files is in its version store" on $n "test -f $VSTORE/wp-content/uploads/2026/06/on-two-nodes.jpg && test -f $VSTORE/wp-content/plugins/extra-plugin/extra.php"
done
if wait_until 30 same_global n1 n2 n3; then ok "same global state on every node: $(global_of n1)"
else bad "same global state on every node" "$(global_of n1) / $(global_of n2) / $(global_of n3)"; fi
for n in n1 n2 n3; do
    check "$n: ignored files unchanged (cache, logs, upgrade)" [ "$(tree $n all | grep -E ' wp-content/(cache|upgrade)|\.log$|\.DS_Store$')" = "$(grep -E ' wp-content/(cache|upgrade)|\.log$|\.DS_Store$' "$WORK/before-all-$n.txt")" ]
    check "$n: no conflict copies" no_conflicts $n
    check "$n: every file owned by $WEBUSER" [ -z "$(on $n "find $ROOT ! -user $WEBUSER | head -n 3")" ]
    expect "$n: folder send-receive, delay 1, trashcan 14 days in $VSTORE" "sendreceive 1 trashcan 14 $VSTORE $ROOT" \
        "$(api $n /rest/config/folders/webroot | pyj '" ".join(map(str, (d["type"], d["fsWatcherDelayS"], d["versioning"]["type"], d["versioning"]["params"]["cleanoutDays"], d["versioning"]["fsPath"], d["path"])))')"
done
expect "joins done on n2 and n3" "done done" "$(on n2 'sed -n s/^state=//p /var/lib/stsync/join.state') $(on n3 'sed -n s/^state=//p /var/lib/stsync/join.state')"
check "listening on the private IP only" on n1 "ss -Hltn | grep -q ':22000 ' && ! ss -Hltn | grep -qE '(0\.0\.0\.0|\*|\[::\]):(22000|8384) '"
status_check 3 101 102 103

# ---- 2. propagation -------------------------------------------------------------

section "2. edits, new files and deletes propagate; ignored paths stay local"
as_web n3 "echo '/* edited on node 103 */' >> wp-content/themes/twentytwentysix/functions.php"
as_web n2 "rm -f wp-content/uploads/2026/08/photo-02.jpg && mkdir -p wp-content/uploads/2026/10 && head -c 2000000 /dev/urandom > wp-content/uploads/2026/10/new-upload.jpg"
as_web n1 "echo fresh > wp-content/cache/page-new.html && echo 'more master log' >> wp-content/debug.log && echo x > wp-content/upgrade/tmp.zip"
EDIT=$(sha n3 wp-content/themes/twentytwentysix/functions.php)
UPLOAD=$(sha n2 wp-content/uploads/2026/10/new-upload.jpg)
converge 60 n1 n2 n3
for n in n1 n2; do expect "$n: the edit made on n3 arrived" "$EDIT" "$(sha $n wp-content/themes/twentytwentysix/functions.php)"; done
for n in n1 n3; do
    expect "$n: the upload made on n2 arrived" "$UPLOAD" "$(sha $n wp-content/uploads/2026/10/new-upload.jpg)"
    check "$n: the file deleted on n2 is gone" on $n "! test -e $ROOT/wp-content/uploads/2026/08/photo-02.jpg"
    check "$n: the deleted file is in its version store" on $n "test -f $VSTORE/wp-content/uploads/2026/08/photo-02.jpg"
done
for n in n2 n3; do
    check "$n: n1's new cache, log and upgrade files did not arrive" on $n "! test -e $ROOT/wp-content/cache/page-new.html && ! grep -q 'more master log' $ROOT/wp-content/debug.log 2>/dev/null && ! test -e $ROOT/wp-content/upgrade/tmp.zip"
done
check "n1 keeps its own ignored files" on n1 "test -f $ROOT/wp-content/cache/page-new.html && grep -q 'more master log' $ROOT/wp-content/debug.log"

# ---- 3. Configure ----------------------------------------------------------------

section "3. Configure: new ignore rules and delay; the path cannot change"
IGNORE=$(printf '%s\n' '// e2e rules' '(?d)/wp-content/cache' '(?d)/wp-content/upgrade' '(?d)/wp-content/backups' '(?d)*.log' '(?d)*.tmp')
manage configure op=apply phase=configure path=/srv/elsewhere delay=3 versionsDays=7 "ignore-b64=$(printf '%s' "$IGNORE" | base64 | tr -d '\n')"
expect "Configure: result warning (path change refused)" 2 "$MRC"
check "Configure: says the directory cannot be changed" has "cannot be changed after install; it stays $ROOT"
expect "settings: path kept, new rules, delay 3, 7 days" "$ROOT True 3 7" \
    "$(IGN=$IGNORE setting '" ".join(map(str, (s["path"], s["ignore"] == os.environ["IGN"], s["delay"], s["versionsDays"])))')"
for n in n1 n2 n3; do
    expect "$n: .stignore has the new rules" "$IGNORE" "$(on $n "cat $ROOT/.stignore")"
    expect "$n: folder path kept, delay 3, 7 days" "$ROOT 3 7" \
        "$(api $n /rest/config/folders/webroot | pyj '" ".join(map(str, (d["path"], d["fsWatcherDelayS"], d["versioning"]["params"]["cleanoutDays"])))')"
done
check "no directory was created at the refused path" on n1 "! test -e /srv/elsewhere"
as_web n1 "echo tmp > draft.tmp && mkdir -p wp-content/backups && echo b > wp-content/backups/db.sql && echo after > after-configure.txt"
converge 60 n1 n2 n3
for n in n2 n3; do
    check "$n: a normal file still arrives" on $n "test -f $ROOT/after-configure.txt"
    check "$n: newly ignored files stay on n1 (*.tmp, wp-content/backups)" on $n "! test -e $ROOT/draft.tmp && ! test -e $ROOT/wp-content/backups"
done

# ---- 4. redeploy -----------------------------------------------------------------

section "4. simulated redeploy of node 102"
DEV2=$(device n2)
on n2 "systemctl disable --now stsync > /dev/null 2>&1; rm -f /usr/local/bin/syncthing /etc/systemd/system/stsync.service /etc/stsync.env /usr/local/sbin/stsync; systemctl daemon-reload"
# Changes while node 102 is away.
as_web n1 "echo '<?php // v3' > index.php && rm -f wp-content/plugins/akismet/akismet-03.php"
docker restart "$(c n2)" > /dev/null && wait_until 60 sh -c "docker exec $(c n2) systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded'"
check "after the restart node 102 has no Syncthing (binary, unit and runner gone)" on n2 "! test -e /usr/local/bin/syncthing && ! test -e /etc/systemd/system/stsync.service && ! test -e /usr/local/sbin/stsync && test -s /var/lib/stsync/cert.pem"
manage redeploy op=apply phase=redeploy
expect "apply/redeploy: result 0" 0 "$MRC"
[ "$MRC" = 0 ] || show
expect "node 102 keeps its device id" "$DEV2" "$(device n2)"
converge 90 n1 n2 n3
expect "n2: the edit made while it was away arrived" "$(sha n1 index.php)" "$(sha n2 index.php)"
check "n2: the file deleted while it was away is gone" on n2 "! test -e $ROOT/wp-content/plugins/akismet/akismet-03.php"
expect "n2: ignore rules intact" "$IGNORE" "$(on n2 "cat $ROOT/.stignore")"
expect "n2: redeploy.conf lists /var/lib/stsync once, other lines kept" "/etc/sysconfig/iptables|/var/spool/cron|/var/lib/stsync" "$(on n2 'paste -sd "|" /etc/jelastic/redeploy.conf')"
expect "n2: service active and enabled" "active enabled" "$(on n2 'echo $(systemctl is-active stsync) $(systemctl is-enabled stsync)')"

# ---- 5. scale out with a clone -----------------------------------------------------

section "5. scale out with a clone of node 101"
DEV1=$(device n1)
docker commit "$(c n1)" "$CLONE_IMG" > /dev/null || bad "docker commit"
# The cluster moves on after the copy was taken.
as_web n2 "echo '/* newer, from node 102 */' >> wp-content/plugins/woocommerce/includes/wc-05.php"
as_web n3 "rm -f wp-content/uploads/2026/08/photo-03.jpg"
converge 60 n1 n2 n3
start_node n4 "node104-$PFX" "$CLONE_IMG" || bad "cannot start the clone"
check "the clone has node 101's Syncthing identity on disk" [ "$(on n4 'cat /var/lib/stsync/bound')" = "node101-$PFX" ]
sleep 5
check "the guard keeps Syncthing stopped on the clone" on n4 "! pgrep -x syncthing"
check "stsync guard: exit 1, names the original node" on n4 "! stsync guard > /tmp/g 2>&1 && grep -q 'is a copy of node101-$PFX' /tmp/g"
check "the unit gives up instead of looping" wait_until 40 on n4 "systemctl is-failed -q stsync"
# The copy's stale state: an edit dated LATER than the cluster's, a file
# only it has, a file the cluster deleted, and its own cache.
as_web n4 "echo '<?php // stale edit on the clone' > index.php && touch -d '2 hours' index.php && echo mine > clone-only.txt && echo c > wp-content/cache/clone-page.html"
check "the clone still has the file the cluster deleted" on n4 "test -f $ROOT/wp-content/uploads/2026/08/photo-03.jpg"
tree n1 shared > "$WORK/cluster-before-scale.txt"
tree n4 shared > "$WORK/clone-before-scale.txt"
NODES=$NODES,104:$(c n4)
manage scaleout op=apply phase=scale
expect "apply/scale: result 0" 0 "$MRC"
[ "$MRC" = 0 ] || show
check "apply/scale: node 104 reported as a copy with its own identity" has "Node 104 was a copy of another node"
check "apply/scale: node 104 joins" has "Joining: node 104"
DEV4=$(device n4)
check "node 104 has a new device id" [ -n "$DEV4" -a "$DEV4" != "$DEV1" ]
expect "node 101 keeps its device id" "$DEV1" "$(device n1)"
converge 180 n1 n2 n3 n4
expect "the cluster's files are unchanged" "$(cat "$WORK/cluster-before-scale.txt")" "$(tree n1 shared)"
check "the clone has exactly the cluster's files" [ "$(tree n4 shared)" = "$(cat "$WORK/cluster-before-scale.txt")" ]
for n in n1 n2 n3 n4; do
    check "$n: the file deleted after the copy stays deleted" on $n "! test -e $ROOT/wp-content/uploads/2026/08/photo-03.jpg"
    check "$n: no conflict copies" no_conflicts $n
done
if r=$(kept_in_versions n4 "$WORK/clone-before-scale.txt" "$WORK/cluster-before-scale.txt"); then
    ok "n4: its stale files are in its version store: $r"
else bad "n4: its stale files in the version store" "$r"; fi
check "n4 keeps its own cache file" on n4 "test -f $ROOT/wp-content/cache/clone-page.html"
if wait_until 30 same_global n1 n2 n3 n4; then ok "same global state on the 4 nodes"; else bad "same global state on the 4 nodes" "$(global_of n1) / $(global_of n4)"; fi
expect "settings: node 104 with its new device" "$DEV4" "$(setting 's["nodes"]["104"]["device"]')"
status_check 4 101 102 103 104

# ---- 6. scale in -----------------------------------------------------------------

section "6. scale in: node 103 removed"
DEV3=$(device n3)
docker rm -f "$(c n3)" > /dev/null
NODES=101:$(c n1):master,102:$(c n2),104:$(c n4)
manage scalein op=apply phase=scale
expect "apply/scale: result 0" 0 "$MRC"
[ "$MRC" = 0 ] || show
for n in n1 n2 n4; do
    check "$n: node 103's device is gone (devices and folder)" [ "$(api $n /rest/config/devices | pyj "'$DEV3' in [x['deviceID'] for x in d]")$(api $n /rest/config/folders/webroot | pyj "'$DEV3' in [x['deviceID'] for x in d['devices']]")" = FalseFalse ]
done
expect "settings: nodes 101, 102, 104" "101 102 104" "$(setting '" ".join(sorted(s["nodes"]))')"
as_web n4 "echo 'after scale in' > after-scale-in.txt"
converge 60 n1 n2 n4
for n in n1 n2; do check "$n: an edit made on n4 arrived" on $n "test -f $ROOT/after-scale-in.txt"; done

# ---- 7. Status and Rescan ------------------------------------------------------------

section "7. Status and Rescan"
status_check 3 101 102 104
check "Status: no peers reported disconnected" bash -c "! grep -q 'disconnected' '$LOGS/status-3.out'"
manage rescan op=rescan
expect "Rescan: result 0" 0 "$MRC"
check "Rescan: started on every node" has "Rescan started on nodes 101, 102, 104."

# ---- 8. uninstall ------------------------------------------------------------------

section "8. uninstall"
for n in n1 n2 n4; do
    tree $n all > "$WORK/pre-uninstall-$n.txt"
    on $n "cd $VSTORE && find . -type f -print0 | sort -z | xargs -0 -r sha256sum" > "$WORK/versions-$n.txt"
done
manage uninstall op=uninstall
expect "uninstall: result 0" 0 "$MRC"
for n in n1 n2 n4; do
    check "$n: service gone (no unit, no process)" on $n "! systemctl cat stsync.service && ! pgrep -x syncthing"
    check "$n: binary, runner, env file and home removed" on $n "! test -e /usr/local/bin/syncthing && ! test -e /usr/local/sbin/stsync && ! test -e /etc/stsync.env && ! test -e /var/lib/stsync"
    check "$n: .stfolder and .stignore removed" on $n "! test -e $ROOT/.stfolder && ! test -e $ROOT/.stignore"
    check "$n: every other file still there, unchanged" [ "$(tree $n all)" = "$(cat "$WORK/pre-uninstall-$n.txt")" ]
    expect "$n: redeploy.conf back to its own lines" "/etc/sysconfig/iptables|/var/spool/cron" "$(on $n 'paste -sd "|" /etc/jelastic/redeploy.conf')"
    if [ -s "$WORK/versions-$n.txt" ]; then
        check "$n: old versions kept under /root/stsync-versions-*" dx -i "$(c $n)" bash -c "cd /root/stsync-versions-*/webroot && sha256sum -c --quiet" < "$WORK/versions-$n.txt"
    fi
done
check "the stale node's own files are among its kept versions" on n2 "test -f /root/stsync-versions-*/webroot/wp-content/plugins/old-plugin/old-plugin.php"
expect "settings cleared" "None" "$(setting 's')"
manage uninstall-again op=uninstall
expect "a second uninstall is harmless (result 0)" 0 "$MRC"
check "the second uninstall left the files alone" [ "$(tree n1 all)" = "$(cat "$WORK/pre-uninstall-n1.txt")" ]

# ---- result --------------------------------------------------------------------

say ""
say "== $PASS passed, $FAIL failed in $(( $(date +%s) - T0 )) s"
for f in "${FAILED[@]+"${FAILED[@]}"}"; do say "  failed: $f"; done
[ "$FAIL" = 0 ] && exit 0
exit 1
