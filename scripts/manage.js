/*
 * Syncthing file replication add-on - platform side.
 *
 * Run by manifest.jps as a Cloud Scripting `script:` action (context: appid,
 * session, getParam, jelastic, toJSON). Operations (param "op"):
 *
 *   apply   phase install | configure | scale | redeploy | migrate | clone.
 *           Installs the node runner (scripts/stsync.sh, as /usr/local/sbin/stsync)
 *           and Syncthing on every running node of the app layer, gives every
 *           node the device id and private IP of every other node, seeds a new
 *           cluster from one node and lets every other node join safely
 *           (receive-only first, see `stsync join`), then saves the settings.
 *   status  One block per node plus an overall line, as an info popup.
 *   rescan  Asks every node to rescan the directory now.
 *
 * Uninstall runs inline in manifest.jps: it must work even when this file
 * cannot be downloaded.
 *
 * The settings live in the cp node group's data under the key "stSync" (a JSON
 * string, written per key with ApplyNodeGroupData). Never under "globals":
 * other packages keep their parameters there. The build contract is
 * docs/DESIGN.md, section 4.
 *
 * Safety rules of the seed and the joins (docs/DESIGN.md, section 4):
 *   - a fresh install resets any Syncthing state left on a node (prepare
 *     --fresh) and refuses a seed that holds far fewer files than another node,
 *     unless the form names the seed node;
 *   - joiners sync only against send-receive nodes (stsync join --from): the
 *     seed, nodes already send-receive, and nodes saved as send-receive that
 *     did not answer - never against another joiner alone.
 */

var NAMES = ["op", "phase", "envName", "cloneEnvName", "basePath", "path", "ignore", "delay", "versionsDays", "seedNode"];
var P = {}, _i, _v;
for (_i = 0; _i < NAMES.length; _i++) {
    _v = getParam(NAMES[_i], "");
    _v = (_v === null || _v === undefined) ? "" : String(_v);
    // An unresolved JPS placeholder means "not provided".
    P[NAMES[_i]] = /^\$\{[^\n]*\}$/.test(_v) ? "" : _v;
}

var GROUP = "cp";
var KEY = "stSync";
var FOLDER = "webroot";
var RUNNER = "/usr/local/sbin/stsync";
var PORT = 22000;
// Outside the webroot, so old versions are never served.
var VERSIONS_PATH = "/var/lib/stsync/versions/" + FOLDER;
var DEFAULTS = {
    path: "/var/www/webroot/ROOT",
    delay: 2,
    versionsDays: 14,
    ignore: [
        "// Caches, logs and temporary files: each node keeps its own",
        "(?d)/wp-content/cache",
        "(?d)/wp-content/upgrade",
        "(?d)*.log",
        "(?d).DS_Store",
        "(?d)Thumbs.db"
    ].join("\n")
};
var FORM_PHASES = { install: true, configure: true };
var EVENT_PHASES = { scale: true, redeploy: true, migrate: true, clone: true };
// The clone event fires on the original environment; the copy is the one to set up.
var ENV = P.phase == "clone" ? P.cloneEnvName : P.envName;

// ---- helpers ------------------------------------------------------------------------

function ok(extra) { var r = { result: 0 }, k; for (k in (extra || {})) r[k] = extra[k]; return r; }
function fail(msg) { return { result: 99, error: msg, message: msg, type: "error" }; }
// The dashboard picks the popup by "type"; the message is rendered as markdown,
// so line breaks need two trailing spaces.
function info(msg) { return { result: "info", type: "info", message: md(msg) }; }
function warning(msg) { return { result: "warning", type: "warning", message: md(msg) }; }
function md(text) { return String(text).replace(/\n/g, "  \n"); }
function trim(s) { return String(s === undefined || s === null ? "" : s).replace(/^\s+|\s+$/g, ""); }
function q(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }
function parseJSON(s) { try { return JSON.parse(String(s)); } catch (e) { return null; } }
function errText(r) { return (r && r.error) ? String(r.error) : "result " + (r ? r.result : "?"); }
function now() { return new Date().toISOString(); }
function tail(s, n) {
    s = trim(s);
    return s.length > n ? "..." + s.substring(s.length - n) : s;
}
function b64(s) {
    return String(java.util.Base64.getEncoder().encodeToString(new java.lang.String(String(s)).getBytes("UTF-8")));
}
// Runner messages carry no final period.
function sentence(msg) { msg = trim(msg); return /[.!?]$/.test(msg) ? msg : msg + "."; }
function list(ids) { return (ids.length > 1 ? "nodes " : "node ") + ids.join(", "); }

// ---- settings -----------------------------------------------------------------------

