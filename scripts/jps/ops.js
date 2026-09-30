/*
 * sfs platform-side operations (Cloud Scripting, run by manifest.jps and addons/*.jps
 * as a `script:` loaded from the package base URL).
 *
 * Param "op":
 *   deploy        manifest onInstall: install runner + weed on every storage node, the
 *                 control plane on the primary cp node, enroll every node, nginx on bl,
 *                 save node-group data key sfsCluster.
 *   join          region.jps onInstall: install runner, enroll every storage node of this
 *                 (secondary) env into the primary control plane (cpEnvName/cpNodeId).
 *   enroll-new    onAfterScaleOut[storage]: install + enroll every storage node that has
 *                 no /etc/sfs/node.pem yet.
 *   drain         onBeforeScaleIn[storage]: drain the nodes in "nodeIds" (comma list).
 *   redeploy      onAfterRedeployContainer[storage]: reinstall runner/binary (+ control
 *                 plane on the cp node) and restart roles.
 *   status | rebalance | heal | backup | sso     card buttons (sfsctl on the cp node).
 *   remove-node   menu: drain + remove one node ("nodeId") and scale the group in.
 *   add-region    button: create region env <cluster>-<n> from addons/region.jps.
 *   mount         addons/mount.jps: mount a storage region's filer on this env's layer.
 *   unmount       addons/mount.jps onUninstall.
 *
 * Node commands: jelastic.env.control.ExecCmdById(env, session, nodeId, cmds, true, "root").
 * Runner machine lines: SFS_RESULT=ok|failed, SFS_MESSAGE=..., SFS_JSON=...
 * Node-group data (storage group) key "sfsCluster"; never writes "globals".
 * NOTE: never write a dollar-brace sequence in this file (the JPS loader interpolates it).
 */

var NAMES = ["op", "envName", "envDomain", "basePath", "clusterName", "region", "version",
             "nodeIds", "nodeId", "uid", "email", "newRegion", "newRegionName", "nodeCount", "hwRegion",
             "cpEnvName", "cpNodeId", "cpIp", "cpUrl", "caFingerprint", "clusterId",
             "sourceEnv", "mountPath", "cacheMb", "nodeGroup"];
var P = {}, _i, _v;
for (_i = 0; _i < NAMES.length; _i++) {
    _v = getParam(NAMES[_i], "");
    _v = (_v === null || _v === undefined) ? "" : String(_v);
    P[NAMES[_i]] = /^\$\{.*\}$/.test(_v) ? "" : _v;   // unresolved placeholder = not provided
}

var GROUP = "storage";
var KEY = "sfsCluster";
var WEED_VERSION = "4.48";
var CP_PORT = 8480;
var BASE = String(P.basePath || "").replace(/\/+$/, "");

function ok(extra) { var r = { result: 0 }, k; for (k in (extra || {})) r[k] = extra[k]; return r; }
function fail(msg) { return { result: 99, error: String(msg), message: String(msg), type: "error" }; }
function info(msg) { return { result: "info", message: String(msg) }; }
function trim(s) { return String(s || "").replace(/^\s+|\s+$/g, ""); }
function parseJSON(s) { try { return JSON.parse(String(s)); } catch (e) { return null; } }
function q(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }        // shell single-quote
function safeName(s) { return String(s || "").toLowerCase().replace(/[^a-z0-9-]+/g, "-").replace(/^-+|-+$/g, "").substring(0, 40); }
function sleep(ms) { java.lang.Thread.sleep(ms); }

// ---- node exec ---------------------------------------------------------------------

