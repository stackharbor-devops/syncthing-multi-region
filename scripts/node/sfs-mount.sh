#!/bin/bash
# sfs-mount - SeaweedFS client mount runner for application nodes.
# Installed as /usr/local/sbin/sfs-mount by addons/mount.jps; run as root.
#
# Subcommands:
#   install [--version 4.48] [--tarball FILE]
#   mount   --filer ip:8888[,ip2:8888] --path P [--cache-dir D] [--cache-mb N]
#           [--filer-path /] [--collection C] [--replication R] [--read-only]
#           [--volume-access direct|publicUrl|filerProxy] [--meta-ttl SEC]
#           [--ca F --cert F --key F] [--force-move]
#   status  [--path P]            (no --path: every configured mount)
#   unmount --path P
#   remove  --path P | --all [--purge-binary]
#
# Output contract (ARCHITECTURE.md section 7): free-form lines plus
#   SFS_RESULT=ok|failed, SFS_MESSAGE=<one line>, SFS_JSON=<one-line JSON>
# Exit code 0 only when SFS_RESULT=ok.
set -u
umask 022
export LC_ALL=C PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WEED_VERSION_PIN="4.48"
# sha256 of the official release assets (github.com/seaweedfs/seaweedfs/releases/tag/4.48),
# same pins as the storage node runner.
SHA256_linux_amd64="4a7d108384d044d95212d1342cdda9533fa55842c1c9b41f606ca3c8a9561124"
SHA256_linux_arm64="557e92c38c5c7d180748eb8e2b2b45e426f8e5282a4caca8e098a90d09f03a07"
WEED_BIN=/usr/local/bin/weed
CONF_DIR=/etc/sfs/mount.d
UNIT_TEMPLATE=/etc/systemd/system/sfs-mount@.service

log() { echo "[sfs-mount] $*"; }

json_str() { # JSON string literal of $1
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/}; s=${s//$'\t'/\\t}
  printf '"%s"' "$s"
}

finish() { # finish ok|failed "message" [json]
  local res=$1 msg=$2 js=${3:-}
  msg=${msg//$'\n'/ }
  echo "SFS_RESULT=$res"
  echo "SFS_MESSAGE=$msg"
  [ -n "$js" ] && echo "SFS_JSON=$js"
  [ "$res" = ok ] && exit 0
  exit 1
}
fail() { finish failed "$1" "${2:-}"; }

need_root() { [ "$(id -u)" = 0 ] || fail "must run as root"; }

arch_asset() {
  case "$(uname -m)" in
    x86_64|amd64) echo linux_amd64 ;;
    aarch64|arm64) echo linux_arm64 ;;
    *) echo "" ;;
  esac
}

weed_version() { [ -x "$WEED_BIN" ] && "$WEED_BIN" version 2>/dev/null | awk '/^version/{print $3; exit}'; }

unit_for() { echo "sfs-mount@$(systemd-escape --path "$1").service"; }
inst_for() { systemd-escape --path "$1"; }

is_mounted() { # true when $1 is a mount point
  findmnt -n -M "$1" >/dev/null 2>&1
}

fs_type() { findmnt -n -o FSTYPE -M "$1" 2>/dev/null | head -n1; }

