# Multi-Region Distributed Storage for Jelastic / Virtuozzo

A distributed, replicated file storage platform for Virtuozzo Application Platform
(Jelastic), installed from the marketplace as JPS add-ons. The data plane is
[SeaweedFS](https://github.com/seaweedfs/seaweedfs) 4.48 (pinned, sha256-verified). On top
of it the package adds its own control plane, `sfsctl`: node enrollment with a cluster CA,
jobs for rebalancing, healing, draining and backups, health monitoring with self-healing,
cross-region replication supervision, and a web UI ("Advanced Management") opened from
the dashboard with single sign-on.

> **Status: v0 preview.** Every component has been tested locally (unit tests, a control
> plane smoke test, Docker labs with the real SeaweedFS 4.48 binary and the real Jelastic
> storage and nginx images), but the package **has not yet been installed on a live
> Jelastic platform**. Do not store data you cannot lose until the first live install has
> been verified. See [docs/TEST-RESULTS.md](docs/TEST-RESULTS.md) and
> [docs/ROADMAP.md](docs/ROADMAP.md).

The repository name is historical: the first design used Syncthing; it was replaced by
SeaweedFS (see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), section 1).

## How it works

```
                        dashboard user
                             | Open Advanced Management (one-time SSO link, 60 s)
                             v
  Region 1 (primary env <cluster>-1)            Region 2 (env <cluster>-2)
  +-------------------------------------+       +-------------------------------+
  | bl: nginx  HTTPS -> TLS proxy --+   |       | storage nodes                 |
  |                                 v   |       |  weed master (1 or 3, Raft)   |
  | storage nodes                       |       |  weed volume  (every node)    |
  |  sfsctl control plane :8480 (node 1)|<------|  weed filer   (every node)    |
  |  weed master (1 or 3, Raft)         | mTLS  |  sfs-agent heartbeat (30 s)   |
  |  weed volume  (every node)          |       +---------------^---------------+
  |  weed filer   (every node)          |                       |
  |  sfs-agent heartbeat (30 s)         |<-- weed filer.sync (active-active,
  +------------------^------------------+     supervised by sfsctl)
                     |
          app envs: addons/mount.jps -> weed mount (FUSE, mTLS client cert)
```

- **One Jelastic environment per region.** Each region is a complete SeaweedFS cluster:
  masters (3 when the region has 3 or more nodes, else 1), and a volume server and a filer
  on every node. Default replication `010`: 2 copies on different nodes of the region.
- **Cross-region** replication is asynchronous: one `weed filer.sync` per region pair,
  active-active, started and restarted by the control plane.
- **Control plane** `sfsctl` (Python 3.9 standard library only) runs on the first storage
  node of the primary region. It owns the cluster CA, the node registry (SQLite), jobs,
  the audit log, the health monitor, the backup scheduler and the REST API
  ([ARCHITECTURE.md section 5](docs/ARCHITECTURE.md)). CLI: `sfsctl`.
- **Node runner** `sfs-node` on every storage node installs the pinned `weed` binary,
  enrolls with a one-time token (CSR signed by the cluster CA), writes `security.toml`
  (gRPC mTLS, volume JWTs) and runs the services as systemd units.
- **Mount runner** `sfs-mount` on app nodes mounts the filesystem with `weed mount` as a
  systemd unit, using a client certificate (role `client`) from the cluster CA.

## Deploy

1. Import `manifest.jps` in the dashboard (Import > URL, raw GitHub URL of this repo).
2. Choose the cluster name, region, number of storage nodes (1-9, default 3), cloudlets and
   disk per node. Install creates the environment `<cluster>-1` with a `storage` layer and
   a `bl` (nginx) layer, installs the control plane on the first storage node, enrolls the
   masters first, then the other nodes, and configures nginx.
3. The **Storage Cluster** add-on card appears on the storage layer. Buttons: Status,
   Open Advanced Management, Rebalance, Heal, Backup Now, Add Region; menu: Remove Node.
4. To use the storage from an application environment, install `addons/mount.jps` on the
   app layer: pick the storage env, the mount path and the cache size.

## Day-2 operations

Step-by-step runbooks are in [docs/OPERATIONS.md](docs/OPERATIONS.md).

- **Add a node**: scale out the Storage layer in the dashboard. `onAfterScaleOut` enrolls
  the new nodes (volume + filer). Then press Rebalance, or let the monitor rebalance when
  capacity skew exceeds 20%.
- **Remove a node**: card menu > Remove Node, or scale in. The node is drained first (its
  volumes are moved away), then removed. Master and control-plane nodes are refused in v0.
- **Add a region**: card > Add Region (platform region, name, node count). A new env
  `<cluster>-<n>` is created, its nodes enrolled, and `filer.sync` connects it.
- **Backups / restore**: card > Backup Now, or the schedule in Advanced Management >
  Backups. Each backup is a full snapshot of the filer tree with a manifest; restore any
  path to a target path from the UI.
- **Open Advanced Management**: card button. It shows a one-time link (valid 60 s) that
  signs you in as admin; the session lasts 8 h (30 min idle).

## Security model (summary)

Details: [docs/SECURITY-MODEL.md](docs/SECURITY-MODEL.md).

- All SeaweedFS gRPC traffic uses mTLS with certificates from the cluster CA (EC P-256);
  volume reads and writes need JWTs; services bind to private IPs only.
- Nodes join only with a one-time, 15-minute enroll token bound to region, node id, roles
  and IP; the CSR's CN and IP must match; the token is burned before signing.
- The control plane API is HTTPS only. Callers: the loopback-only local admin token (used
  by the JPS buttons through `sfsctl`), API tokens (revocable), browser sessions from SSO
  (Secure, HttpOnly, SameSite=Strict, CSRF header required for changes), and node
  certificates for heartbeats. RBAC roles: viewer, operator, admin. Every change is audited.
- Network isolation and the platform firewall are the outer boundary. Known gaps: the filer
  HTTP API (8888) is not authenticated inside the private network, and there is no CRL yet.

## Guarantees and limits

- Within a region: every file is stored on 2 nodes (`010`) when the region has 2 or more
  nodes. A single node failure loses no data, and reads and writes continue (lab-tested).
- Master failover: a new Raft leader in 12-14 s; writes can fail for up to about 20 s.
- Across regions: asynchronous, sub-second lag in the lab. Concurrent writes to the same
  path in two regions are last-writer-wins. A cut-off region keeps working and catches up
  after reconnection (tested for short cuts only).
- Backups are full snapshots, not point-in-time recovery; no S3 target yet.
- One control plane (no HA) in the primary region; the data plane keeps working without it.
- 1-9 storage nodes per region in the installer.

## Requirements

- Virtuozzo Application Platform with the `storage` (AlmaLinux 9) and `nginx` node types.
- Outbound internet from the nodes to download SeaweedFS from GitHub releases.
- Multi-region: private connectivity between regions for ports 8888/18888 (filer) and 8480
  (control plane). App nodes need 8888/18888 and 8080 to the storage nodes.
- App nodes that mount the storage need systemd and `/dev/fuse`.

## Development

```
PYTHONPATH=control-plane python3 -m unittest discover -s tests/unit   # unit tests
bash tests/smoke/local.sh                                           # control plane smoke test
python3 .github/scripts/check.py                                    # JPS checks
WEED_BIN=/path/to/weed tests/e2e/run-all.sh                         # Docker failure scenarios
```

## License & contribution

MIT, see [LICENSE](LICENSE). See [CONTRIBUTING.md](CONTRIBUTING.md) and
[SECURITY.md](SECURITY.md). Version history: [CHANGELOG.md](CHANGELOG.md).