function exec(envName, nodeId, command) {
    var r, x, o, lines, i, m;
    try {
        r = jelastic.env.control.ExecCmdById(envName, session, nodeId, toJSON([{ command: command }]), true, "root");
    } catch (e) { r = { result: -1, error: String(e) }; }
    x = { api: r ? r.result : -1, error: (r && r.error) ? String(r.error) : "", out: "", err: "", sfs: {} };
    if (r && r.responses && r.responses.length) {
        o = r.responses[0];
        x.out = String(o.out || "");
        x.err = String(o.errOut || "");
        if (!x.error && o.error) x.error = String(o.error);
    }
    lines = x.out.split("\n");
    for (i = 0; i < lines.length; i++) {
        m = /^SFS_([A-Z_]+)=(.*)$/.exec(lines[i]);
        if (m) x.sfs[m[1].toLowerCase()] = m[2];
    }
    x.ok = x.api == 0 && (x.sfs.result === undefined || x.sfs.result === "ok");
    x.json = x.sfs.json ? parseJSON(x.sfs.json) : lastJSON(x.out);
    return x;
}

// sfsctl prints one JSON document on stdout; take the last line that parses.
function lastJSON(out) {
    var lines = String(out || "").split("\n"), i, j;
    j = parseJSON(trim(out));
    if (j !== null && typeof j === "object") return j;
    for (i = lines.length - 1; i >= 0; i--) {
        if (trim(lines[i]).charAt(0) != "{" && trim(lines[i]).charAt(0) != "[") continue;
        j = parseJSON(trim(lines[i]));
        if (j !== null) return j;
    }
    return null;
}

function why(x) {
    return trim(x.sfs.message || x.error || x.err.split("\n").slice(-3).join(" ") || x.out.split("\n").slice(-3).join(" ") || ("API result " + x.api));
}

// ---- environment ---------------------------------------------------------------------

function envInfo(envName) {
    var r = jelastic.env.control.GetEnvInfo(envName, session);
    if (!r || r.result != 0) throw "cannot read environment " + envName + ": " + (r && r.error ? r.error : "result " + (r ? r.result : "?"));
    return r;
}

function groupNodes(envName, group) {
    var nodes = envInfo(envName).nodes || [], out = [], i;
    for (i = 0; i < nodes.length; i++) if (String(nodes[i].nodeGroup) == group) out.push(nodes[i]);
    out.sort(function (a, b) { return a.id - b.id; });
    return out;
}

function loadCluster(envName) {
    var r = jelastic.env.control.GetNodeGroups(envName, session), g, i, raw;
    if (!r || r.result != 0) throw "cannot read node groups of " + envName;
    g = r.object || [];
    for (i = 0; i < g.length; i++) {
        if (String(g[i].name) != GROUP) continue;
        raw = g[i][KEY];
        if (raw === null || raw === undefined || String(raw) === "") return null;
        return parseJSON(raw);
    }
    return null;
}

function saveCluster(envName, obj) {
    var data = {}, forms, f, r;
    data[KEY] = toJSON(obj);
    forms = [toJSON(data), data];
    for (f = 0; f < forms.length; f++) {
        try { r = jelastic.env.control.ApplyNodeGroupData(envName, session, GROUP, forms[f]); } catch (e) { r = { result: 99, error: String(e) }; }
        if (r && r.result == 0) return r;
    }
    throw "could not save node-group data " + KEY + " on " + envName + ": " + (r && r.error ? r.error : "?");
}

function requireCluster(envName) {
    var c = loadCluster(envName);
    if (!c || !c.cpEnvName || !c.cpNodeId) throw "this storage layer is not an enrolled sfs cluster (node-group data " + KEY + " missing)";
    return c;
}

// ---- building blocks -------------------------------------------------------------------

// control-plane/install.sh takes the whole source tree as a tarball (--tarball URL).
function tarballUrl(base) {
    var m = /^https:\/\/raw\.githubusercontent\.com\/([^\/]+)\/([^\/]+)\/(.+)$/.exec(base);
    return m ? "https://codeload.github.com/" + m[1] + "/" + m[2] + "/tar.gz/" + m[3] : "";
}

function runnerInstallCmd(base) {
    return "set -e; curl -fsSL --retry 3 " + q(base + "/scripts/node/sfs-node.sh") + " -o /usr/local/sbin/sfs-node.new" +
           " && install -m 0755 /usr/local/sbin/sfs-node.new /usr/local/sbin/sfs-node && rm -f /usr/local/sbin/sfs-node.new" +
           " && /usr/local/sbin/sfs-node install --version " + WEED_VERSION;
}

