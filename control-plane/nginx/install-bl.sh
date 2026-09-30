#!/bin/bash
# Install the Advanced Management ingress (sfs.conf) on the bl (nginx) node.
#
# Usage (root, via JPS ExecCmd on the bl node):
#   install-bl.sh --cp-ip 10.0.0.5 --server-name env.example.com \
#       (--ca-file /path/ca.pem | --ca-fingerprint sha256:<hex>) \
#       [--conf /path/sfs.conf | --conf-url https://.../sfs.conf]
# --ca-fingerprint: fetch the CA from https://<cp-ip>:8480/api/v1/ca and pin it.
# Output: log lines + SFS_RESULT=ok|failed, SFS_MESSAGE=... ; exit 0 only on ok.
set -u
umask 022

CP_IP="" SERVER_NAME="" CA_FILE="" CA_FP="" CONF="" CONF_URL=""
DEST_DIR=/etc/nginx/sfs
DEST_CONF=/etc/nginx/conf.d/sfs.conf
HTTP_CONF=/etc/nginx/nginx-jelastic.conf

finish() { # result message
    echo "SFS_RESULT=$1"
    echo "SFS_MESSAGE=$2"
    [ "$1" = ok ] && exit 0 || exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --cp-ip) CP_IP="$2"; shift 2 ;;
        --server-name) SERVER_NAME="$2"; shift 2 ;;
        --ca-file) CA_FILE="$2"; shift 2 ;;
        --ca-fingerprint) CA_FP="$2"; shift 2 ;;
        --conf) CONF="$2"; shift 2 ;;
        --conf-url) CONF_URL="$2"; shift 2 ;;
        *) finish failed "unknown argument $1" ;;
    esac
done

echo "$CP_IP" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || finish failed "--cp-ip must be an IPv4 address"
echo "$SERVER_NAME" | grep -Eq '^[A-Za-z0-9._ -]+$' || finish failed "--server-name is required (env domain)"
command -v nginx >/dev/null || finish failed "nginx not found on this node"

TMP=$(mktemp -d) || finish failed "mktemp failed"
trap 'rm -rf "$TMP"' EXIT

# 1. template
if [ -z "$CONF" ]; then
    if [ -n "$CONF_URL" ]; then
        curl -fsSL --max-time 60 -o "$TMP/sfs.conf.in" "$CONF_URL" || finish failed "cannot download $CONF_URL"
        CONF="$TMP/sfs.conf.in"
    else
        CONF="$(cd "$(dirname "$0")" && pwd)/sfs.conf"
    fi
fi
[ -s "$CONF" ] || finish failed "template $CONF missing"

# 2. cluster CA (pinned by fingerprint when fetched over the network)
fp_of() { openssl x509 -in "$1" -outform DER 2>/dev/null | sha256sum | awk '{print "sha256:"$1}'; }
if [ -n "$CA_FILE" ]; then
    [ -s "$CA_FILE" ] || finish failed "CA file $CA_FILE missing"
    cp "$CA_FILE" "$TMP/ca.pem"
elif [ -n "$CA_FP" ]; then
    curl -fsS -k --max-time 30 "https://$CP_IP:8480/api/v1/ca" -o "$TMP/ca.json" \
        || finish failed "cannot fetch CA from https://$CP_IP:8480/api/v1/ca"
    python3 -c 'import json,sys; sys.stdout.write(json.load(open(sys.argv[1]))["ca"])' "$TMP/ca.json" > "$TMP/ca.pem" 2>/dev/null \
        || sed -n 's/.*"ca"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$TMP/ca.json" | sed 's/\\n/\n/g' > "$TMP/ca.pem"
else
    finish failed "one of --ca-file or --ca-fingerprint is required"
