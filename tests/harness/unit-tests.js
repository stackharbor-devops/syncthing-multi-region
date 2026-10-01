/*
 * Unit tests of scripts/manage.js and the manifest's inline scripts, in FAKE
 * mode (scripted nodes, no containers). Run with tests/harness/run-unit.sh.
 *
 * jjs unit-tests.js -- <repo> <manifest.json from extract.py>
 */
load(__DIR__ + "harness.js");

var REPO = String(arguments[0]);
var MANIFEST = JSON.parse(H.readFile(arguments[1]));
var BASE = "https://raw.example.test/syncthing/main";
var DEFAULT_PATH = "/var/www/webroot/ROOT";
var DEFAULT_IGNORE = "// Caches, logs and temporary files: each node keeps its own\n(?d)/wp-content/cache\n(?d)/wp-content/upgrade\n" +
                     "(?d)*.log\n(?d).DS_Store\n(?d)Thumbs.db";
var test = H.test, assert = H.assert, eq = H.eq, contains = H.contains;

// ---- fixtures ---------------------------------------------------------------------------

// specs: [{id, master, status, ...FakeNode opts}] -> {p, nodes, env}
function cluster(specs, opts) {
    opts = opts || {};
    var nodes = opts.nodes || {}, list = [], i, s, p = opts.platform;
    for (i = 0; i < specs.length; i++) {
        s = specs[i];
        nodes[String(s.id)] = new H.FakeNode(s.id, s);
        list.push({ id: s.id, intIP: s.ip || "10.0.0." + (s.id % 250), ismaster: !!s.master, status: s.status });
    }
    if (!p) p = new H.Platform({ exec: H.fakeExecutor(nodes), firewall: !!opts.firewall });
    p.addEnv(opts.env || "env1", list);
    return { p: p, nodes: nodes, env: opts.env || "env1" };
}

function saveSettings(c, s, env) { c.p.env(env || c.env).groups.cp.stSync = JSON.stringify(s); }

function settings(nodes, extra) {
    var s = { v: 1, path: DEFAULT_PATH, folderId: "webroot", ignore: DEFAULT_IGNORE, delay: 2, versionsDays: 14,
              seedNodeId: "101", nodes: {}, updated: "2026-09-01T00:00:00.000Z-1" }, k;
    for (k in nodes) {
        s.nodes[k] = { device: nodes[k].device, joinedAt: "2026-09-01T00:00:00.000Z" };
        if (nodes[k].folderType && nodes[k].folderType != "none") s.nodes[k].type = nodes[k].folderType;
    }
    for (k in (extra || {})) s[k] = extra[k];
    return s;
}

// What the manifest passes: form values on install/Configure, and on events
// the ${settings.*} of the install (here: stale values or unresolved).
function apply(c, phase, form, extra) {
    var params = { op: "apply", phase: phase, envName: c.env, cloneEnvName: "${this.cloneEnvName}", basePath: BASE,
                   path: "${settings.path}", ignore: "${settings.ignore}", delay: "${settings.delay}", versionsDays: "${settings.versionsDays}" }, k;
    for (k in (form || {})) params[k] = form[k];
    for (k in (extra || {})) params[k] = extra[k];
    return H.runManage(REPO, c.p, params);
}
var INSTALL_FORM = { path: DEFAULT_PATH, ignore: DEFAULT_IGNORE + "\n", delay: "2", versionsDays: "14" };

function planLine(node, method, path) {
    var plan = node.lastPlan(), i;
    assert(plan, "node " + node.id + " got no API plan");
    for (i = 0; i < plan.length; i++) if (plan[i].method == method && plan[i].path == path) return plan[i].body;
    return null;
}
function hasLine(node, method, path) {
    var plan = node.lastPlan() || [], i;
    for (i = 0; i < plan.length; i++) if (plan[i].method == method && plan[i].path == path) return true;
    return false;
}
function devicesOf(body) { var out = [], i; for (i = 0; i < body.length; i++) out.push(body[i].deviceID); return out.sort(); }
function configureOrder(c) {
    var out = [], calls = c.p.execCalls(), i;
    for (i = 0; i < calls.length; i++) if (/^: stsync configure/.test(calls[i].command)) out.push(calls[i].nodeId);
    return out;
}

// ---- install ------------------------------------------------------------------------------

