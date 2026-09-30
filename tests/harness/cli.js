/*
 * DOCKER mode: runs the real scripts/manage.js (or the manifest's inline
 * onUninstall / Configure form script) against containers, the way the
 * platform would, through the harness's stub `jelastic`. Node commands run
 * with `docker exec <container> bash -c <command>` (or the Engine API on
 * /var/run/docker.sock when there is no docker CLI). Use tests/harness/manage.sh,
 * which runs this in JDK 11.
 *
 * jjs cli.js -- <repo> <manifest.json> <state.json> key=value...
 *   env=NAME             environment name (default: sta-env)
 *   nodes=ID:CONTAINER[:master][:stopped],...   the app layer (cp) nodes;
 *                        private IPs come from `docker inspect`
 *   clone-env=NAME clone-nodes=...   the copy, for phase=clone
 *   base=URL             basePath: where the nodes download scripts/stsync.sh
 *   dockerenv=K=V;K=V    environment of every command (for example
 *                        STSYNC_DOWNLOAD_BASE=http://host.docker.internal:8000)
 *   firewall=1           the account's firewall is on
 *   op=apply|status|rescan|uninstall|form   phase=install|configure|scale|...
 *   path= delay= versionsDays=  form values; ignore-b64= the ignore rules
 *   log=FILE             write every node command and its output there
 * The node group data (settings) and firewall rules persist in state.json
 * between runs, like the platform keeps them. Prints the script's result as
 * JSON on the last line; exit 0 for result 0 or info, 2 for warning, 1 else.
 */
load(__DIR__ + "harness.js");

var argv = [], i;
for (i = 0; i < arguments.length; i++) argv.push(String(arguments[i]));
var REPO = argv[0], MANIFEST = JSON.parse(H.readFile(argv[1])), STATE_FILE = argv[2], A = {};
for (i = 3; i < argv.length; i++) {
    var eqAt = argv[i].indexOf("=");
    if (eqAt > 0) A[argv[i].substring(0, eqAt)] = argv[i].substring(eqAt + 1);
}
var ENV = A.env || "sta-env";

var state = { envs: {}, rules: [] };
try { state = JSON.parse(H.readFile(STATE_FILE)); } catch (e) { /* first run */ }

function parseNodes(spec) {
    var out = [], parts = String(spec || "").split(","), j, f;
    for (j = 0; j < parts.length; j++) {
        if (!parts[j]) continue;
        f = parts[j].split(":");
        out.push({ id: parseInt(f[0], 10), container: f[1], ismaster: f.indexOf("master") > 1, status: f.indexOf("stopped") > 1 ? 2 : 1 });
    }
    return out;
}

var map = {}, dockerEnv = {}, envNodes = {}, platform, name, list, j, k, p;
envNodes[ENV] = parseNodes(A.nodes);
if (A["clone-env"]) envNodes[A["clone-env"]] = parseNodes(A["clone-nodes"]);
if (A.dockerenv) {
    p = A.dockerenv.split(";");
    for (j = 0; j < p.length; j++) if (p[j].indexOf("=") > 0) dockerEnv[p[j].substring(0, p[j].indexOf("="))] = p[j].substring(p[j].indexOf("=") + 1);
}
platform = new H.Platform({ firewall: A.firewall == "1" });
for (name in envNodes) {
    list = envNodes[name];
    for (j = 0; j < list.length; j++) {
        map[String(list[j].id)] = list[j].container;
        list[j].intIP = H.containerIP(list[j].container);
    }
    platform.addEnv(name, list);
    if (state.envs[name]) platform.env(name).groups = state.envs[name].groups;
}
platform.rules = state.rules || [];
platform.exec = H.dockerExecutor(map, dockerEnv);

var params = { op: A.op, phase: A.phase || "", envName: ENV, cloneEnvName: A["clone-env"] || "${this.cloneEnvName}", basePath: A.base || "",
               path: A.path !== undefined ? A.path : "${settings.path}",
               ignore: A["ignore-b64"] !== undefined ? H.b64decode(A["ignore-b64"]) : "${settings.ignore}",
               delay: A.delay !== undefined ? A.delay : "${settings.delay}",
               versionsDays: A.versionsDays !== undefined ? A.versionsDays : "${settings.versionsDays}" };
var result, form;
if (A.op == "uninstall") {
    result = H.runInline(MANIFEST.onUninstall[0].script, { "env.envName": ENV, "globals.base_path": A.base || "" }, platform, undefined);
} else if (A.op == "form") {
    form = JSON.parse(JSON.stringify(MANIFEST.settings.main));
    result = H.runInline(form.onBeforeInit, { "env.envName": ENV }, platform, form);
} else {
    result = H.runManage(REPO, platform, params);
}

// Persist the platform state.
state.envs = state.envs || {};
for (name in platform.envs) state.envs[name] = { groups: platform.env(name).groups };
state.rules = platform.rules;
H.writeFile(STATE_FILE, JSON.stringify(state, null, 1));

if (A.log) {
    var log = [], c;
    for (j = 0; j < platform.calls.length; j++) {
        c = platform.calls[j];
        if (!c.command || c.api == "ExecCmdByGroup") { log.push("== " + c.api + (c.command ? "\n" + c.command : "")); continue; }
        log.push("== " + c.api + " node " + c.nodeId + " (" + map[c.nodeId] + ")\n" + c.command + "\n-- exit " + c.response.result +
                 "\n" + c.response.out + (c.response.errOut ? "\n-- stderr\n" + c.response.errOut : ""));
    }
    H.writeFile(A.log, log.join("\n\n") + "\n");
}

if (result && typeof result.message === "string") print(result.message.replace(/  \n/g, "\n"));
print(JSON.stringify(result));
java.lang.System.exit(result && (result.result === 0 || result.result === "info") ? 0 : result && result.result === "warning" ? 2 : 1);
