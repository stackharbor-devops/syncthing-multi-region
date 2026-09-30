#!/usr/bin/env bash
# tests/e2e/lab.sh - reusable SeaweedFS lab on Docker (one container per weed process).
# Source it:  WEED_BIN=/path/to/weed(linux) . tests/e2e/lab.sh
# Region R = one docker network "sfse2e-R" = one SeaweedFS cluster (3 Raft masters,
# M volume servers with -dataCenter=R -rack=rackI, one filer). Every container runs
# almalinux:9 with the pinned weed binary bind-mounted read-only.
set -u
LAB_IMAGE=${LAB_IMAGE:-almalinux:9}
LAB_PREFIX=${LAB_PREFIX:-sfse2e}
LAB_VOL_LIMIT_MB=${LAB_VOL_LIMIT_MB:-4}          # small volumes -> many volumes -> balance is observable
LAB_REPL=${LAB_REPL:-010}
LAB_LOGDIR=${LAB_LOGDIR:-${TMPDIR:-/tmp}/sfse2e-logs}; mkdir -p "$LAB_LOGDIR"
: "${WEED_BIN:?set WEED_BIN to a linux weed 4.48 binary}"

log()  { printf '%s [lab] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
fail() { printf '%s [FAIL] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; exit 1; }
ok()   { printf '%s [PASS] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

_run() { # _run <name> <region> <cmd...>
  local name=$1 region=$2; shift 2
  docker run -d --name "$name" --hostname "$name" --network "${LAB_PREFIX}-${region}" -v /data \
    -v "${WEED_BIN}:/usr/local/bin/weed:ro" "$LAB_IMAGE" "$@" >/dev/null
}
masters_of() { echo "${LAB_PREFIX}-$1-m1:9333,${LAB_PREFIX}-$1-m2:9333,${LAB_PREFIX}-$1-m3:9333"; }

lab_master() { # lab_master R i
  local R=$1 i=$2 n="${LAB_PREFIX}-$1-m$2"
  _run "$n" "$R" weed master -ip="$n" -port=9333 -mdir=/data -peers="$(masters_of "$R")" \
    -defaultReplication="$LAB_REPL" -volumeSizeLimitMB="$LAB_VOL_LIMIT_MB"
}
lab_volume() { # lab_volume R i
  local R=$1 i=$2 n="${LAB_PREFIX}-$1-v$2"
  _run "$n" "$R" weed volume -ip="$n" -port=8080 -dir=/data -max=100 \
    -master="$(masters_of "$R")" -dataCenter="$R" -rack="rack$i"
}
lab_filer() {
  local R=$1 n="${LAB_PREFIX}-$1-filer"
  _run "$n" "$R" weed filer -ip="$n" -port=8888 -master="$(masters_of "$R")" -defaultReplicaPlacement="$LAB_REPL"
}
lab_client() { _run "${LAB_PREFIX}-$1-client" "$1" sleep infinity; }

lab_region_up() { # lab_region_up R nvolumes
  local R=$1 nv=$2 i
  docker network create "${LAB_PREFIX}-${R}" >/dev/null
  for i in 1 2 3; do lab_master "$R" "$i"; done
  wait_leader "$R" 60 >/dev/null || fail "no raft leader in $R"
  for i in $(seq 1 "$nv"); do lab_volume "$R" "$i"; done
  lab_filer "$R"; lab_client "$R"
  wait_http "$R" "http://${LAB_PREFIX}-${R}-filer:8888/" 60 || fail "filer $R not up"
  wait_nodes "$R" "$nv" 60 || fail "volume servers of $R did not register"
  log "region $R up: 3 masters, $nv volume servers, 1 filer"
}
lab_down() { # remove every container/network of the lab
  docker ps -aq --filter "name=^${LAB_PREFIX}-" | xargs -r docker rm -fv >/dev/null 2>&1
  docker network ls -q --filter "name=^${LAB_PREFIX}-" | xargs -r docker network rm >/dev/null 2>&1
  true
}

cx() { local c=$1; shift; docker exec -i "$c" "$@"; }       # exec in container
client() { local R=$1; shift; cx "${LAB_PREFIX}-${R}-client" "$@"; }
wshell() { # wshell R  < commands   (runs weed shell against region R masters)
  client "$1" weed shell -master="$(masters_of "$1")" -filer="${LAB_PREFIX}-$1-filer:8888" 2>&1
}
wait_http() { local R=$1 url=$2 t=$3 s=0
  while ! client "$R" curl -sf -o /dev/null "$url" 2>/dev/null; do s=$((s+1)); [ $s -ge $t ] && return 1; sleep 1; done; }
leader_of() { # prints leader host:port as seen by any live master
  local R=$1 i out
  for i in 1 2 3; do
    out=$(docker exec "${LAB_PREFIX}-${R}-m$i" curl -sf "http://${LAB_PREFIX}-${R}-m$i:9333/cluster/status" 2>/dev/null) || continue
    # "Leader" is "host:9333.19333" (http port . grpc port); a just-restarted master reports ""
    out=$(echo "$out" | grep -o '"Leader":"[^"]*"' | cut -d'"' -f4 | sed 's/\.[0-9]*$//')
    [ -n "$out" ] && { echo "$out"; return 0; }
  done; return 1; }
wait_leader() { local R=$1 t=$2 s=0 l
  while :; do l=$(leader_of "$R") && [ -n "$l" ] && { echo "$l"; return 0; }
    s=$((s+1)); [ $s -ge $t ] && return 1; sleep 1; done; }
# docker exec needs curl in the master container: almalinux:9 ships curl-minimal.
topo() { client "$1" curl -sf "http://$(leader_of "$1")/dir/status?pretty=y"; }
node_count() { local c; c=$(topo "$1" | grep -c '"Url"'); echo "${c:-0}"; }
wait_nodes() { local R=$1 n=$2 t=$3 s=0
  while [ "$(node_count "$R" 2>/dev/null)" -lt "$n" ]; do s=$((s+1)); [ $s -ge $t ] && return 1; sleep 1; done; }

# volume -> nodes map from "volume.list": prints "<vid> <node>" lines
vol_map() { printf 'volume.list\n' | wshell "$1" | awk '
  /DataNode /{ for(i=1;i<=NF;i++) if($i=="DataNode"){n=$(i+1)} }
  /volume Id:/{ for(i=1;i<=NF;i++) if($i ~ /^Id:/){v=$i; gsub(/Id:|,/,"",v); print v, n} }' | sort -n; }
vol_copies() { vol_map "$1" | awk '{c[$1]++} END{for(v in c) print v, c[v]}' | sort -n; }   # "<vid> <copies>"

# write N files of random size into the filer under /e2e/<tag>/ and keep sha256 manifest in the client
write_files() { # write_files R tag N
  local R=$1 tag=$2 N=$3
  client "$R" bash -c "set -e; rm -rf /work/$tag; mkdir -p /work/$tag; cd /work/$tag
    for i in \$(seq 1 $N); do head -c \$(( (RANDOM % 12 + 1) * 1024 )) /dev/urandom > f\$i.bin; done
    sha256sum f*.bin > /work/$tag.sha256
    for try in 1 2 3; do weed filer.copy -c=16 /work/$tag http://${LAB_PREFIX}-$R-filer:8888/e2e/ >/work/$tag.log 2>&1 && break; sleep 3; done"
}
# verify every file of tag via region R2's filer (defaults to R) against manifest held in region R's client
verify_files() { # verify_files R tag [R2]  -> prints "ok=<n> bad=<n>"
  local R=$1 tag=$2 R2=${3:-$1}
  client "$R" cat /work/$tag.sha256 | client "$R2" bash -c "ok=0; bad=0
    while read -r sum f; do
      got=\$(curl -sf http://${LAB_PREFIX}-$R2-filer:8888/e2e/$tag/\$f | sha256sum | cut -d' ' -f1)
      if [ \"\$got\" = \"\$sum\" ]; then ok=\$((ok+1)); else bad=\$((bad+1)); fi
    done; echo ok=\$ok bad=\$bad"
}