test("install seeds the master and joins the rest", function () {
    var c = cluster([{ id: 101 }, { id: 102, master: true }, { id: 103 }]), r, s, n, k, opts, dev, f, all;
    r = apply(c, "install", INSTALL_FORM);
    eq(r.result, 0, "result");
    contains(r.onAfterReturn.setGlobals.stReport, "Node 102 is the seed", "report names the seed");
    contains(r.onAfterReturn.setGlobals.stReport, "Joining: nodes 101, 103", "report names the joiners");

    all = [c.nodes["101"].device, c.nodes["102"].device, c.nodes["103"].device].sort();
    for (k in c.nodes) {
        n = c.nodes[k];
        eq(n.prepared, { path: DEFAULT_PATH, ip: "10.0.0." + (k % 250), folder: "webroot", fresh: true, "count-b64": H.b64encode(DEFAULT_IGNORE) },
           "prepare args on " + k + " (fresh install: reset leftovers, count the files)");
        eq(n.countRules, DEFAULT_IGNORE, "the count leaves out what the ignore rules match on " + k);
        assert(n.downloads[0].indexOf(BASE + "/scripts/stsync.sh?_r=") === 0, "runner downloaded from basePath on " + k);
        eq(n.ignore, DEFAULT_IGNORE + "\n", "default ignore rules on " + k);
        opts = planLine(n, "PATCH", "/rest/config/options");
        eq(opts, { listenAddresses: ["tcp://10.0.0." + (k % 250) + ":22000"], globalAnnounceEnabled: false, localAnnounceEnabled: false,
                   relaysEnabled: false, natEnabled: false, urAccepted: -1, crashReportingEnabled: false, autoUpgradeIntervalH: 0,
                   startBrowser: false }, "private-only options on " + k);
        dev = planLine(n, "PUT", "/rest/config/devices");
        eq(devicesOf(dev), all, "every node incl. itself in the devices of " + k);
        eq(dev[0], { deviceID: c.nodes["101"].device, name: "node101", addresses: ["tcp://10.0.0.101:22000"] }, "device entry shape");
        f = planLine(n, "POST", "/rest/config/folders");
        assert(f, "folder created on " + k);
        eq([f.id, f.label, f.path, f.fsWatcherDelayS], ["webroot", "webroot", DEFAULT_PATH, 2], "folder fields on " + k);
        eq(f.versioning, { type: "trashcan", params: { cleanoutDays: "14" }, fsPath: "/var/lib/stsync/versions/webroot" }, "versioning on " + k);
        eq(devicesOf(f.devices), all, "folder shared with every node on " + k);
    }
    eq(c.nodes["102"].folderType, "sendreceive", "master seeds send-receive");
    eq(c.nodes["102"].joins, 0, "the seed does not join");
    eq([c.nodes["101"].folderType, c.nodes["103"].folderType], ["receiveonly", "receiveonly"], "others start receive-only");
    eq([c.nodes["101"].joins, c.nodes["103"].joins], [1, 1], "others start the safe join");
    eq([c.nodes["101"].joinFrom, c.nodes["103"].joinFrom], [[c.nodes["102"].device], [c.nodes["102"].device]],
       "joiners sync only against the seed, never against each other");
    contains(r.onAfterReturn.setGlobals.stReport, "keep joining nodes out of the load balancer", "report says what happens to writes on a joiner");
    eq(configureOrder(c)[0], "102", "the seed is configured first");

    s = c.p.settings("env1");
    eq([s.v, s.path, s.folderId, s.ignore, s.delay, s.versionsDays, s.seedNodeId], [1, DEFAULT_PATH, "webroot", DEFAULT_IGNORE, 2, 14, "102"], "saved settings");
    for (k in c.nodes) eq(s.nodes[k].device, c.nodes[k].device, "saved device of " + k);
    eq([s.nodes["101"].type, s.nodes["102"].type, s.nodes["103"].type], ["receiveonly", "sendreceive", "receiveonly"], "saved folder types");
    assert(s.updated && s.nodes["101"].joinedAt, "updated and joinedAt set");
    eq(Object.keys(c.p.env("env1").groups.cp).sort(), ["name", "stSync"], "only the stSync key is written (never globals)");
});

test("a fresh install resets Syncthing left over from an earlier install", function () {
    // 102 kept its old send-receive folder: an uninstall could not reach it.
    var c = cluster([{ id: 101, master: true }, { id: 102, folderType: "sendreceive", hasRunner: true }]), r, old = c.nodes["102"].device;
    r = apply(c, "install", INSTALL_FORM);
    eq(r.result, 0, "result: " + r.message);
    eq(c.nodes["102"].resets, 1, "the leftover node was reset");
    assert(c.nodes["102"].device != old, "it has a new identity");
    contains(r.message, "Node 102 still had Syncthing from an earlier install", "reported");
    eq([c.nodes["101"].folderType, c.nodes["102"].folderType], ["sendreceive", "receiveonly"], "the master seeds, the leftover node joins");
    contains(r.message, "Node 101 is the seed", "report names the master as the seed");
    eq(c.nodes["102"].joinFrom, [c.nodes["101"].device], "it joins against the master");
    // Events never reset: only a fresh install passes --fresh.
    r = apply(c, "scale");
    eq([r.result, c.nodes["102"].resets, c.nodes["102"].prepared.fresh, c.nodes["102"].prepared["count-b64"]], [0, 1, undefined, undefined], "no reset or count on events");
});

test("install refuses a seed with far fewer files than another node, unless the form names it", function () {
    var c, r, specs = function (m, o) { return [{ id: 101, master: true, files: m, bytes: m * 1000 }, { id: 102, files: o, bytes: o * 1000 }, { id: 103, files: 10 }]; };
    // an empty master (recreated) and a node with the site
    c = cluster(specs(0, 268));
    r = apply(c, "install", INSTALL_FORM);
    eq(r.result, 99, "empty master refused");
    contains(r.message, "Node 101 (master) would be the starting copy, but it holds 0 file(s) (0 B) in " + DEFAULT_PATH + " while node 102 holds 268 (261.7 KB)", "names the nodes and counts");
    contains(r.message, "enter the id of the node with the right copy in Starting copy (101 to use node 101's copy anyway). Nothing was installed.", "says how to go on");
    eq(c.p.settings("env1"), null, "no settings saved");
    eq([c.nodes["101"].plans.length, c.nodes["102"].plans.length, c.nodes["103"].plans.length], [0, 0, 0], "no node was configured");
    eq([c.nodes["101"].removed, c.nodes["102"].removed, c.nodes["103"].removed], [true, true, true], "Syncthing taken off again");
    // a partial master (less than half of the largest copy)
    c = cluster(specs(120, 250));
    eq(apply(c, "install", INSTALL_FORM).result, 99, "partial master refused");
    // a similar master: fine
    c = cluster(specs(130, 250));
    eq(apply(c, "install", INSTALL_FORM).result, 0, "master with at least half the files: installed");
    // the form names the master: its copy anyway
    c = cluster(specs(0, 268));
    r = apply(c, "install", INSTALL_FORM, { seedNode: "101" });
    eq([r.result, c.nodes["101"].folderType, c.nodes["102"].folderType], [0, "sendreceive", "receiveonly"], "named master seeds");
    // the form names another node: it seeds, the master joins against it
    c = cluster(specs(0, 268));
    r = apply(c, "install", INSTALL_FORM, { seedNode: "102" });
    eq([r.result, c.nodes["102"].folderType, c.nodes["101"].folderType], [0, "sendreceive", "receiveonly"], "named node seeds");
    contains(r.message, "Node 102 is the seed", "reported");
    eq(c.nodes["101"].joinFrom, [c.nodes["102"].device], "the master joins against the named seed");
    eq(c.p.settings("env1").seedNodeId, "102", "saved");
    // a named node that is not running, or not a node id
    c = cluster(specs(0, 268));
    r = apply(c, "install", INSTALL_FORM, { seedNode: "999" });
    eq(r.result, 99, "unknown node refused");
    contains(r.message, "Starting copy: node 999 is not a running node of the app layer (nodes 101, 102, 103). Nothing was installed.", "message");
    eq(c.p.settings("env1"), null, "nothing saved");
    c = cluster(specs(0, 268));
    eq(apply(c, "install", INSTALL_FORM, { seedNode: "abc" }).result, 99, "not a node id");
    eq(c.p.execCalls().length, 0, "refused before touching a node");
    // after install the field means nothing (events carry its install-time value)
    c = cluster([{ id: 101, master: true, folderType: "sendreceive" }, { id: 104 }]);
    saveSettings(c, settings({ "101": c.nodes["101"] }));
    r = apply(c, "scale", null, { seedNode: "104" });
    eq([r.result, c.nodes["101"].folderType, c.nodes["104"].folderType], [0, "sendreceive", "receiveonly"], "ignored on events");
});

