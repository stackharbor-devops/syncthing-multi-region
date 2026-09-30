# Security model (v0)

Scope: the SeaweedFS data plane, the `sfsctl` control plane, the bl (nginx) ingress and
the JPS add-ons. Contract details are in ARCHITECTURE.md sections 3 to 6.

## Trust boundaries

| Zone | Who is there | Trusted for |
|---|---|---|
| Platform dashboard / JPS | the env owner (and collaborators with env access) | everything: they already own the containers |
| Control-plane node (primary storage master) | root on that container | everything: holds the CA key and the HMAC secret |
| Storage nodes | root on each node | its own node key; volume JWT keys (cluster-wide) |
| Private network (region LAN + GRE between regions) | platform containers, possibly other tenants' traffic filtered by the platform firewall | reaching ports 9333/8080/8888/8480; nothing else by itself |
| Internet | anyone | only the env domain through the platform SLB -> bl nginx |

The platform's network isolation and firewall are the outer wall. Everything below is
defence in depth and assumes an attacker may already have a foothold on the private
network.

## Secrets and key custody

| Secret | Where | Mode | Leaves the node? |
|---|---|---|---|
| Cluster HMAC secret (256-bit) | `/etc/sfsctl/config.json` on the control-plane node | 0600 | never (tokens are minted on that node by `sfsctl`) |
| CA private key (EC P-256, 10 y) | `/var/lib/sfsctl/ca.key` | 0600 | never |
| CP TLS key | `/var/lib/sfsctl/server.key` | 0600 | never |
| Node key (EC P-256) | `/etc/sfs/node.key`, generated on the node | 0600 | never (CSR flow) |
| Volume JWT write/read keys | derived `HMAC(secret, "sfs/jwt-signing/v1")`, `.../jwt-read/v1`; written to `/etc/sfs/security.toml` | 0600 | yes, to enrolled nodes only, inside the TLS enroll response |
| Local admin API token | `/etc/sfsctl/local.token` | 0600 | never |

The JWT keys are one-way derivations, so a leaked `security.toml` does not reveal the
cluster secret. Rotating the cluster secret rotates the JWT keys (all nodes must re-enroll).

## Tokens

Format: `base64url(JSON claims) "." base64url(HMAC-SHA256(key, claims))`, verified in
constant time; claims always carry `typ`, `iat`, `exp`, `jti` (128-bit random).
`verify` checks signature, then `typ` (so an SSO grant can never be used as an enroll
token and vice versa), then `exp`.

| Token | typ | Lifetime | Use | Replay |
|---|---|---|---|---|
| Enroll token | `enroll` | 15 min | one node, bound to cluster id, region, node id, roles and IP | jti burned on first successful use |
| SSO grant | `sso` | 60 s | opens one browser session | jti burned by `/sso` |
| Session | server-side, random 256-bit id | 8 h absolute, 30 min idle | cookie `sfs_session` (Secure, HttpOnly, SameSite=Strict) | id stored hashed; logout deletes it |
| API token | `api` (bearer) | set at creation | automation with a role | revocable: must exist in the tokens table |

Enroll hardening (`sfsctl/enroll.py`):
- roles, region and node id come from the token, never from the request body;
- the CSR must be self-signature valid, have CN `node<N>.<region>`, and SAN IPs equal to
  the token IP (127.0.0.1 tolerated); extra IPs are refused; key EC P-256/384 or RSA >= 2048;
- the request source IP must equal the token IP (`enrollCheckSourceIp`, default on);
- the issued certificate carries our own extensions (CSR extensions are never copied):
  CA:FALSE, serverAuth+clientAuth, 365 days, random 128-bit serial;
- the CSR is validated before the jti is burned (a typo does not waste the token) and the
  jti is burned before signing (two concurrent replays: exactly one wins);
- every attempt, accepted or denied, is written to the audit log.

## Browser access (Advanced Management)

No permanent credentials exist for the UI. The dashboard button runs `sfsctl sso-grant`
on the control-plane node, the browser gets a 60 s single-use URL, `/sso` swaps it for a
session cookie and redirects to `/ui/` so the grant does not stay in the address bar or
browser history. nginx does not log `/sso` requests. State-changing API calls made with
the cookie also need the `X-SFS-CSRF: 1` header (not settable cross-site without CORS,
which is never enabled). Responses carry HSTS, `Content-Security-Policy: default-src
'self'`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, `nosniff`.

The bl ingress (`control-plane/nginx/sfs.conf`) reaches the control plane over TLS verified
against the cluster CA (`proxy_ssl_name sfsctl`), strips client-supplied `X-SFS-User`/`X-SFS-Role`,
rate-limits `/sso`, refuses `/api/v1/enroll` for anything relayed by the SLB, and returns 404
for every path it does not know. Note: the platform nginx balancer (1.30.x) is built
**without** `auth_request`; `install-bl.sh` then removes those lines and the control plane
alone authenticates `/ui/` and `/api/` (it always does, nginx was only a second check).
The control plane must never trust `X-SFS-*` request headers.

## What an attacker can and cannot do

Attacker on the internet:
- can reach only the env domain; gets 401 on `/ui/` and `/api/`, can read the CA cert;
- cannot forge an SSO grant (HMAC key never leaves the CP node), cannot brute-force one
  (256-bit key, 60 s lifetime, rate limit), cannot reach enroll through the SLB.

Attacker on the private network (another container, no credentials):
- can reach the ports. The control plane API requires a session, bearer token or a valid
  enroll token; gRPC between SeaweedFS components requires a client certificate from the
  cluster CA; volume reads/writes need a JWT signed with the cluster JWT keys.
- cannot enroll a rogue node without an unexpired, unused enroll token that names its IP.
- **can** read/write through the filer HTTP port 8888 and master HTTP 9333 if SeaweedFS does
  not require auth there (SeaweedFS HTTP filer access is not covered by gRPC mTLS). This is
  why the platform firewall must restrict 8888/9333/8080 to the cluster's own containers
  and the app envs that mount it. TODO(sfs): filer JWT (`jwt.filer_signing.key`) to close this.
- can observe traffic metadata; TLS covers gRPC and the control plane, but plain HTTP
  volume/filer traffic inside the private network is not encrypted.

Attacker with root on one storage node:
- has that node's key and the cluster-wide JWT keys, so can read/write any volume data;
  cannot mint tokens, enroll other nodes, sign certificates or open the admin UI.
- Response: drain + remove the node, rotate the cluster secret, re-enroll the rest.

Attacker with root on the control-plane node, or with env-owner access in the dashboard:
- owns the cluster. This is by design: the platform account is the root of trust.

## Known gaps (v0)

- No certificate revocation list: a removed node's certificate stays valid until expiry.
  Mitigation: the firewall/cluster membership; TODO(sfs): CRL or short-lived certs.
- Single control plane; the CA key has no offline backup beyond the cluster backup job.
- Rate limiting at the ingress keys on the SLB address (the realip module is not trusted,
  to keep `X-Forwarded-For` unspoofable for the enroll rule), so it is effectively global.