// null = nothing saved. A failed read is NOT "nothing saved": it throws, so a
// read error never turns an existing cluster into a fresh install.
function loadSettings(envName) {
    var r = jelastic.env.control.GetNodeGroups(envName, session), groups, raw, s, i;
    if (!r || r.result != 0) {
        throw "could not read the add-on settings of " + envName + " (" + errText(r) + "), so nothing was changed - try again";
    }
    groups = r.object || [];
    for (i = 0; i < groups.length; i++) {
        if (String(groups[i].name) != GROUP) continue;
        raw = groups[i][KEY];
        if (raw === null || raw === undefined || String(raw) === "") return null;
        s = parseJSON(raw);
        if (!s || typeof s !== "object") s = parseJSON(toJSON(raw));
        if (!s || typeof s !== "object") throw "the saved add-on settings of " + envName + " are not valid JSON";
        return s;
    }
    return null;
}

function writeSettings(value) {
    var data = {}, forms, f, r;
    data[KEY] = value;
    forms = [toJSON(data), data];
    for (f = 0; f < forms.length; f++) {
        try { r = jelastic.env.control.ApplyNodeGroupData(ENV, session, GROUP, forms[f]); } catch (e) { r = { result: 99, error: String(e) }; }
        if (r && r.result == 0) return r;
    }
    return r;
}

// Saved = read back with the same "updated" stamp.
function saveSettings(s) {
    var r = writeSettings(toJSON(s)), back, i;
    for (i = 0; i < 3; i++) {
        try { back = loadSettings(ENV); } catch (e) { back = null; }
        if (back && back.updated == s.updated) return ok();
        java.lang.Thread.sleep(1000);
    }
    return fail("Could not save the add-on settings on the " + GROUP + " node group of " + ENV + " (" +
                (r && r.result != 0 ? errText(r) : "read-back mismatch") + ").");
}

function normPath(p) {
    p = trim(p);
    while (p.length > 1 && p.charAt(p.length - 1) == "/") p = p.substring(0, p.length - 1);
    return p;
}
function validPath(p) {
    // No "//" inside a regular expression literal anywhere in this file: the platform's
    // script engine reads it as a comment and fails with "unterminated regular expression
    // literal" (seen live, 2026-10-01). A double slash is checked with indexOf instead.
    return /^\/[A-Za-z0-9._\/-]*[A-Za-z0-9_-]$/.test(p) && !/(^|\/)\.\.?(\/|$)/.test(p) && p.indexOf("/" + "/") < 0;
}
function normIgnore(t) {
    return String(t || "").replace(/\r\n?/g, "\n").replace(/\s+$/, "");
}
function intIn(v, lo, hi) {
    var n = trim(v);
    if (!/^\d+$/.test(n)) return null;
    n = parseInt(n, 10);
    return (n < lo || n > hi) ? null : n;
}

// Saved settings + form values (install and Configure only; events always use
// what is saved - their ${settings.*} are the install-time values).
function buildSettings(e, phase) {
    var s = { v: 1, path: DEFAULTS.path, folderId: FOLDER, ignore: DEFAULTS.ignore, delay: DEFAULTS.delay,
              versionsDays: DEFAULTS.versionsDays, seedNodeId: "", nodes: {}, updated: "" },
        notes = [], path, ign, n;
    if (e) {
        if (e.path) s.path = normPath(e.path);
        if (e.ignore !== undefined && e.ignore !== null) s.ignore = normIgnore(e.ignore);
        if (intIn(e.delay, 1, 60) !== null) s.delay = intIn(e.delay, 1, 60);
        if (intIn(e.versionsDays, 0, 365) !== null) s.versionsDays = intIn(e.versionsDays, 0, 365);
        if (e.seedNodeId) s.seedNodeId = String(e.seedNodeId);
        if (e.nodes && typeof e.nodes === "object") s.nodes = e.nodes;
    }
    // A copy gets new identities and its own mesh.
    if (phase == "clone") { s.nodes = {}; s.seedNodeId = ""; }
    if (FORM_PHASES[phase]) {
        path = normPath(P.path);
        if (path && (phase == "install" || !e)) s.path = path;
        else if (path && path != s.path) notes.push("The directory cannot be changed after install; it stays " + s.path + ".");
        // Empty keeps the current rules: a form that could not load them must
        // never wipe them. A single comment line means "no rules".
        ign = normIgnore(P.ignore);
        if (trim(ign)) s.ignore = ign;
        if (trim(P.delay)) {
            n = intIn(P.delay, 1, 60);
            if (n === null) return fail("The change delay must be a whole number of seconds from 1 to 60.");
            s.delay = n;
        }
        if (trim(P.versionsDays)) {
            n = intIn(P.versionsDays, 0, 365);
            if (n === null) return fail("The days to keep old versions must be a whole number from 0 to 365.");
            s.versionsDays = n;
        }
    }
    if (!validPath(s.path)) return fail("The directory '" + s.path + "' is not valid: use an absolute path such as " + DEFAULTS.path + ".");
    if (s.ignore.length > 65536) return fail("The ignore rules are longer than 64 KB.");
    return { result: 0, settings: s, notes: notes };
}

// ---- nodes --------------------------------------------------------------------------