test("a failed node on install fails the op", function () {
    var c = cluster([{ id: 101, master: true }, { id: 102, fail: { prepare: "/var/www/webroot/ROOT is on a fuse.glusterfs filesystem" } }, { id: 103 }]), r;
    r = apply(c, "install", INSTALL_FORM);
    eq(r.result, 99, "result");
    contains(r.message, "Node 102: /var/www/webroot/ROOT is on a fuse.glusterfs filesystem", "names the node and the runner's message");
    contains(r.message, "Nothing was installed", "says nothing was installed");
    eq([c.nodes["101"].plans.length, c.nodes["102"].plans.length, c.nodes["103"].plans.length], [0, 0, 0], "no node was configured");
    eq(c.p.settings("env1"), null, "no settings saved");
    eq([c.nodes["101"].removed, c.nodes["102"].removed, c.nodes["103"].removed], [true, true, false], "the touched nodes are cleaned up");
    eq(c.nodes["103"].commands.length, 0, "the node after the failure is not touched");
});

test("a failed API plan on install fails the op and cleans up", function () {
    var c = cluster([{ id: 101, master: true }, { id: 102 }, { id: 103, fail: { apiAt: 3 } }]), r;
    r = apply(c, "install", INSTALL_FORM);
    eq(r.result, 99, "result");
    contains(r.message, "Node 103: api: plan line 3 (POST /rest/config/folders) failed with HTTP 500. Nothing was installed", "names the node, the step and the error");
    eq(c.p.settings("env1"), null, "no settings saved");
    eq([c.nodes["101"].removed, c.nodes["102"].removed, c.nodes["103"].removed], [true, true, true], "every node is cleaned up");
});

test("install with a stopped node seeds from the running ones and reports it", function () {
    var c = cluster([{ id: 101, master: true, status: 2 }, { id: 102 }, { id: 103 }]), r;
    r = apply(c, "install", INSTALL_FORM);
    eq(r.result, 0, "result");
    eq(c.nodes["101"].commands.length, 0, "stopped node untouched");
    eq(c.nodes["102"].folderType, "sendreceive", "lowest running id seeds when the master is stopped");
    eq(c.nodes["103"].folderType, "receiveonly", "the other joins");
    contains(r.onAfterReturn.setGlobals.stReport, "Node 101 is not running", "reported");
});

test("the firewall rule is added once, only when the account's firewall is on", function () {
    var c = cluster([{ id: 101, master: true }, { id: 102 }], { firewall: true }), r;
    r = apply(c, "install", INSTALL_FORM);
    eq(r.result, 0, "install");
    eq(c.p.rules.length, 1, "one rule");
    eq(c.p.rules[0].group, "cp", "on the app layer");
    eq([c.p.rules[0].rule.direction, c.p.rules[0].rule.protocol, c.p.rules[0].rule.ports, c.p.rules[0].rule.action], ["INPUT", "TCP", "22000", "ALLOW"], "rule");
    r = apply(c, "configure", INSTALL_FORM);
    eq(r.result, 0, "configure");
    eq(c.p.rules.length, 1, "no duplicate on Configure");
    c = cluster([{ id: 101, master: true }], { firewall: false });
    eq(apply(c, "install", INSTALL_FORM).result, 0, "install without firewall");
    eq(c.p.rules.length, 0, "no rule when the firewall is off");
});

// ---- events ---------------------------------------------------------------------------------