function installRunner(envName, node, base) {
    var x = exec(envName, node.id, runnerInstallCmd(base));
    if (!x.ok) throw "node " + node.id + ": runner/weed install failed: " + why(x);
}

function cpCtl(c, args) {
    var x = exec(c.cpEnvName, c.cpNodeId, "/usr/local/bin/sfsctl " + args);
    if (!x.ok || !x.json || x.json.error) throw "sfsctl " + args.split(" ")[0] + " failed on the control plane: " + (x.json && x.json.error ? x.json.error : why(x));
    return x.json;
}

function mintToken(c, region, nodeId, roles, ip) {
    var j = cpCtl(c, "enroll-token --region " + q(region) + " --node-id " + q(nodeId) + " --roles " + q(roles) + " --ip " + q(ip));
    if (!j.token) throw "enroll-token returned no token";
    if (j.caFingerprint && !c.caFingerprint) c.caFingerprint = j.caFingerprint;
    return j;
}

function enrollNode(c, envName, region, node, roles) {
    var t = mintToken(c, region, node.id, roles, node.intIP), x;
    x = exec(envName, node.id, "/usr/local/sbin/sfs-node enroll --cp " + q(c.cpUrl) + " --token " + q(t.token) +
             " --ca-fingerprint " + q(t.caFingerprint || c.caFingerprint) + " --region " + q(region) +
             " --node-id " + q(node.id) + " --ip " + q(node.intIP) + " --roles " + q(roles));
    if (!x.ok) throw "node " + node.id + ": enroll failed: " + why(x);
}

function isEnrolled(envName, node) {
    var x = exec(envName, node.id, "test -s /etc/sfs/node.pem && echo SFS_ENROLLED=1 || echo SFS_ENROLLED=0");
    return x.sfs.enrolled === "1";
}

// Masters = up to 3 lowest node ids (3 when >= 3 nodes, else 1: Raft needs an odd count).
// Control-plane node record id: "<region>-<jelastic node id>" (sfsctl enroll.node_key).
function nodeKey(c, id) { return c.region + "-" + id; }

function masterIds(nodes) {
    var n = nodes.length >= 3 ? 3 : 1, ids = {}, i;
    for (i = 0; i < n && i < nodes.length; i++) ids[nodes[i].id] = true;
    return ids;
}

function enrollAll(c, envName, region, nodes) {
    var masters = masterIds(nodes), i;
    // masters first so volume servers find a leader when they start
    for (i = 0; i < nodes.length; i++) if (masters[nodes[i].id]) enrollNode(c, envName, region, nodes[i], "volume,filer,master");
    for (i = 0; i < nodes.length; i++) if (!masters[nodes[i].id]) enrollNode(c, envName, region, nodes[i], "volume,filer");
}

// ---- operations ----------------------------------------------------------------------------