function layerNodes() {
    var r = jelastic.env.control.GetEnvInfo(ENV, session), out = [], i, n;
    if (!r || r.result != 0) throw "could not read environment " + ENV + " (" + errText(r) + ")";
    for (i = 0; i < (r.nodes || []).length; i++) {
        n = r.nodes[i];
        if (String(n.nodeGroup) != GROUP) continue;
        out.push({ id: String(n.id), ip: n.intIP ? String(n.intIP) : "", master: String(n.ismaster) == "true",
                   running: n.status === undefined || n.status === null || n.status == 1 });
    }
    out.sort(function (a, b) { return parseInt(a.id, 10) - parseInt(b.id, 10); });
    return out;
}

// STSYNC_* lines of the runner, keys lower-cased without the prefix (last
// occurrence wins).
function contract(text) {
    var c = {}, lines = String(text || "").split("\n"), i, m;
    for (i = 0; i < lines.length; i++) {
        m = /^STSYNC_([A-Z0-9_]+)=(.*)$/.exec(lines[i].replace(/\r$/, ""));
        if (m) c[m[1].toLowerCase()] = m[2];
    }
    return c;
}

function execResult(r, o) {
    var x = { api: r ? r.result : -1, error: (r && r.error) ? String(r.error) : "", out: "", err: "" };
    if (o) {
        x.out = String(o.out || "");
        x.err = String(o.errOut || "");
    }
    x.c = contract(x.out);
    x.ok = x.c.result == "ok";
    x.message = x.c.message || tail(x.err, 300) || x.error || tail(x.out, 300) || ("no answer (result " + x.api + ")");
    return x;
}

function exec(nodeId, command) {
    var r;
    try {
        r = jelastic.env.control.ExecCmdById(ENV, session, nodeId, toJSON([{ command: command }]), true, "root");
    } catch (e) {
        r = { result: -1, error: String(e) };
    }
    return execResult(r, (r && r.responses && r.responses.length) ? r.responses[0] : null);
}

// One group call for the same command on every node; any running node it did
// not answer for (a failed call, no node ids) gets its own call.
function groupRun(nodes, command) {
    var out = {}, r, i, o, n;
    try {
        r = jelastic.env.control.ExecCmdByGroup(ENV, session, GROUP, toJSON([{ command: command }]), true, false, "root");
    } catch (e) { r = null; }
    for (i = 0; r && r.responses && i < r.responses.length; i++) {
        o = r.responses[i];
        if (o && o.nodeid !== undefined && o.nodeid !== null) out[String(o.nodeid)] = execResult(r, o);
    }
    for (i = 0; i < nodes.length; i++) {
        n = nodes[i];
        if (n.running && !out[n.id]) out[n.id] = exec(n.id, command);
    }
    return out;
}

// ---- node commands --------------------------------------------------------------------

// The runner is downloaded on every apply (a redeploy deletes it). Only a
// complete, parseable file replaces the installed copy; when the download
// fails, an installed copy is used and reported.
function prepareCmd(s, n, fresh) {
    var url = P.basePath.replace(/\/+$/, "") + "/scripts/stsync.sh",
        u = q(url + "?_r=" + Math.floor(Math.random() * 1e9));
    return [
        ": stsync prepare",
        "R=" + RUNNER + "; T=$(mktemp)",
        "if { timeout 60 curl -fsSL --connect-timeout 10 -o \"$T\" " + u + " || timeout 60 wget -q -T 10 -t 1 -O \"$T\" " + u + "; } 2>/dev/null" +
            " && head -n 1 \"$T\" | grep -q '^#!.*bash' && grep -q STSYNC_RESULT \"$T\" && bash -n \"$T\"; then mkdir -p /usr/local/sbin && install -m 0755 \"$T\" \"$R\"",
        "elif [ -x \"$R\" ]; then echo STSYNC_RUNNER=stale",
        "else rm -f \"$T\"; echo STSYNC_RESULT=failed; echo " + q("STSYNC_MESSAGE=could not download the runner from " + url) + "; exit 1; fi",
        "rm -f \"$T\"",
        "\"$R\" prepare --path " + q(s.path) + " --ip " + q(n.ip) + " --folder " + FOLDER +
            (fresh ? " --fresh --count-b64 " + (b64(s.ignore) || "-") : "")
    ].join("\n");
}

// ignore, then the API plan, then (for a receive-only node) the join - each
// step stops the command on failure; STSYNC_STEP names the failed one.
function configureCmd(s, plan, join, from) {
    var ign = b64(s.ignore ? s.ignore + "\n" : "");
    var lines = [
        ": stsync configure",
        "R=" + RUNNER,
        "echo STSYNC_STEP=ignore; \"$R\" ignore --path " + q(s.path) + " --b64 " + (ign || "-") + " || exit 1",
        "echo STSYNC_STEP=api; \"$R\" api --plan-b64 " + b64(plan) + " || exit 1"
    ];
    if (join) lines.push("echo STSYNC_STEP=join; \"$R\" join --folder " + FOLDER + (from.length ? " --from " + from.join(",") : ""));
    return lines.join("\n");
}

