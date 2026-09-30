#!/bin/bash
# End-to-end test of scripts/node/sfs-mount.sh against a real SeaweedFS 4.48 in Docker.
#
#   tests/e2e/mount/run.sh <dir-with-linux_<arch>.tar.gz>   (keep containers: KEEP=1)
#
# Needs: docker, images almalinux:9 and r3e-node (AlmaLinux 9 with systemd), the
# SeaweedFS 4.48 release tarball for the Docker host architecture, /dev/fuse on the host VM.
# Lab: sfsmc-srv (weed server: master+volume+filer) and sfsmc-cli (systemd, --device /dev/fuse,
# CAP_SYS_ADMIN) on network sfsmc-net. The client runs the real runner under systemd.
set -u
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
ASSETS=${1:?usage: run.sh <dir with linux_arm64.tar.gz / linux_amd64.tar.gz>}
ASSETS=$(cd "$ASSETS" && pwd)
case "$(docker version -f '{{.Server.Arch}}' 2>/dev/null)" in
  arm64|aarch64) ASSET=linux_arm64 ;; *) ASSET=linux_amd64 ;;
esac
TGZ="$ASSETS/$ASSET.tar.gz"
[ -f "$TGZ" ] || { echo "missing $TGZ"; exit 2; }
NFILES=${NFILES:-5000}
NET=sfsmc-net SRV=sfsmc-srv CLI=sfsmc-cli
PASS=0 FAILN=0
ok()   { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad()  { FAILN=$((FAILN + 1)); echo "FAIL: $*"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
cx() { docker exec "$CLI" bash -c "$1"; }

cleanup() { [ "${KEEP:-0}" = 1 ] || docker rm -f "$SRV" "$CLI" >/dev/null 2>&1; }
trap cleanup EXIT

docker rm -f "$SRV" "$CLI" >/dev/null 2>&1
docker network create "$NET" >/dev/null 2>&1
WORK=$(mktemp -d); tar -xzf "$TGZ" -C "$WORK" weed
docker run -d --name "$SRV" --network "$NET" -v "$WORK/weed:/usr/local/bin/weed:ro" almalinux:9 \
  sh -c 'mkdir -p /data && exec /usr/local/bin/weed server -dir=/data -master.volumeSizeLimitMB=64 -volume.max=20 -filer -ip=sfsmc-srv -ip.bind=0.0.0.0' >/dev/null
docker run -d --name "$CLI" --hostname "$CLI" --network "$NET" --device /dev/fuse --cap-add SYS_ADMIN \
  --security-opt apparmor:unconfined --security-opt seccomp=unconfined --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock -v "$ASSETS:/assets:ro" r3e-node >/dev/null
docker cp "$ROOT/scripts/node/sfs-mount.sh" "$CLI:/usr/local/sbin/sfs-mount"
cx 'chmod 755 /usr/local/sbin/sfs-mount'
for i in $(seq 1 30); do cx 'curl -sf -o /dev/null http://sfsmc-srv:8888/' && break; sleep 1; done

# --- install (sha256-verified tarball, fuse3 package, /dev/fuse)
out=$(cx "sfs-mount install --tarball /assets/$ASSET.tar.gz"); echo "$out" | tail -3
check "install ok" grep -q '^SFS_RESULT=ok' <<<"$out"
out=$(cx "cp /assets/$ASSET.tar.gz /tmp/bad.tgz && echo x >> /tmp/bad.tgz && rm -f /usr/local/bin/weed && sfs-mount install --tarball /tmp/bad.tgz")
check "install rejects a tampered tarball" grep -q 'sha256 mismatch' <<<"$out"
cx "sfs-mount install --tarball /assets/$ASSET.tar.gz" >/dev/null

# --- non-empty mount point: refused, then --force-move
cx 'mkdir -p /data/shared/sub && echo pre-existing > /data/shared/old.txt && chmod 640 /data/shared/old.txt && echo s > /data/shared/sub/x.sh && chmod 755 /data/shared/sub/x.sh'
out=$(cx 'sfs-mount mount --filer sfsmc-srv:8888 --path /data/shared --cache-mb 256'); rc=$?
check "refuses non-empty dir without --force-move" [ $rc -ne 0 ]
check "non-empty dir untouched" cx 'test -f /data/shared/old.txt && ! ls -d /data/shared.local-* >/dev/null 2>&1'
out=$(cx 'sfs-mount mount --filer sfsmc-srv:8888 --path /data/shared --cache-mb 256 --force-move'); rc=$?
echo "$out" | tail -3
check "mount --force-move ok" [ $rc -eq 0 ]
check "fstype fuse.seaweedfs" cx '[ "$(findmnt -n -o FSTYPE -M /data/shared)" = fuse.seaweedfs ]'
check "unit active" cx 'systemctl is-active -q sfs-mount@data-shared.service'
check "moved content present in mount" cx 'grep -q pre-existing /data/shared/old.txt'
check "moved content keeps modes" cx '[ "$(stat -c %a /data/shared/old.txt)" = 640 ] && [ "$(stat -c %a /data/shared/sub/x.sh)" = 755 ]'
check "moved content visible through filer" cx 'curl -sf http://sfsmc-srv:8888/old.txt | grep -q pre-existing'
check "local copy kept" cx 'ls /data/shared.local-*/old.txt >/dev/null'

# --- write/read, both directions
cx 'dd if=/dev/urandom of=/data/shared/blob.bin bs=1M count=8 status=none; sha256sum /data/shared/blob.bin | cut -d" " -f1 > /tmp/blob.sha'
check "8 MiB file readable via filer with same sha256" cx '[ "$(curl -sf http://sfsmc-srv:8888/blob.bin | sha256sum | cut -d" " -f1)" = "$(cat /tmp/blob.sha)" ]'
cx 'echo from-filer > /tmp/ff.txt && curl -sf -F file=@/tmp/ff.txt http://sfsmc-srv:8888/viafiler/ >/dev/null'
sleep 2
check "file written via filer appears in mount" cx 'grep -q from-filer /data/shared/viafiler/ff.txt'

# --- status contract
out=$(cx 'sfs-mount status --path /data/shared'); echo "$out" | grep '^SFS_JSON'
check "status ok" grep -q '^SFS_RESULT=ok' <<<"$out"
check "status json mounted+reachable" grep -q '"mounted":true.*"filerReachable":true' <<<"$out"
check "status json is valid" cx "python3 -c 'import json,sys; json.loads(sys.argv[1])' '$(grep '^SFS_JSON=' <<<"$out" | cut -d= -f2-)'"
out=$(cx 'sfs-mount status'); check "status (all) ok" grep -q '^SFS_RESULT=ok' <<<"$out"

# --- restart resilience: kill weed, systemd brings the mount back
cx 'pkill -9 -x weed'
check "mount recovers after weed is killed" cx 'for i in $(seq 1 30); do sleep 1; grep -qs pre-existing /data/shared/old.txt && exit 0; done; exit 1'
check "no stacked stale mounts" cx '[ "$(grep -c " /data/shared fuse" /proc/self/mounts)" = 1 ]'

# --- metadata benchmark: stat NFILES files cold (fresh mount) vs cached
CREATE=$(cx "set -e; mkdir -p /data/shared/bench && cd /data/shared/bench && t0=\$(date +%s%N) && for i in \$(seq 1 $NFILES); do : > f\$i; done && echo create_ms=\$(( (\$(date +%s%N)-t0)/1000000 ))")
echo "BENCH create $NFILES empty files: $CREATE"
cx 'systemctl restart sfs-mount@data-shared.service; for i in $(seq 1 30); do findmnt -M /data/shared >/dev/null && break; sleep 1; done'
BENCH=$(cx "cd /data/shared/bench || exit 1
t0=\$(date +%s%N); n1=\$(find . -type f | xargs stat -c %s | wc -l); t1=\$(date +%s%N)
n2=\$(find . -type f | xargs stat -c %s | wc -l); t2=\$(date +%s%N)
echo \"files=\$n1 cold_ms=\$(( (t1-t0)/1000000 )) cached_ms=\$(( (t2-t1)/1000000 ))\"")
echo "BENCH (list+stat $NFILES files): $BENCH"
check "benchmark saw all files" grep -q "files=$NFILES " <<<"$BENCH"

# --- unmount / remount / remove
out=$(cx 'sfs-mount unmount --path /data/shared'); check "unmount ok" grep -q '^SFS_RESULT=ok' <<<"$out"
check "not mounted after unmount" cx '! findmnt -M /data/shared >/dev/null'
out=$(cx 'sfs-mount mount --filer sfsmc-srv:8888 --path /data/shared --cache-mb 256'); check "remount on empty dir ok" grep -q '^SFS_RESULT=ok' <<<"$out"
check "data still there after remount" cx '[ "$(sha256sum /data/shared/blob.bin | cut -d" " -f1)" = "$(cat /tmp/blob.sha)" ]'
out=$(cx 'sfs-mount remove --path /data/shared'); check "remove ok" grep -q '^SFS_RESULT=ok' <<<"$out"
check "remove cleaned unit + cache" cx '! findmnt -M /data/shared >/dev/null && [ ! -d /etc/systemd/system/sfs-mount@data-shared.service.d ] && [ ! -d /var/cache/sfs-mount/data-shared ]'
out=$(cx 'sfs-mount mount --filer sfsmc-srv:8888 --path /etc'); check "refuses system path" grep -q 'refusing' <<<"$out"

echo "RESULT: $PASS passed, $FAILN failed"
[ "$FAILN" = 0 ]