test("on scale a new node joins receive-only and existing nodes keep their type", function () {
    var c = cluster([{ id: 101, master: true, folderType: "sendreceive" }, { id: 102, folderType: "sendreceive" },
                     { id: 104, copyOf: "node101" }]), before, r, s, f, k;
    before = settings({ "101": c.nodes["101"], "102": c.nodes["102"] }, { ignore: "(?d)custom-rule", delay: 3, versionsDays: 7 });
    saveSettings(c, before);
    before = c.nodes["104"].device;
    // stale install-time form values must be ignored on events
    r = apply(c, "scale", { path: "/other", ignore: "stale", delay: "9", versionsDays: "1" });
    eq(r.result, 0, "result: " + r.message);
    contains(r.message, "Node 104 was a copy of another node", "clone reported");
    assert(c.nodes["104"].device != before, "the copy got its own identity");
    eq(c.nodes["104"].folderType, "receiveonly", "new node joins receive-only");
    eq(c.nodes["104"].joins, 1, "new node starts the safe join");
    eq(c.nodes["104"].joinFrom.sort(), [c.nodes["101"].device, c.nodes["102"].device].sort(), "it joins against the send-receive nodes");
    for (k in { "101": 1, "102": 1 }) {
        f = planLine(c.nodes[k], "PATCH", "/rest/config/folders/webroot");
        assert(f && f.type === undefined, "existing node " + k + " is patched without a type change");
        eq(f.fsWatcherDelayS, 3, "saved delay on " + k);
        eq(f.versioning.params.cleanoutDays, "7", "saved versioning on " + k);
        eq(devicesOf(f.devices).length, 3, "folder shared with the new node on " + k);
        eq(c.nodes[k].folderType, "sendreceive", "node " + k + " keeps send-receive");
        eq(c.nodes[k].joins, 0, "node " + k + " does not join");
        eq(c.nodes[k].prepared.path, DEFAULT_PATH, "saved path used on " + k);
        eq(c.nodes[k].ignore, "(?d)custom-rule\n", "saved ignore rules on " + k);
    }
    s = c.p.settings("env1");
    eq(s.seedNodeId, "101", "seed unchanged");
    eq(s.nodes["104"].device, c.nodes["104"].device, "new node saved");
    eq([s.nodes["101"].type, s.nodes["104"].type], ["sendreceive", "receiveonly"], "folder types saved");
    eq(s.nodes["101"].joinedAt, "2026-09-01T00:00:00.000Z", "joinedAt kept for unchanged identities");
    eq([s.path, s.ignore, s.delay, s.versionsDays], [DEFAULT_PATH, "(?d)custom-rule", 3, 7], "settings unchanged by the event");
});

test("scale in removes the node's device everywhere and drops it from the settings", function () {
    var c = cluster([{ id: 101, master: true, folderType: "sendreceive" }, { id: 102, folderType: "sendreceive" }]), r, s, k, plan, gone = H.fakeDevice("gone");
    s = settings({ "101": c.nodes["101"], "102": c.nodes["102"], "103": { device: gone } });
    saveSettings(c, s);
    r = apply(c, "scale");
    eq(r.result, 0, "result");
    for (k in { "101": 1, "102": 1 }) {
        plan = c.nodes[k].lastPlan();
        eq(planLine(c.nodes[k], "PUT", "/rest/config/devices").length, 2, "devices without the removed node on " + k);
        eq(devicesOf(planLine(c.nodes[k], "PATCH", "/rest/config/folders/webroot").devices).length, 2, "folder unshared on " + k);
        // PUT never removes a device: an explicit DELETE, after the folder PATCH
        eq([plan[plan.length - 1].method, plan[plan.length - 1].path], ["DELETE", "/rest/config/devices/" + gone], "DELETE of the removed device on " + k);
    }
    eq(Object.keys(c.p.settings("env1").nodes).sort(), ["101", "102"], "removed node dropped from settings");
    r = apply(c, "scale");
    assert(!hasLine(c.nodes["101"], "DELETE", "/rest/config/devices/" + gone), "no DELETE once it is gone everywhere");
});

test("a node that left stays listed until every node applied", function () {
    var c = cluster([{ id: 101, master: true, folderType: "sendreceive" }, { id: 102, folderType: "sendreceive", fail: { api: "Syncthing does not answer" } }]),
        r, gone = H.fakeDevice("gone");
    saveSettings(c, settings({ "101": c.nodes["101"], "102": c.nodes["102"], "103": { device: gone } }));
    r = apply(c, "scale");
    eq(r.result, 99, "reported");
    eq(c.p.settings("env1").nodes["103"].device, gone, "kept while node 102 missed the removal");
    delete c.nodes["102"].fail.api;
    r = apply(c, "scale");
    eq(r.result, 0, "second apply");
    assert(hasLine(c.nodes["102"], "DELETE", "/rest/config/devices/" + gone), "removed on the node that missed it");
    eq(c.p.settings("env1").nodes["103"], undefined, "then dropped");
});

test("a node with a new identity: the old device is removed, a device still in use never", function () {
    var c = cluster([{ id: 101, master: true, folderType: "sendreceive" }, { id: 104, copyOf: "node101" }]), r, k, plan, i;
    // 104 was saved with 101's identity (a copy that was never re-applied)
    saveSettings(c, settings({ "101": c.nodes["101"], "104": c.nodes["101"] }));
    r = apply(c, "scale");
    eq(r.result, 0, "result");
    for (k in c.nodes) {
        plan = c.nodes[k].lastPlan();
        for (i = 0; i < plan.length; i++) assert(plan[i].method != "DELETE", "101's identity is in use: not deleted on " + k);
    }
    eq(c.p.settings("env1").nodes["104"].device, c.nodes["104"].device, "new identity saved");
});

test("an event skips a failed node, updates the rest and reports it", function () {
    var c = cluster([{ id: 101, master: true, folderType: "sendreceive" }, { id: 102, folderType: "sendreceive", fail: { prepare: "disk full" } },
                     { id: 104 }]), r, s;
    saveSettings(c, settings({ "101": c.nodes["101"], "102": c.nodes["102"] }));
    r = apply(c, "scale");
    eq(r.result, 99, "the event reports the failure");
    contains(r.message, "skipped node 102 (disk full)", "names the node and the message");
    eq(c.nodes["104"].folderType, "receiveonly", "the new node still joins");
    eq(planLine(c.nodes["101"], "PUT", "/rest/config/devices").length, 3, "the skipped node stays in the mesh with its saved identity");
    s = c.p.settings("env1");
    eq(s.nodes["102"].device, c.nodes["102"].device, "skipped node kept in the settings");
    assert(s.nodes["104"], "new node saved");
});

