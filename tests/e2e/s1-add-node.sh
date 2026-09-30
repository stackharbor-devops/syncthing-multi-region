#!/usr/bin/env bash
# Scenario 1: Add Node. 3 volume servers, replication 010, 2000 files, add v4, volume.balance -force.
# Asserts: v4 holds volumes after balance, every volume still has 2 copies, all files readable, checksums match.
cd "$(dirname "$0")" && . ./lab.sh
N=${N:-2000}
lab_down; lab_region_up a 3
t0=$(date +%s); write_files a s1 "$N"; t1=$(date +%s)
log "wrote $N files in $((t1-t0))s; volumes: $(vol_copies a | wc -l | tr -d ' ')"
r=$(verify_files a s1); log "before add: $r"; [ "$r" = "ok=$N bad=0" ] || fail "pre-check $r"
lab_volume a 4; wait_nodes a 4 60 || fail "v4 did not register"
before=$(vol_map a | grep -c "${LAB_PREFIX}-a-v4" || true); log "v4 volumes before balance: $before"
t2=$(date +%s)
printf 'lock\nvolume.balance -force\nunlock\n' | wshell a > "$LAB_LOGDIR/s1-balance.log" 2>&1 || true
t3=$(date +%s); sleep 3
after=$(vol_map a | grep -c "${LAB_PREFIX}-a-v4" || true)
log "volume.balance -force took $((t3-t2))s; v4 volumes after: $after"
for n in 1 2 3 4; do log "  v$n holds $(vol_map a | grep -c "${LAB_PREFIX}-a-v$n:") volume replicas"; done
[ "$after" -gt 0 ] || fail "no volumes moved to v4"
bad=$(vol_copies a | awk '$2!=2' | wc -l | tr -d ' '); [ "$bad" = 0 ] || fail "$bad volumes without exactly 2 copies"
r=$(verify_files a s1); log "after balance: $r"; [ "$r" = "ok=$N bad=0" ] || fail "post-check $r"
ok "S1 add-node: $after volume replicas moved to v4, all $N files intact"
