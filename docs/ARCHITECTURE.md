# Architecture and component contracts (v0)

This file is the contract every component is built against. Change it first when an
interface changes.

## 1. Decision: SeaweedFS as the data plane

Selected: **SeaweedFS 4.48** (Apache-2.0, single static Go binary `weed`).

| Requirement | SeaweedFS | Rejected alternatives |
|---|---|---|
| Runs in Jelastic containers (no kernel modules, no raw block devices) | Yes: user-space binary, data in plain files | Ceph (OSDs need block devices, kernel client), LINSTOR/DRBD (kernel module) |
| Add node = capacity grows, data rebalances | Volume server registers with master; `volume.balance` | Syncthing (full copy per node, no capacity growth), GlusterFS (manual add-brick/rebalance) |
| Local redundancy, automatic healing | Replica placement per collection, `volume.fix.replication`, master maintenance scripts | |
| Cross-region async replication, no WAN wait on writes | One cluster per region, `weed filer.sync` active-active between filers | Garage (object-only, cross-zone quorum writes), GlusterFS geo-rep (one-way) |
| POSIX filesystem for apps with near-local reads | `weed mount` (FUSE) with local metadata cache (filer subscription) and local chunk cache | MinIO/Garage (S3 only), JuiceFS (needs a separate HA metadata database) |
| Integrity | Per-needle CRC, `volume.fsck`, `volume.check.disk` | |
| Backups | `weed filer.backup` (continuous), filer metadata log, S3 gateway | |

Trade-offs accepted:
- Writes are synchronous only **inside** a region (LAN, sub-millisecond). Between regions
  replication is asynchronous; RPO across regions = replication lag (seconds). Concurrent
  writes to the same path in two regions: last writer wins (SeaweedFS filer.sync).
- Client access is FUSE (`weed mount`). Metadata lookups are served from the mount's
  local metadata cache, file data from a local chunk cache after first read. PHP sites
  should keep opcache enabled.
- v0 control plane is a single instance in the primary region (state in SQLite, backed
  up to the cluster). HA control plane is a follow-up.

## 2. Topology

```
Region env  <cluster>-<n>   (one Jelastic environment per region, n = 1 is primary)
  nodeGroup storage  (nodeType: storage, AlmaLinux 9, systemd)  count >= 1
     every node:  weed volume  (-dataCenter=<region> -rack=node<jelasticNodeId>)
                  weed filer   (embedded leveldb2 store; filers of a region peer via the master)
                  sfs-agent timer (heartbeat/metrics to control plane)
     nodes 1..3 (lowest Jelastic node ids): weed master (Raft, 3 when >= 3 nodes, else 1)
  nodeGroup bl  (nodeType: nginx)  primary region only, count 1
     nginx: HTTPS ingress (platform SLB/env domain) -> TLS proxy -> control plane (sfsctl checks the session itself; the platform nginx has no auth_request module)
Primary region storage master node additionally runs:
     sfsctl (control plane, systemd sfsctl.service, listens 0.0.0.0:8480 private, TLS)
App envs (clients): addons/mount.jps installs weed + systemd mount unit on an app layer
```

Ports (private network only): master 9333/19333, volume 8080/18080, filer 8888/18888,
control plane 8480, control-plane plain-HTTP loopback for nginx 127.0.0.1 is NOT used
(nginx runs on the bl node and reaches 8480 over the private network with TLS).

Default storage policy: replication `010` (2 copies on different nodes of the same
region) when the region has >= 2 nodes, `000` for a single node. Stored per cluster,
changeable per collection later.

Filesystem paths on storage nodes:
- `/etc/sfs/`        node.env, security.toml, master.toml, ca.pem, node.pem, node.key (0600)
- `/var/lib/sfs/master`, `/var/lib/sfs/volume`, `/var/lib/sfs/filer`  data
- `/usr/local/bin/weed`  pinned binary, `/usr/local/sbin/sfs-node`  node runner
- `/etc/jelastic/redeploy.conf` must list `/etc/sfs` and `/var/lib/sfs`
Control plane:
- `/opt/sfsctl/` code, `/etc/sfsctl/config.json` (0600), `/var/lib/sfsctl/` (sqlite db, CA key)
- `/usr/local/bin/sfsctl` CLI wrapper

## 3. Security model