function simpleCmd(label, args) {
    return ": stsync " + label + "\nR=" + RUNNER + "; if [ -x \"$R\" ]; then \"$R\" " + args +
           "; else echo STSYNC_RESULT=failed; echo 'STSYNC_MESSAGE=the add-on runner is not installed on this node - open Configure and click Save'; fi; true";
}

function planLine(method, path, body) {
    return method + " " + path + " " + (body === null ? "-" : b64(toJSON(body)));
}

// The API plan of one node. folder: "create" (POST, with type) or "update"
// (PATCH; type only when promoting a seed). retired: device ids to remove -
// PUT /rest/config/devices only adds and updates, it never removes a device
// (Syncthing 2.1.5), and DELETE of a missing device answers 200.
function planFor(s, n, mesh, folder, type, retired) {
    var devices = [], fdevs = [], lines = [], i, versioning, body;
    for (i = 0; i < mesh.length; i++) {
        devices.push({ deviceID: mesh[i].device, name: "node" + mesh[i].id, addresses: ["tcp://" + mesh[i].ip + ":" + PORT] });
        fdevs.push({ deviceID: mesh[i].device });
    }
    versioning = s.versionsDays > 0
        ? { type: "trashcan", params: { cleanoutDays: String(s.versionsDays) }, fsPath: VERSIONS_PATH }
        : { type: "", params: {}, fsPath: "" };
    // Private network only: no discovery, relays, NAT, usage reports or upgrades.
    lines.push(planLine("PATCH", "/rest/config/options", {
        listenAddresses: ["tcp://" + n.ip + ":" + PORT], globalAnnounceEnabled: false, localAnnounceEnabled: false,
        relaysEnabled: false, natEnabled: false, urAccepted: -1, crashReportingEnabled: false,
        autoUpgradeIntervalH: 0, startBrowser: false }));
    lines.push(planLine("PUT", "/rest/config/devices", devices));
    if (folder == "create") {
        lines.push(planLine("POST", "/rest/config/folders", {
            id: FOLDER, label: FOLDER, path: s.path, type: type, fsWatcherDelayS: s.delay, devices: fdevs, versioning: versioning }));
    } else {
        body = { devices: fdevs, fsWatcherDelayS: s.delay, versioning: versioning };
        if (type) body.type = type;
        lines.push(planLine("PATCH", "/rest/config/folders/" + FOLDER, body));
    }
    // After the folder no longer shares with them.
    for (i = 0; i < retired.length; i++) lines.push(planLine("DELETE", "/rest/config/devices/" + retired[i], null));
    return lines.join("\n") + "\n";
}

// ---- firewall ---------------------------------------------------------------------------

// Best effort, only when the account's firewall is enabled. Syncthing listens
// on the private IP only. Returns a note for the report ("" = nothing to say).
function openFirewall() {
    var qr, on, r, rules, i;
    try {
        if (!jelastic.environment || !jelastic.environment.security) return "";
        qr = jelastic.billing.account.GetOwnerQuotas(appid, session, "firewall.enabled");
        on = (qr && qr.array && qr.array[0]) ? qr.array[0].value : 0;
        if (!on || String(on) == "0" || String(on) == "false") return "";
        try {
            r = jelastic.environment.security.GetRules(ENV, session, GROUP, "INPUT");
            rules = (r && r.result == 0) ? (r.rules || r.array || r.objects || []) : [];
            for (i = 0; i < rules.length; i++) if (String(rules[i].name) == "syncthing") return "";
        } catch (e) { /* unknown: add it (a duplicate rule is harmless) */ }
        r = jelastic.environment.security.AddRule(ENV, session,
            { direction: "INPUT", name: "syncthing", protocol: "TCP", ports: String(PORT), src: "ALL", priority: 1080, action: "ALLOW" }, GROUP);
        if (r && r.result == 0) return "Firewall: allowed TCP " + PORT + " into the app layer.";
        return "Could not add the firewall rule for TCP " + PORT + " (" + errText(r) + "): add it to the app layer by hand.";
    } catch (e2) {
        return "";
    }
}

// ---- apply --------------------------------------------------------------------------

