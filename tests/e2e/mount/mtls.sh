#!/bin/bash
# mTLS variant of the mount e2e test: the filer (and the whole test cluster) requires
# gRPC mutual TLS; sfs-mount must fail without a client certificate and work with one.
#
#   tests/e2e/mount/mtls.sh <dir-with-linux_<arch>.tar.gz>   (keep containers: KEEP=1)
set -u
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
ASSETS=$(cd "${1:?usage: mtls.sh <assets dir>}" && pwd)
case "$(docker version -f '{{.Server.Arch}}' 2>/dev/null)" in
  arm64|aarch64) ASSET=linux_arm64 ;; *) ASSET=linux_amd64 ;;
esac
NET=sfsmt-net SRV=sfsmt-srv CLI=sfsmt-cli
PASS=0 FAILN=0
check() { local d=$1; shift; if "$@"; then PASS=$((PASS + 1)); echo "PASS: $d"; else FAILN=$((FAILN + 1)); echo "FAIL: $d"; fi; }
cx() { docker exec "$CLI" bash -c "$1"; }
cleanup() { [ "${KEEP:-0}" = 1 ] || docker rm -f "$SRV" "$CLI" >/dev/null 2>&1; }
trap cleanup EXIT

T=$(mktemp -d); WORK=$(mktemp -d)
tar -xzf "$ASSETS/$ASSET.tar.gz" -C "$WORK" weed
# Test-only CA (P-256, SHA-256 signatures: Go rejects SHA-1 signed certificates).
openssl ecparam -name prime256v1 -genkey -noout -out "$T/ca.key" 2>/dev/null
openssl req -x509 -new -sha256 -key "$T/ca.key" -subj /CN=sfs-test-ca -days 2 -out "$T/ca.pem" 2>/dev/null
for n in srv cli; do
  openssl ecparam -name prime256v1 -genkey -noout -out "$T/$n.key" 2>/dev/null
  openssl req -new -sha256 -key "$T/$n.key" -subj "/CN=$n" -out "$T/$n.csr" 2>/dev/null
  printf 'subjectAltName=DNS:%s,DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth,clientAuth\n' "$SRV" > "$T/$n.ext"
  openssl x509 -req -sha256 -in "$T/$n.csr" -CA "$T/ca.pem" -CAkey "$T/ca.key" -CAcreateserial -days 2 -extfile "$T/$n.ext" -out "$T/$n.pem" 2>/dev/null
done
chmod 644 "$T"/*.key
{
  echo '[grpc]'; echo 'ca = "/tls/ca.pem"'
  for s in master volume filer client; do printf '[grpc.%s]\ncert = "/tls/srv.pem"\nkey = "/tls/srv.key"\n' "$s"; done
} > "$T/security.toml"

docker rm -f "$SRV" "$CLI" >/dev/null 2>&1
docker network create "$NET" >/dev/null 2>&1
docker run -d --name "$SRV" --network "$NET" -v "$WORK/weed:/usr/local/bin/weed:ro" -v "$T:/tls:ro" almalinux:9 \
  sh -c "mkdir -p /data && exec /usr/local/bin/weed -config_dir=/tls server -dir=/data -master.volumeSizeLimitMB=64 -volume.max=10 -filer -ip=$SRV -ip.bind=0.0.0.0" >/dev/null
docker run -d --name "$CLI" --hostname "$CLI" --network "$NET" --device /dev/fuse --cap-add SYS_ADMIN \
  --security-opt apparmor:unconfined --security-opt seccomp=unconfined --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock -v "$ASSETS:/assets:ro" r3e-node >/dev/null
docker cp "$ROOT/scripts/node/sfs-mount.sh" "$CLI:/usr/local/sbin/sfs-mount"
cx 'chmod 755 /usr/local/sbin/sfs-mount; mkdir -p /etc/sfs/tls'
for f in ca.pem cli.pem cli.key; do docker cp "$T/$f" "$CLI:/etc/sfs/tls/$f"; done
cx 'chmod 600 /etc/sfs/tls/cli.key'
for i in $(seq 1 30); do cx "curl -sf -o /dev/null http://$SRV:8888/" && break; sleep 1; done
cx "sfs-mount install --tarball /assets/$ASSET.tar.gz" | tail -1

out=$(cx "sfs-mount mount --filer $SRV:8888 --path /mnt/sec --cache-mb 64"); rc=$?
check "mount without client cert fails" [ $rc -ne 0 ]
check "failed mount leaves no retrying unit" cx '! systemctl is-active -q sfs-mount@mnt-sec.service && ! findmnt -M /mnt/sec >/dev/null'
out=$(cx "sfs-mount mount --filer $SRV:8888 --path /mnt/sec --cache-mb 64 --ca /etc/sfs/tls/ca.pem --cert /etc/sfs/tls/cli.pem --key /etc/sfs/tls/cli.key"); rc=$?
echo "$out" | tail -2
check "mount with client cert ok" [ $rc -eq 0 ]
check "security.toml is 0600" cx '[ "$(stat -c %a /etc/sfs/mount.d/mnt-sec/security.toml)" = 600 ]'
cx 'echo tlsdata > /mnt/sec/tls.txt'
check "write through mTLS mount readable via filer" cx "curl -sf http://$SRV:8888/tls.txt | grep -q tlsdata"
out=$(cx 'sfs-mount status --path /mnt/sec'); check "status reports mtls" grep -q '"mtls":true' <<<"$out"
out=$(cx 'sfs-mount remove --all'); check "remove --all ok" grep -q '^SFS_RESULT=ok' <<<"$out"
echo "RESULT: $PASS passed, $FAILN failed"
[ "$FAILN" = 0 ]
