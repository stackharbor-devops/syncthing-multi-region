# Syncthing Multi-Region File Replication for Jelastic / Virtuozzo

A JPS package that keeps a directory identical on every node of an app layer, within one
region or across several, while every node reads its own local copy at disk speed.
Replication is done by [Syncthing](https://syncthing.net). This package does the platform
side: install, mesh, scaling, redeploys, persistent settings, monitoring and backups.

Repository: <https://github.com/stackharbor-devops/syncthing-multi-region>

> **Status: early development.** The first milestone is a proof of concept for one
> environment. Do not use it in production yet.

---

## Why

It replaces lsyncd/rsync file sync between app servers, such as the platform's File
Synchronization add-on, which in multi-node use:

- **loses custom ignore rules** when the add-on is reset or a node is redeployed, because
  its settings live only on the nodes;
- **undoes changes and brings deleted files back**, because rsync keeps no record of which
  node changed a file last, so a stale node's push overwrites newer work.

It is also an alternative to a shared network filesystem (GlusterFS, NFS) for PHP sites,
where every file check crosses the network. With this package, page loads never touch the
network: each node serves its own copy.

## How it works

- **Syncthing on every node** of the chosen layer, in every environment (region) of the
  cluster. It is a single open-source program: no FUSE, no kernel modules, so it runs in
  platform containers.
- **Private network only.** Nodes connect directly to each other's private IP addresses,
  including between regions. They authenticate each other with certificates. Public
  discovery, relays and the web interface are off.
- **No lost or undone changes.** Every node tracks a version of every file and records
  deletes. A node that was offline or missed changes catches up instead of overwriting
  newer work, and deleted files stay deleted. When two nodes change the same file at once,
  one version wins and the other is kept as a conflict copy and reported.
- **Settings that persist.** Paths, ignore rules and options are stored on the platform
  side and re-applied on every event that touches a node: install, scale out or in,
  redeploy, clone, migrate and restart. Ignore rules can be set for all regions, for one
  region, or for one node.
- **Safe joins.** A new node first only receives: it pulls the current state and discards
  stale local differences, then starts sending. A node cloned from another gets its own
  identity. Until its first sync is done, the load balancer's health check keeps it out of
  rotation.
- **One writer where it matters.** Optionally, a path such as the site code can be written
  on one node only, while uploads stay writable everywhere.
- **Undo.** File versioning keeps replaced and deleted files for a set time.
- **Visibility.** A scheduled check in the Tasks log reports each node's peers, sync state,
  errors and conflicts, and can send an e-mail. Backups run with restic from one node's
  local copy.

## Guarantees and limits

- **Guaranteed:** no silent loss, no change undone by a stale node, deleted files stay
  deleted, every node ends up identical, conflicts are kept and reported.
- **Not instant.** Replication is asynchronous: a change reaches the other nodes within
  seconds. If every node must see a write before the request returns, use a shared
  filesystem such as
  [glusterfs-multi-region](https://github.com/stackharbor-devops/glusterfs-multi-region),
  at the cost of network reads.
- **Not for files several nodes write at once,** such as PHP sessions, SQLite databases,
  logs and caches. Exclude them with ignore rules, or keep them in Redis or the database.

## Roadmap

| Milestone | Scope |
|---|---|
| 0.1 | Proof of concept: one environment, one app layer. Install, uninstall, scale out and in, redeploy, persistent ignore rules, safe joins, status. |
| 0.2 | Single-writer paths, file versioning, conflict reporting, load balancer health gating. |
| 0.3 | Multi-region: several environments in one mesh, add and remove regions, per-region rules. |
| 0.4 | Scheduled health checks with e-mail alerts, restic backups. |
| 1.0 | Production-ready after field testing. |

## Requirements

- Virtuozzo Application Platform (Jelastic) with systemd-based app nodes, for example the
  LiteSpeed, NGINX or Apache PHP images on AlmaLinux 9.
- Outbound internet access from the nodes, to download Syncthing from its GitHub releases.
- For multi-region: private network connectivity between the regions, with TCP port 22000
  allowed between cluster nodes.

## License & contribution

MIT, see [LICENSE](LICENSE). Bug reports, test results, ideas and pull requests are
welcome: see [CONTRIBUTING.md](CONTRIBUTING.md). File bugs and feature requests at
<https://github.com/stackharbor-devops/syncthing-multi-region/issues>. Report security
problems privately, as described in [SECURITY.md](SECURITY.md).
