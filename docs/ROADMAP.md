# Roadmap

Every known remaining task for v0 -> v1, ordered by priority area. Items marked
`TODO(sfs)` also have a comment at the exact place in the code. "Live" means it needs a
real Jelastic platform to prove.

## 1. Architecture

- Decide the master-set migration procedure: growing a region from 1 to 3 masters rewrites
  `-peers` on re-enroll but does not migrate the Raft state in `/var/lib/sfs/master`
  (TODO(sfs) in `scripts/node/sfs-node.sh`, above `weed_args`). Needs an ordered procedure
  driven by the control plane.
- Control plane HA (today one instance on the primary region's first node). Out of v0 scope.
- ARCHITECTURE.md section 5 still describes heal as "fix.replication then volume.fsck";
  the e2e lab proved `volume.fsck` misses on-disk corruption (see section 7 below).

## 2. Control plane

- Per-IP rate limit for the unauthenticated `/api/v1/enroll` and `/sso`
  (TODO(sfs) in `control-plane/sfsctl/server.py`, `App._build_routes`).
- Heartbeat with an enroll secret for nodes without a certificate (section 5 says "or
  enroll secret"); only mTLS node certs and operator credentials are accepted now.
- `install.sh --tarball URL` (used by the JPS deploy) was not exercised; only `--src`.
- (done) `.gitignore` ignores `__pycache__/`.
- Master HTTP API is called over plain `http://`; revisit if `[https.master]` is enabled.
- Leader awareness: ops use any reachable master, not necessarily the Raft leader.
- `seaweed.filer_upload` reads whole files into memory (TODO(sfs) in `seaweed.py`).

## 3. JPS deploy

- Live: does root-level `region: ${settings.region}` place the env; is `diskLimit` in GB
  (TODO(sfs) in `manifest.jps`).
- Live: does the `install:` action with `nodeGroup` give the card an Uninstall entry.
- Live: `${user.uid}` / `${user.email}` in button actions.
- Deploy installs nodes one after another; parallelise with ExecCmdByGroup if slow.
- All `.jps` files hard-code the main-branch `baseUrl`; branch testing means editing four
  files.
- The control plane tarball URL is derived from a GitHub `baseUrl`; other hosts fail deploy.
- Live: the nginx `bl` node - SLB forwards `https://<env domain>/` to port 80 with
  `X-Forwarded-Proto: https`; reload method (`nginx -s reload` vs systemctl); whether
  `/var/lib/jelastic/SSL/jelastic.chain` exists; `server_names_hash_bucket_size` for long
  domains.

## 4. Enrollment

- Enroll source-IP check must be proven on the platform (`enrollCheckSourceIp`, set false
  if cross-region traffic is NATed).
- No CRL: removed nodes' certificates stay valid until expiry (365 days). Add a CRL or a
  deny list checked by the control plane and pushed to nodes.
- Client role (`client`, cert only, for mounts) added by the integrator: covered by the
  local smoke test up to token minting; the full `sfs-node enroll --roles client --no-start`
  path has not run against the real control plane.

- Heartbeat URL fixed by the integrator (runner now reads `node.id` from the enroll
  response); verify on a live node that `sfsctl node list` turns `online` from heartbeats.

## 5. Add node

- Live: `onAfterScaleOut[storage]` with `forEach(event.response.nodes)` enrolls new nodes.
- No "Add Node" button; scaling the layer in the dashboard is the way.
- New nodes get volume + filer only; there is no promotion to master.

## 6. Rebalancing

- `volume.balance -apply` (4.48; the e2e lab used `-force`, which the cp-ops agent found
  absent from `weed shell help volume.balance`): confirm on the real binary which spelling
  applies and align `tests/e2e/s1-add-node.sh` or `sfsctl/ops.py`.
- `volumeServer.evacuate -apply` never succeeded in the lab; drain completed via the
  `volume.move` fallback loop. Verify on real multi-host nodes.

## 7. Self-healing

- Heal should run `volume.scrub` (and/or `fs.verify /`) and repair flagged replicas with
  `volume.delete -node <host:port> -volumeId <vid>` + `volume.fix.replication -apply`
  (proven in `tests/e2e/s5-integrity.sh`); today heal runs fix.replication +
  `volume.check.disk` (report only), which does not detect content corruption.
- security.toml `[guard] white_list` is not set; `jwt.filer_signing` is not set, so the
  filer HTTP API (8888) is unauthenticated inside the private network (TODO(sfs) in
  `sfs-node.sh` and `docs/SECURITY-MODEL.md`).

## 8. Backups

- S3 targets (`set_policy` rejects `s3://`), incremental snapshots, and real
  point-in-time recovery via `weed filer.backup` / `filer.meta.backup` (TODO(sfs) in the
  `sfsctl/backups.py` docstring).
- Restore should write with `tar --no-acls --no-xattrs` semantics or explicit chmod
  (SeaweedFS 4.48 stores POSIX ACL xattrs without updating the mode; `cp -a` gives 0600).

## 9. Add region

- New env name `<cluster>-<regions+1>` can collide after a region was removed
  (TODO(sfs) in `scripts/jps/ops.js`, `opAddRegion`).
- Both region envs must belong to the same user (ExecCmdById on the primary env).
- Live: `marketplace.jps.install` with `region` via `onAfterReturn`.

## 10. Async replication

- `replication.status` lag comes only from filer.sync log lines; use `-metricsPort`
  counters (TODO(sfs) in `sfsctl/replication.py`).
- Not tested: filer.sync restart during a link cut, cuts longer than the metadata log
  retention, same-path concurrent writes (last-writer-wins).
- filer.sync with mTLS across regions (`-a.security` / `-b.security`) not tested.

## 11. SSO

- Live: that the dashboard renders the info popup body as HTML so the link is clickable
  (dashboard side verified from its source; engine side not).

## 12. Monitoring

- Health monitor thresholds are fixed (80/90% disk, 5 min under-replication, 20% skew);
  make them configurable. No external metrics export (Prometheus) yet.

## 13. UI

- Only tested against `mock.js`; run it against the real API (the local smoke test covers
  `/ui/` auth and the JSON endpoints it calls, not a browser session).
- `uptimeSeconds` in GET `/api/v1/cluster` is shown by the UI but not returned.
- Consider excluding `mock.js` from `/opt/sfsctl/ui` (inert unless `?mock=1`).
- Mount add-on: `sourceEnv` is free text (could be a list); add a `--force-move` checkbox.

## 14. Failure tests

- Re-run `tests/e2e/s1-s5` with mTLS and JWT enabled (security.toml), and with the real
  `sfs-node` runner instead of raw `weed` processes.
- `tests/e2e/lab.sh` `leader_of` fix has not been through a full run.
- amd64 not tested (only sha256 pins); Debian/Ubuntu app images for `sfs-mount` untested.
- mount with several filers in `--filer`, and with volume JWT signing enabled.

## 15. Docs

- Replace `docs/TEST-RESULTS.md` lab numbers with live-platform numbers after the first
  install; record the answers to the "Live" items above in `docs/PLATFORM-NOTES.md`.