# ---------------------------------------------------------------- install
cmd_install() {
  local version=$WEED_VERSION_PIN tarball=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --version) version=$2; shift 2 ;;
      --tarball) tarball=$2; shift 2 ;;
      *) fail "install: unknown option $1" ;;
    esac
  done
  need_root
  [ "$version" = "$WEED_VERSION_PIN" ] || fail "only SeaweedFS $WEED_VERSION_PIN is pinned in this runner (asked $version)"
  local asset; asset=$(arch_asset)
  [ -n "$asset" ] || fail "unsupported architecture $(uname -m)"
  local pinvar="SHA256_${asset}"; local want=${!pinvar}

  # FUSE userspace tools (fusermount3) and the kernel device.
  if ! command -v fusermount3 >/dev/null 2>&1 && ! command -v fusermount >/dev/null 2>&1; then
    log "installing fuse3 package"
    if command -v dnf >/dev/null 2>&1; then dnf -y -q install fuse3 >/dev/null 2>&1 || dnf -y -q install fuse >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then yum -y -q install fuse3 >/dev/null 2>&1 || yum -y -q install fuse >/dev/null 2>&1
    elif command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get -y -qq install fuse3 >/dev/null 2>&1
    fi
  fi
  command -v fusermount3 >/dev/null 2>&1 || command -v fusermount >/dev/null 2>&1 \
    || fail "fusermount3/fusermount not found and the fuse3 package could not be installed"
  [ -c /dev/fuse ] || fail "/dev/fuse is missing: FUSE is not available in this container (ask the hoster to enable FUSE for the node)"
  command -v systemctl >/dev/null 2>&1 || fail "systemd is required"

  if [ "$(weed_version)" = "$version" ]; then
    log "weed $version already installed"
  else
    local tmp; tmp=$(mktemp -d /tmp/sfs-mount.XXXXXX) || fail "mktemp failed"
    if [ -n "$tarball" ]; then
      cp "$tarball" "$tmp/weed.tgz" || { rm -rf "$tmp"; fail "cannot read $tarball"; }
    else
      local url="https://github.com/seaweedfs/seaweedfs/releases/download/${version}/${asset}.tar.gz"
      log "downloading $url"
      curl -fsSL --retry 3 --connect-timeout 20 -o "$tmp/weed.tgz" "$url" || { rm -rf "$tmp"; fail "download failed: $url"; }
    fi
    local got; got=$(sha256sum "$tmp/weed.tgz" | awk '{print $1}')
    if [ "$got" != "$want" ]; then rm -rf "$tmp"; fail "sha256 mismatch for $asset: got $got want $want"; fi
    tar -xzf "$tmp/weed.tgz" -C "$tmp" weed || { rm -rf "$tmp"; fail "cannot extract weed"; }
    install -m 0755 "$tmp/weed" "$WEED_BIN.new" && mv -f "$WEED_BIN.new" "$WEED_BIN" || { rm -rf "$tmp"; fail "cannot install $WEED_BIN"; }
    rm -rf "$tmp"
  fi
  [ "$(weed_version)" = "$version" ] || fail "installed weed does not report version $version"

  mkdir -p "$CONF_DIR" && chmod 0755 "$CONF_DIR"
  write_template
  finish ok "weed $version installed, FUSE available" "{\"weedVersion\":$(json_str "$version"),\"arch\":$(json_str "$asset")}"
}

write_template() {
  cat > "$UNIT_TEMPLATE.tmp" <<'EOF'
# Managed by sfs-mount. Per-mount settings live in sfs-mount@<path>.service.d/10-sfs.conf
[Unit]
Description=SeaweedFS mount %f
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
# Clear a stale FUSE mount left by a crashed weed process ("transport endpoint is not connected").
ExecStartPre=-/bin/sh -c 'grep -qs " %f fuse" /proc/self/mounts && umount -l "%f"; exit 0'
ExecStop=/bin/sh -c 'umount "%f" 2>/dev/null || umount -l "%f" 2>/dev/null; exit 0'
KillMode=mixed
TimeoutStopSec=60
Restart=always
RestartSec=5
LimitNOFILE=1048576
Nice=-5

[Install]
WantedBy=multi-user.target
EOF
  mv -f "$UNIT_TEMPLATE.tmp" "$UNIT_TEMPLATE"
  systemctl daemon-reload
}

# ---------------------------------------------------------------- mount
valid_filers() { # host:port[,host:port]
  local IFS=, f
  for f in $1; do
    [[ "$f" =~ ^[A-Za-z0-9._-]+:[0-9]{1,5}$ ]] || return 1
  done
  return 0
}

