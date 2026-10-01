# Add-on design (v0.1) - build contract

Scope of v0.1: one environment, the app layer (`cp`). Install, Configure (ignore rules,
delay, versioning), Status, Rescan, Uninstall; scale out / scale in, redeploy, migrate and
clone handling; safe joins; persistent settings. Multi-region, single-writer paths and
load-balancer health gating are later milestones (README roadmap).

Engine: **Syncthing 2.1.5** (pinned). Release assets and sha256 (from the signed
`sha256sum.txt.asc` of the release):

| Asset | sha256 |
|---|---|
| syncthing-linux-amd64-v2.1.5.tar.gz | 3d222b609f7ab2944e02748cb10488b4160d446b49e0eafc107ef2a525ab3486 |
| syncthing-linux-arm64-v2.1.5.tar.gz | 3666f3069feeee3651e185f867759206059755101797bdd69ea5317610130855 |

URL: `https://github.com/syncthing/syncthing/releases/download/v2.1.5/<asset>`.

## 1. Behaviours already proven in the lab (Syncthing 2.1.5, 3 nodes)

- Empty receive-only nodes pull 200 files in about 4 s; edits reach the other nodes in about
  2.3 s with `fsWatcherDelayS: 1`.
- A delete made while a node is offline reaches it when it returns; the file stays deleted.
- `.stignore` rules are local to each node (never synced); ignored files are neither sent
  nor deleted.
- Concurrent edits of one file: newer wins everywhere, the other becomes a
  `*.sync-conflict-*` copy on every node.
- A stale node joining **send-receive** pushes its local-only files and old versions (as
  conflict copies) into the cluster. Joining **receive-only**, then `POST /rest/db/revert`,
  then switching to send-receive leaves the cluster untouched; with trashcan versioning the
  joiner's differing files are moved into its version store, not lost. (Measured in the
  e2e test: a joiner's file that differs from the cluster's, older or newer, is first moved
  aside as a `*.sync-conflict-*` copy on the joiner only; the revert then moves that copy,
  and every local-only file, into the version store. So kept files may carry the
  conflict-copy name.)
- `POST /rest/db/revert` on a receive-only folder records a file that exists only on that
  node as **deleted with an empty version vector**. A second joiner that holds the same
  file sees that record as the global state, and its own revert keeps its copy, also with
  an empty version: equal versions, no winner, `receiveOnlyTotalItems` 0 - the nodes stay
  different for good (reproduced by the review of v0.1 with 3 nodes). So the join sets
  such files aside itself before the revert (section 3). `GET /rest/db/file` answers 404
  for a file that only this node's receive-only changes know; after another joiner's
  revert it answers `global: {deleted: true, version: []}`.
- `POST /rest/config/folders` with a partial object fills the rest from defaults
  (`maxConflicts` 10, `rescanIntervalS` 3600, and so on). `PATCH` changes only given fields.
  `PUT /rest/config/devices` adds and updates devices but never removes one (measured on
  2.1.5); `DELETE /rest/config/devices/<id>` removes one and answers 200 even when it is
  missing.

## 2. Files

```
manifest.jps            the add-on (type: update, targetNodes nodeGroup cp)
scripts/manage.js       platform-side orchestration (Cloud Scripting JS, like the
                        GlusterFS backup add-on's manage.js): ops apply | status | rescan
scripts/stsync.sh       node runner, installed as /usr/local/sbin/stsync
tests/                  node-runner tests and end-to-end tests (Docker, systemd image)
```

## 3. Node runner `stsync` (bash, run as root through ExecCmd)

Machine-readable output lines (anything else is human text):
`STSYNC_RESULT=ok|failed`, `STSYNC_MESSAGE=<one line>`, plus per-command lines below.
Exit code 0 only with `STSYNC_RESULT=ok`.

Paths: binary `/usr/local/bin/syncthing`; home `/var/lib/stsync` (config, keys, database,
`apikey`, `bound`), owned by the run user; versions `/var/lib/stsync/versions/<folder>`
(outside the webroot, so old files are never served); env file `/etc/stsync.env` (0600
root): `STGUIADDRESS=127.0.0.1:8384`, `STGUIAPIKEY=<apikey>`, `STNOUPGRADE=1`,
`STDBDELETERETENTIONINTERVAL=0` (never forget deletes); unit
`/etc/systemd/system/stsync.service`:
`User=<run user>`, `EnvironmentFile=/etc/stsync.env`, `ExecStartPre=+/usr/local/sbin/stsync guard`,
`ExecStart=/usr/local/bin/syncthing serve --home=/var/lib/stsync --no-browser --no-restart
--log-file=/var/lib/stsync/syncthing.log --log-max-size=10485760 --log-max-old-files=3`,
`ExecStartPost=-+/usr/local/sbin/stsync join --folder <F>` (resumes a join a restart
interrupted; a no-op on a send-receive folder; `-` so it never fails the service),
`Restart=on-failure`, `RestartSec=5`, `LimitNOFILE=65536`, WantedBy multi-user.target.
`/etc/jelastic/redeploy.conf` must list `/var/lib/stsync` (identity and database survive a
redeploy; binary and unit are re-created by `prepare`).