test("no seed while a known node that may hold the data did not answer", function () {
    var c = cluster([{ id: 101, master: true, folderType: "sendreceive", fail: { prepare: "timeout" } }, { id: 104 }]), r;
    saveSettings(c, settings({ "101": c.nodes["101"] }));
    r = apply(c, "scale");
    eq(r.result, 99, "reported");
    eq(c.nodes["104"].folderType, "receiveonly", "the new node waits receive-only instead of seeding");
    eq(c.nodes["104"].joinFrom, [c.nodes["101"].device], "it joins against the saved send-receive node once that is back");
    eq(c.p.settings("env1").seedNodeId, "101", "seed unchanged");
    eq(c.p.settings("env1").nodes["101"].type, "sendreceive", "the node that did not answer keeps its saved type");
});

test("joiners never sync against another joiner alone", function () {
    // Every send-receive node is stopped (the seed-down case): the new nodes
    // may only wait for them, not for each other.
    var c = cluster([{ id: 101, master: true, folderType: "sendreceive", status: 2 }, { id: 104 }, { id: 105 }]), r;
    saveSettings(c, settings({ "101": c.nodes["101"] }));
    r = apply(c, "scale");
    eq(r.result, 0, "result: " + r.message);
    eq([c.nodes["104"].joinFrom, c.nodes["105"].joinFrom], [[c.nodes["101"].device], [c.nodes["101"].device]], "both wait for the stopped send-receive node");
    // No send-receive node known at all (saved without a type): wait, and say so.
    c = cluster([{ id: 101, master: true, folderType: "sendreceive", status: 2 }, { id: 104 }]);
    saveSettings(c, settings({ "101": { device: c.nodes["101"].device } }));
    r = apply(c, "scale");
    eq([r.result, c.nodes["104"].folderType, c.nodes["104"].joinFrom], [0, "receiveonly", null], "joins without a list: it waits");
    contains(r.message, "No node is known to send the directory's content (send-receive), so these nodes wait receive-only: node 104.", "warned");
});

test("redeploy keeps types and restarts an interrupted join", function () {
    var c = cluster([{ id: 101, master: true, folderType: "sendreceive" }, { id: 102, folderType: "receiveonly", join: "none" },
                     { id: 103, folderType: "receiveonly", join: "running" }]), r;
    saveSettings(c, settings({ "101": c.nodes["101"], "102": c.nodes["102"], "103": c.nodes["103"] }));
    r = apply(c, "redeploy");
    eq(r.result, 0, "result");
    eq([c.nodes["101"].folderType, c.nodes["102"].folderType, c.nodes["103"].folderType], ["sendreceive", "receiveonly", "receiveonly"], "types kept");
    eq(c.nodes["102"].joins, 1, "interrupted join restarted");
    eq([c.nodes["102"].joinFrom, c.nodes["103"].joinFrom], [[c.nodes["101"].device], [c.nodes["101"].device]], "against the send-receive node only");
    eq(c.nodes["103"].callsOf("join").length, 1, "running join asked again (idempotent)");
    eq(c.nodes["101"].callsOf("join").length, 0, "no join on a send-receive node");
    assert(!planLine(c.nodes["102"], "POST", "/rest/config/folders"), "existing folder patched, not re-created");
});

test("an event without saved settings fails instead of guessing", function () {
    var c = cluster([{ id: 101, master: true }]), r;
    r = apply(c, "migrate");
    eq(r.result, 99, "result");
    contains(r.message, "no saved settings", "message");
    eq(c.p.execCalls().length, 0, "no node touched");
});

test("clone phase resets identities and seeds the copy", function () {
    var c = cluster([{ id: 101, master: true, folderType: "sendreceive" }, { id: 102, folderType: "sendreceive" }]), copy, r, s, orig, i, calls;
    orig = settings({ "101": c.nodes["101"], "102": c.nodes["102"] }, { ignore: "(?d)custom-rule", delay: 4 });
    saveSettings(c, orig);
    copy = cluster([{ id: 201, master: true, copyOf: "node101", folderType: "sendreceive" }, { id: 202, copyOf: "node102", folderType: "sendreceive" }],
                   { platform: c.p, nodes: c.nodes, env: "env1-clone" });
    saveSettings(copy, orig);   // the copy carries the original's node group data
    r = apply(c, "clone", null, { cloneEnvName: "env1-clone" });
    eq(r.result, 0, "result: " + r.message);
    eq(c.nodes["201"].folderType, "sendreceive", "the copy's master seeds");
    eq([c.nodes["202"].folderType, c.nodes["202"].joins], ["receiveonly", 1], "the other node joins");
    s = c.p.settings("env1-clone");
    eq(Object.keys(s.nodes).sort(), ["201", "202"], "only the copy's nodes");
    eq([s.seedNodeId, s.ignore, s.delay], ["201", "(?d)custom-rule", 4], "seed reset, settings kept");
    eq(c.p.settings("env1").updated, orig.updated, "the original's settings are untouched");
    calls = c.p.execCalls();
    for (i = 0; i < calls.length; i++) eq(calls[i].env, "env1-clone", "every command goes to the copy");
    eq([c.nodes["101"].commands.length, c.nodes["102"].commands.length], [0, 0], "the original's nodes are untouched");
    eq(planLine(c.nodes["202"], "PUT", "/rest/config/devices").length, 2, "the copy's own mesh");
});

test("clone phase takes the original's settings when the copy has none", function () {
    var c = cluster([{ id: 101, master: true, folderType: "sendreceive" }]), r;
    saveSettings(c, settings({ "101": c.nodes["101"] }, { ignore: "(?d)from-original" }));
    cluster([{ id: 301, master: true }], { platform: c.p, nodes: c.nodes, env: "copy2" });
    r = apply(c, "clone", null, { cloneEnvName: "copy2" });
    eq(r.result, 0, "result");
    eq(c.nodes["301"].ignore, "(?d)from-original\n", "original's rules applied");
    eq(c.p.settings("copy2").ignore, "(?d)from-original", "saved on the copy");
});

// ---- Configure -----------------------------------------------------------------------------