wait_mounted() { # path seconds
  local i=0
  while [ $i -lt "$2" ]; do
    is_mounted "$1" && return 0
    sleep 1; i=$((i + 1))
  done
  return 1
}

cmd_mount() {
  local filer="" path="" cache_dir="" cache_mb=1024 filer_path=/ collection="" replication=""
  local readonly=0 vaccess=direct meta_ttl=60 ca="" cert="" key="" force_move=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --filer) filer=$2; shift 2 ;;
      --path) path=$2; shift 2 ;;
      --cache-dir) cache_dir=$2; shift 2 ;;
      --cache-mb) cache_mb=$2; shift 2 ;;
      --filer-path) filer_path=$2; shift 2 ;;
      --collection) collection=$2; shift 2 ;;
      --replication) replication=$2; shift 2 ;;
      --read-only) readonly=1; shift ;;
      --volume-access) vaccess=$2; shift 2 ;;
      --meta-ttl) meta_ttl=$2; shift 2 ;;
      --ca) ca=$2; shift 2 ;;
      --cert) cert=$2; shift 2 ;;
      --key) key=$2; shift 2 ;;
      --force-move) force_move=1; shift ;;
      *) fail "mount: unknown option $1" ;;
    esac
  done
  need_root
  [ -n "$filer" ] && valid_filers "$filer" || fail "mount: --filer ip:port[,ip:port] is required"
  [[ "$path" =~ ^/[A-Za-z0-9._/@+-]*$ ]] || fail "mount: --path must be an absolute path without spaces or special characters"
  path=$(realpath -m "$path")
  case "$path" in
    /|/bin|/boot|/dev|/etc|/lib|/lib64|/proc|/run|/sbin|/sys|/usr|/var|/tmp|/root|/home|/opt|/usr/*|/proc/*|/sys/*|/dev/*|/etc/*|/boot/*|/run/*)
      fail "mount: refusing to mount over system path $path" ;;
  esac
  [[ "$filer_path" =~ ^/[A-Za-z0-9._/@+-]*$ ]] || fail "mount: bad --filer-path"
  [[ "$cache_mb" =~ ^[0-9]+$ ]] || fail "mount: --cache-mb must be an integer"
  [[ "$meta_ttl" =~ ^[0-9]+$ ]] || fail "mount: --meta-ttl must be an integer"
  case "$vaccess" in direct|publicUrl|filerProxy) ;; *) fail "mount: bad --volume-access" ;; esac
  [ -z "$replication" ] || [[ "$replication" =~ ^[0-9]{3}$ ]] || fail "mount: bad --replication"
  [ -z "$collection" ] || [[ "$collection" =~ ^[A-Za-z0-9_-]+$ ]] || fail "mount: bad --collection"
  [ -x "$WEED_BIN" ] || fail "weed is not installed; run: sfs-mount install"
  [ -f "$UNIT_TEMPLATE" ] || write_template

  local inst unit; inst=$(inst_for "$path"); unit=$(unit_for "$path")
  [ -n "$cache_dir" ] || cache_dir="/var/cache/sfs-mount/$inst"
  [[ "$cache_dir" =~ ^/[A-Za-z0-9._/@+\\-]*$ ]] || fail "mount: bad --cache-dir"

  # Already mounted by us with the same settings: idempotent success.
  if is_mounted "$path"; then
    if systemctl is-active -q "$unit"; then
      log "$path is already mounted by $unit; reconfiguring"
      systemctl stop "$unit"
      is_mounted "$path" && fail "cannot unmount $path to apply the new configuration"
    else
      fail "$path is already a mount point ($(fs_type "$path")) not managed by sfs-mount"
    fi
  fi

  # Non-empty mount point: refuse, or move the content aside and copy it in after mounting.
  local moved=""
  mkdir -p "$path"
  if [ -n "$(ls -A "$path" 2>/dev/null)" ]; then
    [ "$force_move" = 1 ] || fail "$path is not empty; rerun with --force-move to move its content into the shared filesystem (a copy is kept in $path.local-<timestamp>)"
    moved="$path.local-$(date -u +%Y%m%d%H%M%S)"
    log "moving existing content of $path to $moved"
    local mode owner; mode=$(stat -c %a "$path"); owner=$(stat -c %u:%g "$path")
    mv "$path" "$moved" || fail "cannot move $path aside"
    mkdir -p "$path" && chmod "$mode" "$path" && chown "$owner" "$path"
  fi

  mkdir -p "$cache_dir" && chmod 0700 "$cache_dir"

  # mTLS client config (security.toml read by weed from -config_dir).
  local cfgdir="$CONF_DIR/$inst" global_opts=""
  mkdir -p "$cfgdir" && chmod 0700 "$cfgdir"
  if [ -n "$ca$cert$key" ]; then
    [ -r "$ca" ] && [ -r "$cert" ] && [ -r "$key" ] || fail "mount: --ca, --cert and --key must all be readable files"
    cat > "$cfgdir/security.toml" <<EOF
# Managed by sfs-mount: gRPC mutual TLS towards the filer.
[grpc]
ca = "$ca"

[grpc.client]
cert = "$cert"
key = "$key"
EOF
    chmod 0600 "$cfgdir/security.toml"
  else
    rm -f "$cfgdir/security.toml"
  fi
  # Always point weed at our own config dir so a stray ./security.toml or
  # /etc/seaweedfs/security.toml on the app node is never picked up.
  global_opts="-config_dir=$cfgdir"

  local args="-filer=$filer -dir=$path -filer.path=$filer_path -cacheDir=$cache_dir -cacheCapacityMB=$cache_mb"
  args="$args -cacheMetaTtlSec=$meta_ttl -volumeServerAccess=$vaccess -allowOthers=true -localSocket=/run/sfs-mount-$(printf %s "$inst" | md5sum | cut -c1-12).sock"
  [ -n "$collection" ] && args="$args -collection=$collection"
  [ -n "$replication" ] && args="$args -replication=$replication"
  [ "$readonly" = 1 ] && args="$args -readOnly"

  mkdir -p "/etc/systemd/system/$unit.d"
  cat > "/etc/systemd/system/$unit.d/10-sfs.conf" <<EOF
# Managed by sfs-mount
[Service]
ExecStart=
ExecStart=$WEED_BIN $global_opts mount $args
EOF
  # The escaped instance name can contain backslashes: keep the state file name md5-based.
  cat > "$cfgdir/mount.env" <<EOF
SFS_PATH=$path
SFS_FILER=$filer
SFS_FILER_PATH=$filer_path
SFS_CACHE_DIR=$cache_dir
SFS_CACHE_MB=$cache_mb
SFS_UNIT=$unit
SFS_MTLS=$([ -n "$ca" ] && echo 1 || echo 0)
EOF
  systemctl daemon-reload
  systemctl enable "$unit" >/dev/null 2>&1
  systemctl restart "$unit"
  if ! wait_mounted "$path" 30; then
    local err; err=$(journalctl -u "$unit" -n 20 --no-pager 2>/dev/null | grep -E 'failed|error|Error' | tail -n 2 | cut -c1-300 | tr '\n' ' ')
    # Do not leave a unit retrying in the background after reporting failure.
    systemctl disable "$unit" >/dev/null 2>&1
    systemctl stop "$unit" 2>/dev/null
    if [ -n "$moved" ]; then
      rmdir "$path" 2>/dev/null && mv "$moved" "$path" && log "restored original content of $path"
    fi
    fail "mount of $path did not come up within 30s: $err"
  fi

  local copied=""
  if [ -n "$moved" ]; then
    log "copying $moved into the mounted filesystem"
    # tar instead of cp -a: cp preserves permissions via the POSIX ACL xattr, which
    # SeaweedFS 4.48 stores without updating the file mode (files came out 0600).
    if tar -C "$moved" --no-acls --no-xattrs -cf - . | tar -C "$path" --no-acls --no-xattrs -xpf -; then
      copied=" (existing content copied in; original kept at $moved)"
    else
      fail "mounted $path but copying the original content from $moved failed; the original is untouched in $moved"
    fi
  fi
  finish ok "mounted $filer:$filer_path at $path$copied" "$(status_json "$path")"
}

# ---------------------------------------------------------------- status
filer_reachable() { # "ip:port,..." -> first reachable http endpoint or ""
  local IFS=, f
  for f in $1; do
    local h=${f%:*} p=${f##*:}
    local gp=$((p + 10000))
    if timeout 3 bash -c "exec 3<>/dev/tcp/$h/$gp" 2>/dev/null; then echo "$f"; return 0; fi
  done
  return 1
}

status_json() { # path -> json for one configured mount
  local path=$1 inst cfgdir
  inst=$(inst_for "$path"); cfgdir="$CONF_DIR/$inst"
  local SFS_FILER="" SFS_CACHE_DIR="" SFS_CACHE_MB=0 SFS_UNIT="" SFS_FILER_PATH=/ SFS_MTLS=0
  # shellcheck disable=SC1090
  [ -f "$cfgdir/mount.env" ] && . "$cfgdir/mount.env"
  local mounted=false fstype="" active reach="" reachable=false cache_used=0 size=0 used=0
  is_mounted "$path" && mounted=true && fstype=$(fs_type "$path")
  active=$(systemctl is-active "${SFS_UNIT:-$(unit_for "$path")}" 2>/dev/null)
  if [ -n "$SFS_FILER" ]; then reach=$(filer_reachable "$SFS_FILER") && reachable=true; fi
  [ -d "$SFS_CACHE_DIR" ] && cache_used=$(du -sb "$SFS_CACHE_DIR" 2>/dev/null | awk '{print $1}')
  if [ "$mounted" = true ]; then
    read -r size used < <(timeout 5 df -B1 --output=size,used "$path" 2>/dev/null | tail -n1) || true
  fi
  printf '{"path":%s,"mounted":%s,"fstype":%s,"service":%s,"filer":%s,"filerPath":%s,"filerReachable":%s,"reachableFiler":%s,"mtls":%s,"cacheDir":%s,"cacheCapacityMB":%s,"cacheUsedBytes":%s,"fsTotalBytes":%s,"fsUsedBytes":%s,"weedVersion":%s}' \
    "$(json_str "$path")" "$mounted" "$(json_str "$fstype")" "$(json_str "${active:-unknown}")" \
    "$(json_str "$SFS_FILER")" "$(json_str "$SFS_FILER_PATH")" "$reachable" "$(json_str "$reach")" \
    "$([ "$SFS_MTLS" = 1 ] && echo true || echo false)" "$(json_str "$SFS_CACHE_DIR")" "${SFS_CACHE_MB:-0}" \
    "${cache_used:-0}" "${size:-0}" "${used:-0}" "$(json_str "$(weed_version)")"
}

configured_paths() {
  local f
  for f in "$CONF_DIR"/*/mount.env; do
    [ -f "$f" ] && sed -n 's/^SFS_PATH=//p' "$f"
  done
}

