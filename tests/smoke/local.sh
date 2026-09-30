#!/usr/bin/env bash
# Local smoke test of the control plane (no SeaweedFS needed):
# start sfsctl with a temp config, mint an enroll token with the CLI, enroll a fake
# node with a real openssl CSR through the API, follow an SSO grant with a cookie jar,
# and call /auth/check, /api/v1/me, /api/v1/nodes, /api/v1/health.
# Usage: tests/smoke/local.sh            (exit 0 = all checks passed)
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/sfs-smoke.XXXXXX")
PORT=${SFS_SMOKE_PORT:-18480}
export PYTHONPATH="$ROOT/control-plane"
fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "ok   $*"; }
SECRET=$(openssl rand -hex 32)
cat > "$W/config.json" <<JSON
{"clusterId": "smoke-cluster", "clusterName": "smoke", "primaryRegion": "r1",
 "envDomain": "smoke.local", "listen": "127.0.0.1:$PORT", "stateDir": "$W/state",
 "secret": "$SECRET", "weedBin": "/nonexistent/weed", "replication": "010",
 "cpIp": "127.0.0.1", "localTokenPath": "$W/local.token", "enrollCheckSourceIp": false,
 "uiDir": "$ROOT/control-plane/ui"}
JSON
openssl rand -hex 32 > "$W/local.token"; chmod 600 "$W/local.token" "$W/config.json"
python3 -m sfsctl.server --config "$W/config.json" > "$W/server.log" 2>&1 &
SPID=$!
trap 'kill $SPID 2>/dev/null || true; rm -rf "$W"' EXIT
export SFSCTL_CONFIG="$W/config.json" SFSCTL_API="https://127.0.0.1:$PORT"
for _ in $(seq 1 50); do [ -s "$W/state/ca.pem" ] && curl -fsS --cacert "$W/state/ca.pem" "https://127.0.0.1:$PORT/api/v1/ca" >/dev/null 2>&1 && break; sleep 0.2; done
CA="$W/state/ca.pem"; B="https://127.0.0.1:$PORT"
curl -fsS --cacert "$CA" "$B/api/v1/ca" >/dev/null || { cat "$W/server.log"; fail "server did not start"; }
pass "server up, GET /api/v1/ca"

