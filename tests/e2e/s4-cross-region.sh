#!/usr/bin/env bash
# Scenario 4: cross-region async. Regions a and b (separate networks = separate clusters),
# one filer.sync process (active-active) on a host attached to both networks, using
# -a.filerProxy -b.filerProxy so chunk data flows filer-to-filer (only filer ports cross regions).
# Asserts a->b and b->a convergence with lag measurement, then link cut + restore catch-up.
cd "$(dirname "$0")" && . ./lab.sh
SYNC=${LAB_PREFIX}-sync
lab_down; lab_region_up a 2; lab_region_up b 2
FA=${LAB_PREFIX}-a-filer:8888; FB=${LAB_PREFIX}-b-filer:8888
docker run -d --name "$SYNC" --hostname "$SYNC" --network "${LAB_PREFIX}-a" -v "${WEED_BIN}:/usr/local/bin/weed:ro" \
  "$LAB_IMAGE" weed filer.sync -a="$FA" -b="$FB" -a.filerProxy -b.filerProxy >/dev/null
docker network connect "${LAB_PREFIX}-b" "$SYNC"
sleep 3
converge() { # converge <writerRegion> <tag> <n> <readerRegion> <timeout>  -> prints seconds
  local s=0 t0; t0=$(date +%s)
  while [ "$(verify_files "$1" "$2" "$4")" != "ok=$3 bad=0" ]; do s=$((s+1)); [ $s -ge "$5" ] && return 1; sleep 1; done
  echo $(( $(date +%s) - t0 ))
}
# single-file lag probe
lag_probe() { # lag_probe from to
  local f="probe-$(date +%s%N)" t0 t1
  client "$1" bash -c "echo $f > /tmp/$f; curl -sf -F file=@/tmp/$f http://${LAB_PREFIX}-$1-filer:8888/e2e/probe/ >/dev/null"
  t0=$(date +%s%N)
  local k=0; while ! client "$2" curl -sf -o /dev/null "http://${LAB_PREFIX}-$2-filer:8888/e2e/probe/$f"; do k=$((k+1)); [ $k -ge 300 ] && { echo "TIMEOUT"; return; }; sleep 0.2; done
  t1=$(date +%s%N); echo "$(( (t1-t0)/1000000 ))ms"
}
log "lag probe a->b: $(lag_probe a b)"; log "lag probe b->a: $(lag_probe b a)"
write_files a s4a 300; d=$(converge a s4a 300 b 120) || fail "a->b did not converge"; log "300 files a->b converged ${d}s after write finished"
write_files b s4b 300; d=$(converge b s4b 300 a 120) || fail "b->a did not converge"; log "300 files b->a converged ${d}s after write finished"
log "cutting link: disconnect sync process from region b network"
docker network disconnect "${LAB_PREFIX}-b" "$SYNC"
write_files a s4c 200; write_files b s4d 200; sleep 5
r=$(verify_files a s4c b); log "while cut, s4c on b: $r (expected not converged)"
t0=$(date +%s); docker network connect "${LAB_PREFIX}-b" "$SYNC"; log "link restored"
d1=$(converge a s4c 200 b 300) || { docker logs --tail 20 "$SYNC" >&2; fail "a->b no catch-up"; }
d2=$(converge b s4d 200 a 300) || { docker logs --tail 20 "$SYNC" >&2; fail "b->a no catch-up"; }
log "catch-up after restore: a->b ${d1}s, b->a done $(( $(date +%s)-t0 ))s after restore"
# no echo loop: file counts equal in both regions
ca=$(client a curl -sf -H 'Accept: application/json' "http://$FA/e2e/s4a/?limit=10000" | grep -o '"FullPath"' | wc -l | tr -d ' ')
cb=$(client b curl -sf -H 'Accept: application/json' "http://$FB/e2e/s4a/?limit=10000" | grep -o '"FullPath"' | wc -l | tr -d ' ')
log "s4a entries: a=$ca b=$cb"; [ "$ca" = "$cb" ] || fail "entry count mismatch"
ok "S4 cross-region: both directions converge, catch-up after link restore"