cmd_status() {
  local path=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --path) path=$2; shift 2 ;;
      *) fail "status: unknown option $1" ;;
    esac
  done
  if [ -n "$path" ]; then
    path=$(realpath -m "$path")
    [ -f "$CONF_DIR/$(inst_for "$path")/mount.env" ] || fail "no sfs mount configured at $path"
    local js; js=$(status_json "$path")
    case "$js" in
      *'"mounted":true'*'"filerReachable":true'*) finish ok "$path mounted, filer reachable" "$js" ;;
      *'"mounted":true'*) finish failed "$path mounted but no filer reachable" "$js" ;;
      *) finish failed "$path is not mounted" "$js" ;;
    esac
  fi
  local out="" p n=0 bad=0 js
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    js=$(status_json "$p"); n=$((n + 1))
    case "$js" in *'"mounted":true'*) ;; *) bad=$((bad + 1)) ;; esac
    out="$out${out:+,}$js"
  done < <(configured_paths)
  local all="{\"weedVersion\":$(json_str "$(weed_version)"),\"fuse\":$([ -c /dev/fuse ] && echo true || echo false),\"mounts\":[$out]}"
  [ "$bad" = 0 ] || finish failed "$bad of $n configured mounts are not mounted" "$all"
  finish ok "$n mounts configured, all mounted" "$all"
}

