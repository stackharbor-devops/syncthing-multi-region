#!/bin/bash
# =============================================================================
# stsync - node runner of the Syncthing file replication add-on
# =============================================================================
# Installed as /usr/local/sbin/stsync on every node of the app layer by the
# add-on's platform script (scripts/manage.js), which runs it as root through
# ExecCmd. The build contract is docs/DESIGN.md, section 3.
#
# Output contract - machine lines (anything else is human text):
#   per-command lines first (STSYNC_DEVICE=..., STSYNC_JSON=..., ...), then
#   STSYNC_RESULT=ok|failed
#   STSYNC_MESSAGE=<one line>
# The exit status is 0 only with STSYNC_RESULT=ok.
#
# Commands:
#   prepare --path P --ip IP [--folder F] [--fresh] [--count-b64 B]
#                                           install / repair, start the service
#   guard                                   ExecStartPre: block a cloned node
#   ignore  --path P --b64 B                write P/.stignore
#   api     --plan-b64 B                    run REST calls against the local API
#   join    --folder F [--from IDS]         start the detached safe join
#   status  --folder F --path P             one-line JSON status
#   rescan  --folder F                      rescan the folder now
#   remove  [--path P]                      uninstall, leave the files in place
#
# prepare --fresh (a first install): any Syncthing state already on the node is
# left over from an earlier install, so it is reset like a cloned node's.
# prepare --count-b64 B: also print STSYNC_FILES / STSYNC_BYTES, the files
# under P that would replicate (B = base64 ignore rules, "-" for none), so the
# platform can refuse a seed that holds far fewer files than another node.
# join --from IDS: the device ids (comma-separated) of send-receive nodes. A
# joiner only syncs against one of them - never against another joiner alone.
#
# Test hooks: STSYNC_DOWNLOAD_BASE replaces the GitHub release URL (for example
# a local HTTP server that serves the real release tarballs; the sha256 check
# below still runs on whatever is downloaded); STSYNC_JOIN_IDLE_S replaces the
# 15 s a join waits in sync before it reverts.
# =============================================================================

set -u -o pipefail
umask 022
export LC_ALL=C
# Platform commands may run without /usr/local/sbin on PATH.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}

