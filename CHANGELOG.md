# Changelog

What changed in each version of the package, newest first. Releases are tagged `vX.Y`
on the main branch.

## Unreleased

v0 preview of the SeaweedFS-based storage platform. Tested locally only; not yet installed
on a live Jelastic platform.

- Design switched from Syncthing to SeaweedFS 4.48 (pinned, sha256-verified):
  `docs/ARCHITECTURE.md`, `docs/PLATFORM-NOTES.md`, `docs/SECURITY-MODEL.md`.
- Control plane `sfsctl` (Python 3.9 stdlib): REST API with RBAC, CSRF and audit; cluster
  CA and one-time enroll tokens; node registry and mTLS heartbeats; jobs for rebalance,
  heal, drain, backup and restore; health monitor with self-healing; `filer.sync`
  supervisor for cross-region replication; SSO into the Advanced Management UI; `sfsctl`
  CLI; `install.sh` and systemd unit.
- Advanced Management web UI (vanilla HTML/CSS/JS): overview, nodes, regions,
  replication, backups, jobs, audit, API tokens.
- Node runner `sfs-node` (install, enroll, services, heartbeat timer, drain-check, remove)
  and mount runner `sfs-mount` (FUSE mount as a systemd unit, mTLS).
- JPS: `manifest.jps` (install), `addons/cluster.jps` (card: status, SSO, rebalance, heal,
  backup, add region, remove node; scale events), `addons/region.jps`, `addons/mount.jps`,
  `scripts/jps/ops.js`; nginx ingress for the `bl` node (`control-plane/nginx`).
- Enrollment role `client` (certificate only) for mount clients; the node runner does not
  start the heartbeat timer for it.
- Node runner heartbeats now use the control-plane node id from the enroll response
  (`node.id`, `<region>-<nodeId>`); before, they posted to the bare Jelastic node id and
  would have been rejected with 404.
- SSO button shows a clickable HTML link (the dashboard popup body is HTML).
- API tokens accept `expiresInDays` (UI) as well as `ttlDays`.
- Tests: 73 unit tests, `tests/smoke/local.sh` control-plane smoke test, Docker failure
  scenarios `tests/e2e/s1-s5` (`docs/TEST-RESULTS.md`), mount e2e tests.
- Docs: README rewritten, `docs/OPERATIONS.md` runbooks, `docs/ROADMAP.md`.