# ---------------------------------------------------------------- unmount / remove
do_unmount() { # path
  local path=$1 unit; unit=$(unit_for "$path")
  systemctl stop "$unit" 2>/dev/null
  if is_mounted "$path"; then
    umount "$path" 2>/dev/null || umount -l "$path" 2>/dev/null || fusermount3 -uz "$path" 2>/dev/null
  fi
  ! is_mounted "$path"
}

cmd_unmount() {
  local path=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --path) path=$2; shift 2 ;;
      *) fail "unmount: unknown option $1" ;;
    esac
  done
  need_root
  [ -n "$path" ] || fail "unmount: --path is required"
  path=$(realpath -m "$path")
  local unit; unit=$(unit_for "$path")
  systemctl disable "$unit" >/dev/null 2>&1
  do_unmount "$path" || fail "could not unmount $path (busy?)"
  finish ok "unmounted $path (configuration kept; mount again with sfs-mount mount or remove it)" "{\"path\":$(json_str "$path"),\"mounted\":false}"
}

remove_one() { # path
  local path=$1 inst unit cfgdir SFS_CACHE_DIR=""
  inst=$(inst_for "$path"); unit=$(unit_for "$path"); cfgdir="$CONF_DIR/$inst"
  [ -f "$cfgdir/mount.env" ] && SFS_CACHE_DIR=$(sed -n 's/^SFS_CACHE_DIR=//p' "$cfgdir/mount.env")
  systemctl disable "$unit" >/dev/null 2>&1
  do_unmount "$path" || return 1
  rm -rf "/etc/systemd/system/$unit.d" "$cfgdir"
  # The cache holds only copies of filer data; the mount point itself is left in place.
  [ -n "$SFS_CACHE_DIR" ] && [ "$SFS_CACHE_DIR" != / ] && rm -rf "$SFS_CACHE_DIR"
  return 0
}