function opApply() {
    var phase = P.phase, existing, b, s, nodes, running = [], prepared = [], failed = [], notes = [], warns = [],
        fresh, i, n, x, sr = false, unseen = false, seed = null, mesh = [], saved, joiners = [], order, fw, sv, report, dev, old, keep,
        inMesh = {}, retired = [], inLayer = {}, k, srDevs = [], from, why, named = trim(P.seedNode);
    if (!FORM_PHASES[phase] && !EVENT_PHASES[phase]) return fail("Unknown phase '" + phase + "'.");
    if (!ENV) return fail(phase == "clone" ? "The name of the cloned environment is missing." : "The envName parameter is missing.");
    if (!P.basePath) return fail("The add-on's base URL is unknown - reinstall the add-on.");

    // 1. Settings.
    existing = loadSettings(ENV);
    // A copy may or may not carry the node group data: fall back to the original.
    if (!existing && phase == "clone" && P.envName) existing = loadSettings(P.envName);
    if (!existing && EVENT_PHASES[phase]) {
        return fail("The Syncthing add-on has no saved settings on " + ENV + " - open the add-on's Configure and click Save.");
    }
    fresh = phase == "install" && !existing;
    b = buildSettings(existing, phase);
    if (b.result != 0) return b;
    s = b.settings;
    warns = warns.concat(b.notes);
    saved = s.nodes;
    if (fresh && named && !/^\d+$/.test(named)) return fail("Starting copy: '" + named + "' is not a node id.");

    nodes = layerNodes();
    for (i = 0; i < nodes.length; i++) {
        if (nodes[i].running) running.push(nodes[i]);
        else warns.push("Node " + nodes[i].id + " is not running and was left out; once it runs, open Configure and click Save.");
    }
    if (!running.length) return fail("No node of the app layer (" + GROUP + ") of " + ENV + " is running.");

    // 2. Runner and Syncthing on every running node. Install/Configure stop at
    //    the first failure; events skip the node and report it. A fresh install
    //    resets state left from an earlier install (such a node would otherwise
    //    keep its old folder and become the source) and counts the files.
    for (i = 0; i < running.length; i++) {
        n = running[i];
        x = n.ip ? exec(n.id, prepareCmd(s, n, fresh)) : { ok: false, c: {}, message: "the node has no private IP" };
        if (!x.ok || !x.c.device) {
            x.message = x.ok ? "the runner did not report a device id" : x.message;
            if (FORM_PHASES[phase]) {
                if (fresh) undoInstall(s, prepared.concat([n]));
                return fail("Node " + n.id + ": " + sentence(x.message) + (fresh ? " Nothing was installed." : " The settings were not changed."));
            }
            failed.push("node " + n.id + " (" + x.message + ")");
            continue;
        }
        n.device = x.c.device;
        n.type = x.c.folder_type || "none";
        n.join = x.c.join || "none";
        n.files = /^\d+$/.test(x.c.files || "") ? parseInt(x.c.files, 10) : null;
        n.bytes = x.c.bytes || 0;
        if (x.c.cloned == "1") notes.push("Node " + n.id + " was a copy of another node: it got its own identity and joins like a new node.");
        if (x.c.reset == "1") notes.push("Node " + n.id + " still had Syncthing from an earlier install: it was reset and starts like a new node.");
        if (x.c.runner == "stale") warns.push("Node " + n.id + ": the current runner could not be downloaded, so the installed copy was used.");
        if (n.type == "sendreceive") sr = true;
        prepared.push(n);
    }
    if (!prepared.length) return fail("No node could be set up: " + failed.join("; ") + ".");

    // 3. Seed. Only when the whole layer is visible and no node sends: a known
    //    node that did not answer may hold the data, so then new nodes just
    //    wait for it (receive-only). The seed is the node the install form
    //    names, else the master (or lowest id) - refused on a fresh install
    //    when it holds far fewer files than another node.
    for (i = 0; i < nodes.length; i++) {
        if (!nodes[i].device && saved[nodes[i].id] && saved[nodes[i].id].device) unseen = true;
    }
    if (!sr && !unseen) {
        if (fresh && named) {
            for (i = 0; i < prepared.length; i++) if (prepared[i].id == named) seed = prepared[i];
            if (!seed) {
                undoInstall(s, prepared);
                return fail("Starting copy: node " + named + " is not a running node of the app layer (" + list(idsOf(prepared)) + "). Nothing was installed.");
            }
        } else {
            for (i = 0; i < prepared.length; i++) if (prepared[i].master) seed = prepared[i];
            if (!seed) seed = prepared[0];
            why = fresh ? seedCheck(s, seed, prepared) : "";
            if (why) { undoInstall(s, prepared); return fail(why + " Nothing was installed."); }
        }
        s.seedNodeId = seed.id;
    } else if (!sr) {
        warns.push("No node with a send-receive folder answered, so new nodes wait receive-only until one is back.");
    }
    for (i = 0; i < prepared.length; i++) {
        n = prepared[i];
        if (n === seed) {
            n.folder = n.type == "none" ? "create" : "update";
            // A seed that was still receive-only becomes the source as it is.
            n.newType = n.type == "sendreceive" ? "" : "sendreceive";
        } else if (n.type == "none") {
            n.folder = "create";
            n.newType = "receiveonly";
        } else {
            n.folder = "update";
            n.newType = "";
        }
        // Receive-only nodes (new, or a join the restart interrupted) run the
        // safe join; it does nothing when one is running already.
        n.doJoin = (n.newType || n.type) == "receiveonly";
        if (n.doJoin) joiners.push(n.id);
    }

    // Joiners sync only against send-receive nodes (their list updates a join
    // that already runs): the seed, nodes already send-receive, and nodes
    // saved as send-receive that did not answer now.
    for (i = 0; i < nodes.length; i++) {
        n = nodes[i];
        if (n.device) { if (n === seed || n.type == "sendreceive") srDevs.push(n.device); }
        else if (saved[n.id] && saved[n.id].device && saved[n.id].type == "sendreceive") srDevs.push(String(saved[n.id].device));
    }
    if (joiners.length && !srDevs.length) {
        warns.push("No node is known to send the directory's content (send-receive), so these nodes wait receive-only: " +
                   list(joiners) + ". Once such a node runs, open Configure and click Save.");
    }

    // 4. Mesh: every node of the layer with a known device (a node skipped
    //    this time keeps its saved identity, so it rejoins when it is back).
    for (i = 0; i < nodes.length; i++) {
        n = nodes[i];
        dev = n.device || (saved[n.id] && saved[n.id].device ? String(saved[n.id].device) : "");
        if (dev && n.ip) { mesh.push({ id: n.id, ip: n.ip, device: dev }); inMesh[dev] = true; }
        inLayer[n.id] = true;
    }
    // Identities that left: nodes scaled in, or a node that got a new identity.
    for (k in saved) {
        dev = saved[k] && saved[k].device ? String(saved[k].device) : "";
        if (dev && !inMesh[dev] && retired.indexOf(dev) < 0) retired.push(dev);
    }
    // The seed first, so its folder exists before joiners ask for it.
    order = seed ? [seed] : [];
    for (i = 0; i < prepared.length; i++) if (prepared[i] !== seed) order.push(prepared[i]);
    for (i = 0; i < order.length; i++) {
        n = order[i];
        from = [];
        for (k = 0; k < srDevs.length; k++) if (srDevs[k] != n.device) from.push(srDevs[k]);
        x = exec(n.id, configureCmd(s, planFor(s, n, mesh, n.folder, n.newType, retired), n.doJoin, from));
        if (!x.ok) {
            x.message = (x.c.step ? x.c.step + ": " : "") + x.message;
            if (FORM_PHASES[phase]) {
                if (fresh) undoInstall(s, prepared);
                return fail("Node " + n.id + ": " + sentence(x.message) + (fresh ? " Nothing was installed."
                    : " The settings were not saved; nodes configured before it already use the new ones - fix the node and click Save again."));
            }
            failed.push("node " + n.id + " (" + x.message + ")");
            n.failed = true;
        }
    }

    // 5. Firewall.
    if (FORM_PHASES[phase] || phase == "clone") {
        fw = openFirewall();
        if (fw) (/^Could not/.test(fw) ? warns : notes).push(fw);
    }

    // 6. Settings: nodes still in the layer; joinedAt is kept while the identity
    //    is; type = the folder type at this apply (a joiner turns send-receive
    //    on its own later, so "sendreceive" here is never wrong).
    s.nodes = {};
    for (i = 0; i < nodes.length; i++) {
        n = nodes[i];
        old = saved[n.id];
        if (n.device) {
            keep = old && String(old.device) == n.device && old.joinedAt;
            s.nodes[n.id] = { device: n.device, joinedAt: keep ? String(old.joinedAt) : now(),
                              type: (!n.failed && n.newType) ? n.newType : n.type };
        } else if (old && old.device) {
            s.nodes[n.id] = old;
        }
    }
    // A node that left stays listed until every node applied without error,
    // so the next apply removes its device from the nodes that missed it.
    for (k in saved) if (failed.length && !inLayer[k] && saved[k] && saved[k].device) s.nodes[k] = saved[k];
    s.updated = now() + "-" + Math.floor(Math.random() * 1e6);
    sv = saveSettings(s);
    if (sv.result != 0) {
        if (fresh) { undoInstall(s, prepared); return fail(sv.message + " Nothing was installed."); }
        return fail(sv.message + " The nodes already use the new settings; click Save in Configure again.");
    }

    report = summary(s, prepared, seed, joiners, notes, warns);
    if (failed.length) {
        return fail("Syncthing (" + phase + "): skipped " + failed.join("; ") + ". The other nodes were updated. " + report);
    }
    if (phase == "install") return ok({ message: report, onAfterReturn: { setGlobals: { stReport: report } } });
    if (phase == "configure" && warns.length) return warning("Settings saved and applied, with warnings.\n" + report);
    return ok({ message: report });
}

