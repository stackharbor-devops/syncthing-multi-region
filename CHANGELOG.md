# Changelog

What changed in each version of the package, newest first. Releases are tagged `vX.Y`
on the main branch.

## 0.1.0 - unreleased

First working version: one environment, one app layer. Tested in Docker (systemd
containers, the real Syncthing and the real platform script), not yet on a live platform.

- **Keeps a directory identical on every node of the app layer** (default
  `/var/www/webroot/ROOT`) with Syncthing 2.1.5, pinned and sha256-checked. Each node reads
  its own local copy; no NFS or FUSE mounts. Nodes talk only over the private network
  (TCP 22000, certificates); discovery, relays, NAT, usage reports, upgrades and the
  outside web interface are off.
- **Safe install and joins.** The master's copy is the starting content (or the node named
  in the install form); the install is refused when that copy is empty or holds less than
  half the files of another node's. Other nodes, and nodes added later, first only
  receive from a node that sends - never from another joining node alone - move their
  own differing and extra files into their version store, then start sending: a stale or
  copied node never overwrites the cluster, and a file several joining nodes share
  survives on none of them. A join interrupted by a restart resumes on its own; Syncthing
  state left from an earlier install is reset on a new install.
- **Settings that survive** scale out and in, redeploy, migration and environment clone:
  kept in the app layer's node group data (`stSync`) and re-applied on every event. A node
  created as a copy of another gets its own identity; a redeployed node keeps its own.
- **Card buttons:** Status (per-node sync state, peers, errors, conflict copies; nodes whose
  copy diverged, receive-only nodes without a join), Configure (ignore rules, change
  delay, days to keep old versions), Rescan. Uninstall never fails and leaves every file
  in place; old versions, and the conflict copies of an unfinished join, go to
  `/root/stsync-versions-<time>`.
- **File versions:** replaced and deleted files are kept 14 days (configurable) outside
  the webroot.
- Firewall: TCP 22000 allowed into the app layer when the account's firewall is on.
- Refuses a directory on NFS or FUSE, and a node that runs the File Synchronization add-on
  (lsyncd).
- Tests: node runner tests, platform script unit tests and an end-to-end test on a
  WordPress-like tree (`tests/`).
- Repository created: design, roadmap, contributor files and automatic checks.
