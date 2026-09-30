/* In-browser fake of the control-plane API (ARCHITECTURE.md section 5).
 * Loaded by app.js ONLY when the page URL contains ?mock=1. Never used in production.
 * Extra: ?mock=1&expired=1 simulates a 401 to show the session-expired banner. */
(function () {
  'use strict';
  var GiB = 1073741824, now = Date.now();
  function iso(msAgo) { return new Date(now - msAgo).toISOString(); }
  var jobSeq = 41, backupSeq = 12, tokSeq = 3;

  var nodes = [
    { id: 'n-101', region: 'eu-west', envName: 'files-1', nodeId: 101, ip: '10.100.1.11', roles: ['master', 'volume', 'filer'], status: 'online', capacity: { totalBytes: 200 * GiB, usedBytes: 131 * GiB }, volumes: 34, lastSeen: iso(8000) },
    { id: 'n-102', region: 'eu-west', envName: 'files-1', nodeId: 102, ip: '10.100.1.12', roles: ['master', 'volume', 'filer'], status: 'online', capacity: { totalBytes: 200 * GiB, usedBytes: 127 * GiB }, volumes: 33, lastSeen: iso(5000) },
    { id: 'n-103', region: 'eu-west', envName: 'files-1', nodeId: 103, ip: '10.100.1.13', roles: ['master', 'volume', 'filer'], status: 'online', capacity: { totalBytes: 200 * GiB, usedBytes: 178 * GiB }, volumes: 41, lastSeen: iso(12000) },
    { id: 'n-104', region: 'eu-west', envName: 'files-1', nodeId: 104, ip: '10.100.1.14', roles: ['volume', 'filer'], status: 'draining', capacity: { totalBytes: 200 * GiB, usedBytes: 42 * GiB }, volumes: 9, lastSeen: iso(3000) },
    { id: 'n-201', region: 'us-east', envName: 'files-2', nodeId: 201, ip: '10.200.2.21', roles: ['master', 'volume', 'filer'], status: 'online', capacity: { totalBytes: 250 * GiB, usedBytes: 140 * GiB }, volumes: 37, lastSeen: iso(6000) },
    { id: 'n-202', region: 'us-east', envName: 'files-2', nodeId: 202, ip: '10.200.2.22', roles: ['volume', 'filer'], status: 'offline', capacity: { totalBytes: 250 * GiB, usedBytes: 133 * GiB }, volumes: 35, lastSeen: iso(3 * 3600e3) },
    { id: 'n-301', region: 'ap-south', envName: 'files-3', nodeId: 301, ip: '10.250.3.31', roles: ['master', 'volume', 'filer'], status: 'joining', capacity: { totalBytes: 100 * GiB, usedBytes: 1 * GiB }, volumes: 0, lastSeen: iso(20000) }
  ];
  var regions = [
    { id: 'eu-west', name: 'eu-west', envName: 'files-1', status: 'healthy', masters: ['10.100.1.11:9333', '10.100.1.12:9333', '10.100.1.13:9333'], filers: ['10.100.1.11:8888', '10.100.1.12:8888', '10.100.1.13:8888', '10.100.1.14:8888'], nodes: 4 },
    { id: 'us-east', name: 'us-east', envName: 'files-2', status: 'degraded', masters: ['10.200.2.21:9333'], filers: ['10.200.2.21:8888', '10.200.2.22:8888'], nodes: 2 },
    { id: 'ap-south', name: 'ap-south', envName: 'files-3', status: 'syncing', masters: ['10.250.3.31:9333'], filers: ['10.250.3.31:8888'], nodes: 1 }
  ];
  var repl = [
    { from: 'eu-west', to: 'us-east', mode: 'async', status: 'healthy', lagSeconds: 2, lastError: null },
    { from: 'us-east', to: 'eu-west', mode: 'async', status: 'lagging', lagSeconds: 94, lastError: 'filer 10.200.2.22:8888 unreachable (retrying)' },
    { from: 'eu-west', to: 'ap-south', mode: 'async', status: 'syncing', lagSeconds: 3710, lastError: null },
    { from: 'ap-south', to: 'eu-west', mode: 'async', status: 'healthy', lagSeconds: 1, lastError: null }
  ];
  var jobs = [
    { id: 41, type: 'drain', status: 'running', createdAt: iso(300e3), startedAt: iso(290e3), finishedAt: null, actor: 'admin@example.com', target: 'n-104',
      log: ['volume.move 17 10.100.1.14:8080 -> 10.100.1.11:8080 ... ok', 'volume.move 18 10.100.1.14:8080 -> 10.100.1.12:8080 ... ok', 'volume.move 22 10.100.1.14:8080 -> 10.100.1.13:8080 ... in progress'] },
    { id: 40, type: 'backup', status: 'succeeded', createdAt: iso(7200e3), startedAt: iso(7195e3), finishedAt: iso(6400e3), actor: 'scheduler', log: ['filer.backup snapshot started', 'copied 184213 files (61.2 GiB)', 'done'] },
    { id: 39, type: 'heal', status: 'failed', createdAt: iso(86400e3), startedAt: iso(86390e3), finishedAt: iso(86100e3), actor: 'ops@example.com', log: ['volume.fix.replication', 'error: no free volume slot in rack node202', 'exit status 1'] },
    { id: 38, type: 'rebalance', status: 'succeeded', createdAt: iso(172800e3), startedAt: iso(172790e3), finishedAt: iso(171000e3), actor: 'admin@example.com', log: ['volume.balance -force', 'moved 6 volumes', 'done'] }
  ];
  var backups = [
    { id: 12, createdAt: iso(7200e3), kind: 'scheduled', status: 'succeeded', sizeBytes: 61.2 * GiB, target: 'local:/var/lib/sfs/backup' },
    { id: 11, createdAt: iso(93600e3), kind: 'scheduled', status: 'succeeded', sizeBytes: 60.8 * GiB, target: 'local:/var/lib/sfs/backup' },
    { id: 10, createdAt: iso(120000e3), kind: 'manual', status: 'failed', sizeBytes: 0, target: 'local:/var/lib/sfs/backup' },
    { id: 9, createdAt: iso(180000e3), kind: 'scheduled', status: 'succeeded', sizeBytes: 59.9 * GiB, target: 'local:/var/lib/sfs/backup' }
  ];
  var policy = { enabled: true, intervalMinutes: 1440, retentionDays: 14, target: 'local:/var/lib/sfs/backup' };
  var audit = [
    { ts: iso(300e3), actor: 'admin@example.com', action: 'node.drain', target: 'n-104', result: 'ok', detail: 'job 41' },
    { ts: iso(3600e3), actor: 'admin@example.com', action: 'sso.login', target: 'session', result: 'ok', detail: 'grant jti 7f3c...' },
    { ts: iso(86400e3), actor: 'ops@example.com', action: 'ops.heal', target: 'cluster', result: 'failed', detail: 'job 39' },
    { ts: iso(90000e3), actor: 'token:ci-backup', action: 'backup.policy.update', target: 'policy', result: 'ok', detail: { retentionDays: 14 } }
  ];
  var tokens = [
    { id: 't-1', name: 'ci-backup', role: 'operator', createdAt: iso(30 * 86400e3), expiresAt: new Date(now + 60 * 86400e3).toISOString(), lastUsedAt: iso(90000e3) },
    { id: 't-2', name: 'grafana', role: 'viewer', createdAt: iso(10 * 86400e3), expiresAt: null, lastUsedAt: iso(60e3) }
  ];

  function sum(f) { return nodes.filter(function (n) { return n.status !== 'removed'; }).reduce(function (a, n) { return a + f(n); }, 0); }
  function newJob(type, actor, log) {
    var j = { id: ++jobSeq, type: type, status: 'running', createdAt: new Date().toISOString(), startedAt: new Date().toISOString(), finishedAt: null, actor: actor || 'admin@example.com', log: log.slice(0, 1) };
    jobs.unshift(j);
    var i = 1, t = setInterval(function () {
      if (i < log.length) { j.log.push(log[i++]); return; }
      clearInterval(t); j.status = 'succeeded'; j.finishedAt = new Date().toISOString();
      if (type === 'backup') backups.unshift({ id: ++backupSeq, createdAt: j.createdAt, kind: 'manual', status: 'succeeded', sizeBytes: 61.4 * GiB, target: policy.target });
    }, 1200);
    audit.unshift({ ts: j.createdAt, actor: j.actor, action: type, target: 'cluster', result: 'ok', detail: 'job ' + j.id });
    return j;
  }

  function route(method, path, body) {
    var m;
    if (/[?&]expired=1/.test(location.search)) return [401, { error: 'no session' }];
    if (method === 'GET' && path === '/me') return [200, { sub: '12345', email: 'admin@example.com', role: 'admin' }];
    if (method === 'GET' && path === '/health') return [200, { status: 'degraded', updatedAt: new Date().toISOString(), checks: [
      { name: 'masters quorum', status: 'ok', detail: 'eu-west 3/3, us-east 1/1, ap-south 1/1' },
      { name: 'nodes online', status: 'degraded', detail: 'node202 (us-east) offline for 3h' },
      { name: 'replication lag', status: 'degraded', detail: 'eu-west -> ap-south initial sync 1h 1m behind' },
      { name: 'disk usage', status: 'ok', detail: 'max 89% (node103)' }] }];
    if (method === 'GET' && path === '/cluster') {
      var t = sum(function (n) { return n.capacity.totalBytes; }), u = sum(function (n) { return n.capacity.usedBytes; });
      return [200, { clusterId: 'c-7f2a9e41', name: 'files', primaryRegion: 'eu-west', replication: '010', capacity: { totalBytes: t, usedBytes: u, freeBytes: t - u },
        counts: { regions: regions.length, nodes: nodes.length, volumes: sum(function (n) { return n.volumes; }) }, version: 'sfsctl 0.1.0 / SeaweedFS 4.48', uptimeSeconds: 1234567 }];
    }
    if (method === 'GET' && path === '/regions') return [200, regions];
    if (method === 'POST' && path === '/regions') { var r = { id: body.name, name: body.name, envName: body.envName, status: 'joining', masters: [], filers: [], nodes: 0 }; regions.push(r); return [200, r]; }
    if (method === 'DELETE' && (m = /^\/regions\/(.+)$/.exec(path))) { regions = regions.filter(function (x) { return x.id !== decodeURIComponent(m[1]); }); return [200, newJob('region.remove', null, ['stopping filer.sync', 'unregistering nodes', 'done'])]; }
    if (method === 'GET' && path === '/nodes') return [200, nodes];
    if (method === 'POST' && (m = /^\/nodes\/(.+)\/drain$/.exec(path))) {
      var n = nodes.filter(function (x) { return x.id === decodeURIComponent(m[1]); })[0]; if (!n) return [404, { error: 'no such node' }];
      n.status = 'draining'; return [200, newJob('drain', null, ['volume.move 1 ...', 'volume.move 2 ...', 'volume.move 3 ...', 'drained ' + n.id])];
    }
    if (method === 'DELETE' && (m = /^\/nodes\/([^?]+)(\?force=1)?$/.exec(path))) {
      var d = nodes.filter(function (x) { return x.id === decodeURIComponent(m[1]); })[0]; if (!d) return [404, { error: 'no such node' }];
      if (d.status !== 'draining' && !(d.status === 'offline' && m[2])) return [409, { error: 'node must be drained first (or offline > 24h with force)' }];
      d.status = 'removed'; audit.unshift({ ts: new Date().toISOString(), actor: 'admin@example.com', action: 'node.remove', target: d.id, result: 'ok', detail: '' }); return [200, { ok: true }];
    }
    if (method === 'POST' && path === '/ops/rebalance') return [200, newJob('rebalance', null, ['volume.balance -force', 'planning moves', 'moved 4 volumes', 'done'])];
    if (method === 'POST' && path === '/ops/heal') return [200, newJob('heal', null, ['volume.fix.replication', 'replicated 2 volumes', 'volume.fsck', 'no orphan chunks', 'done'])];
    if (method === 'GET' && path === '/jobs') return [200, jobs.map(function (j) { var c = {}; for (var k in j) if (k !== 'log') c[k] = j[k]; return c; })];
    if (method === 'GET' && (m = /^\/jobs\/(.+)$/.exec(path))) { var jj = jobs.filter(function (x) { return String(x.id) === m[1]; })[0]; return jj ? [200, jj] : [404, { error: 'no such job' }]; }
    if (method === 'GET' && path === '/replication') return [200, repl];
    if (method === 'GET' && path === '/backups') return [200, backups];
    if (method === 'POST' && path === '/backups') return [200, newJob('backup', null, ['filer.backup snapshot started', 'copying...', 'copied 184502 files', 'done'])];
    if (method === 'GET' && path === '/backups/policy') return [200, policy];
    if (method === 'PUT' && path === '/backups/policy') { policy = body; return [200, policy]; }
    if (method === 'POST' && (m = /^\/backups\/(.+)\/restore$/.exec(path))) return [200, newJob('restore', null, ['restoring ' + body.path + ' -> ' + body.targetPath, 'copied 1204 files', 'done'])];
    if (method === 'GET' && /^\/audit/.test(path)) return [200, audit];
    if (method === 'GET' && path === '/tokens') return [200, tokens];
    if (method === 'POST' && path === '/tokens') {
      var tk = { id: 't-' + (++tokSeq), name: body.name, role: body.role, createdAt: new Date().toISOString(), expiresAt: new Date(now + body.expiresInDays * 86400e3).toISOString(), lastUsedAt: null };
      tokens.push(tk); var out = {}; for (var k in tk) out[k] = tk[k]; out.token = 'sfs_mock_' + Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2); return [200, out];
    }
    if (method === 'DELETE' && (m = /^\/tokens\/(.+)$/.exec(path))) { tokens = tokens.filter(function (x) { return x.id !== decodeURIComponent(m[1]); }); return [200, { ok: true }]; }
    return [404, { error: 'mock: no route ' + method + ' ' + path }];
  }

  window.SFS_MOCK_FETCH = function (url, opts) {
    var method = (opts && opts.method) || 'GET';
    if (method !== 'GET' && !(opts.headers && opts.headers['X-SFS-CSRF'] === '1')) return Promise.resolve(new Response('{"error":"csrf"}', { status: 403 }));
    if (url === '/auth/logout') return Promise.resolve(new Response('{}', { status: 200 }));
    var path = url.replace(/^\/api\/v1/, ''), body = opts && opts.body ? JSON.parse(opts.body) : undefined;
    var res = route(method, path, body);
    return new Promise(function (resolve) {
      setTimeout(function () { resolve(new Response(JSON.stringify(res[1]), { status: res[0], headers: { 'Content-Type': 'application/json' } })); }, 80);
    });
  };
})();