function opDeploy() {
    var nodes = groupNodes(P.envName, GROUP), bl = groupNodes(P.envName, "bl"), cp, region, x, c, i, st, clusterId;
    if (!nodes.length) return fail("no storage nodes in " + P.envName);
    if (!BASE) return fail("basePath missing");
    region = safeName(P.region) || safeName(envInfo(P.envName).env.hardwareNodeGroup) || "region1";
    for (i = 0; i < nodes.length; i++) installRunner(P.envName, nodes[i], BASE);

    cp = nodes[0];
    clusterId = String(java.util.UUID.randomUUID().toString());
    if (!tarballUrl(BASE)) return fail("cannot derive the source tarball URL from " + BASE);
    x = exec(P.envName, cp.id, "set -e; curl -fsSL --retry 3 " + q(BASE + "/control-plane/install.sh") + " -o /root/sfs-cp-install.sh" +
             " && bash /root/sfs-cp-install.sh --cluster-id " + q(clusterId) + " --cluster-name " + q(P.clusterName || P.envName) +
             " --primary-region " + q(region) + " --env-domain " + q(P.envDomain) + " --cp-ip " + q(cp.intIP) +
             " --replication " + (nodes.length >= 2 ? "010" : "000") + " --listen 0.0.0.0:" + CP_PORT + " --tarball " + q(tarballUrl(BASE)));
    if (!x.ok) return fail("control plane install failed: " + why(x));

    c = { clusterId: clusterId, name: P.clusterName || P.envName, region: region, primary: true,
          cpIp: cp.intIP, cpUrl: "https://" + cp.intIP + ":" + CP_PORT, caFingerprint: "",
          cpEnvName: P.envName, cpNodeId: cp.id, envDomain: P.envDomain, version: WEED_VERSION };
    if (x.json && x.json.caFingerprint) c.caFingerprint = x.json.caFingerprint;
    // The primary region is not registered by install.sh (counts.regions starts at 0).
    cpCtl(c, "region add --name " + q(region) + " --env " + q(P.envName));
    enrollAll(c, P.envName, region, nodes);

    for (i = 0; i < bl.length; i++) {
        x = exec(P.envName, bl[i].id, "set -e; curl -fsSL --retry 3 " + q(BASE + "/control-plane/nginx/install-bl.sh") + " -o /root/sfs-install-bl.sh" +
                 " && bash /root/sfs-install-bl.sh --cp-ip " + q(c.cpIp) + " --server-name " + q(P.envDomain) +
                 " --ca-fingerprint " + q(c.caFingerprint) + " --conf-url " + q(BASE + "/control-plane/nginx/sfs.conf"));
        if (!x.ok) return fail("nginx (bl node " + bl[i].id + ") configuration failed: " + why(x));
    }
    if (!c.clusterId) {
        try { st = cpCtl(c, "status --json"); c.clusterId = st.clusterId || (st.cluster && st.cluster.clusterId) || ""; } catch (e) { /* keep empty */ }
    }
    saveCluster(P.envName, c);
    return ok({ onAfterReturn: { setGlobals: { sfsRegion: region, sfsCpUrl: c.cpUrl, sfsClusterId: c.clusterId } } });
}

// region.jps: this env joins an existing control plane in another env.
function opJoin() {
    var nodes = groupNodes(P.envName, GROUP), region = safeName(P.region), c, i;
    if (!nodes.length) return fail("no storage nodes in " + P.envName);
    if (!region || !P.cpEnvName || !P.cpNodeId || !P.cpUrl) return fail("region, cpEnvName, cpNodeId and cpUrl are required");
    c = { clusterId: P.clusterId, name: P.clusterName, region: region, primary: false, cpIp: P.cpIp, cpUrl: P.cpUrl,
          caFingerprint: P.caFingerprint, cpEnvName: P.cpEnvName, cpNodeId: parseInt(P.cpNodeId, 10), version: WEED_VERSION };
    for (i = 0; i < nodes.length; i++) installRunner(P.envName, nodes[i], BASE);
    enrollAll(c, P.envName, region, nodes);
    saveCluster(P.envName, c);
    // registering the region makes the control plane start filer.sync with the other regions
    try { cpCtl(c, "region add --name " + q(region) + " --env " + q(P.envName)); } catch (e) { /* already registered by add-region */ }
    return ok();
}

function opEnrollNew() {
    var c = requireCluster(P.envName), nodes = groupNodes(P.envName, GROUP), done = [], i;
    for (i = 0; i < nodes.length; i++) {
        if (isEnrolled(P.envName, nodes[i])) continue;
        installRunner(P.envName, nodes[i], BASE);
        enrollNode(c, P.envName, c.region, nodes[i], "volume,filer");
        done.push(nodes[i].id);
    }
    return ok({ message: done.length ? "enrolled nodes " + done.join(", ") : "no new nodes" });
}