test("configure updates ignore rules and delay without changing path", function () {
    var c = cluster([{ id: 101, master: true, folderType: "sendreceive" }, { id: 102, folderType: "sendreceive" }]), r, s, f;
    saveSettings(c, settings({ "101": c.nodes["101"], "102": c.nodes["102"] }));
    r = apply(c, "configure", { path: "/srv/other", ignore: "(?d)/wp-content/cache\r\n*.tmp\r\n", delay: "5", versionsDays: "0" });
    eq(r.result, "warning", "a changed path is reported");
    contains(r.message, "The directory cannot be changed after install; it stays " + DEFAULT_PATH, "message");
    s = c.p.settings("env1");
    eq([s.path, s.ignore, s.delay, s.versionsDays, s.seedNodeId], [DEFAULT_PATH, "(?d)/wp-content/cache\n*.tmp", 5, 0, "101"], "saved");
    eq([c.nodes["101"].prepared.path, c.nodes["102"].prepared.path], [DEFAULT_PATH, DEFAULT_PATH], "prepare keeps the path");
    eq([c.nodes["101"].ignore, c.nodes["102"].ignore], ["(?d)/wp-content/cache\n*.tmp\n", "(?d)/wp-content/cache\n*.tmp\n"], "new rules written");
    f = planLine(c.nodes["101"], "PATCH", "/rest/config/folders/webroot");
    eq([f.fsWatcherDelayS, f.versioning.type, f.type], [5, "", undefined], "delay and versioning patched, type kept");

    r = apply(c, "configure", { path: DEFAULT_PATH, ignore: "", delay: "5", versionsDays: "3" });
    eq(r.result, 0, "unchanged path: plain success");
    eq(c.p.settings("env1").ignore, "(?d)/wp-content/cache\n*.tmp", "empty rules keep the current ones");
});

test("configure rejects bad values before touching a node", function () {
    var c = cluster([{ id: 101, master: true, folderType: "sendreceive" }]), r;
    saveSettings(c, settings({ "101": c.nodes["101"] }));
    r = apply(c, "configure", { path: DEFAULT_PATH, ignore: "x", delay: "0", versionsDays: "3" });
    eq(r.result, 99, "delay 0");
    r = apply(c, "configure", { path: DEFAULT_PATH, ignore: "x", delay: "2", versionsDays: "999" });
    eq(r.result, 99, "versionsDays 999");
    c = cluster([{ id: 101, master: true }]);
    r = apply(c, "install", { path: "/var/www/../etc", ignore: "", delay: "2", versionsDays: "3" });
    eq(r.result, 99, "path with ..");
    eq(c.p.execCalls().length, 0, "no node touched");
});

test("a failed node on Configure fails the op and keeps the settings", function () {
    var c = cluster([{ id: 101, master: true, folderType: "sendreceive" }, { id: 102, folderType: "sendreceive", fail: { ignore: "cannot write .stignore" } }]), r;
    saveSettings(c, settings({ "101": c.nodes["101"], "102": c.nodes["102"] }));
    r = apply(c, "configure", { path: DEFAULT_PATH, ignore: "(?d)new", delay: "2", versionsDays: "14" });
    eq(r.result, 99, "result");
    contains(r.message, "Node 102: ignore: cannot write .stignore", "names the node and the step");
    eq(c.p.settings("env1").ignore, DEFAULT_IGNORE, "settings not saved");
    eq([c.nodes["101"].removed, c.nodes["102"].removed], [false, false], "Configure never removes anything");
});

// ---- settings read failure -----------------------------------------------------------------

test("settings read failure throws", function () {
    var phases = ["install", "configure", "scale", "redeploy", "clone"], i, c, r;
    for (i = 0; i < phases.length; i++) {
        c = cluster([{ id: 101, master: true }]);
        c.p.failApi.GetNodeGroups = true;
        r = apply(c, phases[i], INSTALL_FORM, { cloneEnvName: "env1" });
        eq(r.result, 99, phases[i] + ": result");
        contains(r.message, "could not read the add-on settings of env1", phases[i] + ": message");
        eq(c.p.execCalls().length, 0, phases[i] + ": no node touched");
        eq(c.p.env("env1").groups.cp.stSync, undefined, phases[i] + ": nothing written");
    }
    c = cluster([{ id: 101, master: true }]);
    saveSettings(c, "not json");
    c.p.env("env1").groups.cp.stSync = "{not json";
    r = apply(c, "scale");
    eq(r.result, 99, "invalid saved JSON is an error, not 'no settings'");
    contains(r.message, "not valid JSON", "message");
});

test("a failed settings write is reported and undoes a fresh install", function () {
    var c = cluster([{ id: 101, master: true }]), r;
    c.p.failApi.ApplyNodeGroupData = true;
    r = apply(c, "install", INSTALL_FORM);
    eq(r.result, 99, "result");
    contains(r.message, "Could not save the add-on settings", "message");
    eq(c.nodes["101"].removed, true, "fresh install undone");
});

// ---- status and rescan -----------------------------------------------------------------------

function statusCluster(overrides, opts) {
    var specs = [{ id: 101, master: true, folderType: "sendreceive" }, { id: 102, folderType: "sendreceive" }, { id: 103, folderType: "sendreceive" }], i, c;
    for (i = 0; i < specs.length; i++) { specs[i].statusJSON = overrides[specs[i].id]; specs[i].hasRunner = true; }
    c = cluster(specs, opts);
    saveSettings(c, settings({ "101": c.nodes["101"], "102": c.nodes["102"], "103": c.nodes["103"] }));
    for (i in c.nodes) c.nodes[i].peers = 2;
    return c;
}

