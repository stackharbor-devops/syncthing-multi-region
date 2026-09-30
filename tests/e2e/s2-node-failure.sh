#!/usr/bin/env bash
# Scenario 2: node failure + self-heal. 4 volume servers, rep 010, stop v1, write more,
# volume.fix.replication -apply. Asserts every volume has 2 copies on live nodes and all files intact.
cd "$(dirname "$0")" && . ./lab.sh
lab_down; lab_region_up a 4
write_files a s2a 500; r=$(verify_files a s2a); [ "$r" = "ok=500 bad=0" ] || fail "pre $r"
log "v1 holds $(vol_map a | grep -c "${LAB_PREFIX}-a-v1:") replicas; stopping v1"
t0=$(date +%s); docker stop "${LAB_PREFIX}-a-v1" >/dev/null
s=0; while vol_map a | grep -q "${LAB_PREFIX}-a-v1:"; do s=$((s+1)); [ $s -ge 120 ] && fail "master never dropped v1"; sleep 1; done
t1=$(date +%s); log "master removed v1 from topology after $((t1-t0))s"
under=$(vol_copies a | awk '$2<2' | wc -l | tr -d ' '); log "under-replicated volumes: $under"
r=$(verify_files a s2a); log "reads with v1 down (before heal): $r"; [ "$r" = "ok=500 bad=0" ] || fail "degraded read $r"
t2=$(date +%s); write_files a s2b 300; r=$(verify_files a s2b); log "writes with v1 down: $r ($(( $(date +%s)-t2 ))s)"
[ "$r" = "ok=300 bad=0" ] || fail "degraded write $r"
t3=$(date +%s)
printf 'lock\nvolume.fix.replication -apply\nunlock\n' | wshell a > "$LAB_LOGDIR/s2-fix.log" 2>&1 || true
t4=$(date +%s); sleep 3; log "volume.fix.replication -apply took $((t4-t3))s"
bad=$(vol_copies a | awk '$2!=2' | wc -l | tr -d ' ')
vol_map a | grep -q "${LAB_PREFIX}-a-v1:" && fail "dead node still listed"
[ "$bad" = 0 ] || { vol_copies a >&2; fail "$bad volumes not at 2 copies after heal"; }
r1=$(verify_files a s2a); r2=$(verify_files a s2b); log "after heal: s2a $r1, s2b $r2"
[ "$r1" = "ok=500 bad=0" ] && [ "$r2" = "ok=300 bad=0" ] || fail "files after heal"
ok "S2 node-failure: $under under-replicated volumes healed to 2 copies on live nodes, 800 files intact"