// Drain one node and wait (<= ~15 min) until the runner reports it empty.
function drainNode(c, node) {
    var t0 = new Date().getTime(), x, roles;
    // The node's real roles (the lowest ids are not always the masters after scale-out).
    x = exec(P.envName, node.id, "/usr/local/sbin/sfs-node status");
    roles = x.json && x.json.roles ? String(x.json.roles) : "";
    if (/master/.test(roles) || (c.primary && node.id == c.cpNodeId)) throw "node " + node.id + " runs a master or the control plane and cannot be removed in v0";
    cpCtl(c, "node drain " + q(nodeKey(c, node.id)));
    for (;;) {
        x = exec(P.envName, node.id, "/usr/local/sbin/sfs-node drain-check");
        if (x.ok) return;
        if (new Date().getTime() - t0 > 15 * 60 * 1000) throw "node " + node.id + " still holds data after 15 minutes: " + why(x);
        sleep(20000);
    }
}

function opDrain() {
    var c = requireCluster(P.envName), ids = String(P.nodeIds || "").split(","), nodes = groupNodes(P.envName, GROUP), byId = {}, i;
    for (i = 0; i < nodes.length; i++) byId[nodes[i].id] = nodes[i];
    for (i = 0; i < ids.length; i++) {
        if (!trim(ids[i]) || !byId[trim(ids[i])]) continue;
        // Remove Node already drained and unenrolled it before RemoveNode fired this event.
        if (!isEnrolled(P.envName, byId[trim(ids[i])])) continue;
        drainNode(c, byId[trim(ids[i])]);
        exec(P.envName, parseInt(trim(ids[i]), 10), "/usr/local/sbin/sfs-node remove --purge");
        try { cpCtl(c, "node remove " + q(nodeKey(c, trim(ids[i])))); } catch (e) { /* control plane marks it offline later */ }
    }
    return ok();
}

function opRemoveNode() {
    var c = requireCluster(P.envName), nodes = groupNodes(P.envName, GROUP), node = null, i, r;
    for (i = 0; i < nodes.length; i++) if (String(nodes[i].id) == String(P.nodeId)) node = nodes[i];
    if (!node) return fail("node " + P.nodeId + " is not in the storage layer");
    if (nodes.length <= 1) return fail("the last storage node cannot be removed");
    drainNode(c, node);
    exec(P.envName, node.id, "/usr/local/sbin/sfs-node remove --purge");
    try { cpCtl(c, "node remove " + q(nodeKey(c, node.id))); } catch (e) { /* best effort */ }
    r = jelastic.env.control.RemoveNode(P.envName, session, node.id);
    if (!r || r.result != 0) return fail("node drained, but removing the container failed: " + (r && r.error ? r.error : "?"));
    return info("Node " + node.id + " was drained and removed.");
}

function opRedeploy() {
    var c = loadCluster(P.envName), nodes = groupNodes(P.envName, GROUP), ids = {}, i, x, list = trim(P.nodeIds);
    if (list) { list = list.split(","); for (i = 0; i < list.length; i++) ids[trim(list[i])] = true; }
    for (i = 0; i < nodes.length; i++) {
        if (list && !ids[String(nodes[i].id)]) continue;
        installRunner(P.envName, nodes[i], BASE);
        if (c && c.primary && nodes[i].id == c.cpNodeId) {
            // install.sh listed /opt/sfsctl, /etc/sfsctl, /var/lib/sfsctl, the CLI and the unit in
            // redeploy.conf; only the systemd enablement is lost with the container.
            x = exec(P.envName, nodes[i].id, "systemctl daemon-reload && systemctl enable --now sfsctl.service && sleep 3 && systemctl is-active sfsctl.service");
            if (!x.ok) return fail("control plane reinstall failed on node " + nodes[i].id + ": " + why(x));
        }
        if (!isEnrolled(P.envName, nodes[i])) continue;       // never enrolled: enroll-new handles it
        x = exec(P.envName, nodes[i].id, "/usr/local/sbin/sfs-node start");
        if (!x.ok) return fail("node " + nodes[i].id + ": start failed: " + why(x));
    }
    return ok();
}