ST_VERSION=2.1.5
# From the signed sha256sum.txt.asc of the release.
SHA256_amd64=3d222b609f7ab2944e02748cb10488b4160d446b49e0eafc107ef2a525ab3486
SHA256_arm64=3666f3069feeee3651e185f867759206059755101797bdd69ea5317610130855
DOWNLOAD_BASE=${STSYNC_DOWNLOAD_BASE:-https://github.com/syncthing/syncthing/releases/download/v$ST_VERSION}

BIN=/usr/local/bin/syncthing
RUNNER=/usr/local/sbin/stsync
STHOME=/var/lib/stsync
VERSIONS=$STHOME/versions
APIKEY_FILE=$STHOME/apikey
BOUND=$STHOME/bound
JOIN_STATE=$STHOME/join.state
JOIN_LOG=$STHOME/join.log
# The send-receive devices a join may sync against. Kept apart from join.state
# so a later apply can update the list of a join that already runs, and so a
# join resumed at boot (ExecStartPost) still has it.
JOIN_FROM=$STHOME/join.from
ENV_FILE=/etc/stsync.env
UNIT=stsync.service
UNIT_FILE=/etc/systemd/system/$UNIT
REDEPLOY_CONF=/etc/jelastic/redeploy.conf
API=http://127.0.0.1:8384
# A join switches the folder to send-receive only after it was idle with
# nothing left to pull for this many seconds in a row.
JOIN_IDLE_S=${STSYNC_JOIN_IDLE_S:-15}

SELF=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
TMPD=

# ---- helpers ----------------------------------------------------------------

ts()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
log()  { printf '[%s] %s\n' "$(ts)" "$*"; }
# oneline [TEXT] - TEXT (or stdin) on one line, trimmed.
oneline() {
    if [ $# -gt 0 ]; then printf '%s' "$*"; else cat; fi \
        | tr '\r\n\t' '   ' | sed 's/  */ /g; s/^ //; s/ $//' | cut -c1-1000
}
out()  { printf 'STSYNC_%s=%s\n' "$1" "$2"; }

# emit ok|failed MESSAGE - print the contract lines and exit.
emit() {
    printf 'STSYNC_RESULT=%s\nSTSYNC_MESSAGE=%s\n' "$1" "$(oneline "$2")"
    [ "$1" = ok ] && exit 0
    exit 1
}
die() { emit failed "$*"; }

cleanup() { [ -n "$TMPD" ] && rm -rf "$TMPD"; }
trap cleanup EXIT
mktmp() {
    [ -n "$TMPD" ] && return 0
    TMPD=$(mktemp -d /var/tmp/stsync.XXXXXX) || die "cannot create a temporary directory in /var/tmp"
}

hostname_now() { uname -n; }

# owner_of P - the user that owns P; Syncthing runs as that user so that the
# files it writes belong to the site's user.
owner_of() {
    local u
    u=$(stat -c %U "$1" 2>/dev/null) || return 1
    [ -n "$u" ] && [ "$u" != UNKNOWN ] || return 1
    printf '%s' "$u"
}

valid_folder() { case $1 in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; return 0; }

# check_path P - fail unless P is an absolute existing directory on a local
# filesystem. Jelastic network mounts are automounts, so a probe can trigger a
# mount of an unreachable server: every probe is bounded by a timeout.
check_path() {
    local p=$1 fst
    case $p in /*) ;; *) die "path '$p' is not absolute" ;; esac
    timeout 20 test -d "$p" || die "path $p is not an existing directory"
    fst=$(timeout 20 findmnt -rn -o FSTYPE --target "$p" 2>/dev/null | tail -n 1)
    [ -n "$fst" ] || die "cannot tell which filesystem $p is on (findmnt gave no answer)"
    case $fst in
        nfs*|fuse*|glusterfs|cifs|smb*|ceph|9p|autofs)
            die "path $p is on a network or FUSE filesystem ($fst): Syncthing needs a local directory on every node" ;;
    esac
}

need() { # need VALUE OPTION
    [ -n "$1" ] || die "missing $2"
}

# ---- local REST API ---------------------------------------------------------

# api_req METHOD PATH [BODY_FILE] - sets API_CODE (000 = no answer); the
# response body is in $TMPD/resp. The key goes in a header file, not argv.
api_req() {
    local key args
    mktmp
    key=$(cat "$APIKEY_FILE" 2>/dev/null) || key=
    printf 'X-API-Key: %s\n' "$key" > "$TMPD/hdr"
    args=(-s -o "$TMPD/resp" -w '%{http_code}' --connect-timeout 5 --max-time 120 -X "$1" -H "@$TMPD/hdr")
    if [ -n "${3:-}" ]; then args+=(-H 'Content-Type: application/json' --data-binary "@$3"); fi
    : > "$TMPD/resp"
    API_CODE=$(curl "${args[@]}" "$API$2" 2>/dev/null)
    case $API_CODE in [0-9][0-9][0-9]) ;; *) API_CODE=000 ;; esac
}

# jfield EXPR - evaluate a Python expression over the last response (as d);
# booleans print as true/false. Fails on invalid JSON or a missing key.
jfield() {
    python3 - "$1" "$TMPD/resp" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[2]))
    v = eval(sys.argv[1])
except Exception:
    sys.exit(1)
print(str(v).lower() if isinstance(v, bool) else v)
PY
}

# wait_ping SECONDS - wait until the API answers.
wait_ping() {
    local end=$(( $(date +%s) + $1 ))
    while :; do
        api_req GET /rest/system/ping
        [ "$API_CODE" = 200 ] && return 0
        [ "$(date +%s)" -ge "$end" ] && return 1
        sleep 1
    done
}

# folder_type F - none when the folder is not configured; fails when the API
# does not answer.
folder_type() {
    api_req GET "/rest/config/folders/$1"
    case $API_CODE in
        200) jfield 'd["type"]' ;;
        404) echo none ;;
        *) return 1 ;;
    esac
}

# ---- join state -------------------------------------------------------------

getf() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1; }

write_state() { # write_state key=value... - atomic
    local tmp kv
    tmp=$(mktemp "$JOIN_STATE.XXXXXX") || return 1
    for kv in "$@"; do printf '%s\n' "$(oneline "$kv")" >> "$tmp"; done
    mv -f "$tmp" "$JOIN_STATE"
}

# join_pid - PID of the running join worker, if any (a stale file, or a PID
# reused after a restart, does not count).
join_pid() {
    local pid
    pid=$(getf "$JOIN_STATE" pid)
    case $pid in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$pid" 2>/dev/null || return 1
    tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q ' join-worker ' || return 1
    printf '%s' "$pid"
}

# join_state - none | running | done (the prepare/join contract). A join that
# died or failed reads as none, so the next apply starts it again.
join_state() {
    case $(join_detail) in running) echo running ;; done) echo 'done' ;; *) echo none ;; esac
}

# join_detail - join_state, plus "failed" when the last join ended in failure
# (reason in join.state and join.log). Used by status.
join_detail() {
    if join_pid > /dev/null; then echo running; return; fi
    case $(getf "$JOIN_STATE" state) in done) echo 'done' ;; failed) echo failed ;; *) echo none ;; esac
}

stop_join() {
    local pid
    pid=$(join_pid) || return 0
    kill "$pid" 2>/dev/null
    sleep 1
    kill -9 "$pid" 2>/dev/null
    return 0
}

# ---- prepare ----------------------------------------------------------------

# install_binary - install the pinned Syncthing release unless it is already
# there. Sets CHANGED=1 when the binary was replaced.
install_binary() {
    local arch sum asset got
    if [ -x "$BIN" ]; then
        case $("$BIN" --version 2>/dev/null | head -n 1) in "syncthing v$ST_VERSION "*) return 0 ;; esac
    fi
    case $(uname -m) in
        x86_64|amd64) arch=amd64; sum=$SHA256_amd64 ;;
        aarch64|arm64) arch=arm64; sum=$SHA256_arm64 ;;
        *) die "unsupported CPU architecture $(uname -m)" ;;
    esac
    asset=syncthing-linux-$arch-v$ST_VERSION.tar.gz
    mktmp
    curl -fsSL --retry 3 --connect-timeout 20 --max-time 600 -o "$TMPD/$asset" "$DOWNLOAD_BASE/$asset" \
        || die "cannot download $DOWNLOAD_BASE/$asset"
    got=$(sha256sum "$TMPD/$asset" | cut -d ' ' -f 1)
    [ "$got" = "$sum" ] || die "checksum mismatch for $asset (got $got): not installed"
    tar -xzf "$TMPD/$asset" -C "$TMPD" "syncthing-linux-$arch-v$ST_VERSION/syncthing" \
        || die "cannot unpack $asset"
    install -m 0755 -o root -g root "$TMPD/syncthing-linux-$arch-v$ST_VERSION/syncthing" "$BIN.new" \
        && mv -f "$BIN.new" "$BIN" || die "cannot install $BIN"
    case $("$BIN" --version 2>/dev/null | head -n 1) in
        "syncthing v$ST_VERSION "*) ;;
        *) die "the installed $BIN does not report version $ST_VERSION" ;;
    esac
    CHANGED=1
}

# write_if_changed FILE MODE - replace FILE with stdin when the content differs.
# Sets CHANGED=1 when it wrote.
write_if_changed() {
    local f=$1 mode=$2 tmp
    tmp=$(mktemp "$f.XXXXXX") || die "cannot write $f"
    cat > "$tmp"
    chmod "$mode" "$tmp"
    if [ -f "$f" ] && cmp -s "$tmp" "$f"; then rm -f "$tmp"; return 0; fi
    mv -f "$tmp" "$f" || die "cannot write $f"
    CHANGED=1
}

# private_options CONFIG IP - fresh config only: listen on the private IP and
# switch off discovery, relays, NAT and reporting BEFORE the first start, so a
# new node never contacts anything outside (the platform's API plan sets the
# same options again).
private_options() {
    python3 - "$1" "$2" <<'PY'
import sys, xml.etree.ElementTree as ET
path, ip = sys.argv[1], sys.argv[2]
if ":" in ip:
    ip = "[%s]" % ip
tree = ET.parse(path)
opts = tree.getroot().find("options")
old = opts.findall("listenAddress")
pos = list(opts).index(old[0]) if old else len(opts)
for e in old:
    opts.remove(e)
la = ET.Element("listenAddress")
la.text = "tcp://%s:22000" % ip
opts.insert(pos, la)
for k, v in (("globalAnnounceEnabled", "false"), ("localAnnounceEnabled", "false"),
             ("relaysEnabled", "false"), ("natEnabled", "false"), ("urAccepted", "-1"),
             ("crashReportingEnabled", "false"), ("autoUpgradeIntervalH", "0"),
             ("startBrowser", "false")):
    e = opts.find(k)
    if e is None:
        e = ET.SubElement(opts, k)
    e.text = v
tree.write(path)
PY
}

# reset_state WHY - stop Syncthing and a join, delete identity, config and
# database (everything in the home but versions/, which holds site files).
reset_state() {
    systemctl stop "$UNIT" > /dev/null 2>&1
    stop_join
    find "$STHOME" -mindepth 1 -maxdepth 1 ! -name versions -exec rm -rf {} + \
        || die "cannot reset the Syncthing state ($1)"
}

# count_files P B64 - "FILES BYTES" of the regular files and symlinks under P
# that would replicate: Syncthing's markers, temporary files and conflict
# copies left out, and what the ignore rules match. The rules are matched the
# way .stignore does for the common forms (//, (?d), (?i), !, leading /, *,
# **, ?, [...]; the first matching rule decides; a matched directory is left
# out whole). It is a size check for the seed choice, not an exact count.
count_files() {
    timeout 600 python3 - "$1" "$2" <<'PY'
import base64, os, re, sys
root, b64 = sys.argv[1], sys.argv[2]
text = "" if b64 in ("", "-") else base64.b64decode(b64).decode("utf-8", "replace")
rules = []
for line in text.splitlines():
    line = line.strip()
    if not line or line.startswith("//") or line.startswith("#"):
        continue
    neg, icase = False, False
    while True:
        if line.startswith("!"):
            neg, line = True, line[1:]
        elif line.startswith("(?i)"):
            icase, line = True, line[4:]
        elif line.startswith("(?d)"):
            line = line[4:]
        else:
            break
    anchored = line.startswith("/")
    line = line.strip("/")
    if not line:
        continue
    rx, i = "", 0
    while i < len(line):
        ch = line[i]
        if line.startswith("**", i):
            rx, i = rx + ".*", i + 2
            continue
        if ch == "*":
            rx += "[^/]*"
        elif ch == "?":
            rx += "[^/]"
        elif ch == "[" and "]" in line[i + 1:]:
            j = line.index("]", i + 1)
            rx, i = rx + "[" + line[i + 1:j].replace("\\", "\\\\") + "]", j + 1
            continue
        elif ch == "\\" and i + 1 < len(line):
            rx, i = rx + re.escape(line[i + 1]), i + 2
            continue
        else:
            rx += re.escape(ch)
        i += 1
    rules.append((re.compile(("^" if anchored else "^(?:.*/)?") + rx + "$", re.I if icase else 0), neg))
def ignored(rel):
    for rx, neg in rules:
        if rx.match(rel):
            return not neg
    return False
skip = re.compile(r"^(\.stfolder|\.stversions)$|\.sync-conflict-|^\.syncthing\..*\.tmp$|^~syncthing~.*\.tmp$")
files = size = 0
for d, dirs, names in os.walk(root):
    rel_d = os.path.relpath(d, root)
    rel_d = "" if rel_d == "." else rel_d + "/"
    dirs[:] = [x for x in dirs if not skip.search(x) and not ignored(rel_d + x)]
    for n in names:
        if n == ".stignore" or skip.search(n) or ignored(rel_d + n):
            continue
        try:
            st = os.lstat(os.path.join(d, n))
        except OSError:
            continue
        files += 1
        size += st.st_size
print(files, size)
PY
}

cmd_prepare() {
    local user host old apikey cloned=0 reset=0 ftype key counted=''
    need "$O_PATH" --path
    need "$O_IP" --ip
    case $O_IP in *[!0-9A-Fa-f:.]*) die "invalid --ip '$O_IP'" ;; esac
    if [ -n "$O_FOLDER" ]; then valid_folder "$O_FOLDER" || die "invalid --folder '$O_FOLDER'"; fi
    check_path "$O_PATH"
    if [ "$O_COUNT_SET" = 1 ]; then
        counted=$(count_files "$O_PATH" "$O_COUNT") || die "cannot count the files under $O_PATH"
    fi
    # /proc, not pgrep: procps is not in every image.
    if grep -qxs lsyncd /proc/[0-9]*/comm 2>/dev/null; then
        die "an lsyncd process runs on this node: remove the File Synchronization add-on first"
    fi
    for key in python3 curl systemctl findmnt runuser sha256sum; do
        command -v "$key" > /dev/null 2>&1 || die "$key is required on the node"
    done
    user=$(owner_of "$O_PATH") || die "the owner of $O_PATH has no user account"
    host=$(hostname_now)
    CHANGED=0

    install_binary

    mkdir -p "$STHOME" || die "cannot create $STHOME"
    chmod 0700 "$STHOME"

    # Clone guard: identity and database belong to the node that wrote bound.
    old=$(cat "$BOUND" 2>/dev/null)
    if [ -n "$old" ] && [ "$old" != "$host" ]; then
        reset_state "identity copied from $old"
        cloned=1
        CHANGED=1
    # A first install: state from an earlier install (for example a node an
    # uninstall could not reach) is foreign. Kept, its old send-receive folder
    # would become the cluster's source instead of the chosen seed.
    elif [ "$O_FRESH" = 1 ] && [ -n "$(find "$STHOME" -mindepth 1 -maxdepth 1 ! -name versions -print -quit 2>/dev/null)" ]; then
        reset_state "left over from an earlier install"
        reset=1
        CHANGED=1
    fi

    if [ "$(stat -c %U "$STHOME")" != "$user" ]; then
        chown -R "$user:" "$STHOME" || die "cannot give $STHOME to $user"
    fi
    mkdir -p "$VERSIONS" && chown "$user:" "$VERSIONS"

    apikey=$(cat "$APIKEY_FILE" 2>/dev/null)
    case $apikey in
        ????????????????????????????????) ;;
        *)
            apikey=$(head -c 512 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 32)
            [ ${#apikey} -eq 32 ] || die "cannot generate an API key"
            (umask 077; printf '%s\n' "$apikey" > "$APIKEY_FILE") || die "cannot write $APIKEY_FILE"
            ;;
    esac
    chown "$user:" "$APIKEY_FILE"; chmod 0600 "$APIKEY_FILE"

    write_if_changed "$ENV_FILE" 0600 <<EOF
STGUIADDRESS=127.0.0.1:8384
STGUIAPIKEY=$apikey
STNOUPGRADE=1
STDBDELETERETENTIONINTERVAL=0
EOF
    chown root:root "$ENV_FILE"

    # StartLimit*: upstream Syncthing's values. They also stop the 5-second
    # restart loop of a cloned node whose guard refuses to start.
    # ExecStartPost resumes a join that a restart interrupted (a no-op on a
    # send-receive folder); "-" so that it can never fail the service.
    local post=
    [ -n "$O_FOLDER" ] && post="ExecStartPost=-+$RUNNER join --folder $O_FOLDER"
    write_if_changed "$UNIT_FILE" 0644 <<EOF
[Unit]
Description=Syncthing file replication (stsync add-on)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=4

[Service]
User=$user
EnvironmentFile=$ENV_FILE
ExecStartPre=+$RUNNER guard
ExecStart=$BIN serve --home=$STHOME --no-browser --no-restart --log-file=$STHOME/syncthing.log --log-max-size=10485760 --log-max-old-files=3
$post
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    # Identity and database survive a redeploy; binary and unit are
    # re-created by the next prepare.
    mkdir -p "$(dirname "$REDEPLOY_CONF")"
    if ! grep -qxF "$STHOME" "$REDEPLOY_CONF" 2>/dev/null; then
        if [ -s "$REDEPLOY_CONF" ] && [ -n "$(tail -c 1 "$REDEPLOY_CONF")" ]; then
            printf '\n' >> "$REDEPLOY_CONF"
        fi
        printf '%s\n' "$STHOME" >> "$REDEPLOY_CONF" || die "cannot update $REDEPLOY_CONF"
    fi

    if [ ! -s "$STHOME/cert.pem" ] || [ ! -s "$STHOME/key.pem" ] || [ ! -s "$STHOME/config.xml" ]; then
        systemctl stop "$UNIT" > /dev/null 2>&1
        mktmp
        runuser -u "$user" -- "$BIN" generate --home="$STHOME" --no-port-probing > "$TMPD/generate.log" 2>&1 \
            || die "syncthing generate failed: $(tail -n 3 "$TMPD/generate.log" | oneline)"
        private_options "$STHOME/config.xml" "$O_IP" || die "cannot write the private options into config.xml"
        chown "$user:" "$STHOME/config.xml"
        CHANGED=1
    fi
    printf '%s\n' "$host" > "$BOUND" && chown "$user:" "$BOUND" || die "cannot write $BOUND"

    systemctl daemon-reload
    systemctl enable "$UNIT" > /dev/null 2>&1 || die "cannot enable $UNIT"
    if [ "$CHANGED" = 1 ] || ! systemctl is-active -q "$UNIT"; then
        systemctl reset-failed "$UNIT" > /dev/null 2>&1
        systemctl restart "$UNIT" || die "cannot start $UNIT"
    fi
    wait_ping 60 || die "Syncthing does not answer on $API after 60 s ($(systemctl is-active "$UNIT")): $(tail -n 3 "$STHOME/syncthing.log" 2>/dev/null | oneline)"

    api_req GET /rest/system/status
    DEVICE=$(jfield 'd["myID"]') || die "cannot read the device ID"
    ftype=none
    if [ -n "$O_FOLDER" ]; then
        ftype=$(folder_type "$O_FOLDER") || die "cannot read folder $O_FOLDER (HTTP $API_CODE)"
    fi

    [ "$cloned" = 1 ] && out CLONED 1
    [ "$reset" = 1 ] && out RESET 1
    out DEVICE "$DEVICE"
    out USER "$user"
    out FOLDER_TYPE "$ftype"
    out JOIN "$(join_state)"
    if [ -n "$counted" ]; then
        out FILES "${counted% *}"
        out BYTES "${counted#* }"
    fi
    if [ "$cloned" = 1 ]; then
        emit ok "Syncthing $ST_VERSION running as $user, device ${DEVICE%%-*}; identity reset: this node was a copy of $old"
    fi
    if [ "$reset" = 1 ]; then
        emit ok "Syncthing $ST_VERSION running as $user, device ${DEVICE%%-*}; state left over from an earlier install was reset"
    fi
    emit ok "Syncthing $ST_VERSION running as $user, device ${DEVICE%%-*}"
}

# ---- guard ------------------------------------------------------------------

cmd_guard() {
    local old host
    old=$(cat "$BOUND" 2>/dev/null)
    host=$(hostname_now)
    if [ -n "$old" ] && [ "$old" != "$host" ]; then
        echo "stsync: this node ($host) is a copy of $old; Syncthing stays stopped until the add-on re-applies" >&2
        emit failed "this node ($host) is a copy of $old: not starting"
    fi
    emit ok "node identity belongs to $host"
}

# ---- ignore -----------------------------------------------------------------

cmd_ignore() {
    local user tmp n
    need "$O_PATH" --path
    [ "$O_B64_SET" = 1 ] || die "missing --b64 (use - for an empty file)"
    check_path "$O_PATH"
    user=$(owner_of "$O_PATH") || die "the owner of $O_PATH has no user account"
    # Syncthing skips .syncthing.*.tmp names, so the watcher never picks up
    # the temporary file.
    tmp="$O_PATH/.syncthing.stignore.$$.tmp"
    if [ -z "$O_B64" ] || [ "$O_B64" = - ]; then
        : > "$tmp"
    else
        printf '%s' "$O_B64" | base64 -d > "$tmp" 2>/dev/null || { rm -f "$tmp"; die "--b64 is not valid base64"; }
    fi
    chown "$user:" "$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$O_PATH/.stignore" \
        || { rm -f "$tmp"; die "cannot write $O_PATH/.stignore"; }
    n=$(grep -c '' "$O_PATH/.stignore")
    emit ok "wrote $O_PATH/.stignore ($n lines)"
}

# ---- api --------------------------------------------------------------------

cmd_api() {
    local n=0 method path body bodyf
    need "$O_PLAN" --plan-b64
    mktmp
    printf '%s' "$O_PLAN" | base64 -d > "$TMPD/plan" 2>/dev/null || die "--plan-b64 is not valid base64"
    wait_ping 30 || die "Syncthing does not answer on $API"
    while read -r method path body || [ -n "$method" ]; do
        [ -n "$method" ] || continue
        case $method in \#*) continue ;; esac
        n=$((n + 1))
        case $method in GET|POST|PUT|PATCH|DELETE) ;; *) die "plan line $n: bad method '$method'" ;; esac
        case $path in /rest/*) ;; *) die "plan line $n: bad path '$path'" ;; esac
        bodyf=
        if [ -n "$body" ] && [ "$body" != - ]; then
            bodyf=$TMPD/body.$n
            printf '%s' "$body" | base64 -d > "$bodyf" 2>/dev/null || die "plan line $n: body is not valid base64"
        fi
        api_req "$method" "$path" $bodyf
        out "API_$n" "$API_CODE"
        if [ "$API_CODE" -lt 200 ] || [ "$API_CODE" -ge 400 ]; then
            die "plan line $n ($method $path) failed with HTTP $API_CODE: $(head -c 300 "$TMPD/resp" | oneline)"
        fi
    done < "$TMPD/plan"
    emit ok "$n API call(s) done"
}

# ---- join -------------------------------------------------------------------

valid_ids() { case $1 in ''|*[!A-Z2-7,-]*) return 1 ;; esac; return 0; }

cmd_join() {
    local ftype pid=
    need "$O_FOLDER" --folder
    valid_folder "$O_FOLDER" || die "invalid --folder '$O_FOLDER'"
    if [ -n "$O_FROM" ]; then valid_ids "$O_FROM" || die "invalid --from '$O_FROM'"; fi
    wait_ping 30 || die "Syncthing does not answer on $API"
    ftype=$(folder_type "$O_FOLDER") || die "cannot read folder $O_FOLDER (HTTP $API_CODE)"
    [ "$ftype" != none ] || die "folder $O_FOLDER is not configured"
    if [ "$ftype" = sendreceive ]; then
        out JOIN "$(join_state)"
        emit ok "folder $O_FOLDER is already send-receive: nothing to join"
    fi
    # Written even when a join already runs: the worker reads it on every poll.
    if [ -n "$O_FROM" ]; then
        { printf '%s\n' "$O_FROM" | tr ',' '\n' | grep . > "$JOIN_FROM.tmp" && mv -f "$JOIN_FROM.tmp" "$JOIN_FROM"; } \
            || die "cannot write $JOIN_FROM"
    fi
    exec 9> "$STHOME/join.lock"
    flock -n 9 || { out JOIN running; emit ok "a join of $O_FOLDER is being started"; }
    if pid=$(join_pid); then
        out JOIN running
        emit ok "a join of $O_FOLDER is already running (PID $pid)"
    fi
    # Detached: a first sync can outlast one ExecCmd (about 1 h). The worker
    # records its own PID; wait for that so the answer is reliable.
    write_state state=starting "folder=$O_FOLDER" "started=$(ts)"
    setsid bash "$SELF" join-worker --folder "$O_FOLDER" >> "$JOIN_LOG" 2>&1 < /dev/null 9>&- &
    for _ in $(seq 1 50); do pid=$(join_pid) && break; sleep 0.1; done
    [ -n "$pid" ] || die "the join worker did not start: $(tail -n 3 "$JOIN_LOG" 2>/dev/null | oneline)"
    out JOIN running
    emit ok "join of $O_FOLDER started (PID $pid, log $JOIN_LOG)"
}

# join_poll F - one poll for the worker: prints "state need receiveOnlyChanged"
# of the folder, or fails when the API does not answer.
join_poll() {
    api_req GET "/rest/db/status?folder=$1"
    [ "$API_CODE" = 200 ] || return 1
    jfield '"%s %s %s" % (d["state"], d["needTotalItems"], d.get("receiveOnlyTotalItems", 0))'
}

# worker_gone - the add-on was removed or the folder dropped: the worker ends.
worker_gone() {
    [ -f "$APIKEY_FILE" ] || { WHY="the add-on was removed"; return 0; }
    local t
    t=$(folder_type "$FOLDER") || return 1
    case $t in
        none) WHY="folder $FOLDER is no longer configured"; return 0 ;;
        sendreceive) WHY=switched; return 0 ;;
    esac
    return 1
}

# peers_ready - a connected SEND-RECEIVE peer (one listed in join.from) that
# shares the folder with us. Another joiner does not count: it has no
# authority over the content, and syncing against it alone would pull its
# files or drop the cluster's.
peers_ready() {
    local ids d
    [ -s "$JOIN_FROM" ] || return 1
    api_req GET /rest/system/connections
    [ "$API_CODE" = 200 ] || return 1
    ids=$(jfield '" ".join(k for k, v in d["connections"].items() if v.get("connected"))') || return 1
    for d in $ids; do
        grep -qxF "$d" "$JOIN_FROM" || continue
        api_req GET "/rest/db/completion?folder=$FOLDER&device=$d"
        [ "$API_CODE" = 200 ] || continue
        case $(jfield 'd.get("remoteState", "valid")') in valid) return 0 ;; esac
    done
    return 1
}

# wait_idle - the folder is idle with nothing to pull for JOIN_IDLE_S s in a
# row. Returns 1 when the worker must end (see worker_gone).
wait_idle() {
    local since='' now st last=0
    while :; do
        worker_gone && return 1
        now=$(date +%s)
        if st=$(join_poll "$FOLDER"); then
            set -- $st
            if [ "$1" = idle ] && [ "$2" = 0 ]; then
                [ -n "$since" ] || since=$now
                [ $((now - since)) -ge "$JOIN_IDLE_S" ] && return 0
            else
                since=
            fi
            if [ $((now - last)) -ge 60 ]; then log "folder $1, $2 item(s) to pull, $3 local change(s)"; last=$now; fi
        else
            since=
        fi
        sleep 1
    done
}

# set_aside F - move every local file of F that the cluster does not have into
# the version store (same relative path, like Syncthing's trashcan), and remove
# such directories once empty. "Does not have" = no live, valid global version
# with a non-empty version vector: the file exists only here (including the
# join's own *.sync-conflict-* copies), or the global is a delete - possibly
# the empty-version delete another joiner's revert recorded. Syncthing's revert
# must not handle these itself: it records a local-only file as deleted with
# an EMPTY version, and a second joiner holding the same file then keeps it
# (equal versions, no winner), so the nodes stay different for good. Kept
# even with versioning off: these files exist nowhere else. Prints "FILES
# DIRS"; fails when the API fails.
set_aside() {
    python3 - "$1" "$APIKEY_FILE" "$VERSIONS" <<'PY'
import json, os, shutil, sys, time, urllib.error, urllib.parse, urllib.request
folder, keyfile, versions = sys.argv[1:4]
key = open(keyfile).read().strip()
q = urllib.parse.quote
def get(path):
    req = urllib.request.Request("http://127.0.0.1:8384" + path, headers={"X-API-Key": key})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None     # /rest/db/file: no global version at all
        raise
root = get("/rest/config/folders/" + q(folder))["path"]
store = os.path.join(versions, folder)
items, page = [], 1
while True:
    d = get("/rest/db/localchanged?folder=%s&page=%d&perpage=1000" % (q(folder), page))
    got = d.get("files") or []
    items += got
    if not got or len(got) < int(d.get("perpage") or 1000):
        break
    page += 1
files, dirs = [], []
for f in items:
    name = f["name"]
    if f.get("deleted") or name.startswith("/") or ".." in name.split("/"):
        continue
    g = (get("/rest/db/file?folder=%s&file=%s" % (q(folder), q(name, safe=""))) or {}).get("global")
    if g and not g.get("deleted") and not g.get("invalid") and g.get("version"):
        continue    # the cluster has it: the revert replaces ours (old one to the store)
    (dirs if f.get("type") == "FILE_INFO_TYPE_DIRECTORY" else files).append(name)
own = os.stat(versions)
stamp = time.strftime("%Y%m%d-%H%M%S")
moved = 0
for name in files:
    src = os.path.join(root, name)
    if not os.path.lexists(src) or (os.path.isdir(src) and not os.path.islink(src)):
        continue
    # Directories on the way belong to the run user, so Syncthing can clean up.
    parent = versions
    for part in [folder] + name.split("/")[:-1]:
        parent = os.path.join(parent, part)
        if not os.path.isdir(parent):
            os.mkdir(parent)
            os.chown(parent, own.st_uid, own.st_gid)
    dst = os.path.join(store, name)
    if os.path.lexists(dst):
        base, ext = os.path.splitext(dst)
        dst = "%s~%s%s" % (base, stamp, ext)
    shutil.move(src, dst)
    # As the trashcan does: the kept days count from now.
    if not os.path.islink(dst):
        os.utime(dst)
    moved += 1
removed = 0
for name in sorted(dirs, key=lambda n: n.count("/"), reverse=True):
    try:
        os.rmdir(os.path.join(root, name))
        removed += 1
    except OSError:
        pass        # not empty: ignored files, or a file written meanwhile
print(moved, removed)
PY
}

cmd_join_worker() {
    local tries last=0 now moved started
    FOLDER=$O_FOLDER
    WHY=
    started=$(ts)
    mktmp
    # phase TEXT - what the join does now (status shows it).
    phase() { write_state state=running "pid=$$" "folder=$FOLDER" "started=$started" "phase=$1"; }
    finish() { # finish STATE MESSAGE
        write_state "state=$1" "folder=$FOLDER" "started=$started" "finished=$(ts)" "message=$2"
        log "$2"
        exit 0
    }
    phase "waiting for a send-receive node"
    log "join of folder $FOLDER started (PID $$)"
    trap 'finish failed "join stopped by a signal"' TERM INT HUP

    # 1. Wait for a send-receive peer that shares the folder: before that the
    #    global state is empty or only other joiners' (see peers_ready).
    while :; do
        worker_gone && break
        peers_ready && break
        now=$(date +%s)
        if [ $((now - last)) -ge 60 ]; then
            if [ -s "$JOIN_FROM" ]; then log "waiting for a connected send-receive node that shares $FOLDER ($(cut -c1-7 "$JOIN_FROM" | paste -sd, -))"
            else log "waiting: no send-receive node is known yet (the next apply of the add-on names them)"; fi
            last=$now
        fi
        sleep 2
    done
    [ "$WHY" = switched ] && finish 'done' "folder $FOLDER was switched to send-receive by someone else"
    [ -n "$WHY" ] && finish failed "join ended: $WHY"
    log "a send-receive node is connected; waiting until $FOLDER has pulled everything"

    # 2. Receive-only until in sync, 3. set aside the local files the cluster
    #    does not have, 4. revert the other local differences (Syncthing moves
    #    the replaced files to the version store), 5. start sending.
    phase "pulling"
    wait_idle || finish "$([ "$WHY" = switched ] && echo 'done' || echo failed)" "join ended: $WHY"
    local ro=1
    for tries in 1 2 3; do
        phase "setting aside local files"
        if ! moved=$(set_aside "$FOLDER"); then log "setting aside failed (attempt $tries)"; sleep 5; continue; fi
        log "set aside ${moved% *} local file(s) the cluster does not have, removed ${moved#* } empty director(y/ies)"
        if [ "$moved" != "0 0" ]; then
            api_req POST "/rest/db/scan?folder=$FOLDER"
            wait_idle || finish "$([ "$WHY" = switched ] && echo 'done' || echo failed)" "join ended: $WHY"
        fi
        phase "reverting"
        api_req POST "/rest/db/revert?folder=$FOLDER"
        [ "$API_CODE" = 200 ] || { log "revert failed with HTTP $API_CODE"; sleep 5; continue; }
        log "reverted local differences (attempt $tries)"
        wait_idle || finish "$([ "$WHY" = switched ] && echo 'done' || echo failed)" "join ended: $WHY"
        read -r _ _ ro <<< "$(join_poll "$FOLDER")"
        [ "${ro:-1}" = 0 ] && break
        log "still ${ro:-?} local change(s) after the revert"
    done
    [ "${ro:-1}" = 0 ] || finish failed "local changes remain after 3 reverts: folder stays receive-only"
    phase "switching to send-receive"
    mktmp
    printf '{"type":"sendreceive"}' > "$TMPD/sr"
    api_req PATCH "/rest/config/folders/$FOLDER" "$TMPD/sr"
    [ "$API_CODE" = 200 ] || finish failed "cannot switch $FOLDER to send-receive (HTTP $API_CODE)"
    [ "$(folder_type "$FOLDER")" = sendreceive ] || finish failed "$FOLDER did not switch to send-receive"
    finish 'done' "join of $FOLDER done: in sync with the cluster, now send-receive"
}

# ---- status -----------------------------------------------------------------

cmd_status() {
    local service user conflicts inotify jphase
    need "$O_FOLDER" --folder
    need "$O_PATH" --path
    valid_folder "$O_FOLDER" || die "invalid --folder '$O_FOLDER'"
    command -v python3 > /dev/null 2>&1 || die "python3 is required on the node"
    mktmp
    if [ -f "$UNIT_FILE" ]; then
        service=$(systemctl is-active "$UNIT" 2>/dev/null)
        user=$(sed -n 's/^User=//p' "$UNIT_FILE" | head -n 1)
    else
        service=missing
        user=$(owner_of "$O_PATH" 2>/dev/null)
    fi
    conflicts=0
    if timeout 20 test -d "$O_PATH"; then
        conflicts=$(timeout 60 find "$O_PATH" -name .stversions -prune -o -name '*.sync-conflict-*' -print 2>/dev/null \
            | head -n 1000 | wc -l)
    fi
    inotify=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null)
    jphase=
    [ "$(join_detail)" = running ] && jphase=$(getf "$JOIN_STATE" phase)
    python3 - "$O_FOLDER" "$service" "$user" "$(join_detail)" "$conflicts" "${inotify:-}" \
        "$APIKEY_FILE" "$BIN" "$STHOME" "$jphase" > "$TMPD/json" <<'PY' || die "cannot build the status JSON"
import json, subprocess, sys, urllib.request
folder, service, user, join, conflicts, inotify, keyfile, binary, home, jphase = sys.argv[1:11]
try:
    key = open(keyfile).read().strip()
except Exception:
    key = ""
def get(path):
    try:
        req = urllib.request.Request("http://127.0.0.1:8384" + path, headers={"X-API-Key": key})
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.load(r)
    except Exception:
        return None
def num(v):
    try:
        return int(v)
    except Exception:
        return None
s = {"service": service, "version": None, "device": None, "user": user or None,
     "folderType": None, "state": None, "needItems": None, "needBytes": None,
     "globalFiles": None, "globalDirectories": None, "globalDeleted": None, "globalBytes": None,
     "localFiles": None, "errors": None, "error": "",
     "connectedPeers": None, "totalPeers": None, "conflicts": num(conflicts),
     "join": join, "joinPhase": jphase, "lastScan": None, "inotifyLimit": num(inotify)}
ver = get("/rest/system/version") if key else None
if ver:
    s["version"] = ver.get("version")
    st = get("/rest/system/status") or {}
    s["device"] = st.get("myID")
    cfg = get("/rest/config/folders/" + folder)
    s["folderType"] = cfg.get("type") if cfg else "none"
    if cfg:
        db = get("/rest/db/status?folder=" + folder) or {}
        s["state"] = db.get("state")
        s["needItems"] = db.get("needTotalItems")
        s["needBytes"] = db.get("needBytes")
        # The global state: equal on every node once all are in sync, so
        # the platform can tell nodes whose copies disagree.
        for k in ("globalFiles", "globalDirectories", "globalDeleted", "globalBytes"):
            s[k] = db.get(k)
        s["localFiles"] = db.get("localFiles")
        s["errors"] = db.get("errors", db.get("pullErrors"))
        # A watcher error (e.g. too few inotify watches) is not fatal, but
        # changes then wait for the hourly rescan: worth reporting.
        s["error"] = db.get("error") or ("file watcher: " + db["watchError"] if db.get("watchError") else "")
        stats = get("/rest/stats/folder") or {}
        s["lastScan"] = (stats.get(folder) or {}).get("lastScan")
    devs = get("/rest/config/devices") or []
    peers = [d["deviceID"] for d in devs if d.get("deviceID") != s["device"]]
    conns = (get("/rest/system/connections") or {}).get("connections") or {}
    s["totalPeers"] = len(peers)
    s["connectedPeers"] = sum(1 for p in peers if (conns.get(p) or {}).get("connected"))
else:
    # Service down: read what the files can tell.
    try:
        out = subprocess.run([binary, "--version"], capture_output=True, text=True, timeout=10).stdout.split()
        s["version"] = out[1] if len(out) > 1 else None
        out = subprocess.run([binary, "device-id", "--home=" + home], capture_output=True, text=True, timeout=10)
        s["device"] = out.stdout.strip() or None if out.returncode == 0 else None
    except Exception:
        pass
print(json.dumps(s, separators=(",", ":")))
PY
    out JSON "$(cat "$TMPD/json")"
    emit ok "service $service, folder $O_FOLDER: $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("%s %s, %s item(s) to pull, peers %s/%s, %s conflict(s)" % (d["folderType"], d["state"], d["needItems"], d["connectedPeers"], d["totalPeers"], d["conflicts"]))' "$TMPD/json")"
}

# ---- rescan -----------------------------------------------------------------

cmd_rescan() {
    need "$O_FOLDER" --folder
    valid_folder "$O_FOLDER" || die "invalid --folder '$O_FOLDER'"
    wait_ping 30 || die "Syncthing does not answer on $API"
    api_req POST "/rest/db/scan?folder=$O_FOLDER"
    [ "$API_CODE" = 200 ] || die "rescan of $O_FOLDER failed with HTTP $API_CODE: $(head -c 300 "$TMPD/resp" | oneline)"
    emit ok "rescan of $O_FOLDER requested"
}

# ---- remove -----------------------------------------------------------------

# join_leftovers P - when the folder at P is still receive-only (a join that
# never finished: uninstall during a join, a failed install), move the join's
# *.sync-conflict-* copies from P into the version store, same relative
# paths. They are the node's old versions of differing files - old PHP code
# among them - that the join would have set aside; left in P they would be
# served at new URLs. Real conflict copies (send-receive folder) stay for the
# user to review. The folder type comes from config.xml: Syncthing is stopped.
# Prints the number moved.
join_leftovers() {
    python3 - "$1" "$STHOME/config.xml" "$VERSIONS" <<'PY'
import os, shutil, sys, xml.etree.ElementTree as ET
path, config, versions = sys.argv[1:4]
try:
    folders = ET.parse(config).getroot().findall("folder")
except Exception:
    folders = []
fid = None
for f in folders:
    if os.path.normpath(f.get("path", "")) == os.path.normpath(path) and f.get("type") == "receiveonly":
        fid = f.get("id")
moved = 0
if fid:
    for d, dirs, names in os.walk(path):
        dirs[:] = [x for x in dirs if not (d == path and x in (".stfolder", ".stversions"))]
        for n in names:
            if ".sync-conflict-" not in n:
                continue
            rel = os.path.relpath(os.path.join(d, n), path)
            dst = os.path.join(versions, fid, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if os.path.lexists(dst):
                continue
            shutil.move(os.path.join(d, n), dst)
            moved += 1
print(moved)
PY
}

cmd_remove() {
    local kept='' notes='' left='' aside=0 anote=''
    systemctl disable --now "$UNIT" > /dev/null 2>&1
    stop_join
    rm -f "$UNIT_FILE" "$ENV_FILE" "$BIN" "$BIN.new"
    systemctl daemon-reload > /dev/null 2>&1
    systemctl reset-failed "$UNIT" > /dev/null 2>&1

    if [ -n "$O_PATH" ] && [ -f "$STHOME/config.xml" ] && timeout 20 test -d "$O_PATH"; then
        aside=$(join_leftovers "$O_PATH") || { aside=0; anote="; could not move the unfinished join's conflict copies out of $O_PATH"; }
    fi

    # Old versions of site files are user data: keep them, outside the site.
    if [ -d "$VERSIONS" ] && [ -n "$(find "$VERSIONS" -mindepth 1 -type f -print -quit 2>/dev/null)" ]; then
        kept=/root/stsync-versions-$(date -u +%Y%m%d-%H%M%S)
        mv "$VERSIONS" "$kept" || { notes="$notes; cannot move $VERSIONS to $kept"; kept=; }
    fi
    if [ -z "$notes" ]; then rm -rf "$STHOME"; fi

    if [ -n "$O_PATH" ] && timeout 20 test -d "$O_PATH"; then
        rm -rf "$O_PATH/.stfolder"
        rm -f "$O_PATH/.stignore"
    fi

    if [ -f "$REDEPLOY_CONF" ] && grep -qxF "$STHOME" "$REDEPLOY_CONF"; then
        mktmp
        grep -vxF "$STHOME" "$REDEPLOY_CONF" > "$TMPD/redeploy"
        # cat, not mv: keep the file's owner, mode and any symlink.
        cat "$TMPD/redeploy" > "$REDEPLOY_CONF" || notes="$notes; cannot update $REDEPLOY_CONF"
    fi
    rm -f "$RUNNER"

    for f in "$UNIT_FILE" "$ENV_FILE" "$BIN" "$STHOME"; do [ -e "$f" ] && left="$left $f"; done
    [ -n "$kept" ] && out VERSIONS_KEPT "$kept"
    [ -z "$left" ] || die "Syncthing not fully removed, still present:$left$notes"
    [ "$aside" -gt 0 ] 2>/dev/null && anote="; $aside conflict copies of the unfinished join moved there$anote"
    emit ok "Syncthing removed; files under ${O_PATH:-the site} left in place${kept:+; old file versions kept in $kept}$anote$notes"
}

# ---- main -------------------------------------------------------------------

# One function, called on the last line: bash reads a script as it runs, and
# the platform may replace this file while a join worker still runs from it.
main() {
    O_PATH='' O_IP='' O_FOLDER='' O_B64='' O_B64_SET=0 O_PLAN='' O_FROM='' O_FRESH=0 O_COUNT='' O_COUNT_SET=0
    CMD=${1:-}
    [ $# -gt 0 ] && shift
    while [ $# -gt 0 ]; do
        case $1 in
            --fresh) O_FRESH=1; shift ;;
            --path|--ip|--folder|--b64|--plan-b64|--from|--count-b64)
                [ $# -ge 2 ] || die "$1 needs a value"
                case $1 in
                    --path) O_PATH=$2 ;;
                    --ip) O_IP=$2 ;;
                    --folder) O_FOLDER=$2 ;;
                    --b64) O_B64=$2; O_B64_SET=1 ;;
                    --plan-b64) O_PLAN=$2 ;;
                    --from) O_FROM=$2 ;;
                    --count-b64) O_COUNT=$2; O_COUNT_SET=1 ;;
                esac
                shift 2 ;;
            *) die "unknown argument '$1'" ;;
        esac
    done
    # /var/www/webroot/ROOT/ and /var/www/webroot/ROOT are the same folder.
    while [ "${#O_PATH}" -gt 1 ] && [ "${O_PATH%/}" != "$O_PATH" ]; do O_PATH=${O_PATH%/}; done

    case $CMD in
        prepare|remove)
            [ "$(id -u)" = 0 ] || die "stsync must run as root"
            exec 8> /run/stsync.lock
            flock -w 300 8 || die "another stsync prepare or remove is still running"
            "cmd_$CMD" ;;
        guard|ignore|api|join|status|rescan)
            [ "$(id -u)" = 0 ] || die "stsync must run as root"
            "cmd_$CMD" ;;
        join-worker) cmd_join_worker ;;
        *) die "usage: stsync prepare|guard|ignore|api|join|status|rescan|remove [options] (got '$CMD')" ;;
    esac
    die "internal error: $CMD returned without a result"
}

main "$@"; exit $?