python3 -m sfsctl.cli region add --name r1 --env smoke-env > "$W/region.json" || true
TOK=$(python3 -m sfsctl.cli enroll-token --region r1 --node-id 5 --roles master,volume,filer --ip 10.0.0.5)
echo "$TOK" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["token"] and d["caFingerprint"].startswith("sha256:"), d' || fail "enroll-token: $TOK"
pass "sfsctl enroll-token"
T=$(echo "$TOK" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')

openssl ecparam -name prime256v1 -genkey -noout -out "$W/node.key" 2>/dev/null
printf '[req]\ndistinguished_name=dn\nreq_extensions=ext\nprompt=no\n[dn]\nCN=node5.r1\n[ext]\nsubjectAltName=IP:10.0.0.5\n' > "$W/csr.cnf"
openssl req -new -sha256 -key "$W/node.key" -config "$W/csr.cnf" -out "$W/node.csr"
python3 -c 'import json,sys; print(json.dumps({"token":sys.argv[1],"csr":open(sys.argv[2]).read(),"ip":"10.0.0.5","hostname":"node5","roles":["master","volume","filer"]}))' "$T" "$W/node.csr" > "$W/enroll.json"
curl -sS --cacert "$CA" -o "$W/enroll.out" -w '%{http_code}' -H 'Content-Type: application/json' --data @"$W/enroll.json" "$B/api/v1/enroll" > "$W/code"
grep -qE '^20[01]$' "$W/code" || fail "enroll HTTP $(cat "$W/code"): $(cat "$W/enroll.out")"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); open(sys.argv[2],"w").write(d["cert"]); c=d["config"]; assert c["masters"]==["10.0.0.5:9333"], c; assert d["node"]["id"]=="r1-5"' "$W/enroll.out" "$W/node.pem"
openssl verify -CAfile "$CA" "$W/node.pem" >/dev/null || fail "issued cert does not chain"
pass "POST /api/v1/enroll with real CSR, cert chains to CA"
C2=$(curl -sS --cacert "$CA" -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' --data @"$W/enroll.json" "$B/api/v1/enroll")
[ "$C2" = 401 ] || [ "$C2" = 403 ] || fail "token replay gave HTTP $C2"
pass "enroll token replay refused (HTTP $C2)"

HB=$(curl -sS --cacert "$CA" --cert "$W/node.pem" --key "$W/node.key" -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"roles":["master","volume","filer"],"diskTotal":100,"diskUsed":10}' "$B/api/v1/nodes/r1-5/heartbeat")
[ "$HB" = 200 ] || fail "mTLS heartbeat HTTP $HB"
pass "mTLS heartbeat"

G=$(python3 -m sfsctl.cli sso-grant --sub 42 --email admin@example.com --role admin)
URL=$(echo "$G" | python3 -c 'import json,sys; print(json.load(sys.stdin)["url"])')
case "$URL" in https://smoke.local/sso\?grant=*) ;; *) fail "sso-grant url $URL";; esac
Q=${URL#https://smoke.local}
curl -sS --cacert "$CA" -c "$W/jar" -o /dev/null -w '%{http_code} %{redirect_url}\n' "$B$Q" > "$W/sso"
grep -q '^302 ' "$W/sso" || fail "/sso: $(cat "$W/sso")"
pass "/sso grant -> 302 + session cookie"
R2=$(curl -sS --cacert "$CA" -o /dev/null -w '%{http_code}' "$B$Q")
[ "$R2" = 401 ] || [ "$R2" = 403 ] || fail "SSO grant replay gave HTTP $R2"
pass "SSO grant replay refused (HTTP $R2)"
AC=$(curl -sS --cacert "$CA" -b "$W/jar" -D - -o /dev/null "$B/auth/check")
echo "$AC" | grep -qi '^x-sfs-role: admin' || fail "/auth/check: $AC"
pass "/auth/check -> admin"
for p in me nodes health cluster regions jobs audit; do
  code=$(curl -sS --cacert "$CA" -b "$W/jar" -o "$W/$p.out" -w '%{http_code}' "$B/api/v1/$p")
  [ "$code" = 200 ] || fail "GET /api/v1/$p HTTP $code: $(cat "$W/$p.out")"
  python3 -m json.tool "$W/$p.out" >/dev/null || fail "/api/v1/$p is not JSON"
  pass "GET /api/v1/$p"
done
python3 -c 'import json,sys; n=json.load(open(sys.argv[1])); n=n.get("items",n) if isinstance(n,dict) else n; assert any(x["id"]=="r1-5" for x in n), n' "$W/nodes.out" || fail "enrolled node missing from /api/v1/nodes"
pass "enrolled node listed"
UI=$(curl -sS --cacert "$CA" -b "$W/jar" -o /dev/null -w '%{http_code}' "$B/ui/")
[ "$UI" = 200 ] || fail "/ui/ with session HTTP $UI"
UI0=$(curl -sS --cacert "$CA" -o /dev/null -w '%{http_code}' "$B/ui/")
[ "$UI0" = 401 ] || fail "/ui/ without session HTTP $UI0"
pass "/ui/ needs a session (200 with, 401 without)"
CS=$(curl -sS --cacert "$CA" -b "$W/jar" -o /dev/null -w '%{http_code}' -X POST "$B/api/v1/ops/rebalance")
[ "$CS" = 403 ] || fail "POST without CSRF header gave HTTP $CS"
pass "state change without X-SFS-CSRF refused"
CT=$(python3 -m sfsctl.cli enroll-token --region r1 --node-id 9 --roles client --ip 10.0.0.9)
echo "$CT" | grep -q '"token"' || fail "client enroll-token: $CT"
pass "client-role enroll token"
echo "ALL SMOKE CHECKS PASSED"