function fmtBytes(b) {
    var u = ["B", "KB", "MB", "GB", "TB", "PB"], i = 0; b = Number(b || 0);
    while (b >= 1024 && i < u.length - 1) { b /= 1024; i++; }
    return (Math.round(b * 10) / 10) + " " + u[i];
}

function opStatus() {
    var c = requireCluster(P.envName), s = cpCtl(c, "status --json"), h = s.health || s, cl = s.cluster || s, lines = [], i, chk;
    lines.push("Cluster: " + (cl.name || c.name || "") + " (" + (cl.clusterId || c.clusterId || "") + ")");
    lines.push("Health: " + (h.status || "unknown"));
    if (cl.capacity) lines.push("Capacity: " + fmtBytes(cl.capacity.usedBytes) + " used of " + fmtBytes(cl.capacity.totalBytes));
    if (cl.counts) lines.push("Regions: " + cl.counts.regions + ", nodes: " + cl.counts.nodes + ", volumes: " + cl.counts.volumes);
    chk = h.checks || [];
    for (i = 0; i < chk.length; i++) if (chk[i].status != "ok") lines.push("- " + chk[i].name + ": " + chk[i].status + " " + (chk[i].detail || ""));
    lines.push("This region: " + c.region + (c.primary ? " (primary, control plane)" : ""));
    return info(lines.join("\n"));
}

function opJob(args, label) {
    var c = requireCluster(P.envName), j = cpCtl(c, args);
    return info(label + " started" + (j.id ? " (job " + j.id + ")" : "") + ". Follow it in Advanced Management > Jobs.");
}

function opSso() {
    var c = requireCluster(P.envName), j;
    if (!P.uid) return fail("user id unavailable");
    j = cpCtl(c, "sso-grant --sub " + q(P.uid) + " --email " + q(P.email || "") + " --role admin");
    if (!j.url) return fail("sso-grant returned no URL");
    // The dashboard has no open-URL response; an info popup body is raw HTML
    // (docs/PLATFORM-NOTES.md), so show a clickable link plus the bare URL.
    var u = String(j.url).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
    return info('<a href="' + u + '" target="_blank" rel="noopener noreferrer">Open Advanced Management</a>' +
        " (link valid 60 seconds, single use)<br><br>" + u);
}

function opAddRegion() {
    var c = requireCluster(P.envName), regs, n, name, envName, r, count = parseInt(P.nodeCount, 10) || 3;
    if (!c.primary) return fail("Add Region runs from the primary region's storage layer (" + c.cpEnvName + ")");
    if (count < 1 || count > 9) return fail("node count must be 1..9");
    name = safeName(P.newRegionName || P.newRegion);
    if (!name) return fail("region name required");
    try { regs = cpCtl(c, "status --json"); n = (regs.cluster || regs).counts ? (regs.cluster || regs).counts.regions : 1; } catch (e) { n = 1; }
    // TODO(sfs): a removed region leaves a gap; pick the first free <cluster>-<n> via GetEnvInfo instead.
    envName = String(c.name || P.envName).replace(/-1$/, "") + "-" + (Number(n || 1) + 1);
    cpCtl(c, "region add --name " + q(name) + " --env " + q(envName));
    r = jelastic.marketplace.jps.Install({
        appid: appid, session: session, jps: BASE + "/addons/region.jps", envName: envName,
        region: P.newRegion,
        settings: { region: name, nodeCount: count, cpEnvName: c.cpEnvName, cpNodeId: String(c.cpNodeId), cpIp: c.cpIp,
                    cpUrl: c.cpUrl, caFingerprint: c.caFingerprint, clusterId: c.clusterId, clusterName: c.name }
    });
    if (!r || r.result != 0) return fail("creating region env " + envName + " failed: " + (r && (r.error || r.message) ? (r.error || r.message) : "?"));
    return info("Region " + name + " created as environment " + envName + ". Replication with the other regions starts once its filers are enrolled.");
}

// ---- mount (addons/mount.jps, run in the APP env) ------------------------------------------