function idsOf(nodes) { var out = [], i; for (i = 0; i < nodes.length; i++) out.push(nodes[i].id); return out; }

// The seed's copy becomes every node's content: refuse (on a fresh install)
// a seed that is empty while another node is not, or holds less than half the
// files of the largest other copy - a recreated master, or content deployed
// to other nodes only. Their files would all move to the version store (and
// with versioning off be deleted). "" = fine.
function seedCheck(s, seed, prepared) {
    var big = null, i, n;
    for (i = 0; i < prepared.length; i++) {
        n = prepared[i];
        if (n !== seed && n.files !== null && (!big || n.files > big.files)) big = n;
    }
    if (!big || seed.files === null || !big.files || (seed.files > 0 && seed.files * 2 >= big.files)) return "";
    return "Node " + seed.id + (seed.master ? " (master)" : "") + " would be the starting copy, but it holds " + seed.files +
           " file(s) (" + bytes(seed.bytes) + ") in " + s.path + " while node " + big.id + " holds " + big.files + " (" + bytes(big.bytes) +
           "): the other nodes would move their files out of the directory. Copy the complete site to node " + seed.id +
           " first, or enter the id of the node with the right copy in Starting copy (" + seed.id + " to use node " + seed.id + "'s copy anyway).";
}

function summary(s, prepared, seed, joiners, notes, warns) {
    var t = [];
    t.push("Replicating " + s.path + " on " + list(idsOf(prepared)) + ".");
    if (seed) t.push("Node " + seed.id + " is the seed: its copy is the starting content.");
    if (joiners.length) {
        t.push("Joining: " + list(joiners) + " - receive-only until caught up with a send-receive node; their files that differ from " +
               "the cluster's go to their version store (/var/lib/stsync/versions)" +
               (s.versionsDays > 0 ? "" : " - with versioning off only the files the cluster does not have, the others are replaced") +
               ", then they send. Check progress with Status.");
        t.push("While a node joins it serves its old files, and what is written on it (an upload, an update) goes to its version " +
               "store instead of the other nodes: keep joining nodes out of the load balancer until Status shows them in sync.");
    }
    t.push("Change delay " + s.delay + " s; " + (s.versionsDays > 0 ? "old versions kept " + s.versionsDays + " days" : "no versioning") +
           "; " + String(s.ignore).split("\n").length + " ignore rule line(s).");
    return t.concat(notes, warns).join("\n");
}