test("status output text", function () {
    var c = statusCluster({ 102: { folderType: "receiveonly", state: "syncing", needItems: 12, needBytes: 3145728, join: "running" },
                            103: { connectedPeers: 1, errors: 2, conflicts: 3 } }), r, calls;
    r = H.runManage(REPO, c.p, { op: "status", envName: "env1" });
    eq(r.result, "info", "an info popup");
    contains(r.message, "Overall: PROBLEMS on node 103; syncing on node 102", "overall line");
    contains(r.message, "Directory: " + DEFAULT_PATH, "directory");
    contains(r.message, "Node 101 (master): in sync  \nservice active (v2.1.5), device " + c.nodes["101"].device.substring(0, 7) +
             ", folder send-receive, state idle, need 0 items (0 B), peers 2/2, errors 0, conflicts 0, last scan 2026-09-30T10:00:00Z", "in-sync block");
    contains(r.message, "Node 102: syncing  \nservice active (v2.1.5), device " + c.nodes["102"].device.substring(0, 7) +
             ", folder receive-only (joining), state syncing, need 12 items (3.0 MB)", "syncing block");
    contains(r.message, "Node 103: PROBLEM - 2 error(s), peers disconnected", "problem block");
    contains(r.message, "peers 1/2, errors 2, conflicts 3", "problem details");
    contains(r.message, "3 conflict copies (*.sync-conflict-*) to review", "conflicts summarised");
    calls = c.p.execCalls();
    eq([calls.length, calls[0].api], [1, "ExecCmdByGroup"], "one group call");
    contains(calls[0].command, "status --folder webroot --path '" + DEFAULT_PATH + "'", "runner status command");

    c = statusCluster({});
    r = H.runManage(REPO, c.p, { op: "status", envName: "env1" });
    contains(r.message, "Overall: in sync on all 3 node(s)", "all in sync");
});

test("status reports stopped and unanswered nodes and falls back to per-node calls", function () {
    var c = statusCluster({}), r, calls;
    c.p.env("env1").nodes[2].status = 2;
    c.nodes["102"].fail.status = "Syncthing does not answer";
    c.p.groupNoNodeIds = true;
    r = H.runManage(REPO, c.p, { op: "status", envName: "env1" });
    eq(r.result, "info", "still an info popup");
    contains(r.message, "Overall: PROBLEMS on nodes 102, 103", "overall");
    contains(r.message, "Node 103: not running", "stopped node");
    contains(r.message, "Node 102: no status (Syncthing does not answer)", "failed node");
    calls = c.p.execCalls();
    eq([calls[0].api, calls[1].api, calls[2].api, calls.length], ["ExecCmdByGroup", "ExecCmdById", "ExecCmdById", 3], "per-node fallback for running nodes only");
});

test("status: receive-only without a join is a problem; a joiner's conflict copies are temporary", function () {
    var c = statusCluster({ 102: { folderType: "receiveonly", join: "none" },
                            103: { folderType: "receiveonly", join: "running", joinPhase: "waiting for a send-receive node", conflicts: 56 } }), r;
    r = H.runManage(REPO, c.p, { op: "status", envName: "env1" });
    contains(r.message, "Overall: PROBLEMS on node 102; syncing on node 103", "overall");
    contains(r.message, "Node 102: PROBLEM - receive-only but no join is running - open Configure and click Save", "a stuck receive-only node");
    contains(r.message, "folder receive-only (joining: waiting for a send-receive node)", "the join's phase");
    contains(r.message, "conflicts 56 (temporary: set aside when the join finishes)", "a joiner's conflict copies");
    assert(r.message.indexOf("to review") < 0, "not counted as conflicts to review");
    c = statusCluster({ 102: { folderType: "receiveonly", join: "failed" } });
    r = H.runManage(REPO, c.p, { op: "status", envName: "env1" });
    contains(r.message, "Node 102: PROBLEM - join failed", "a failed join");
});

test("status flags nodes whose copies diverged", function () {
    // All three report in sync, but node 103 kept files the others deleted.
    var c = statusCluster({ 103: { globalFiles: 44, globalDeleted: 1, globalBytes: 423022 } }), r;
    r = H.runManage(REPO, c.p, { op: "status", envName: "env1" });
    contains(r.message, "Overall: PROBLEMS on node 103", "overall");
    contains(r.message, "The copies differ: node 103 report(s) a different directory content than the other nodes", "explained");
    contains(r.message, "Node 103: PROBLEM - diverged: 44 files, 7 directories, 1 deleted, 413.1 KB, the other nodes 42 files, 7 directories, 3 deleted, 410.2 KB", "node block");
    contains(r.message, "Node 101 (master): in sync", "the majority stays in sync");
    // Two nodes that disagree: no majority, both flagged.
    c = statusCluster({ 102: { globalFiles: 40 }, 103: { folderType: "receiveonly", join: "running" } });
    r = H.runManage(REPO, c.p, { op: "status", envName: "env1" });
    contains(r.message, "Overall: PROBLEMS on nodes 101, 102; syncing on node 103", "tie: both flagged, the syncing node not compared");
    // A node still syncing is not compared.
    c = statusCluster({ 103: { globalFiles: 40, needItems: 2, state: "syncing" } });
    r = H.runManage(REPO, c.p, { op: "status", envName: "env1" });
    contains(r.message, "Overall: syncing - node 103 still catching up", "no divergence while syncing");
});

test("rescan asks every node", function () {
    var c = statusCluster({}), r;
    r = H.runManage(REPO, c.p, { op: "rescan", envName: "env1" });
    eq(r.result, 0, "result");
    eq([c.nodes["101"].rescans, c.nodes["102"].rescans, c.nodes["103"].rescans], [1, 1, 1], "every node");
    c.nodes["103"].fail.rescan = "HTTP 500";
    r = H.runManage(REPO, c.p, { op: "rescan", envName: "env1" });
    eq(r.result, "warning", "partial failure is a warning");
    contains(r.message, "Not started: node 103 (HTTP 500)", "message");
});

// ---- manifest ---------------------------------------------------------------------------------

