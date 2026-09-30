# Operations runbooks

For v0 preview. Commands run as root. `sfsctl` runs on the control-plane node (first
storage node of the primary env, `<cluster>-1`); open it with Web SSH. Every `sfsctl`
command prints one JSON document; job commands accept `--wait --timeout SECONDS`.
Node ids in the control plane are `<region>-<jelastic node id>`.

Health at a glance: `sfsctl status --json`, or Advanced Management > Overview.

## Add a storage node

1. Dashboard: scale out the **Storage** layer of the region env (+1 or more nodes).
2. `onAfterScaleOut` installs `sfs-node`, mints a one-time token and enrolls each new node
   with roles `volume,filer`. Check: `sfsctl node list` shows the node `online` within a
   minute (heartbeat every 30 s).
3. Press **Rebalance** on the card (or `sfsctl rebalance --wait`). The monitor also
   rebalances by itself when capacity skew exceeds 20%.
4. If enrollment failed (card event error): on the new node run
   `sfs-node status` and retry from the card, or mint a token manually:
   `sfsctl enroll-token --region R --node-id N --roles volume,filer --ip IP`, then on the
   node `sfs-node enroll --cp https://CPIP:8480 --token T --ca-fingerprint F --region R
   --node-id N --ip IP --roles volume,filer`.

## Remove a storage node

1. Card menu **Remove Node** (or scale in the layer). v0 refuses master nodes and the
   control-plane node.
2. The node is drained: `sfsctl node drain <region>-<id> --wait` moves its volumes away
   (`volumeServer.evacuate`, falling back to `volume.move`). Status becomes `drained`.
3. On the node, `sfs-node drain-check` must report `{"volumes":0}`; then
   `sfs-node remove --purge`, `sfsctl node remove <region>-<id>`, and the node is deleted.
4. A dead node that cannot be drained: after it has been offline for more than 24 h,
   `sfsctl node remove <id> --force`, then **Heal** to restore the replica count.

## Add a region

1. Card on the primary env > **Add Region**: platform region, region name, node count.
2. A new env `<cluster>-<n>` is created in that platform region; its nodes enroll against
   the primary control plane (masters first). `sfsctl region list` shows it.
3. The control plane starts `weed filer.sync` between the primary and the new region
   within 30 s. Check Advanced Management > Replication (status and lag).
4. Needs private connectivity between regions for 8888/18888 and 8480.

## Node failure

1. Symptom: health `replication_local degraded`, node `offline` in `sfsctl node list`.
2. Reads and writes continue (every file has 2 copies with `010`).
3. After 5 minutes of under-replication the monitor starts a heal job
   (`volume.fix.replication -apply`). Manual: `sfsctl heal --wait`.
4. If the node comes back, it rejoins by itself (systemd units, same certificate).
   If it is gone for good, remove it (see above, `--force`) and add a replacement.
5. Suspected disk corruption: `weed shell` > `volume.scrub`; for each replica it flags:
   `lock; volume.delete -node <host:port> -volumeId <vid>; volume.fix.replication -apply; unlock`.

## Master failure

A 3-master region elects a new leader in 12-14 s; writes may fail for about 20 s, clients
must retry. A 1-master region (fewer than 3 nodes) has no master redundancy: restart the
node; data is safe on the volume servers, but writes stop until it is back.

## Region failure

1. The other regions keep serving their own copy (cross-region replication is
   asynchronous; the last seconds of writes may not have crossed).
2. If the primary region is down, the control plane and Advanced Management are down too;
   the data plane in other regions is unaffected. There is no automatic control-plane
   failover in v0.
3. When the region returns, `filer.sync` resumes from its checkpoint and catches up
   (tested for short cuts). Check Replication status for `lastError`.
4. A region lost for good: remove its env, then `sfsctl region remove <name>` after its
   nodes are marked removed.

## Backup and restore

- Backup now: card **Backup Now** or `sfsctl backup now --wait`. List: `sfsctl backup list`.
- Schedule and target: Advanced Management > Backups > Policy (admin). Default target
  `/var/lib/sfsctl/backups` on the control-plane node; each backup is
  `<target>/<id>/manifest.json` + `data/`. Copy that directory off the node for safety.
- Restore: Advanced Management > Backups > Restore: choose a path inside the backup and a
  target path on the filesystem; follow the job in Jobs. Restores are written as new files
  and never delete anything.

## Upgrade SeaweedFS

v0 pins 4.48 (sha256 in `sfs-node.sh` and `sfs-mount.sh`). To upgrade:
1. Verify the new release against the lab (`tests/e2e/run-all.sh` with the new binary).
2. Update the version and both sha256 pins in `sfs-node.sh` and `sfs-mount.sh`.
3. One node at a time, masters last: `sfs-node install --version X && systemctl restart
   sfs-volume sfs-filer` (and `sfs-master`), waiting for `sfsctl status --json` to show
   the node `online` and no under-replicated volumes before the next node.
Automated rolling upgrade is on the roadmap.

## Rotate secrets

- **Local admin token** (`/etc/sfsctl/local.token`): write a new random value
  (`openssl rand -hex 32 > /etc/sfsctl/local.token; chmod 600`), then
  `systemctl restart sfsctl`.
- **API tokens**: Advanced Management > API Tokens > revoke and create a new one.
- **SSO sessions**: `systemctl restart sfsctl` does not end sessions; delete sessions by
  rotating the cluster secret (below) or signing out.
- **Cluster secret** (`secret` in `/etc/sfsctl/config.json`): it signs all tokens and
  derives the volume JWT keys. Rotating it invalidates every API token, session and enroll
  token, and requires re-enrolling every node so the new JWT keys reach `security.toml`.
  Procedure not automated in v0 (see ROADMAP).
- **Node certificates** (365 days): re-enroll the node with a new token.
- **Cluster CA** (10 years): replacing it means re-enrolling every node and every mount
  client. Not automated in v0.