// A first install that failed: take Syncthing off the nodes it touched (files
// under the directory stay; the runner keeps old versions in /root).
function undoInstall(s, nodes) {
    var i;
    for (i = 0; i < nodes.length; i++) {
        if (nodes[i].type && nodes[i].type != "none") continue;
        exec(nodes[i].id, simpleCmd("undo install", "remove --path " + q(s.path)));
    }
}

// ---- status and rescan ------------------------------------------------------------

var TYPE_NAMES = { sendreceive: "send-receive", receiveonly: "receive-only", sendonly: "send-only", none: "missing" };

function num(v) { var n = parseInt(v, 10); return isNaN(n) ? 0 : n; }
function bytes(v) {
    var n = num(v), u = ["B", "KB", "MB", "GB", "TB"], i = 0;
    while (n >= 1024 && i < u.length - 1) { n = n / 1024; i++; }
    return (i ? n.toFixed(1) : n) + " " + u[i];
}

// {cls: insync | syncing | problem, probs, j (the runner's status JSON)}
function nodeState(n, x) {
    var j, errs, type, probs = [], cls;
    if (!n.running) return { cls: "problem", probs: ["not running"], j: null };
    j = x && x.ok ? parseJSON(x.c.json) : null;
    if (!j || typeof j !== "object") return { cls: "problem", probs: ["no status (" + (x ? x.message : "no answer") + ")"], j: null };
    errs = (j.errors && typeof j.errors === "object") ? num(j.errors.length) : num(j.errors);
    type = String(j.folderType || "none");
    if (j.service != "active") probs.push("service " + (j.service || "unknown"));
    if (type == "none") probs.push("folder missing");
    if (errs) probs.push(errs + " error(s)");
    if (j.error) probs.push(String(j.error));
    if (num(j.connectedPeers) < num(j.totalPeers)) probs.push("peers disconnected");
    if (j.state == "error") probs.push("folder error");
    if (j.join == "failed") probs.push("join failed");
    // Receive-only is only right while a join runs: without one, what is
    // written on this node never reaches the others.
    else if (type == "receiveonly" && j.join != "running") probs.push("receive-only but no join is running - open Configure and click Save");
    if (probs.length) cls = "problem";
    else if (num(j.needItems) > 0 || (j.state && j.state != "idle") || j.join == "running" || type == "receiveonly") cls = "syncing";
    else cls = "insync";
    return { cls: cls, probs: probs, j: j, errs: errs, type: type };
}

function nodeText(n, st) {
    var head = "Node " + n.id + (n.master ? " (master)" : ""), j = st.j, conf, d;
    if (!j) return head + ": " + st.probs.join(", ");
    conf = num(j.conflicts);
    d = String(j.device || "");
    return head + ": " + (st.cls == "problem" ? "PROBLEM - " + st.probs.join(", ") : st.cls == "syncing" ? "syncing" : "in sync") + "\n" +
           "service " + (j.service || "?") + (j.version ? " (" + j.version + ")" : "") + ", device " + (d ? d.substring(0, 7) : "?") +
           ", folder " + (TYPE_NAMES[st.type] || st.type) + (j.join == "running" ? " (joining" + (j.joinPhase ? ": " + j.joinPhase : "") + ")" : "") +
           ", state " + (j.state || "?") + ", need " + num(j.needItems) + " items (" + bytes(j.needBytes) + ")" +
           ", peers " + num(j.connectedPeers) + "/" + num(j.totalPeers) + ", errors " + st.errs +
           ", conflicts " + (conf >= 1000 ? "1000+" : conf) +
           // A joining node's conflict copies are its own old files; the join sets them aside.
           (conf && st.type == "receiveonly" ? " (temporary: set aside when the join finishes)" : "") +
           (j.lastScan ? ", last scan " + j.lastScan : "");
}