Commands:

- `prepare --path P --ip IP` - refuse (failed + clear message) when: P is not an absolute
  existing directory; P is on a network or FUSE filesystem (`findmnt -rn -o FSTYPE --target P
  | tail -n 1` in nfs*, fuse*, glusterfs, cifs, smb*, ceph, 9p, autofs); an `lsyncd` process
  runs ("remove the File Synchronization add-on first"). Run user = owner of P
  (`stat -c %U`). Install the pinned binary if missing or another version (verify sha256,
  pick amd64/arm64 by `uname -m`). Create home, apikey (random 32 chars, kept), env file,
  unit, redeploy.conf entry. **Clone guard:** if `/var/lib/stsync/bound` exists and its
  hostname differs from `hostname`, this is a copy of another node: stop the service, delete
  `cert.pem key.pem config.xml` and the database (keep nothing that identifies the other
  node), print `STSYNC_CLONED=1`. Generate identity if missing (`syncthing generate
  --home=/var/lib/stsync --no-port-probing` as the run user). Write `bound` = current
  hostname. `systemctl daemon-reload; systemctl enable --now stsync`; wait until
  `GET /rest/system/ping` answers (max 60 s). Prints `STSYNC_DEVICE=<device id>`,
  `STSYNC_USER=<run user>`, `STSYNC_FOLDER_TYPE=none|receiveonly|sendreceive|sendonly`
  (from `GET /rest/config/folders/<id>` when `--folder` is given), `STSYNC_JOIN=none|running|done`.
- `guard` - exit 1 when `bound` exists and differs from `hostname` (keeps a cloned container
  from syncing until the add-on re-applies), else 0.
- `ignore --path P --b64 B` - write `P/.stignore` atomically as the run user (content =
  base64-decoded B).
- `api --plan-b64 B` - B decodes to lines `METHOD PATH BODY_B64_OR_-`; run each against the
  local API (`X-API-Key` from the apikey file) in order; stop at the first HTTP status
  >= 400; print `STSYNC_API_<n>=<status>`; failed if any failed.
- `join --folder F [--from IDS]` - start a detached job (setsid, log
  `/var/lib/stsync/join.log`, state `/var/lib/stsync/join.state` with a `phase=` line):
  wait until a peer listed in `/var/lib/stsync/join.from` (IDS: the device ids of the
  send-receive nodes, comma-separated; written on every call, even while a join runs,
  and kept for a join resumed at boot) is connected and shares the folder - never another
  joiner alone; with no list, keep waiting. Then until the folder is idle with
  `needTotalItems` 0 for 15 s in a row. Then **set aside**: for every item of `GET
  /rest/db/localchanged` whose global version is missing (404 from `/rest/db/file`),
  deleted, invalid or has an empty version vector, move the file into
  `/var/lib/stsync/versions/F/<same path>` (mtime set to now, like the trashcan; kept
  even with versioning off, since it exists nowhere else) and remove such directories
  once empty; if anything moved, `POST /rest/db/scan` and wait idle. Then
  `POST /rest/db/revert?folder=F`; wait idle (set aside and revert up to 3 times while
  local changes remain); `PATCH /rest/config/folders/F {"type":"sendreceive"}`; state
  `done`. Idempotent (does nothing when a join is running or the folder is already
  send-receive).
- `status --folder F --path P` - `STSYNC_JSON=<one-line JSON>`: `{service, version, device,
  user, folderType, state, needItems, needBytes, globalFiles, globalDirectories,
  globalDeleted, globalBytes, localFiles, errors, connectedPeers, totalPeers, conflicts
  (count of *.sync-conflict-* under P, excluding .stversions, capped 1000), join,
  joinPhase, lastScan, inotifyLimit}`.