function opMount() {
    var src = trim(P.sourceEnv), c, filers, nodes, i, x, t, cmd, path = trim(P.mountPath) || "/mnt/sfs", cache = parseInt(P.cacheMb, 10) || 1024;
    if (!src) return fail("storage region environment required");
    if (!/^\/[A-Za-z0-9._\/-]+$/.test(path) || path == "/") return fail("invalid mount path " + path);
    c = requireCluster(src);
    filers = groupNodes(src, GROUP);
    if (!filers.length) return fail("no storage nodes in " + src);
    nodes = groupNodes(P.envName, P.nodeGroup);
    for (i = 0; i < nodes.length; i++) {
        // Filer gRPC is mutual TLS (verified: without a client cert weed mount gets
        // "connection error ... error reading server preface"), so every client node is
        // enrolled with role "client" (cert only, no services) before mounting.
        // TODO(sfs): control-plane/sfsctl/enroll.py ALLOWED_ROLES must accept "client"
        // (and not count such nodes as storage); until then this step fails with the CP's error.
        cmd = "set -e; for f in sfs-node sfs-mount; do curl -fsSL --retry 3 " + q(BASE + "/scripts/node/") + "$f.sh -o /usr/local/sbin/$f.new" +
              " && install -m 0755 /usr/local/sbin/$f.new /usr/local/sbin/$f && rm -f /usr/local/sbin/$f.new; done" +
              " && /usr/local/sbin/sfs-mount install --version " + WEED_VERSION;
        if (!isEnrolled(P.envName, nodes[i])) {
            t = mintToken(c, c.region, nodes[i].id, "client", nodes[i].intIP);
            cmd += " && /usr/local/sbin/sfs-node install --version " + WEED_VERSION +
                   " && /usr/local/sbin/sfs-node enroll --no-start --cp " + q(c.cpUrl) + " --token " + q(t.token) +
                   " --ca-fingerprint " + q(t.caFingerprint || c.caFingerprint) + " --region " + q(c.region) +
                   " --node-id " + q(nodes[i].id) + " --ip " + q(nodes[i].intIP) + " --roles client";
        }
        cmd += " && /usr/local/sbin/sfs-mount mount --filer " + q(ipList(filers, ":8888")) + " --path " + q(path) + " --cache-mb " + cache +
               " --ca /etc/sfs/ca.pem --cert /etc/sfs/node.pem --key /etc/sfs/node.key";
        x = exec(P.envName, nodes[i].id, cmd);
        if (!x.ok) return fail("node " + nodes[i].id + ": mount failed: " + why(x));
    }
    return info("Mounted " + src + " (" + c.region + ") at " + path + " on " + nodes.length + " node(s).");
}

function ipList(nodes, suffix) { var a = [], i; for (i = 0; i < nodes.length; i++) a.push(nodes[i].intIP + suffix); return a.join(","); }

// Never fails: it runs from onUninstall, and Uninstall never sends force.
function opUnmount() {
    var nodes, i, path = trim(P.mountPath) || "/mnt/sfs";
    try { nodes = groupNodes(P.envName, P.nodeGroup); } catch (e) { return ok(); }
    for (i = 0; i < nodes.length; i++) exec(P.envName, nodes[i].id, "test -x /usr/local/sbin/sfs-mount && /usr/local/sbin/sfs-mount remove --path " + q(path) + " || true");
    return ok();
}

// ---- dispatch ------------------------------------------------------------------------------

var OPS = {
    "deploy": opDeploy, "join": opJoin, "enroll-new": opEnrollNew, "drain": opDrain, "redeploy": opRedeploy,
    "status": opStatus, "sso": opSso, "remove-node": opRemoveNode, "add-region": opAddRegion,
    "rebalance": function () { return opJob("rebalance", "Rebalance"); },
    "heal": function () { return opJob("heal", "Heal"); },
    "backup": function () { return opJob("backup now", "Backup"); },
    "mount": opMount, "unmount": opUnmount
};

try {
    if (!OPS[P.op]) return fail("unknown op " + P.op);
    return OPS[P.op]();
} catch (e) {
    return fail(String(e));
}