// The global state (files, directories, deletes, bytes) is the same on every
// node once all are in sync. Nodes that report in sync but disagree hold
// different copies (a divergence the per-node view cannot show): mark the ones
// outside the largest group (all of them on a tie) as problems.
function markDiverged(nodes, states) {
    var groups = {}, keys = [], i, j, k, x, best = null, tie = false, out = [];
    for (i = 0; i < nodes.length; i++) {
        x = states[i].j;
        if (states[i].cls != "insync" || !x || x.globalFiles === undefined || x.globalFiles === null) continue;
        k = [num(x.globalFiles), num(x.globalDirectories), num(x.globalDeleted), num(x.globalBytes)].join("/");
        if (!groups[k]) { groups[k] = []; keys.push(k); }
        groups[k].push(i);
    }
    if (keys.length < 2) return out;
    for (i = 0; i < keys.length; i++) {
        if (!best || groups[keys[i]].length > groups[best].length) { best = keys[i]; tie = false; }
        else if (groups[keys[i]].length == groups[best].length) tie = true;
    }
    for (i = 0; i < keys.length; i++) {
        if (!tie && keys[i] == best) continue;
        for (j = 0; j < groups[keys[i]].length; j++) {
            k = groups[keys[i]][j];
            states[k].cls = "problem";
            states[k].probs.push("diverged: " + describeGlobal(states[k].j) + (tie ? ", the other nodes differ" : ", the other nodes " + describeGlobal(states[groups[best][0]].j)));
            out.push(nodes[k].id);
        }
    }
    return out;
}
function describeGlobal(j) {
    return num(j.globalFiles) + " files, " + num(j.globalDirectories) + " directories, " + num(j.globalDeleted) + " deleted, " + bytes(j.globalBytes);
}

function opStatus() {
    var s = loadSettings(ENV), path = s && s.path ? String(s.path) : DEFAULTS.path, nodes = layerNodes(), res, blocks = [],
        problem = [], syncing = [], conflicts = 0, states = [], diverged, i, st, overall;
    if (!nodes.length) return fail("The app layer (" + GROUP + ") of " + ENV + " has no nodes.");
    res = groupRun(nodes, simpleCmd("status", "status --folder " + FOLDER + " --path " + q(path)));
    for (i = 0; i < nodes.length; i++) states.push(nodeState(nodes[i], res[nodes[i].id]));
    diverged = markDiverged(nodes, states);
    for (i = 0; i < nodes.length; i++) {
        st = states[i];
        blocks.push(nodeText(nodes[i], st));
        if (st.cls == "problem") problem.push(nodes[i].id);
        if (st.cls == "syncing") syncing.push(nodes[i].id);
        if (st.j && st.type != "receiveonly") conflicts += num(st.j.conflicts);
    }
    if (problem.length) overall = "Overall: PROBLEMS on " + list(problem) + (syncing.length ? "; syncing on " + list(syncing) : "");
    else if (syncing.length) overall = "Overall: syncing - " + list(syncing) + " still catching up";
    else overall = "Overall: in sync on all " + nodes.length + " node(s)";
    if (diverged.length) overall += "\nThe copies differ: " + list(diverged) + " report(s) a different directory content than the other nodes. If files were changing just now, run Status again.";
    if (conflicts) overall += "\n" + conflicts + " conflict copies (*.sync-conflict-*) to review: keep the right version, delete the copy.";
    if (!s) overall += "\nThe add-on has no saved settings - open Configure and click Save.";
    return info(overall + "\nDirectory: " + path + "\n\n" + blocks.join("\n\n"));
}

function opRescan() {
    var s = loadSettings(ENV), nodes = layerNodes(), res, bad = [], done = [], i, x;
    res = groupRun(nodes, simpleCmd("rescan", "rescan --folder " + FOLDER));
    for (i = 0; i < nodes.length; i++) {
        if (!nodes[i].running) { bad.push("node " + nodes[i].id + " (not running)"); continue; }
        x = res[nodes[i].id];
        if (x && x.ok) done.push(nodes[i].id); else bad.push("node " + nodes[i].id + " (" + (x ? x.message : "no answer") + ")");
    }
    if (!s) bad.push("the add-on has no saved settings - open Configure and click Save");
    if (bad.length) return warning("Rescan started on " + (done.length ? list(done) : "no node") + ". Not started: " + bad.join("; ") + ".");
    return ok({ message: "Rescan started on " + list(done) + "." });
}

var __r;
try {
    if (P.op == "apply") __r = opApply();
    else if (!ENV) __r = fail("The envName parameter is missing.");
    else if (P.op == "status") __r = opStatus();
    else if (P.op == "rescan") __r = opRescan();
    else __r = fail("Unknown op '" + P.op + "'.");
} catch (ex) {
    __r = fail("Syncthing add-on error: " + ex);
}
return __r;
