/*
 * Nashorn (JDK 11 jjs) harness for scripts/manage.js and the manifest's
 * inline scripts.
 *
 * It runs the real platform script with the context Cloud Scripting gives it
 * (getParam, appid, session, toJSON, jelastic) and a stub `jelastic` that keeps
 * the platform state in memory:
 *   env.control      GetEnvInfo, GetNodeGroups, ApplyNodeGroupData (per key),
 *                    ExecCmdById, ExecCmdByGroup
 *   environment.security  GetRules, AddRule
 *   billing.account  GetOwnerQuotas ("firewall.enabled")
 * Node commands go to a pluggable executor, function(nodeId, command) ->
 * {exit, out, err}:
 *   FAKE    FakeNode: a scripted node that answers the way the runner's output
 *           contract says (docs/DESIGN.md section 3) - unit tests;
 *   DOCKER  dockerExecutor(): `docker exec <container> bash -c <command>`, or
 *           the same exec through the Docker Engine API on
 *           /var/run/docker.sock when there is no docker CLI (inside the
 *           eclipse-temurin:11-jdk container) - tests/e2e/run.sh.
 *
 * Usage: load(__DIR__ + "harness.js"); then see unit-tests.js and cli.js.
 */

var H = (function () {
    var Files = Java.type("java.nio.file.Files"), Paths = Java.type("java.nio.file.Paths");
    var JString = Java.type("java.lang.String"), Base64 = Java.type("java.util.Base64");

    function readFile(p) { return String(new JString(Files.readAllBytes(Paths.get(p)), "UTF-8")); }
    function writeFile(p, text) { Files.write(Paths.get(p), new JString(String(text)).getBytes("UTF-8")); }
    function b64decode(s) { return String(new JString(Base64.getDecoder().decode(String(s)), "UTF-8")); }
    function b64encode(s) { return String(Base64.getEncoder().encodeToString(new JString(String(s)).getBytes("UTF-8"))); }
    function toJSON(o) { return JSON.stringify(o); }
    function clone(o) { return JSON.parse(JSON.stringify(o)); }

    // ---- platform stub ---------------------------------------------------------------

    // opts: {exec: function(nodeId, command) -> {exit, out, err}, firewall: bool}
    function Platform(opts) {
        opts = opts || {};
        this.envs = {};        // name -> {nodes: [...], groups: {name: {name, key: value...}}}
        this.exec = opts.exec;
        this.firewall = !!opts.firewall;
        this.rules = [];       // {env, group, rule}
        this.calls = [];       // every API call: {api, env, nodeId?, command?}
        this.failApi = {};     // name -> true: that API answers result 1
        this.groupNoNodeIds = false;   // ExecCmdByGroup answers without node ids
    }

    // nodes: [{id, intIP, ismaster, status}] - nodeGroup defaults to cp.
    Platform.prototype.addEnv = function (name, nodes) {
        var i, list = [];
        for (i = 0; i < nodes.length; i++) {
            list.push({ id: nodes[i].id, intIP: nodes[i].intIP, ismaster: !!nodes[i].ismaster,
                        nodeGroup: nodes[i].nodeGroup || "cp", status: nodes[i].status === undefined ? 1 : nodes[i].status });
        }
        this.envs[name] = { nodes: list, groups: { cp: { name: "cp" } } };
        return this.envs[name];
    };

    Platform.prototype.env = function (name) {
        var e = this.envs[String(name)];
        if (!e) throw "stub: unknown environment " + name;
        return e;
    };

    Platform.prototype.settings = function (envName) {
        var raw = this.env(envName).groups.cp.stSync;
        return (raw === undefined || raw === "") ? null : JSON.parse(raw);
    };

    Platform.prototype.execCalls = function () {
        var out = [], i;
        for (i = 0; i < this.calls.length; i++) if (/^ExecCmd/.test(this.calls[i].api)) out.push(this.calls[i]);
        return out;
    };

    Platform.prototype.runNode = function (nodeId, command) {
        var r;
        try { r = this.exec(String(nodeId), String(command)); } catch (e) { r = { exit: 255, out: "", err: "harness executor error: " + e }; }
        return { nodeid: parseInt(nodeId, 10), out: r.out || "", errOut: r.err || "", result: r.exit, exitStatus: r.exit };
    };

    Platform.prototype.jelastic = function () {
        var p = this;
        function failed(api) { return p.failApi[api] ? { result: 1, error: "stub: " + api + " failed" } : null; }
        function commandOf(json) { var c = JSON.parse(String(json)); return String(c[0].command); }
        return {
            env: {
                control: {
                    GetEnvInfo: function (envName, session) {
                        p.calls.push({ api: "GetEnvInfo", env: String(envName) });
                        var f = failed("GetEnvInfo"), e;
                        if (f) return f;
                        e = p.envs[String(envName)];
                        if (!e) return { result: 11, error: "env not found" };
                        return { result: 0, env: { envName: String(envName), status: 1 }, nodes: clone(e.nodes) };
                    },
                    GetNodeGroups: function (envName, session) {
                        p.calls.push({ api: "GetNodeGroups", env: String(envName) });
                        var f = failed("GetNodeGroups"), e, out = [], k;
                        if (f) return f;
                        e = p.envs[String(envName)];
                        if (!e) return { result: 11, error: "env not found" };
                        for (k in e.groups) out.push(clone(e.groups[k]));
                        return { result: 0, object: out };
                    },
                    ApplyNodeGroupData: function (envName, session, group, data) {
                        p.calls.push({ api: "ApplyNodeGroupData", env: String(envName), group: String(group) });
                        var f = failed("ApplyNodeGroupData"), e, d, k;
                        if (f) return f;
                        e = p.env(envName);
                        d = (typeof data === "string" || data instanceof JString) ? JSON.parse(String(data)) : data;
                        if (!e.groups[group]) e.groups[group] = { name: String(group) };
                        // Per key: other keys of the group stay.
                        for (k in d) e.groups[group][k] = d[k];
                        return { result: 0 };
                    },
                    ExecCmdById: function (envName, session, nodeId, commands, sayYes, user) {
                        var cmd = commandOf(commands), call = { api: "ExecCmdById", env: String(envName), nodeId: String(nodeId), command: cmd }, r;
                        p.calls.push(call);
                        r = p.runNode(nodeId, cmd);
                        call.response = r;
                        return { result: r.result == 0 ? 0 : 4109, error: r.result == 0 ? undefined : "exit status " + r.result, responses: [r] };
                    },
                    ExecCmdByGroup: function (envName, session, group, commands, sayYes, async, user) {
                        var cmd = commandOf(commands), e = p.env(envName), res = [], bad = false, i, n, r;
                        p.calls.push({ api: "ExecCmdByGroup", env: String(envName), group: String(group), command: cmd });
                        for (i = 0; i < e.nodes.length; i++) {
                            n = e.nodes[i];
                            if (n.nodeGroup != group || n.status != 1) continue;
                            r = p.runNode(n.id, cmd);
                            p.calls.push({ api: "(group member)", env: String(envName), nodeId: String(n.id), command: cmd, response: r });
                            if (r.result != 0) bad = true;
                            if (p.groupNoNodeIds) delete r.nodeid;
                            res.push(r);
                        }
                        return { result: bad ? 4109 : 0, error: bad ? "exit status on some node" : undefined, responses: res };
                    }
                }
            },
            environment: {
                security: {
                    GetRules: function (envName, session, group, direction) {
                        var out = [], i;
                        p.calls.push({ api: "GetRules", env: String(envName) });
                        for (i = 0; i < p.rules.length; i++) {
                            if (p.rules[i].env == envName && p.rules[i].group == group && p.rules[i].rule.direction == direction) out.push(clone(p.rules[i].rule));
                        }
                        return { result: 0, rules: out };
                    },
                    AddRule: function (envName, session, rule, group) {
                        p.calls.push({ api: "AddRule", env: String(envName) });
                        p.rules.push({ env: String(envName), group: String(group), rule: clone(rule) });
                        return { result: 0 };
                    }
                }
            },
            billing: {
                account: {
                    GetOwnerQuotas: function (appid, session, names) {
                        p.calls.push({ api: "GetOwnerQuotas" });
                        return { result: 0, array: [{ name: String(names), value: p.firewall ? 1 : 0 }] };
                    }
                }
            }
        };
    };

    // ---- running scripts ---------------------------------------------------------------

    // The platform runs a script as a function body (top-level `return`).
    function compile(src, name, argNames) {
        return load({ name: name, script: "(function (" + argNames.join(", ") + ") {\n" + src + "\n})" });
    }

    // Runs scripts/manage.js with params (a map; missing names answer the
    // default, like getParam).
    function runManage(repo, platform, params) {
        var fn = compile(readFile(repo + "/scripts/manage.js"), "manage.js", ["getParam", "appid", "session", "jelastic", "toJSON"]);
        function getParam(name, dflt) { return params[name] !== undefined ? params[name] : dflt; }
        return fn(getParam, "appid-test", "session-test", platform.jelastic(), toJSON);
    }

    // Fills JPS placeholders: ${a.b} and ${a.b:default}; an unknown one stays.
    function fill(src, values) {
        return String(src).replace(/\$\{([A-Za-z_][\w.]*)(?::([^}]*))?\}/g, function (m, key, dflt) {
            if (values[key] !== undefined) return String(values[key]);
            return dflt !== undefined ? dflt : m;
        });
    }

    // Runs an inline manifest script (onUninstall, a form's onBeforeInit).
    function runInline(src, values, platform, settings) {
        var fn = compile(fill(src, values), "inline", ["appid", "session", "jelastic", "toJSON", "settings"]);
        return fn("appid-test", "session-test", platform.jelastic(), toJSON, settings);
    }

    // ---- FAKE nodes -----------------------------------------------------------------------

    function fakeDevice(seed) {
        var s = String(seed), out = [], i, j, c = "";
        for (i = 0; i < 8; i++) {
            c = "";
            for (j = 0; j < 7; j++) c += "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".charAt((s.charCodeAt((i * 7 + j) % s.length) * (i + 3) + j * 7) % 32);
            out.push(c);
        }
        return out.join("-");
    }

    // Shell-style words after a runner invocation, up to an unquoted ; | & or
    // the end of the line. Single quotes as q() in manage.js writes them.
    function words(text, from) {
        var out = [], cur = null, i = from, ch;
        while (i < text.length) {
            ch = text.charAt(i);
            if (ch == "'") {
                var end = text.indexOf("'", i + 1);
                cur = (cur || "") + text.substring(i + 1, end);
                i = end + 1;
                continue;
            }
            if (ch == "\\" && text.charAt(i + 1) == "'") { cur = (cur || "") + "'"; i += 2; continue; }
            if (ch == ";" || ch == "|" || ch == "&" || ch == "\n") break;
            if (ch == " " || ch == "\t") { if (cur !== null) { out.push(cur); cur = null; } i++; continue; }
            cur = (cur || "") + ch;
            i++;
        }
        if (cur !== null) out.push(cur);
        return out;
    }

    function parseCalls(command) {
        var re = /(?:"\$R"|\$R|\/usr\/local\/sbin\/stsync)[ \t]+(prepare|guard|ignore|api|join|status|rescan|remove)\b/g, m, w, a, i, calls = [];
        while ((m = re.exec(command)) !== null) {
            w = words(command, m.index + m[0].length);
            a = {};
            for (i = 0; i < w.length; i++) {
                if (!/^--/.test(w[i])) continue;
                // A flag (--fresh) has no value: the next word is an option or nothing.
                if (i + 1 >= w.length || /^--/.test(w[i + 1])) { a[w[i].substring(2)] = true; continue; }
                a[w[i].substring(2)] = w[i + 1];
                i++;
            }
            calls.push({ sub: m[1], args: a });
        }
        return calls;
    }

    // A scripted node. opts: {device, folderType, join, copyOf (a clone of
    // that host: prepare resets the identity), hasRunner, files, bytes (what
    // prepare --count-b64 reports), statusJSON: {...} overrides of the status
    // JSON, fail: {download, prepare, ignore, api, apiLine, join, status,
    // rescan, remove} - a message (or true) makes that step fail}. A node with
    // a folder (folderType not none) has state that prepare --fresh resets.
    function FakeNode(id, opts) {
        opts = opts || {};
        this.id = String(id);
        this.device = opts.device || fakeDevice("node" + id);
        this.folderType = opts.folderType || "none";
        this.join = opts.join || "none";
        this.copyOf = opts.copyOf || "";
        this.hasRunner = !!opts.hasRunner;
        this.files = opts.files === undefined ? 100 : opts.files;
        this.bytes = opts.bytes === undefined ? 100000 : opts.bytes;
        this.joinFrom = null;      // the --from list of the last join call
        this.resets = 0;
        this.statusOverride = opts.statusJSON || {};
        this.fail = opts.fail || {};
        this.peers = 0;
        this.commands = [];
        this.calls = [];
        this.downloads = [];
        this.ignore = null;
        this.plans = [];
        this.joins = 0;
        this.rescans = 0;
        this.removed = false;
        this.prepared = null;
    }

    function res(lines, result, message) {
        lines.push("STSYNC_RESULT=" + result);
        lines.push("STSYNC_MESSAGE=" + message);
        return { ok: result == "ok", lines: lines };
    }

    FakeNode.prototype.sub = function (c) {
        var a = c.args, f = this.fail, lines = [], plan, i, parts, body, n, j;
        if (f[c.sub]) return res(lines, "failed", f[c.sub] === true ? c.sub + " failed" : String(f[c.sub]));
        switch (c.sub) {
        case "prepare":
            this.prepared = a;
            if (this.copyOf) {
                this.device = fakeDevice("clone" + this.id + this.device);
                this.folderType = "none";
                this.join = "none";
                this.copyOf = "";
                lines.push("STSYNC_CLONED=1");
            } else if (a.fresh === true && (this.folderType != "none" || this.join != "none")) {
                this.device = fakeDevice("reset" + this.id + this.device);
                this.folderType = "none";
                this.join = "none";
                this.resets++;
                lines.push("STSYNC_RESET=1");
            }
            lines.push("STSYNC_DEVICE=" + this.device, "STSYNC_USER=apache",
                       "STSYNC_FOLDER_TYPE=" + (a.folder ? this.folderType : "none"), "STSYNC_JOIN=" + this.join);
            if (a["count-b64"] !== undefined) {
                this.countRules = a["count-b64"] == "-" ? "" : b64decode(a["count-b64"]);
                lines.push("STSYNC_FILES=" + this.files, "STSYNC_BYTES=" + this.bytes);
            }
            return res(lines, "ok", "Syncthing 2.1.5 running as apache");
        case "ignore":
            this.ignore = a.b64 == "-" ? "" : b64decode(a.b64);
            return res(lines, "ok", "wrote .stignore");
        case "api":
            plan = [];
            parts = b64decode(a["plan-b64"]).split("\n");
            n = 0;
            for (i = 0; i < parts.length; i++) {
                if (!parts[i]) continue;
                j = parts[i].split(" ");
                n++;
                body = j[2] && j[2] != "-" ? JSON.parse(b64decode(j[2])) : null;
                plan.push({ method: j[0], path: j[1], body: body });
                if (this.fail.apiAt == n) {
                    this.plans.push(plan);
                    lines.push("STSYNC_API_" + n + "=500");
                    return res(lines, "failed", "plan line " + n + " (" + j[0] + " " + j[1] + ") failed with HTTP 500");
                }
                if (j[0] == "POST" && j[1] == "/rest/config/folders") this.folderType = body.type;
                if (j[0] == "PATCH" && /^\/rest\/config\/folders\//.test(j[1]) && body.type) this.folderType = body.type;
                if (j[0] == "PUT" && j[1] == "/rest/config/devices") this.peers = body.length - 1;
                lines.push("STSYNC_API_" + n + "=200");
            }
            this.plans.push(plan);
            return res(lines, "ok", n + " API call(s) done");
        case "join":
            if (a.from !== undefined) this.joinFrom = String(a.from).split(",");
            if (this.folderType == "receiveonly" && this.join != "running") { this.join = "running"; this.joins++; }
            return res(lines, "ok", "join " + this.join);
        case "status":
            body = { service: "active", version: "v2.1.5", device: this.device, user: "apache", folderType: this.folderType,
                     state: "idle", needItems: 0, needBytes: 0, globalFiles: 42, globalDirectories: 7, globalDeleted: 3, globalBytes: 420000,
                     localFiles: 42, errors: 0, error: "", connectedPeers: this.peers, totalPeers: this.peers, conflicts: 0, join: this.join, joinPhase: "",
                     lastScan: "2026-09-30T10:00:00Z", inotifyLimit: 524288 };
            for (i in this.statusOverride) body[i] = this.statusOverride[i];
            lines.push("STSYNC_JSON=" + JSON.stringify(body));
            return res(lines, "ok", "status");
        case "rescan":
            this.rescans++;
            return res(lines, "ok", "rescan requested");
        case "remove":
            this.removed = true;
            this.folderType = "none";
            this.hasRunner = false;
            return res(lines, "ok", "Syncthing removed");
        }
        return res(lines, "failed", "unknown command " + c.sub);
    };

    // Runs a command the way bash would for the wrappers manage.js and the
    // manifest send: the download, then the runner invocations in order,
    // stopping at the first failure.
    FakeNode.prototype.run = function (command) {
        var out = [], calls = parseCalls(command), url = /(https?:\/\/[^' ]+)'/.exec(command), i, r, guarded;
        this.commands.push(command);
        // The uninstall wrapper downloads only when the runner is missing.
        guarded = /if \[ -x \$R \]|if \[ -x "\$R" \]/.test(command);
        if (url && (/if \[ ! -x/.test(command) ? !this.hasRunner : true)) {
            this.downloads.push(url[1]);
            if (!this.fail.download) this.hasRunner = true;
            else if (this.hasRunner) out.push("STSYNC_RUNNER=stale");
            else if (!guarded) return { exit: 1, out: "STSYNC_RESULT=failed\nSTSYNC_MESSAGE=could not download the runner from " + url[1], err: "" };
        }
        if (calls.length && !this.hasRunner) {
            if (guarded) return { exit: 0, out: out.concat(["STSYNC_RESULT=failed", "STSYNC_MESSAGE=the add-on runner is not installed on this node"]).join("\n"), err: "" };
            return { exit: 127, out: out.join("\n"), err: "bash: /usr/local/sbin/stsync: No such file or directory" };
        }
        for (i = 0; i < calls.length; i++) {
            if (/STSYNC_STEP=/.test(command)) out.push("STSYNC_STEP=" + calls[i].sub);
            this.calls.push(calls[i]);
            r = this.sub(calls[i]);
            out = out.concat(r.lines);
            if (!r.ok) return { exit: /; true$/.test(command) ? 0 : 1, out: out.join("\n"), err: "" };
        }
        return { exit: 0, out: out.join("\n"), err: "" };
    };

    FakeNode.prototype.lastPlan = function () { return this.plans.length ? this.plans[this.plans.length - 1] : null; };
    FakeNode.prototype.callsOf = function (sub) {
        var out = [], i;
        for (i = 0; i < this.calls.length; i++) if (this.calls[i].sub == sub) out.push(this.calls[i]);
        return out;
    };

    // nodes: {id: FakeNode}
    function fakeExecutor(nodes) {
        return function (nodeId, command) {
            var n = nodes[String(nodeId)];
            if (!n) return { exit: 255, out: "", err: "stub: no fake node " + nodeId };
            return n.run(command);
        };
    }

    // ---- DOCKER executor ------------------------------------------------------------------------

    var ProcessBuilder = Java.type("java.lang.ProcessBuilder");

    // Runs argv; stdin text optional. Returns {exit, out (bytes), err (string)}.
    function runProcess(argv, stdin) {
        var pb = new ProcessBuilder(Java.to(argv, "java.lang.String[]")), errFile = java.io.File.createTempFile("harness", ".err"), p, os, outBytes, err;
        pb.redirectError(errFile);
        p = pb.start();
        os = p.getOutputStream();
        if (stdin !== undefined && stdin !== null) os.write(new JString(String(stdin)).getBytes("UTF-8"));
        os.close();
        outBytes = p.getInputStream().readAllBytes();
        p.waitFor();
        err = readFile(errFile.getPath());
        errFile["delete"]();
        return { exit: p.exitValue(), out: outBytes, err: err };
    }

    function hasDockerCli() {
        try { return runProcess(["sh", "-c", "command -v docker"]).exit === 0; } catch (e) { return false; }
    }

    var SOCK = "/var/run/docker.sock";
    function engine(method, path, body) {
        var argv = ["curl", "-sS", "--unix-socket", SOCK, "-X", method, "-H", "Content-Type: application/json", "http://localhost" + path];
        if (body !== undefined) argv.push("--data-binary", "@-");
        return runProcess(argv, body === undefined ? null : JSON.stringify(body));
    }

    // The Engine API's exec output is multiplexed: 8-byte frame headers
    // (stream 1 = stdout, 2 = stderr, then a big-endian length).
    function demux(bytes) {
        var out = new java.io.ByteArrayOutputStream(), err = new java.io.ByteArrayOutputStream(), i = 0, len, stream;
        while (i + 8 <= bytes.length) {
            stream = bytes[i];
            len = ((bytes[i + 4] & 0xff) << 24) | ((bytes[i + 5] & 0xff) << 16) | ((bytes[i + 6] & 0xff) << 8) | (bytes[i + 7] & 0xff);
            (stream == 2 ? err : out).write(bytes, i + 8, len);
            i += 8 + len;
        }
        return { out: String(new JString(out.toByteArray(), "UTF-8")), err: String(new JString(err.toByteArray(), "UTF-8")) };
    }

    // map: {nodeId: container}; env: {NAME: value} passed to every command.
    function dockerExecutor(map, env) {
        var cli = hasDockerCli(), envList = [], k;
        for (k in (env || {})) envList.push(k + "=" + env[k]);
        return function (nodeId, command) {
            var name = map[String(nodeId)], argv, r, id, d, info, i;
            if (!name) return { exit: 255, out: "", err: "harness: no container for node " + nodeId };
            if (cli) {
                argv = ["docker", "exec"];
                for (i = 0; i < envList.length; i++) argv.push("-e", envList[i]);
                argv.push(name, "bash", "-c", command);
                r = runProcess(argv);
                return { exit: r.exit, out: String(new JString(r.out, "UTF-8")), err: r.err };
            }
            r = engine("POST", "/containers/" + name + "/exec", { AttachStdout: true, AttachStderr: true, Tty: false, User: "root",
                                                                  Env: envList, Cmd: ["bash", "-c", command] });
            id = JSON.parse(String(new JString(r.out, "UTF-8"))).Id;
            if (!id) return { exit: 255, out: "", err: "harness: exec create failed: " + String(new JString(r.out, "UTF-8")) + r.err };
            d = demux(engine("POST", "/exec/" + id + "/start", { Detach: false, Tty: false }).out);
            info = JSON.parse(String(new JString(engine("GET", "/exec/" + id + "/json").out, "UTF-8")));
            return { exit: info.ExitCode, out: d.out, err: d.err };
        };
    }

    function containerIP(name) {
        var r, j, k, nets;
        if (hasDockerCli()) {
            r = runProcess(["docker", "inspect", "-f", "{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}", name]);
            return String(new JString(r.out, "UTF-8")).replace(/^\s+|\s+$/g, "").split(" ")[0];
        }
        j = JSON.parse(String(new JString(engine("GET", "/containers/" + name + "/json").out, "UTF-8")));
        nets = (j.NetworkSettings && j.NetworkSettings.Networks) || {};
        for (k in nets) if (nets[k].IPAddress) return nets[k].IPAddress;
        return "";
    }

    // ---- assertions -------------------------------------------------------------------------------

    var results = { pass: 0, fail: 0, failures: [] };
    function test(name, fn) {
        try {
            fn();
            results.pass++;
            print("ok   " + name);
        } catch (e) {
            results.fail++;
            results.failures.push(name);
            print("FAIL " + name + "\n     " + e + (e && e.stack ? "\n" + e.stack.split("\n").slice(0, 3).join("\n") : ""));
        }
    }
    function assert(cond, msg) { if (!cond) throw "assertion failed: " + msg; }
    function eq(a, b, msg) {
        var x = JSON.stringify(a), y = JSON.stringify(b);
        if (x !== y) throw "assertion failed: " + msg + "\n     expected " + y + "\n     got      " + x;
    }
    function contains(text, part, msg) {
        if (String(text).indexOf(part) < 0) throw "assertion failed: " + msg + "\n     '" + part + "' not in:\n" + text;
    }

    return {
        readFile: readFile, writeFile: writeFile, b64decode: b64decode, b64encode: b64encode, toJSON: toJSON,
        Platform: Platform, FakeNode: FakeNode, fakeExecutor: fakeExecutor, fakeDevice: fakeDevice, parseCalls: parseCalls,
        dockerExecutor: dockerExecutor, containerIP: containerIP, runProcess: runProcess,
        runManage: runManage, runInline: runInline, fill: fill,
        test: test, assert: assert, eq: eq, contains: contains, results: results
    };
})();