- `rescan --folder F` - `POST /rest/db/scan?folder=F`.
- `remove --path P` - stop/disable the service, delete unit, env file, binary and runner;
  delete `/var/lib/stsync` except `versions/` (if non-empty, move it to
  `/root/stsync-versions-<timestamp>` and say so); remove `P/.stfolder` and `P/.stignore`;
  remove the redeploy.conf entry. Never touch other files under P, with one exception:
  when the folder at P is still receive-only (config.xml; a join that never finished),
  its `*.sync-conflict-*` copies under P are the join's (the node's old versions of
  differing files, old PHP among them) and move to the kept versions, same paths.

Added while building (the runner's header and `tests/node/run.sh` have the details):
`prepare --fresh` (a first install) resets any state already in `/var/lib/stsync` the way
the clone guard does (keeping `versions/`) and prints `STSYNC_RESET=1`; `prepare
--count-b64 B` also prints `STSYNC_FILES` and `STSYNC_BYTES` of P (regular files and
symlinks, leaving out Syncthing's markers, temporary files, conflict copies and what the
base64 ignore rules B match - the common .stignore forms, `-` for no rules).
`prepare` also writes the private options of section 4 step 4 into a fresh `config.xml`
before the first start (so a new node never contacts anything outside); the unit also has
`StartLimitIntervalSec=60` and `StartLimitBurst=4` (a cloned node's unit stops retrying
after about 20 s); `status` also has `error` (folder or file-watcher error) and `join` can
be `failed`; `remove` prints `STSYNC_VERSIONS_KEPT=<dir>` (the whole `versions/` moves, so
old files are under `<dir>/<folder>/`). Test hooks: `STSYNC_DOWNLOAD_BASE` replaces the
GitHub release URL (the sha256 check still runs), `STSYNC_JOIN_IDLE_S` the 15 s.

## 4. Platform side `scripts/manage.js`

Runs as a Cloud Scripting `script:` (context: `appid`, `session`, `getParam`, `jelastic.*`,
`toJSON`), same patterns as the GlusterFS backup add-on's `manage.js`
(`git show origin/backup-v2:scripts/backup/manage.js` in the GlusterFS repo): params parsed
with unresolved placeholders treated as empty, `ok()/fail()`, node commands through
`jelastic.env.control.ExecCmdById(envName, session, nodeId, toJSON([{command}]), true, "root")`,
`ExecCmdByGroup` for group-wide commands.

Settings live in the `cp` node group's data under the key **`stSync`** (JSON string,
written per key with `ApplyNodeGroupData`; never `globals`):
`{v:1, path, folderId:"webroot", ignore, delay, versionsDays, seedNodeId, nodes:
{"<nodeId>": {device, joinedAt, type}}, updated}` (`type`: the folder type at the last
apply; a joiner turns send-receive on its own later, so `sendreceive` is never wrong). A failed read throws (never treated as "no
settings"). Defaults: path `/var/www/webroot/ROOT`, delay 2 s, versionsDays 14, ignore:

```
// Caches, logs and temporary files: each node keeps its own
(?d)/wp-content/cache
(?d)/wp-content/upgrade
(?d)*.log
(?d).DS_Store
(?d)Thumbs.db
```

`op apply` (phases install | configure | scale | redeploy | migrate | clone):
1. Load settings; merge form values on install/configure (path is fixed after install).
2. For every running node of `cp`: download the runner from `<basePath>/scripts/stsync.sh`
   (cache-busted) to `/usr/local/sbin/stsync`, then `stsync prepare --path P --ip <intIP>
   --folder webroot` (on a fresh install - phase install, no saved settings - also
   `--fresh --count-b64 <ignore rules>`). Collect device ids, folder types, clone and
   reset flags, file counts. On install/configure a failure fails the operation with the
   node and message; on events, skip the failed node and report it.
3. Seed: if no node has a send-receive folder (and no saved node that did not answer may
   have one), the seed is the node named by the install form's `seedNode`, else the
   layer's master node (or the lowest id). A fresh install without `seedNode` is refused
   (Syncthing taken off again, nothing saved) when the seed's `STSYNC_FILES` is 0 while
   another node's is not, or less than half the largest other node's; the message names
   the nodes, counts and sizes. The seed creates the folder send-receive; every other
   node without the folder creates it **receive-only** and starts `stsync join --from
   <IDS>`, IDS = the device ids of the send-receive nodes (the seed, nodes already
   send-receive, and saved nodes of type `sendreceive` that did not answer), without the
   node's own. Nodes already send-receive or joining keep their type; a joining node gets
   the list again.
4. For every node, one `stsync ignore` then one `stsync api` plan:
   `PATCH /rest/config/options` `{listenAddresses:["tcp://<ip>:22000"],
   globalAnnounceEnabled:false, localAnnounceEnabled:false, relaysEnabled:false,
   natEnabled:false, urAccepted:-1, crashReportingEnabled:false, autoUpgradeIntervalH:0,
   startBrowser:false}`; `PUT /rest/config/devices` (every node incl. itself, name
   `node<id>`, addresses `["tcp://<ip>:22000"]`); folder `POST` (new: id `webroot`, label,
   path, type, `fsWatcherDelayS`, devices, versioning `{type:"trashcan",
   params:{cleanoutDays:"<versionsDays>"}, fsPath:"/var/lib/stsync/versions/webroot"}`) or
   `PATCH` (existing: devices, fsWatcherDelayS, versioning); then
   `DELETE /rest/config/devices/<id>` for retired devices (saved in `nodes` but no longer in
   the mesh: nodes scaled in, or a node whose identity changed; never a device a current
   node still uses). A node that left stays in `nodes` until an apply finishes with no
   failed node, so a node that missed the removal gets it on the next apply.
5. Firewall (best effort, only when the account's firewall is enabled): INPUT ALLOW TCP 22000
   on `cp` (see `setupFirewall` in the GlusterFS repo's cluster-logic.jps on the
   fix-cluster-logic branch). Syncthing listens only on the private IP.
6. Save settings (read back to confirm). Return a summary.

`op status`: `stsync status` on every node; return `{result:"info", message}` with one block
per node (service, device short id, folder type/join and its phase, state, need items,
peers x/y, errors, conflicts) and an overall line (in sync / syncing / problems). A
problem also: receive-only with no join running; a failed join; **diverged** - nodes that
report in sync but whose `globalFiles/globalDirectories/globalDeleted/globalBytes`
differ from the largest group of in-sync nodes (all of them on a tie). A receive-only
node's conflict copies are shown as temporary and not counted in the "to review" line.

`op rescan`: `stsync rescan` on every node.

## 5. `manifest.jps`

`type: update`, `targetNodes: {nodeGroup: cp}`, `globals: {base_path: ${baseUrl}}`.
Settings form `main` (install and Configure, `submitUnchanged: true`): path (string,
default above; shown read-only on Configure via onBeforeInit or a note), ignore (text),
delay (spinner 1-60), versionsDays (spinner 0-365; 0 = no versioning), seedNode (string,
optional, digits: the starting copy's node id; install only, onBeforeInit removes it on
Configure). Buttons: Status,
Configure, Rescan. Events: `onInstall` apply/install; `onAfterScaleOut[cp]`,
`onAfterScaleIn[cp]` apply/scale; `onAfterRedeployContainer[cp]` apply/redeploy;
`onAfterMigrate` apply/migrate; `onAfterClone` apply/clone on
`${event.response.env.envName}` (the copy gets new identities and its own mesh).
`onUninstall`: inline, best effort, never fails (download the runner if missing, `stsync
remove` on every node, clear `stSync`), so the card can always be removed.

## 6. Tests (must run locally before a push)

- `bash -n`, `python3 .github/scripts/check.py`, `node --check` on JS.
- End to end in Docker with the systemd image `r3e-node` (AlmaLinux 9): run the real
  `manage.js` in Nashorn (JDK 11 `jjs`, available on this Mac and in eclipse-temurin:11-jdk)
  with a stub `jelastic` whose ExecCmd runs `docker exec` on the containers, and assert:
  install on 3 nodes with different existing content (seed wins, joiners' differences in
  their version store, nothing lost); propagation; ignore rules applied and persisted after
  a simulated redeploy (binary and unit deleted, `/var/lib/stsync` kept, apply/redeploy);
  scale out with a container cloned from a node (`docker commit`, new hostname: guard blocks
  it, apply/scale gives it a new identity and a safe join, the cluster is unchanged); scale
  in; Configure changing ignore rules; uninstall leaves files in place.

Added after the v0.1 review: install refused while the master's copy is empty; two
joiners holding the same file the seed lacks (it must survive on neither, and every node
must end with the same global state); a node restarted during its join (the join resumes
from the unit); a join held while only non-listed peers share the folder; `prepare
--fresh`; remove during a join.

Where they are: `tests/node/run.sh` (the runner, for real, in systemd containers),
`tests/harness/run-unit.sh` (manage.js and the manifest's inline scripts against scripted
nodes), `tests/e2e/run.sh` (the scenario above, on a WordPress-like tree). The README's
Tests section has the commands.