function uninstall(c) {
    return H.runInline(MANIFEST.onUninstall[0].script, { "env.envName": c.env, "globals.base_path": BASE }, c.p, undefined);
}

test("uninstall removes Syncthing from every node and clears the settings", function () {
    var c = statusCluster({}), r, k;
    c.p.env("env1").groups.cp.stSync = JSON.stringify(settings({}, { path: "/var/www/webroot/site" }));
    c.nodes["102"].hasRunner = false;
    c.nodes["103"].hasRunner = false;
    r = uninstall(c);
    eq(r.result, 0, "result");
    for (k in c.nodes) {
        eq(c.nodes[k].removed, true, "removed on " + k);
        eq(c.nodes[k].callsOf("remove")[0].args.path, "/var/www/webroot/site", "saved path on " + k);
    }
    eq(c.nodes["101"].downloads.length, 0, "an installed runner is not downloaded again");
    assert(c.nodes["102"].downloads[0].indexOf(BASE + "/scripts/stsync.sh") === 0, "a missing runner is downloaded");
    eq(c.p.env("env1").groups.cp.stSync, "", "settings cleared");
});

test("uninstall never fails", function () {
    var c = statusCluster({}), r;
    c.p.failApi.GetNodeGroups = true;
    c.nodes["101"].fail.download = true;
    c.p.jelastic = (function (orig) {
        return function () { var j = orig.call(this); j.env.control.ExecCmdById = function () { throw "node unreachable"; }; return j; };
    })(c.p.jelastic);
    r = uninstall(c);
    eq(r.result, 0, "API errors are ignored");
    c = statusCluster({});
    c.p.failApi.GetEnvInfo = true;
    c.p.failApi.ApplyNodeGroupData = true;
    eq(uninstall(c).result, 0, "GetEnvInfo and ApplyNodeGroupData failures are ignored");
    c = statusCluster({});
    c.nodes["101"].hasRunner = false;
    c.nodes["101"].fail.download = true;
    eq(uninstall(c).result, 0, "a runner that cannot be downloaded is not an error");
    eq([c.nodes["101"].removed, c.nodes["102"].removed], [false, true], "only that node is left");
});

function configureForm(c) {
    var form = JSON.parse(JSON.stringify(MANIFEST.settings.main));
    return H.runInline(form.onBeforeInit, { "env.envName": c.env }, c.p, form);
}
function field(form, name) { var i; for (i = 0; i < form.fields.length; i++) if (form.fields[i].name == name) return form.fields[i]; return null; }

test("the Configure form shows the settings in force, the directory read-only", function () {
    var c = cluster([{ id: 101, master: true }]), form;
    form = configureForm(c);
    eq([field(form, "path")["default"], field(form, "path").readOnly], [DEFAULT_PATH, undefined], "no settings: install defaults");
    eq(field(form, "ignore")["default"], DEFAULT_IGNORE + "\n", "default rules");
    eq([field(form, "seedNode").type, field(form, "seedNode").required], ["string", false], "install: the optional starting copy field");
    saveSettings(c, settings({}, { path: "/var/www/webroot/site", ignore: "(?d)mine", delay: 7, versionsDays: 0 }));
    form = configureForm(c);
    eq([field(form, "path")["default"], field(form, "path").readOnly], ["/var/www/webroot/site", true], "saved path, read-only");
    eq(field(form, "seedNode"), null, "the starting copy is an install-only field");
    eq([field(form, "ignore")["default"], field(form, "ignore").value], ["(?d)mine", "(?d)mine"], "saved rules");
    eq([field(form, "delay")["default"], field(form, "versionsDays")["default"]], [7, 0], "saved numbers");
    c.p.failApi.GetNodeGroups = true;
    form = configureForm(c);
    eq(field(form, "ignore")["default"], "", "after a failed read the rules are empty (Save keeps the current ones)");
    eq([form.fields[0].type, form.fields[0].cls], ["displayfield", "warning"], "warning shown");
});

test("manifest wiring", function () {
    var m = MANIFEST, src = H.readFile(REPO + "/scripts/manage.js"), names, i, p = m.actions.manage[0].params, ev;
    eq([m.type, m.targetNodes.nodeGroup, m.globals.base_path, m.settings.main.submitUnchanged], ["update", "cp", "${baseUrl}", true], "basics");
    names = /var NAMES = \[([^\]]*)\]/.exec(src)[1].replace(/[" \n]/g, "").split(",");
    for (i = 0; i < names.length; i++) assert(p[names[i]] !== undefined, "the manage action passes " + names[i]);
    eq(p.basePath, "${globals.base_path}", "basePath from globals");
    assert(/^\$\{globals\.base_path\}\/scripts\/manage\.js\?_r=/.test(m.actions.manage[0].script), "script from base_path, cache-busted");
    ev = { onInstall: "install", "onAfterScaleOut[cp]": "scale", "onAfterScaleIn[cp]": "scale", "onAfterRedeployContainer[cp]": "redeploy",
           onAfterMigrate: "migrate", onAfterClone: "clone" };
    for (i in ev) eq([m[i][0].manage.op, m[i][0].manage.phase], ["apply", ev[i]], i);
    eq(m.onAfterClone[0].manage.cloneEnvName, "${event.response.env.envName}", "clone targets the copy");
    eq([m.buttons[0].caption, m.buttons[1].caption, m.buttons[2].caption], ["Status", "Configure", "Rescan"], "buttons");
    eq([m.actions.configure[0].manage.phase, m.actions.status[0].manage.op, m.actions.rescan[0].manage.op], ["configure", "status", "rescan"], "button actions");
    eq(m.settings.main.fields[1]["default"].replace(/\n$/, ""), DEFAULT_IGNORE, "form default rules = manage.js defaults");
});

print("\n" + H.results.pass + " passed, " + H.results.fail + " failed" + (H.results.fail ? ": " + H.results.failures.join("; ") : ""));
java.lang.System.exit(H.results.fail ? 1 : 0);
