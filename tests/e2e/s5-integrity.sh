#!/usr/bin/env bash
# Scenario 5: integrity. Flip one byte inside a needle on ONE replica, then report what detects it:
# direct replica read (CRC check), filer read, volume.scrub, volume.check.disk -slow, fs.verify, volume.fsck.
cd "$(dirname "$0")" && . ./lab.sh
lab_down; lab_region_up a 2
M=$(masters_of a); F=${LAB_PREFIX}-a-filer:8888
client a bash -c "{ echo SFSE2EMARKER; head -c 65536 /dev/urandom; } > /tmp/c.bin; sha256sum /tmp/c.bin | cut -d' ' -f1 > /tmp/c.sum
  curl -sf -F file=@/tmp/c.bin http://$F/e2e/s5/ >/dev/null"
fid=$(client a curl -sf "http://$F/e2e/s5/c.bin?metadata=true" | grep -o '"file_id":"[^"]*"' | head -1 | cut -d'"' -f4)
vid=${fid%%,*}; log "file /e2e/s5/c.bin -> fid $fid (volume $vid)"
V=${LAB_PREFIX}-a-v1
off=$(docker exec "$V" grep -boa SFSE2EMARKER "/data/$vid.dat" | head -1 | cut -d: -f1)
[ -n "$off" ] || fail "marker not found in $V:/data/$vid.dat"
pos=$((off + 5000))
orig=$(docker exec "$V" dd if="/data/$vid.dat" bs=1 skip=$pos count=1 2>/dev/null | od -An -tx1 | tr -d ' ')
new=$(printf '%02x' $(( 0x$orig ^ 0xff )))
docker exec "$V" bash -c "printf '\\x$new' | dd of=/data/$vid.dat bs=1 seek=$pos count=1 conv=notrunc 2>/dev/null"
log "flipped byte at /data/$vid.dat offset $pos on $V: $orig -> $new (replica on v2 untouched)"
R1=$(client a curl -s -o /tmp/r1 -w '%{http_code}' "http://$V:8080/$fid"); S1=$(client a sha256sum /tmp/r1 | cut -d' ' -f1)
R2=$(client a curl -s -o /tmp/r2 -w '%{http_code}' "http://${LAB_PREFIX}-a-v2:8080/$fid"); S2=$(client a sha256sum /tmp/r2 | cut -d' ' -f1)
WANT=$(client a cat /tmp/c.sum)
log "direct read corrupted replica v1: HTTP $R1, checksum $([ "$S1" = "$WANT" ] && echo MATCH || echo MISMATCH)"
log "direct read healthy replica v2:   HTTP $R2, checksum $([ "$S2" = "$WANT" ] && echo MATCH || echo MISMATCH)"
good=0; badr=0; for i in $(seq 1 10); do
  s=$(client a bash -c "curl -sf http://$F/e2e/s5/c.bin | sha256sum | cut -d' ' -f1"); [ "$s" = "$WANT" ] && good=$((good+1)) || badr=$((badr+1)); done
log "10 reads through filer: good=$good bad=$badr"
for cmd in "volume.scrub" "volume.check.disk -slow -v" "fs.verify /e2e" "volume.fsck -v"; do
  printf 'lock\n%s\nunlock\n' "$cmd" | wshell a > "$LAB_LOGDIR/s5-$(echo "$cmd" | tr ' /' '__').log" 2>&1
  log "--- $cmd (last lines):"; grep -v '^\s*$' "$LAB_LOGDIR/s5-$(echo "$cmd" | tr ' /' '__').log" | grep -v -E '^> ?$' | tail -6 >&2
done
[ "$R1" != 200 ] || [ "$S1" != "$WANT" ] || fail "corruption not detected on direct read"
# repair: drop the bad replica, re-copy it from the healthy one, re-scrub
out=$(printf 'lock\nvolume.delete -node %s:8080 -volumeId %s\nvolume.fix.replication -apply\nvolume.scrub\nunlock\n' "$V" "$vid" | wshell a)
echo "$out" | grep -q "Got scrub failures" && fail "scrub still failing after repair"
R3=$(client a curl -s -o /tmp/r3 -w '%{http_code}' "http://$V:8080/$fid"); S3=$(client a sha256sum /tmp/r3 | cut -d' ' -f1)
log "after volume.delete + volume.fix.replication -apply: v1 read HTTP $R3, checksum $([ "$S3" = "$WANT" ] && echo MATCH || echo MISMATCH), scrub clean"
[ "$R3" = 200 ] && [ "$S3" = "$WANT" ] || fail "repair did not restore replica"
ok "S5 integrity: corrupted replica detected on read (HTTP $R1); see tool output above"
