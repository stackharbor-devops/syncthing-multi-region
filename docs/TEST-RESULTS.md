# End-to-end test results (SeaweedFS 4.48 data plane)

Run date: 2026-09-30. Binary: `weed version` -> `30GB 4.48 530be3e37337488ecc34d58441e0bc476e121c93 linux arm64`
(release asset `linux_arm64.tar.gz`). Host: Docker Desktop (arm64), image `almalinux:9`, one
container per weed process, one Docker network per region.

These tests cover the storage behaviour the platform relies on. They do not cover TLS/JWT
(`security.toml`), the control plane or the JPS add-ons.

## How to run

```sh
gh release download 4.48 -R seaweedfs/seaweedfs -p linux_arm64.tar.gz   # or linux_amd64 on x86 hosts
tar xzf linux_arm64.tar.gz                                              # -> ./weed
export WEED_BIN=$PWD/weed            # linux weed binary, bind-mounted read-only into containers
export LAB_LOGDIR=/some/dir          # optional, weed shell logs per scenario (default $TMPDIR/sfse2e-logs)
tests/e2e/run-all.sh                 # s1..s5 in order, tears the lab down at the end (KEEP_LAB=1 keeps it)
tests/e2e/s4-cross-region.sh         # or any single scenario
```

`tests/e2e/lab.sh` is a sourceable library: `lab_region_up <region> <nVolumeServers>`,
`lab_volume <region> <i>`, `wshell <region> < cmds`, `vol_map`, `vol_copies`, `leader_of`,
`write_files <region> <tag> <n>`, `verify_files <region> <tag> [readRegion]`, `lab_down`.

Lab topology per region `R` (network `sfse2e-R`):

```
weed master -ip=sfse2e-R-mI -port=9333 -mdir=/data \
  -peers=sfse2e-R-m1:9333,sfse2e-R-m2:9333,sfse2e-R-m3:9333 -defaultReplication=010 -volumeSizeLimitMB=4
weed volume -ip=sfse2e-R-vI -port=8080 -dir=/data -max=100 \
  -master=<the 3 masters> -dataCenter=R -rack=rackI
weed filer  -ip=sfse2e-R-filer -port=8888 -master=<the 3 masters> -defaultReplicaPlacement=010
```

`-volumeSizeLimitMB=4` is a test-only setting so a few thousand small files span several
volumes and balance/heal have something to move. Files: random 1-12 KiB, sha256 manifest
kept on the client; upload with `weed filer.copy -c=16 <localdir> http://filer:8888/e2e/`;
every file read back through the filer HTTP API and compared.

## Results summary

| # | Scenario | Result | Key timing |
|---|---|---|---|
| 1 | Add node + `volume.balance -force` | PASS | 2000 files; balance 26 s; 2 replicas moved to new node; 2000/2000 checksums OK |
| 2 | Node failure + `volume.fix.replication -apply` | PASS | master dropped dead node after 3 s; reads+writes continued while degraded; heal 31 s; 800/800 OK |
| 3 | Raft leader failure | PASS | new leader after 12 s; first write after failover completed in 20 s (filer.copy retried) |
| 4 | Cross-region `filer.sync` active-active | PASS | single-file lag 43-310 ms; 300 files converged 0-1 s after write; catch-up 2-3 s after link restore |
| 5 | Integrity (one flipped byte on one replica) | PASS | detected by direct read (HTTP 500), `volume.scrub`, `fs.verify`; repaired by delete + fix.replication |

## Scenario details

### 1. Add node (tests/e2e/s1-add-node.sh)

3 volume servers (rack1..3), replication 010, 2000 files written (2 s), all verified. Added
`sfse2e-a-v4` (`-rack=rack4`), waited for it to register, then:

```
printf 'lock\nvolume.balance -force\nunlock\n' | weed shell -master=<masters> -filer=<filer>
```

Observed: took 26 s; replicas per node after balance v1=4, v2=3, v3=3, v4=2 (before: v4=0).
Every volume still had exactly 2 copies; 2000/2000 files read back with correct sha256.

Notes: `volume.balance` without `-force` is a dry run. `lock` is required before any
mutating shell command (the shell refuses otherwise).

### 2. Node failure + self-heal (tests/e2e/s2-node-failure.sh)

4 volume servers, 500 files. `docker stop sfse2e-a-v1` (it held 4 replicas).

- The master removed v1 from the topology after 3 s (volume.list no longer shows it).
- 4 volumes under-replicated. Reads of all 500 files OK while degraded.
- 300 more files written while degraded: OK (new volumes are placed on live nodes).
- `printf 'lock\nvolume.fix.replication -apply\nunlock\n' | weed shell ...` took 31 s; log
  shows `volume N replication 010, but under replicated +1` then
  `replicating volume N 010 from <live> to dataNode <other live> ...`.
- After heal: every volume exactly 2 copies, none on the dead node; 800/800 files OK.

`volume.fix.replication` without `-apply` only reports.

### 3. Master (Raft leader) failure (tests/e2e/s3-master-failure.sh)

3 masters. Leader read from `GET http://<master>:9333/cluster/status` (`"Leader"` field has the
form `host:9333.19333`, i.e. http port then grpc port; strip the `.19333`).
`docker stop` of the leader (m1): a new leader (m3) after 12 s. Writing 200 files through
the filer afterwards succeeded, but took 20 s: the first `filer.copy` attempt(s) failed while the
filer switched to the new leader, and the retry loop (3 attempts, 3 s apart) covered it. All old
and new files verified. Right after `docker start` of the old leader, `/cluster/status` on it
returned no leader for a few seconds (it rejoins as follower).