cmd_remove() {
  local path="" all=0 purge=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --path) path=$2; shift 2 ;;
      --all) all=1; shift ;;
      --purge-binary) purge=1; shift ;;
      *) fail "remove: unknown option $1" ;;
    esac
  done
  need_root
  local removed="" p
  if [ "$all" = 1 ]; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      remove_one "$p" || fail "could not unmount $p (busy?)"
      removed="$removed${removed:+,}$(json_str "$p")"
    done < <(configured_paths)
    rm -f "$UNIT_TEMPLATE"; systemctl daemon-reload
    [ "$purge" = 1 ] && rm -f "$WEED_BIN"
  else
    [ -n "$path" ] || fail "remove: --path P or --all is required"
    path=$(realpath -m "$path")
    remove_one "$path" || fail "could not unmount $path (busy?)"
    removed=$(json_str "$path")
    systemctl daemon-reload
  fi
  finish ok "removed sfs mounts: ${removed:-none}" "{\"removed\":[$removed]}"
}

# ---------------------------------------------------------------- main
sub=${1:-}; [ $# -gt 0 ] && shift
case "$sub" in
  install) cmd_install "$@" ;;
  mount) cmd_mount "$@" ;;
  status) cmd_status "$@" ;;
  unmount|umount) cmd_unmount "$@" ;;
  remove) cmd_remove "$@" ;;
  -h|--help|help|"") sed -n '2,18p' "$0"; exit 0 ;;
  *) fail "unknown subcommand $sub" ;;
esac