- All cluster traffic on the platform's private network (GRE between regions).
- SeaweedFS gRPC uses mutual TLS (`security.toml` `[grpc]` sections) with certificates
  issued by the cluster CA. Volume writes/reads require JWTs signed with
  `jwt.signing.key` / `jwt.signing.read.key` distributed at enrollment.
- The control plane owns the CA private key (`/var/lib/sfsctl/ca.key`, 0600). Node private
  keys are generated on the node and never leave it (CSR flow).
- Admin UI is never exposed with permanent credentials: access only through a one-time
  SSO grant minted on the control-plane node at click time (section 6).

## 4. Enrollment protocol

1. JPS (via ExecCmd on the control-plane node) runs
   `sfsctl enroll-token --region R --node-id N --roles volume,filer[,master] --ip IP`
   -> prints `{"token": "...", "expiresAt": "...", "caFingerprint": "sha256:..."}`.
   Token = base64url(JSON claims) + "." + base64url(HMAC-SHA256(secret, claims)),
   claims {typ:"enroll", region, nodeId, roles, ip, exp (<= 15 min), jti}. One-time (jti
   recorded).
2. JPS runs on the new node: `sfs-node enroll --cp https://<cp-ip>:8480 --token T
   --ca-fingerprint sha256:... --region R --node-id N --ip IP --roles ...`.
3. Node generates `node.key` (EC P-256) + CSR (CN=node<N>.<region>, SAN IP), fetches
   the CA cert from `GET /api/v1/ca` and verifies its fingerprint, then
   `POST /api/v1/enroll {token, csr, hostname, ip, roles}` over TLS pinned to that CA.
4. Control plane verifies token (signature, exp, jti unused, ip matches), signs a cert
   (1 year), records the node, returns
   `{cert, ca, config: {clusterId, region, masters: ["ip:9333",...], replication,
   jwtSigningKey, jwtReadKey, dataCenter, rack, filerPeers: [...]}}`.
5. Node writes `/etc/sfs/*`, installs systemd units for its roles, starts them.

## 5. Control plane API (JSON over HTTPS, base `/api/v1`)

Auth: session cookie `sfs_session` (from SSO) or `Authorization: Bearer <api token>`.
Roles: `admin` (everything), `operator` (ops, backups, nodes; not tokens/RBAC),
`viewer` (GET only). State-changing requests also require header `X-SFS-CSRF: 1`
when authenticated by cookie. Every state change is written to the audit log.