fi
GOT_FP=$(fp_of "$TMP/ca.pem")
[ "$GOT_FP" != "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ] && [ -n "$GOT_FP" ] \
    || finish failed "CA certificate is not a valid PEM"
if [ -n "$CA_FP" ] && [ "$GOT_FP" != "$CA_FP" ]; then
    finish failed "CA fingerprint mismatch: got $GOT_FP expected $CA_FP"
fi

# 3. TLS on 443 only when the platform installed a certificate on this node
SSL_LINE=""
if [ -s /var/lib/jelastic/SSL/jelastic.chain ] && [ -s /var/lib/jelastic/SSL/jelastic.key ]; then
    SSL_LINE="listen 443 ssl; ssl_certificate /var/lib/jelastic/SSL/jelastic.chain; ssl_certificate_key /var/lib/jelastic/SSL/jelastic.key; ssl_protocols TLSv1.2 TLSv1.3;"
fi

# 4. render
sed -e "s|__SFS_CP_IP__|$CP_IP|g" -e "s|__SFS_SERVER_NAME__|$SERVER_NAME|g" \
    -e "s|__SFS_CA_FILE__|$DEST_DIR/ca.pem|g" -e "s|__SFS_SSL__|$SSL_LINE|g" "$CONF" > "$TMP/sfs.conf"
if ! nginx -V 2>&1 | grep -q -- '--with-http_auth_request_module'; then
    # The platform nginx balancer is built without auth_request: the control plane
    # authenticates every /ui/ and /api/ request itself (it always does anyway).
    echo "auth_request module not available: relying on control-plane authentication"
    sed -i '/# sfs:auth_request/d' "$TMP/sfs.conf"
fi
grep -Eq '__SFS_[A-Z_]+__' "$TMP/sfs.conf" && finish failed "unrendered placeholder in sfs.conf"

# 5. install with rollback
mkdir -p "$DEST_DIR"
BACKUP="$TMP/backup"; mkdir -p "$BACKUP"
[ -f "$DEST_CONF" ] && cp -p "$DEST_CONF" "$BACKUP/sfs.conf"
[ -f "$DEST_DIR/ca.pem" ] && cp -p "$DEST_DIR/ca.pem" "$BACKUP/ca.pem"
[ -f "$HTTP_CONF" ] && cp -p "$HTTP_CONF" "$BACKUP/http.conf"
install -m 0644 "$TMP/ca.pem" "$DEST_DIR/ca.pem"
install -m 0644 "$TMP/sfs.conf" "$DEST_CONF"
# Make sure the http block loads it (Jelastic's http config may not include conf.d/*.conf).
if ! nginx -T 2>/dev/null | grep -q "^# configuration file $DEST_CONF:"; then
    if [ -f "$HTTP_CONF" ] && grep -q '^http {' "$HTTP_CONF"; then
        sed -i "0,/^http {/s||http {\n    include $DEST_CONF;|" "$HTTP_CONF"
    fi
fi
if ! nginx -t >"$TMP/t.log" 2>&1; then
    cat "$TMP/t.log"
    rm -f "$DEST_CONF"
    [ -f "$BACKUP/sfs.conf" ] && cp -p "$BACKUP/sfs.conf" "$DEST_CONF"
    [ -f "$BACKUP/ca.pem" ] && cp -p "$BACKUP/ca.pem" "$DEST_DIR/ca.pem"
    [ -f "$BACKUP/http.conf" ] && cp -p "$BACKUP/http.conf" "$HTTP_CONF"
    finish failed "nginx -t failed, previous configuration restored: $(tail -n1 "$TMP/t.log")"
fi

# 6. keep across redeploys
if [ -f /etc/jelastic/redeploy.conf ]; then
    for p in "$DEST_CONF" "$DEST_DIR" "$HTTP_CONF"; do
        grep -qxF "$p" /etc/jelastic/redeploy.conf || echo "$p" >> /etc/jelastic/redeploy.conf
    done
fi

if command -v systemctl >/dev/null && systemctl is-active --quiet nginx 2>/dev/null; then
    systemctl reload nginx || finish failed "nginx reload failed"
else
    nginx -s reload 2>/dev/null || nginx || finish failed "nginx start failed"
fi
finish ok "ingress for $SERVER_NAME -> https://$CP_IP:8480 installed (CA $GOT_FP)"