Implication for clients/control plane: expect roughly 10-20 s of failed assigns during a leader
election; retry writes (FUSE mount retries internally).

### 4. Cross-region async (tests/e2e/s4-cross-region.sh)

Two clusters (region a, region b, 2 volume servers each, separate networks, no route between
them). One `weed filer.sync` container attached to both networks:

```
weed filer.sync -a=sfse2e-a-filer:8888 -b=sfse2e-b-filer:8888 -a.filerProxy -b.filerProxy
```

Active-active is the default (`-isActivePassive` not set). `-a.filerProxy -b.filerProxy`
makes chunk data flow through the filers, so only the filer port (8888 + grpc 18888) has to be
reachable across regions, not every volume server.

- Single-file lag probe (write via filer A, poll filer B every 0.2 s): a->b 310 ms, b->a 43 ms.
- 300 files written in a: all readable with correct sha256 from b within 0 s of the write
  finishing (checked immediately); 300 files written in b: converged in a within 1 s.
- Link cut: `docker network disconnect sfse2e-b sfse2e-sync`; 200 files written in each region;
  after 5 s the a-files were not in b (0/200), as expected.
- Link restored (`docker network connect`): a->b complete 2 s after restore, b->a 3 s after.
- No echo loop: `/e2e/s4a` has 300 entries in both regions.

Here the sync process kept running and reconnected by itself after the link came back.
Not tested: restarting the `filer.sync` process itself (it should resume from the offset it
stores in the target filer); a cut longer than the filer's metadata log retention.

### 5. Integrity (tests/e2e/s5-integrity.sh)

2 volume servers, replication 010. One 64 KiB file uploaded via the filer
(fid `5,015928eb5e`). On v1 only, one byte inside the needle data in `/data/5.dat` was flipped
(located via a marker string, changed with `dd conv=notrunc`).

| Check | Detected? | Output |
|---|---|---|
| `GET http://v1:8080/<fid>` (corrupted replica) | YES | HTTP 500 |
| `GET http://v2:8080/<fid>` (healthy replica) | n/a | HTTP 200, checksum match |
| 10 reads through the filer | no errors | 10/10 correct (filer/volume read falls back to the good replica) |
| `volume.scrub` | YES | `Got scrub failures on 1 volumes` / `Affected volumes: sfse2e-a-v1:8080:5` |
| `fs.verify /e2e` | YES | `invalid CRC for needle 1 ... data on disk corrupted ... at volume server sfse2e-a-v1:8080` |
| `volume.check.disk -slow -v` | NO | compares needle indexes between replicas: `has 1 entries ... missed 0` |
| `volume.fsck -v` | NO | finds filer/volume orphans only: `no orphan data` |

Repair that was verified:

```
lock
volume.delete -node sfse2e-a-v1:8080 -volumeId 5
volume.fix.replication -apply        # re-copies volume 5 from the healthy replica
volume.scrub                         # clean afterwards
unlock
```

After that v1 serves the file again with HTTP 200 and the correct checksum.

Conclusion for the heal job (`POST /api/v1/ops/heal`): run `volume.scrub` (content CRC) and
`fs.verify` (filer-to-needle), not only `volume.check.disk`/`volume.fsck`; for a replica that
scrub reports, delete that replica and run `volume.fix.replication -apply`.

## Full suite run (run-all.sh, 2026-09-30 05:30:47-05:34:22 UTC)

`tests/e2e/run-all.sh` exit 0, wall time 3 min 35 s, lab removed afterwards. All five PASS.
Numbers from this run (the per-scenario tables above are from the individual runs just
before it; they agree within a few seconds):

- S1: 2000 files in 2 s, `volume.balance -force` 25 s, 2 replicas on v4, 2000/2000 OK.
- S2: dead node dropped from topology after 4 s, 3 volumes under-replicated, fix 30 s, 800/800 OK.
- S3: new Raft leader after 14 s; 200 files written after failover in 20 s (retried), all OK;
  old leader rejoined as follower (leader stayed m3).
- S4: lag probe a->b 306 ms, b->a 44 ms; 300 files converged 1 s after write each way;
  catch-up after link restore a->b 2 s, b->a 3 s; 300 entries in both regions.
- S5: corrupted replica HTTP 500; `volume.scrub` -> `Affected volumes: sfse2e-a-v1:8080:2`;
  `fs.verify` -> `invalid CRC for needle 1`; `volume.check.disk -slow` and `volume.fsck` did
  not flag it; delete + `volume.fix.replication -apply` restored it (HTTP 200, checksum match).

## Not covered yet

- Security: gRPC mTLS (`security.toml`) and volume JWTs were off in this lab. TODO(sfs): rerun
  s1-s5 with the enrollment-generated `security.toml` mounted at `/etc/seaweedfs/security.toml`.
- `weed mount` (FUSE) behaviour (tests/e2e/mount/ is owned by another component).
- Restart of the `filer.sync` process during a cut, and cuts longer than metadata log retention.
- Concurrent writes to the same path in both regions (last-writer-wins not asserted).
