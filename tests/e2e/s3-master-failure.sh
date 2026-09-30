#!/usr/bin/env bash
# Scenario 3: master failure. Stop the Raft leader; assert a new leader and that writes continue.
cd "$(dirname "$0")" && . ./lab.sh
lab_down; lab_region_up a 3
write_files a s3a 200
old=$(leader_of a); oldc=${old%%:*}; log "leader: $old; stopping $oldc"
t0=$(date +%s); docker stop "$oldc" >/dev/null
s=0; while :; do new=$(leader_of a 2>/dev/null || true)
  [ -n "$new" ] && [ "$new" != "$old" ] && break; s=$((s+1)); [ $s -ge 90 ] && fail "no new leader"; sleep 1; done
t1=$(date +%s); log "new leader $new after $((t1-t0))s"
t2=$(date +%s); write_files a s3b 200; r=$(verify_files a s3b); log "write after failover: $r ($(( $(date +%s)-t2 ))s)"
[ "$r" = "ok=200 bad=0" ] || fail "writes after failover $r"
r=$(verify_files a s3a); [ "$r" = "ok=200 bad=0" ] || fail "old files $r"
docker start "$oldc" >/dev/null; sleep 5; log "old leader restarted; leader now $(leader_of a)"
ok "S3 master-failure: new leader $new in $((t1-t0))s, writes continue"
