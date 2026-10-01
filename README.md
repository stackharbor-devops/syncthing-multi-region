# Syncthing Multi-Region File Replication for Jelastic / Virtuozzo

A JPS add-on that keeps a directory identical on every node of an app layer, while every
node reads its own local copy at disk speed. Replication is done by
[Syncthing](https://syncthing.net). This package does the platform side: install, mesh,
scaling, redeploys, persistent settings and status.

Repository: <https://github.com/stackharbor-devops/syncthing-multi-region>

> **Status: v0.1, not released yet** (branch `addon-v0.1`). One environment, one app
> layer. Every part has been tested in Docker with systemd containers, the real
> Syncthing 2.1.5 and the real platform script (see [Tests](#tests)), but **not yet on a
> live platform**. Try it on a test environment first.

---

## Why

It replaces lsyncd/rsync file sync between app servers, such as the platform's File
Synchronization add-on, which in multi-node use:

- **loses custom ignore rules** when the add-on is reset or a node is redeployed, because
  its settings live only on the nodes;
- **undoes changes and brings deleted files back**, because rsync keeps no record of which
  node changed a file last, so a stale node's push overwrites newer work.

It is also an alternative to a shared network filesystem for PHP sites, where every file
check crosses the network. With this add-on, page loads never touch the network: each
node serves its own copy.

## What v0.1 does

- **Syncthing on every node of the app layer (`cp`).** Version 2.1.5, pinned: each node
  downloads it from Syncthing's GitHub releases and checks the sha256 from the release's
  signed checksum file (amd64 and arm64). It runs as a systemd service (`stsync`) under
  the user that owns the directory (for example `litespeed`, `nginx` or `apache`), so
  the files it writes belong to the site.
- **One directory**, by default the webroot `/var/www/webroot/ROOT`. It must be on the
  node's own disk: a directory on NFS or FUSE is refused, and so is a node that runs the
  File Synchronization add-on (lsyncd).
- **Private network only.** Nodes connect directly to each other's private IP on TCP
  22000 and authenticate each other with certificates. Public discovery, relays, NAT
  traversal, usage reporting and automatic upgrades are off; Syncthing's web interface
  and API listen on 127.0.0.1 only. When the account's firewall is on, the add-on allows
  TCP 22000 into the app layer.
- **Safe start.** On install the master node's copy is the starting content (or the copy
  of the node you name in the form). The install is refused when that copy is empty or
  holds less than half the files of another node's, so a recreated master never wipes
  the site. Every other node first only receives, from a node that already sends (never
  from another joining node alone): it pulls the cluster's state, moves its own differing
  and extra files into its version store, and only then starts sending. A node that
  already had other files never pushes them into the cluster, even when several joining
  nodes hold the same extra file.
- **No undone changes.** Every node tracks a version of every file and records deletes: a
  node that was offline catches up instead of overwriting newer work, and deleted files
  stay deleted. When two nodes change the same file at once, the newer change wins
  everywhere and the other is kept as a `*.sync-conflict-*` copy, which Status counts.
- **File versions.** Files replaced or deleted by a change from another node are kept for
  14 days (configurable) in `/var/lib/stsync/versions/webroot` on each node, outside the
  webroot, so they are never served.
- **Settings that persist.** The directory, ignore rules, change delay and version days
  are stored on the platform, in the app layer's node group data (key `stSync`), and
  re-applied on every event: scale out and in, redeploy, migration and clone.
- **Ignore rules.** Matching files are neither sent nor deleted: each node keeps its own.
  The defaults keep caches, logs and temporary files local:

  ```
  // Caches, logs and temporary files: each node keeps its own
  (?d)/wp-content/cache
  (?d)/wp-content/upgrade
  (?d)*.log
  (?d).DS_Store
  (?d)Thumbs.db
  ```

## Install

v0.1 is on the `addon-v0.1` branch until it is released. In the dashboard choose
**Import** > **URL** and enter:

```
https://raw.githubusercontent.com/stackharbor-devops/syncthing-multi-region/addon-v0.1/manifest.jps
```

Pick the environment and its app layer. The form asks for the directory (fixed after
install), the ignore rules, the change delay (how long a node collects changes before
sending them, 1-60 s, default 2), how many days to keep old versions (0-365, default
14; 0 turns versioning off) and, optionally, the starting copy: leave it empty to start
from the master node's copy, or enter the id of the node whose copy is the right one.
With it empty, the install is refused when the master's copy is empty or holds less than
half the files of another node's (counted without what the ignore rules keep local); the
message names the nodes and their file counts. Enter the master's id to use its copy
anyway.

The manifest loads its scripts from its `baseUrl`. While v0.1 is on the branch, that
`baseUrl` must point at the branch too (a "TEST BRANCH ONLY" commit, see
[CONTRIBUTING.md](CONTRIBUTING.md)); otherwise the scripts are loaded from main.

The success page names the seed node and the joining nodes. A joining node needs about
30 seconds plus the time to pull the files; Status shows the progress. Syncthing state
left on a node by an earlier install (for example a node an uninstall could not reach)
is reset, so it cannot become the source instead of the chosen copy.

## Using the add-on card

The card on the app layer has three buttons and Uninstall.

- **Status** shows an overall line (`in sync on all N node(s)`, `syncing`, or `PROBLEMS
  on ...`) and one block per node: service and version, device id, folder type (a node
  still joining is `receive-only`, with what the join is doing), state, items still to
  pull, connected peers, errors, conflict copies and the last scan. A node is a problem
  when it is receive-only with no join running, when its join failed, or when it reports
  in sync but its view of the directory (files, directories, deletes, bytes) differs from
  the other nodes' (`diverged`). A joining node's conflict copies are its own old files,
  which the join sets aside; they are shown as temporary. For example:

  ```
  Overall: in sync on all 3 node(s)
  Directory: /var/www/webroot/ROOT

  Node 101 (master): in sync
  service active (v2.1.5), device ABCDEFG, folder send-receive, state idle, need 0 items (0 B), peers 2/2, errors 0, conflicts 0, last scan 2026-09-30T07:05:12Z
  ```

- **Configure** shows the settings in force. Change the ignore rules, the change delay or
  the version days and click **Save**: every node gets them at once. The directory cannot
  be changed after install. Save with nothing changed re-applies the settings on every
  node, for example after a node was repaired by hand. An empty ignore field keeps the
  current rules; to have none, enter just a comment line (`// none`). When a rule is
  removed, files that each node kept locally start to replicate; where they differ, the
  newer one wins and the others become conflict copies.
- **Rescan** makes every node scan the directory now. Changes are normally picked up
  within seconds by the file watcher, and every node scans at start and every hour; a
  rescan helps when the watcher missed changes (for example when it ran out of inotify
  watches).
- **Uninstall** stops and removes Syncthing from every node and clears the settings. Every
  file under the directory stays in place; only Syncthing's own `.stfolder` and
  `.stignore` are removed. Old file versions are moved to `/root/stsync-versions-<time>`
  on each node, together with the conflict copies of a join that had not finished. Uninstall
  never fails, so the card can always be removed.

## What happens on platform events

| Event | What the add-on does |
|---|---|
| Scale out | New nodes join receive-only against a node that sends, then send. A node created as a copy of another node (stateful scaling) is detected: it gets its own identity and joins like a new node; its copied files never overwrite the cluster. If no sending node runs, new nodes wait. |
| Scale in | Every remaining node drops the removed node. |
| Redeploy | The node keeps its identity and database (`/var/lib/stsync` is listed in `/etc/jelastic/redeploy.conf`); Syncthing and the service are reinstalled, and the node catches up with what changed meanwhile. |
| Migration | Settings re-applied with the nodes' current private IPs. |
| Clone of the environment | The copy gets new identities and its own mesh; it never connects to the original. |

A node that is stopped or fails during an event is left out and reported; the next event
or a Save in Configure brings it back. A join that a node restart interrupts resumes when
Syncthing starts again.

## Guarantees and limits

- **Guaranteed:** no silent loss, no change undone by a stale node, deleted files stay
  deleted, every node ends up identical, conflicts are kept and reported.
- **Not instant.** Replication is asynchronous: a change reaches the other nodes within
  seconds (about 2 to 6 s in the tests, with a 1-3 s change delay). If every node must see a
  write before the request returns, use a shared filesystem (see below).
- **Not for files several nodes write at once,** such as PHP sessions, SQLite databases,
  logs and caches. Exclude them with ignore rules, or keep them in Redis or the database.
- **Every node holds a full copy** of the directory, so each node needs the disk space.
- **While a node joins it serves its own old files, and what is written on it is not
  replicated.** An upload or an update made on a joining node goes to its version store
  when the join finishes (it is not lost, but it is not on the site either). For those
  seconds its differing files can also appear next to the originals as
  `*.sync-conflict-*` copies (on that node only); the join moves them into its version
  store before the node starts sending. With version days set to 0, its files that
  differ from the cluster's are replaced without a copy; files that only it has are
  always kept. Keep joining nodes out of the load balancer until Status shows them in
  sync; doing that automatically is planned for 0.2.
- **Only the directory itself is checked** for NFS or FUSE. A network mount below it (for
  example an uploads directory on NFS) is not detected: keep it out with an ignore rule.
- **Large trees need enough inotify watches** (`fs.inotify.max_user_watches`). Status shows
  a file watcher error when they run out; changes then wait for the hourly rescan.
- **Needs outbound HTTPS** from the nodes to GitHub (Syncthing's release and this
  package's scripts).
- **One environment, one app layer, one directory** in v0.1. Multi-region is planned for
  0.3.

## Choosing between the three options

These are separate packages for different needs; none replaces another.

| | Syncthing (this package) | [GlusterFS multi-region](https://github.com/stackharbor-devops/glusterfs-multi-region) | SeaweedFS multi-region |
|---|---|---|---|
| What it is | A copy of one directory on every app node, replicated between them | One shared volume, synchronously replicated across regions | A storage cluster per region with its own control plane |
| Where files live | On each app node's own disk | On storage nodes; app nodes mount the volume (FUSE) | On storage nodes; app nodes mount it (FUSE, `weed mount`) |
| Reads | Local disk speed | Over the network | Over the network, with a local cache |
| When other nodes see a write | Seconds later | Before the write returns | At once in the region; other regions asynchronously |
| Extra environments | None | A storage environment per region | A storage environment per region |
| Capacity | Each node holds everything | Grows with storage nodes | Grows with storage nodes |
| Fits best | PHP sites such as WordPress: many small files, read far more than written | Apps where every node must see every write at once | Large or fast-growing data, many clients, backups and self-healing built in |

## Roadmap

| Milestone | Scope |
|---|---|
| 0.1 | One environment, one app layer: install, uninstall, scale out and in, redeploy, migrate, clone, persistent settings, safe joins, file versions, Status, Rescan. |
| 0.2 | Single-writer paths (for example the site code written on one node only), conflict reporting, load balancer health gating while a node joins. |
| 0.3 | Multi-region: several environments in one mesh, add and remove regions, per-region and per-node ignore rules. |
| 0.4 | Scheduled health checks in the Tasks log with e-mail alerts, restic backups from one node's copy. |
| 1.0 | Production-ready after field testing. |

## Requirements

- Virtuozzo Application Platform (Jelastic) with systemd-based app nodes, for example the
  LiteSpeed, NGINX or Apache PHP images on AlmaLinux 9, with `curl` and `python3`.
- Outbound internet access from the nodes, to download Syncthing from its GitHub releases.

## Tests

```bash
pip install pyyaml
python3 .github/scripts/check.py     # the automatic check: YAML, JavaScript, shell, ${} in cmd bodies
tests/harness/run-unit.sh            # manage.js and the manifest's inline scripts, scripted nodes (seconds)
tests/node/run.sh                    # the node runner for real in systemd containers (about 3 min)
tests/e2e/run.sh                     # the whole add-on end to end (about 3 min)
```

The harness runs `manage.js` in Nashorn (JDK 11 `jjs`): a local JDK 11 if there is one,
else the `eclipse-temurin:11-jdk` Docker image. The container tests need Docker and an
AlmaLinux 9 image that boots systemd (`r3e-node` by default: `almalinux:9` with
procps-ng, iproute and findutils; `tests/node/run.sh` also needs glusterfs-server and
glusterfs-fuse for its FUSE test). Both download the Syncthing release once into
`~/.cache/stsync-test`, or take it from `STSYNC_TEST_TARBALLS`; the nodes still check the
pinned sha256.

`tests/e2e/run.sh` runs the real platform script against the real runner and Syncthing on
a WordPress-like tree: an install refused while the master's copy is empty, install on
three nodes that hold different content (the master's copy wins, every differing file of
the others is kept in their version store, files two joining nodes share and the master
lacks survive on neither, every node ends with the same global state), edits and
deletes, ignore rules, Configure, a redeploy, scale out with a copied node, scale in,
Status, Rescan and uninstall. `tests/node/run.sh` also restarts a node during its join
(the join resumes), holds a join to check that it waits for a sending node of its list,
and removes Syncthing during a join (its conflict copies leave the webroot).

## License & contribution

MIT, see [LICENSE](LICENSE). Bug reports, test results, ideas and pull requests are
welcome: see [CONTRIBUTING.md](CONTRIBUTING.md). File bugs and feature requests at
<https://github.com/stackharbor-devops/syncthing-multi-region/issues>. Report security
problems privately, as described in [SECURITY.md](SECURITY.md).