| Method, path | Role | Body -> Response |
|---|---|---|
| GET /api/v1/health | viewer | -> `{status: ok|degraded|critical, checks: [{name, status, detail}], updatedAt}` |
| GET /api/v1/cluster | viewer | -> `{clusterId, name, primaryRegion, replication, capacity: {totalBytes, usedBytes, freeBytes}, counts: {regions, nodes, volumes}, version}` |
| GET /api/v1/regions | viewer | -> `[{id, name, envName, status, masters: [..], filers: [..], nodes: n}]` |
| POST /api/v1/regions | admin | `{name, envName}` -> region (registers; sync starts when its filer is enrolled) |
| DELETE /api/v1/regions/{id} | admin | -> job |
| GET /api/v1/nodes | viewer | -> `[{id, region, envName, nodeId, ip, roles, status: joining|online|offline|draining|removed, capacity: {totalBytes, usedBytes}, volumes, lastSeen}]` |
| POST /api/v1/nodes/enroll-token | admin | `{region, nodeId, roles, ip}` -> `{token, expiresAt, caFingerprint}` |
| POST /api/v1/enroll | enroll token | see section 4 |
| GET /api/v1/ca | none | -> `{ca: PEM, fingerprint}` |
| POST /api/v1/nodes/{id}/heartbeat | node cert (mTLS) or enroll secret | `{status json from sfs-node status}` -> `{ok}` |
| POST /api/v1/nodes/{id}/drain | operator | -> job (moves volumes off, then marks drained) |
| DELETE /api/v1/nodes/{id} | operator | -> `{ok}` (only when drained or offline > 24h with `?force=1`) |
| POST /api/v1/ops/rebalance | operator | -> job (`volume.balance -apply`) |
| POST /api/v1/ops/heal | operator | -> job (`volume.fix.replication`, then `volume.fsck` report) |
| GET /api/v1/jobs, GET /api/v1/jobs/{id} | viewer | -> `{id, type, status: queued|running|succeeded|failed, createdAt, startedAt, finishedAt, actor, log}` |
| GET /api/v1/replication | viewer | -> `[{from, to, mode: "async", status, lagSeconds, lastError}]` |
| GET /api/v1/backups | viewer | -> `[{id, createdAt, kind, status, sizeBytes, target}]` |
| POST /api/v1/backups | operator | -> job |
| POST /api/v1/backups/{id}/restore | admin | `{path, targetPath}` -> job |
| GET, PUT /api/v1/backups/policy | viewer / admin | `{enabled, intervalMinutes, retentionDays, target}` |
| GET /api/v1/audit?limit=N | viewer | -> `[{ts, actor, action, target, result, detail}]` |
| GET /api/v1/me | viewer | -> `{sub, email, role}` |
| GET/POST/DELETE /api/v1/tokens | admin | API tokens (HMAC bearer, role, expiry) |
| GET /auth/check | any | nginx auth_request: 200 + headers `X-SFS-User`, `X-SFS-Role`, or 401 |
| GET /sso?grant=G | none | verify grant, create session, `Set-Cookie`, 302 to `/ui/` |
| POST /auth/logout | session | clears session |
| GET /ui/* | session | static SPA (`control-plane/ui`) |

CLI `sfsctl` (on the control-plane node, talks to the local API with the local admin
token in `/etc/sfsctl/local.token`): `status --json`, `enroll-token ...`, `sso-grant
--sub S --email E --role admin`, `node drain ID`, `node remove ID`, `rebalance`,
`heal`, `region add --name R --env E`, `backup now`. Every command prints one JSON
document on stdout and exits non-zero on failure.

## 6. Advanced Management single sign-on

1. The JPS button **Open Advanced Management** runs a server-side action that execs
   `sfsctl sso-grant --sub <platform uid> --email <user email> --role admin` on the
   control-plane node. The HMAC secret never leaves that node.
2. The grant is a signed token (same format as enroll tokens, `typ:"sso"`), valid 60 s,
   single use (jti), bound to the env. `sfsctl` prints `{url: "https://<env-domain>/sso?grant=..."}`.
3. The JPS action returns the URL to the user (custom response); the browser opens it.
4. `/sso` verifies the grant, burns the jti, creates a server-side session (random 256-bit
   id, 8 h absolute / 30 min idle), sets `sfs_session` (Secure, HttpOnly,
   SameSite=Strict, Path=/), redirects to `/ui/` (grant never stays in the address bar).
5. nginx on the bl node protects `/ui/` and `/api/` with `auth_request /auth/check`.

## 7. Node runner contract (`scripts/node/sfs-node.sh`, installed as `/usr/local/sbin/sfs-node`)

Subcommands (run as root by JPS ExecCmd): `install --version V`, `enroll ...` (section 4),
`start`, `stop`, `status`, `drain-check`, `remove`. Output contract: any lines, plus
machine lines `SFS_RESULT=ok|failed`, `SFS_MESSAGE=<one line>`, `SFS_JSON=<one-line
JSON>` (status: `{roles, services: {master, volume, filer}, weedVersion, diskTotal,
diskUsed, region, nodeId}`). Exit code 0 only when `SFS_RESULT=ok`.
Binary pin: SeaweedFS `4.48`, assets `linux_amd64.tar.gz` / `linux_arm64.tar.gz`, sha256
verified against values pinned in the runner.

## 8. JPS surface

- `manifest.jps` (type install): deploy a storage cluster region env (storage group
  count >= 1, bl nginx in primary), install control plane on the primary storage master,
  enroll every node, configure nginx, install the management card.
- `addons/cluster.jps` (card on the storage layer): Status, Add Node (scale + enroll),
  Remove Node (drain + scale in), Add Region, Backup Now, Rebalance, Heal,
  Open Advanced Management. Events: onAfterScaleOut[storage] enrolls new nodes,
  onBeforeScaleIn[storage] drains, onAfterRedeployContainer[storage] reinstalls binary
  and restarts roles (identity kept via redeploy.conf).
- `addons/region.jps` (type install): an additional region env, enrolled into the
  existing control plane; control plane starts `filer.sync` with the other regions.
- `addons/mount.jps` (type update, app layers): mount the region's filer at a chosen path
  with `weed mount` and a local cache.

Node-group data keys (storage group): `sfsCluster` = JSON `{clusterId, region, primary,
cpIp, cpUrl, caFingerprint, version}`. Never write `globals`.
