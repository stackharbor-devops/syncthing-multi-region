/* sfsctl Advanced Management UI - vanilla JS, no dependencies, CSP default-src 'self'.
 * Consumes the control-plane API in docs/ARCHITECTURE.md section 5.
 * ?mock=1 loads mock.js (in-browser fake API) so the UI can be reviewed without a cluster. */
(function () {
  'use strict';

  var API = '/api/v1';
  var state = { me: null, cluster: null, page: 'overview', timers: [], expired: false, openRegions: {}, selJob: null };

  // ---------- helpers ----------
  function $(sel, root) { return (root || document).querySelector(sel); }
  function esc(v) {
    return String(v === undefined || v === null ? '' : v).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function bytes(n) {
    if (n === undefined || n === null || isNaN(n)) return '-';
    var u = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'], i = 0; n = Number(n);
    while (Math.abs(n) >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return (i === 0 ? n : n.toFixed(n >= 100 ? 0 : n >= 10 ? 1 : 2)) + ' ' + u[i];
  }
  function dur(s) {
    if (s === undefined || s === null || isNaN(s)) return '-';
    s = Math.max(0, Math.round(Number(s)));
    if (s < 60) return s + 's';
    var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
    if (d) return d + 'd ' + h + 'h';
    if (h) return h + 'h ' + m + 'm';
    return m + 'm ' + (s % 60) + 's';
  }
  function ts(v) {
    if (!v) return '-';
    var d = new Date(v); if (isNaN(d)) return esc(v);
    return d.toLocaleString(undefined, { month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false }) + (d.getFullYear() !== new Date().getFullYear() ? ' ' + d.getFullYear() : '');
  }
  function ago(v) {
    if (!v) return '-';
    var d = new Date(v); if (isNaN(d)) return esc(v);
    return dur((Date.now() - d.getTime()) / 1000) + ' ago';
  }
  function pct(used, total) { return total ? Math.min(100, Math.round(used * 100 / total)) : 0; }
  function arr(v) { return Array.isArray(v) ? v : (v && Array.isArray(v.items) ? v.items : []); }

  var BADGE = {
    ok: ['Healthy', 'green'], healthy: ['Healthy', 'green'], online: ['Up to Date', 'green'], active: ['Up to Date', 'green'],
    uptodate: ['Up to Date', 'green'], succeeded: ['Succeeded', 'green'], success: ['Succeeded', 'green'], ok_result: ['OK', 'green'],
    syncing: ['Syncing', 'blue'], running: ['Running', 'blue'], joining: ['Joining', 'blue'], queued: ['Queued', 'grey'],
    draining: ['Draining', 'amber'], degraded: ['Degraded', 'amber'], lagging: ['Lagging', 'amber'], warning: ['Warning', 'amber'],
    offline: ['Offline', 'red'], critical: ['Critical', 'red'], failed: ['Failed', 'red'], error: ['Error', 'red'],
    disconnected: ['Disconnected', 'purple'], paused: ['Paused', 'purple'], removed: ['Removed', 'grey'], unknown: ['Unknown', 'grey']
  };
  function badge(status, label) {
    var k = String(status || 'unknown').toLowerCase().replace(/[\s_-]/g, '');
    var b = BADGE[k] || [String(status || 'Unknown'), 'grey'];
    return '<span class="badge b-' + b[1] + '">' + esc(label || b[0]) + '</span>';
  }
  function canOperate() { return state.me && (state.me.role === 'admin' || state.me.role === 'operator'); }
  function isAdmin() { return state.me && state.me.role === 'admin'; }

  // ---------- API ----------
  function sessionExpired() {
    if (state.expired) return;
    state.expired = true;
    stopTimers();
    var b = $('#banner');
    b.className = 'banner';
    b.textContent = 'Session expired - open Advanced Management again from the platform dashboard.';
    b.hidden = false;
    $('#main').innerHTML = '<div class="card"><div class="empty">' + esc(b.textContent) + '</div></div>';
    try { if ($('#dialog').open) $('#dialog').close(); } catch (e) { /* ignore */ }
  }
  function api(method, path, body) {
    var opts = { method: method, credentials: 'same-origin', headers: { 'Accept': 'application/json' } };
    if (method !== 'GET') opts.headers['X-SFS-CSRF'] = '1';
    if (body !== undefined) { opts.headers['Content-Type'] = 'application/json'; opts.body = JSON.stringify(body); }
    var f = window.SFS_MOCK_FETCH || window.fetch.bind(window);
    return f(API + path, opts).then(function (r) {
      if (r.status === 401) { sessionExpired(); throw new Error('Session expired'); }
      return r.text().then(function (t) {
        var data = null;
        try { data = t ? JSON.parse(t) : null; } catch (e) { data = { error: t }; }
        if (!r.ok) {
          var msg = (data && (data.error || data.message || data.detail)) || ('HTTP ' + r.status);
          if (r.status === 403) msg = 'Not allowed for your role: ' + msg;
          throw new Error(msg);
        }
        return data;
      });
    });
  }
  var get = function (p) { return api('GET', p); };

  // ---------- UI primitives ----------
  var toastTimer = null;
  function toast(msg, isErr) {
    var t = $('#toast');
    t.textContent = msg; t.className = 'toast' + (isErr ? ' err' : ''); t.hidden = false;
    clearTimeout(toastTimer); toastTimer = setTimeout(function () { t.hidden = true; }, isErr ? 7000 : 4000);
  }
  function fail(e) { if (!state.expired) toast(e.message || String(e), true); }

  // Modal dialog. opts: {title, html, ok, danger, cancel(false hides), onOk(form) -> Promise|false}
  function modal(opts) {
    var d = $('#dialog'), okBtn = $('#dialog-ok'), cancel = $('#dialog-cancel'), form = $('#dialog-form');
    $('#dialog-title').textContent = opts.title;
    $('#dialog-body').innerHTML = opts.html || '';
    okBtn.textContent = opts.ok || 'OK';
    okBtn.className = 'btn ' + (opts.danger ? 'danger' : 'primary');
    okBtn.disabled = false;
    cancel.hidden = opts.cancel === false;
    form.onsubmit = function (ev) {
      ev.preventDefault();
      if (!opts.onOk) { d.close(); return; }
      var res = opts.onOk(form);
      if (res === false) return;
      okBtn.disabled = true;
      Promise.resolve(res).then(function (keepOpen) { if (keepOpen !== true) d.close(); })
        .catch(function (e) { fail(e); })
        .then(function () { okBtn.disabled = false; });
    };
    cancel.onclick = function () { d.close(); };
    if (typeof d.showModal === 'function') d.showModal(); else d.setAttribute('open', '');
    var first = $('#dialog-body input, #dialog-body select', d);
    (first || (opts.danger ? cancel : okBtn)).focus();
  }
  function confirmAction(title, text, okLabel, fn) {
    modal({ title: title, html: '<p>' + text + '</p>', ok: okLabel, danger: true, onOk: fn });
  }
  function startJob(promise, what) {
    return promise.then(function (job) {
      toast(what + ' started' + (job && job.id ? ' (job ' + job.id + ')' : ''));
      if (job && job.id) { state.selJob = job.id; location.hash = '#jobs'; }
    });
  }

  // ---------- rendering pieces ----------
  function kv(rows) {
    return '<table class="kv">' + rows.map(function (r) {
      return '<tr><th scope="row">' + esc(r[0]) + '</th><td>' + r[1] + '</td></tr>';
    }).join('') + '</table>';
  }
  function capCell(c) {
    c = c || {};
    var p = pct(c.usedBytes, c.totalBytes);
    return bytes(c.usedBytes) + ' / ' + bytes(c.totalBytes) +
      '<div class="bar' + (p > 85 ? ' hot' : '') + '" role="img" aria-label="' + p + '% used"><span data-w="' + p + '"></span></div>';
  }
  function table(cols, rows, empty, rowAttr) {
    if (!rows.length) return '<div class="table-wrap"><div class="empty">' + esc(empty || 'Nothing here yet.') + '</div></div>';
    return '<div class="table-wrap"><table class="data"><thead><tr>' + cols.map(function (c) {
      return '<th scope="col"' + (c.num ? ' class="num"' : '') + '>' + esc(c.label) + '</th>';
    }).join('') + '</tr></thead><tbody>' + rows.map(function (r, i) {
      return '<tr' + (rowAttr ? rowAttr(r, i) : '') + '>' + cols.map(function (c) {
        return '<td' + (c.num ? ' class="num"' : '') + '>' + c.render(r) + '</td>';
      }).join('') + '</tr>';
    }).join('') + '</tbody></table></div>';
  }
  function nodeLabel(n) { return 'node' + esc(n.nodeId || n.id) + (n.ip ? ' <span class="muted">' + esc(n.ip) + '</span>' : ''); }
  // CSP style-src 'self' blocks style="" attributes in markup; widths are applied via CSSOM (allowed) after render.
  function applyBars(root) {
    Array.prototype.forEach.call((root || document).querySelectorAll('.bar > span[data-w]'), function (s) {
      s.style.width = Math.max(0, Math.min(100, Number(s.getAttribute('data-w')) || 0)) + '%';
    });
  }

  // ---------- pages ----------
  var pages = {};

  pages.overview = function (main) {
    return Promise.all([get('/cluster'), get('/regions'), get('/nodes'), get('/replication'), get('/health')]).then(function (r) {
      var c = r[0] || {}, regions = arr(r[1]), nodes = arr(r[2]), repl = arr(r[3]), health = r[4] || {};
      state.cluster = c; setHeader(c, health);
      var left = '<h2 class="section">Regions</h2>' + (regions.length ? regions.map(function (g) {
        var rn = nodes.filter(function (n) { return n.region === g.id || n.region === g.name; });
        var open = state.openRegions[g.id] !== false;
        var used = 0, total = 0; rn.forEach(function (n) { used += (n.capacity || {}).usedBytes || 0; total += (n.capacity || {}).totalBytes || 0; });
        return '<section class="card"><button type="button" class="card-h" aria-expanded="' + open + '" data-region="' + esc(g.id) + '">' +
          '<span class="chev" aria-hidden="true">&#9656;</span><span class="grow">' + esc(g.name) +
          (g.id === c.primaryRegion || g.name === c.primaryRegion ? ' <span class="muted">(primary)</span>' : '') + '</span>' + badge(g.status) + '</button>' +
          '<div class="card-b"' + (open ? '' : ' hidden') + '>' + kv([
            ['Environment', esc(g.envName)], ['Nodes', esc(g.nodes !== undefined ? g.nodes : rn.length)],
            ['Masters', esc(arr(g.masters).join(', ') || '-')], ['Filers', esc(arr(g.filers).join(', ') || '-')],
            ['Capacity', capCell({ usedBytes: used, totalBytes: total })]
          ]) + rn.map(function (n) {
            return '<div class="sub"><div class="card-h"><span class="grow">' + nodeLabel(n) + '</span>' + badge(n.status) + '</div>' +
              '<div class="card-b">' + kv([['Roles', esc(arr(n.roles).join(', '))], ['Volumes', esc(n.volumes)],
                ['Disk', capCell(n.capacity)], ['Last seen', esc(ago(n.lastSeen))]]) + '</div></div>';
          }).join('') + '</div></section>';
      }).join('') : '<div class="card"><div class="empty">No regions registered.</div></div>');

      var cap = c.capacity || {}, counts = c.counts || {};
      var right = '<h2 class="section">This Cluster</h2><section class="card"><div class="card-h"><span class="grow">' + esc(c.name || c.clusterId) + '</span>' + badge(health.status) + '</div><div class="card-b">' + kv([
        ['Capacity', bytes(cap.totalBytes)], ['Used', capCell(cap)], ['Free', bytes(cap.freeBytes)],
        ['Regions', esc(counts.regions)], ['Nodes', esc(counts.nodes)], ['Volumes', esc(counts.volumes)],
        ['Replication policy', '<span class="mono">' + esc(c.replication) + '</span>'], ['Version', esc(c.version)],
        ['Uptime', c.uptimeSeconds !== undefined ? esc(dur(c.uptimeSeconds)) : '-'], ['Cluster ID', '<span class="mono">' + esc(c.clusterId) + '</span>']
      ]) + '</div></section>' +
        '<h2 class="section">Replication</h2><section class="card"><div class="card-b">' + (repl.length ? kv(repl.map(function (p) {
          return ['' + p.from + ' → ' + p.to, badge(p.status) + ' <span class="muted">lag ' + esc(dur(p.lagSeconds)) + '</span>'];
        })) : '<div class="empty">Single region - no cross-region replication.</div>') + '</div></section>' +
        '<h2 class="section">Health checks</h2><section class="card"><div class="card-b">' + (arr(health.checks).length ? kv(arr(health.checks).map(function (k) {
          return [k.name, badge(k.status) + (k.detail ? '<div class="muted">' + esc(k.detail) + '</div>' : '')];
        })) : '<div class="empty">No checks reported.</div>') + '</div></section>' +
        (canOperate() ? '<div class="toolbar"><button type="button" class="btn" data-op="rebalance">Rebalance</button><button type="button" class="btn" data-op="heal">Heal</button><button type="button" class="btn" data-op="backup">Backup Now</button></div>' : '');

      main.innerHTML = '<div class="grid"><div class="col">' + left + '</div><div class="col">' + right + '</div></div>';
      main.querySelectorAll('button[data-region]').forEach(function (b) {
        b.addEventListener('click', function () {
          var open = b.getAttribute('aria-expanded') !== 'true';
          b.setAttribute('aria-expanded', open); b.nextElementSibling.hidden = !open; state.openRegions[b.dataset.region] = open;
        });
      });
      bindOps(main);
    });
  };

  function bindOps(root) {
    root.querySelectorAll('[data-op]').forEach(function (b) {
      b.addEventListener('click', function () {
        var op = b.dataset.op;
        if (op === 'backup') return startJob(api('POST', '/backups'), 'Backup');
        confirmAction(op === 'heal' ? 'Heal cluster' : 'Rebalance volumes',
          op === 'heal' ? 'Re-create missing replicas (volume.fix.replication) and run a volume.fsck report.' : 'Move volumes so every node carries a fair share (volume.balance -force). This causes extra disk and network I/O.',
          op === 'heal' ? 'Heal' : 'Rebalance', function () { return startJob(api('POST', '/ops/' + op), op === 'heal' ? 'Heal' : 'Rebalance'); });
      });
    });
  }

  pages.nodes = function (main) {
    return get('/nodes').then(function (nodes) {
      nodes = arr(nodes);
      var cols = [
        { label: 'Node', render: function (n) { return nodeLabel(n); } },
        { label: 'Region', render: function (n) { return esc(n.region) + '<div class="muted">' + esc(n.envName) + '</div>'; } },
        { label: 'Roles', render: function (n) { return esc(arr(n.roles).join(', ')); } },
        { label: 'Status', render: function (n) { return badge(n.status); } },
        { label: 'Disk', render: function (n) { return capCell(n.capacity); } },
        { label: 'Volumes', num: true, render: function (n) { return esc(n.volumes); } },
        { label: 'Last seen', render: function (n) { return esc(ago(n.lastSeen)); } }
      ];
      if (canOperate()) cols.push({ label: 'Actions', render: function (n) {
        var s = String(n.status);
        return '<button type="button" class="btn small" data-drain="' + esc(n.id) + '"' + (s === 'online' ? '' : ' disabled') + '>Drain</button> ' +
          '<button type="button" class="btn small danger" data-remove="' + esc(n.id) + '"' + (s === 'removed' ? ' disabled' : '') + '>Remove</button>';
      } });
      main.innerHTML = '<div class="toolbar"><h2 class="section grow">Nodes (' + nodes.length + ')</h2>' +
        (canOperate() ? '<button type="button" class="btn" data-op="rebalance">Rebalance</button>' : '') + '</div>' + table(cols, nodes, 'No nodes enrolled.');
      bindOps(main);
      var byId = {}; nodes.forEach(function (n) { byId[n.id] = n; });
      main.querySelectorAll('[data-drain]').forEach(function (b) {
        b.addEventListener('click', function () {
          var n = byId[b.dataset.drain];
          confirmAction('Drain node' + (n.nodeId || n.id), 'Move all volumes off <b>node' + esc(n.nodeId || n.id) + '</b> (' + esc(n.region) +
            ') to the other nodes of the region. The node stays online until the drain job finishes.', 'Drain', function () {
            return startJob(api('POST', '/nodes/' + encodeURIComponent(n.id) + '/drain'), 'Drain');
          });
        });
      });
      main.querySelectorAll('[data-remove]').forEach(function (b) {
        b.addEventListener('click', function () {
          var n = byId[b.dataset.remove];
          modal({ title: 'Remove node' + (n.nodeId || n.id), danger: true, ok: 'Remove',
            html: '<p>Remove <b>node' + esc(n.nodeId || n.id) + '</b> from the cluster. Only drained nodes can be removed, or nodes offline for more than 24 h with force.</p>' +
              '<label class="check"><input type="checkbox" name="force"' + (n.status === 'offline' ? '' : ' disabled') + '> Force (node offline &gt; 24 h, data on it is lost)</label>' +
              '<label for="confirm-name">Type <b>node' + esc(n.nodeId || n.id) + '</b> to confirm</label><input id="confirm-name" name="confirm" autocomplete="off">',
            onOk: function (f) {
              if (f.confirm.value.trim() !== 'node' + (n.nodeId || n.id)) { toast('Confirmation text does not match', true); return false; }
              return api('DELETE', '/nodes/' + encodeURIComponent(n.id) + (f.force.checked ? '?force=1' : '')).then(function () { toast('Node removed'); render(); });
            } });
        });
      });
    });
  };

  pages.regions = function (main) {
    return Promise.all([get('/regions'), get('/cluster')]).then(function (r) {
      var regions = arr(r[0]), c = r[1] || {};
      var cols = [
        { label: 'Region', render: function (g) { return esc(g.name) + (g.id === c.primaryRegion || g.name === c.primaryRegion ? ' <span class="muted">(primary)</span>' : ''); } },
        { label: 'Environment', render: function (g) { return '<span class="mono">' + esc(g.envName) + '</span>'; } },
        { label: 'Status', render: function (g) { return badge(g.status); } },
        { label: 'Nodes', num: true, render: function (g) { return esc(g.nodes); } },
        { label: 'Masters', render: function (g) { return '<span class="mono">' + esc(arr(g.masters).join(' ')) + '</span>'; } },
        { label: 'Filers', render: function (g) { return '<span class="mono">' + esc(arr(g.filers).join(' ')) + '</span>'; } }
      ];
      if (isAdmin()) cols.push({ label: 'Actions', render: function (g) {
        return (g.id === c.primaryRegion || g.name === c.primaryRegion) ? '<span class="muted">primary</span>' : '<button type="button" class="btn small danger" data-del="' + esc(g.id) + '">Remove</button>';
      } });
      main.innerHTML = '<div class="toolbar"><h2 class="section grow">Regions (' + regions.length + ')</h2>' +
        (isAdmin() ? '<button type="button" class="btn primary" id="add-region">Register region</button>' : '') + '</div>' + table(cols, regions, 'No regions.') +
        '<p class="muted">New regions are deployed from the platform (Add Region on the cluster card). Registering here only records the region; sync starts once its filer is enrolled.</p>';
      var add = $('#add-region');
      if (add) add.addEventListener('click', function () {
        modal({ title: 'Register region', ok: 'Register',
          html: '<label for="r-name">Region name</label><input id="r-name" name="name" required pattern="[a-z0-9][a-z0-9-]{0,30}">' +
            '<label for="r-env">Environment name</label><input id="r-env" name="envName" required>',
          onOk: function (f) { return api('POST', '/regions', { name: f.name.value.trim(), envName: f.envName.value.trim() }).then(function () { toast('Region registered'); render(); }); } });
      });
      main.querySelectorAll('[data-del]').forEach(function (b) {
        b.addEventListener('click', function () {
          var g = regions.filter(function (x) { return String(x.id) === b.dataset.del; })[0];
          confirmAction('Remove region ' + g.name, 'Stop replication with <b>' + esc(g.name) + '</b> and unregister its nodes. Data stored in that region env is not deleted by this action.', 'Remove region',
            function () { return startJob(api('DELETE', '/regions/' + encodeURIComponent(g.id)), 'Region removal'); });
        });
      });
    });
  };

  pages.replication = function (main) {
    return get('/replication').then(function (repl) {
      repl = arr(repl);
      main.innerHTML = '<div class="toolbar"><h2 class="section grow">Cross-region replication</h2></div>' + table([
        { label: 'Pair', render: function (p) { return '<span class="pairs">' + esc(p.from) + ' <span aria-label="to">→</span> ' + esc(p.to) + '</span>'; } },
        { label: 'Mode', render: function (p) { return esc(p.mode); } },
        { label: 'Status', render: function (p) { return badge(p.status); } },
        { label: 'Lag', num: true, render: function (p) { return esc(dur(p.lagSeconds)); } },
        { label: 'Last error', render: function (p) { return p.lastError ? '<span class="mono">' + esc(p.lastError) + '</span>' : '<span class="muted">none</span>'; } }
      ], repl, 'Only one region - nothing to replicate.') +
        '<p class="muted">Writes are synchronous inside a region and asynchronous between regions (filer.sync, active-active). Cross-region RPO equals the lag shown here.</p>';
    });
  };

  pages.backups = function (main) {
    return Promise.all([get('/backups'), get('/backups/policy')]).then(function (r) {
      var list = arr(r[0]), pol = r[1] || {};
      var cols = [
        { label: 'Created', render: function (b) { return esc(ts(b.createdAt)); } },
        { label: 'Kind', render: function (b) { return esc(b.kind); } },
        { label: 'Status', render: function (b) { return badge(b.status); } },
        { label: 'Size', num: true, render: function (b) { return esc(bytes(b.sizeBytes)); } },
        { label: 'Target', render: function (b) { return '<span class="mono">' + esc(b.target) + '</span>'; } }
      ];
      if (isAdmin()) cols.push({ label: 'Actions', render: function (b) {
        return '<button type="button" class="btn small" data-restore="' + esc(b.id) + '"' + (/succe|ok|complete/i.test(b.status) ? '' : ' disabled') + '>Restore...</button>';
      } });
      main.innerHTML = '<div class="split"><div><div class="toolbar"><h2 class="section grow">Backups (' + list.length + ')</h2>' +
        (canOperate() ? '<button type="button" class="btn primary" data-op="backup">Backup Now</button>' : '') + '</div>' + table(cols, list, 'No backups yet.') + '</div>' +
        '<div><h2 class="section">Policy</h2><section class="card"><div class="card-b"><form class="stack" id="policy">' +
        '<label class="check"><input type="checkbox" name="enabled"' + (pol.enabled ? ' checked' : '') + '> Scheduled backups enabled</label>' +
        '<label for="p-int">Interval (minutes)</label><input id="p-int" name="intervalMinutes" type="number" min="5" step="1" required value="' + esc(pol.intervalMinutes || 1440) + '">' +
        '<label for="p-ret">Retention (days)</label><input id="p-ret" name="retentionDays" type="number" min="1" step="1" required value="' + esc(pol.retentionDays || 7) + '">' +
        '<label for="p-tgt">Target</label><input id="p-tgt" name="target" required value="' + esc(pol.target || '') + '" placeholder="e.g. local:/var/lib/sfs/backup or s3://bucket/prefix">' +
        '<p class="muted">Every ' + esc(dur((pol.intervalMinutes || 0) * 60)) + ', kept ' + esc(pol.retentionDays) + ' days.</p>' +
        (isAdmin() ? '<button type="submit" class="btn primary">Save policy</button>' : '<p class="muted">Only admins can change the policy.</p>') +
        '</form></div></section></div></div>';
      bindOps(main);
      var form = $('#policy');
      if (!isAdmin()) Array.prototype.forEach.call(form.elements, function (el) { el.disabled = true; });
      form.addEventListener('submit', function (ev) {
        ev.preventDefault();
        api('PUT', '/backups/policy', { enabled: form.enabled.checked, intervalMinutes: parseInt(form.intervalMinutes.value, 10),
          retentionDays: parseInt(form.retentionDays.value, 10), target: form.target.value.trim() })
          .then(function () { toast('Backup policy saved'); render(); }).catch(fail);
      });
      main.querySelectorAll('[data-restore]').forEach(function (b) {
        b.addEventListener('click', function () {
          var bk = list.filter(function (x) { return String(x.id) === b.dataset.restore; })[0];
          modal({ title: 'Restore from backup', ok: 'Restore', danger: true,
            html: '<p>Backup of ' + esc(ts(bk.createdAt)) + ' (' + esc(bytes(bk.sizeBytes)) + ').</p>' +
              '<label for="rs-path">Path inside the backup</label><input id="rs-path" name="path" value="/" required>' +
              '<label for="rs-target">Restore to (cluster path)</label><input id="rs-target" name="targetPath" required value="/restore-' + esc(String(bk.id)) + '">' +
              '<p class="muted">Restoring into an existing path overwrites files with the same name. Prefer a new folder, then move what you need.</p>',
            onOk: function (f) { return startJob(api('POST', '/backups/' + encodeURIComponent(bk.id) + '/restore', { path: f.path.value.trim(), targetPath: f.targetPath.value.trim() }), 'Restore'); } });
        });
      });
    });
  };

  pages.jobs = function (main) {
    return get('/jobs').then(function (jobs) {
      jobs = arr(jobs);
      if (!state.selJob && jobs.length) state.selJob = jobs[0].id;
      var sel = state.selJob;
      main.innerHTML = '<div class="split"><div><div class="toolbar"><h2 class="section grow">Jobs</h2></div>' + table([
        { label: 'Job', render: function (j) { return '<button type="button" class="btn small ghost" data-job="' + esc(j.id) + '">' + esc(j.type) + ' <span class="muted">#' + esc(j.id) + '</span></button>'; } },
        { label: 'Status', render: function (j) { return badge(j.status); } },
        { label: 'Started', render: function (j) { return esc(ago(j.startedAt || j.createdAt)); } },
        { label: 'Duration', num: true, render: function (j) { return j.startedAt ? esc(dur(((j.finishedAt ? new Date(j.finishedAt) : new Date()) - new Date(j.startedAt)) / 1000)) : '-'; } },
        { label: 'Actor', render: function (j) { return esc(j.actor); } }
      ], jobs, 'No jobs yet.', function (j) { return String(j.id) === String(sel) ? ' class="sel"' : ''; }) + '</div>' +
        '<div><h2 class="section">Log</h2><div id="job-detail"><p class="muted">Select a job.</p></div></div></div>';
      main.querySelectorAll('[data-job]').forEach(function (b) {
        b.addEventListener('click', function () { state.selJob = b.dataset.job; render(); });
      });
      if (sel) return loadJob(sel);
    });
  };
  function loadJob(id) {
    return get('/jobs/' + encodeURIComponent(id)).then(function (j) {
      var box = $('#job-detail'); if (!box) return;
      var log = Array.isArray(j.log) ? j.log.join('\n') : (j.log || '');
      var pre = box.querySelector('pre'), atBottom = !pre || pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 8;
      box.innerHTML = '<section class="card"><div class="card-h"><span class="grow">' + esc(j.type) + ' #' + esc(j.id) + '</span>' + badge(j.status) + '</div><div class="card-b">' +
        kv([['Created', esc(ts(j.createdAt))], ['Started', esc(ts(j.startedAt))], ['Finished', esc(ts(j.finishedAt))], ['Actor', esc(j.actor)]]) +
        '<pre class="log mono" tabindex="0" aria-label="Job log">' + esc(log || '(no output yet)') + '</pre></div></section>';
      pre = box.querySelector('pre'); if (atBottom) pre.scrollTop = pre.scrollHeight;
    }).catch(fail);
  }

  pages.audit = function (main) {
    return get('/audit?limit=200').then(function (rows) {
      rows = arr(rows);
      main.innerHTML = '<div class="toolbar"><h2 class="section grow">Audit log</h2><label for="audit-filter" class="muted">Filter</label><input id="audit-filter" type="search" placeholder="actor, action, target"></div><div id="audit-table"></div>';
      function draw(q) {
        q = (q || '').toLowerCase();
        var f = rows.filter(function (r) { return !q || [r.actor, r.action, r.target, r.result, r.detail].join(' ').toLowerCase().indexOf(q) >= 0; });
        $('#audit-table').innerHTML = table([
          { label: 'Time', render: function (r) { return esc(ts(r.ts)); } },
          { label: 'Actor', render: function (r) { return esc(r.actor); } },
          { label: 'Action', render: function (r) { return '<span class="mono">' + esc(r.action) + '</span>'; } },
          { label: 'Target', render: function (r) { return esc(r.target); } },
          { label: 'Result', render: function (r) { return badge(r.result === 'ok' ? 'ok_result' : r.result, r.result); } },
          { label: 'Detail', render: function (r) { return '<span class="muted">' + esc(typeof r.detail === 'object' ? JSON.stringify(r.detail) : r.detail) + '</span>'; } }
        ], f, 'No audit entries.');
      }
      draw(''); $('#audit-filter').addEventListener('input', function (e) { draw(e.target.value); });
    });
  };

  // TODO(sfs): tokens payload shape is not fixed in ARCHITECTURE.md; UI assumes
  // GET -> [{id, name, role, createdAt, expiresAt, lastUsedAt}], POST {name, role, expiresInDays} -> {id, token, ...}, DELETE /tokens/{id}.
  pages.tokens = function (main) {
    if (!isAdmin()) { main.innerHTML = '<p class="muted pad">API tokens are managed by admins only.</p>'; return Promise.resolve(); }
    return get('/tokens').then(function (toks) {
      toks = arr(toks);
      main.innerHTML = '<div class="toolbar"><h2 class="section grow">API tokens</h2><button type="button" class="btn primary" id="new-token">Create token</button></div>' + table([
        { label: 'Name', render: function (t) { return esc(t.name || t.id); } },
        { label: 'Role', render: function (t) { return esc(t.role); } },
        { label: 'Created', render: function (t) { return esc(ts(t.createdAt)); } },
        { label: 'Expires', render: function (t) { return t.expiresAt ? esc(ts(t.expiresAt)) : 'never'; } },
        { label: 'Last used', render: function (t) { return t.lastUsedAt ? esc(ago(t.lastUsedAt)) : '<span class="muted">never</span>'; } },
        { label: 'Actions', render: function (t) { return '<button type="button" class="btn small danger" data-revoke="' + esc(t.id) + '">Revoke</button>'; } }
      ], toks, 'No API tokens. Tokens are for automation (Authorization: Bearer ...).') +
        '<p class="muted">The token secret is shown once at creation. Store it in your secret manager.</p>';
      $('#new-token').addEventListener('click', function () {
        modal({ title: 'Create API token', ok: 'Create',
          html: '<label for="t-name">Name</label><input id="t-name" name="name" required maxlength="64">' +
            '<label for="t-role">Role</label><select id="t-role" name="role"><option value="viewer">viewer (read only)</option><option value="operator">operator</option><option value="admin">admin</option></select>' +
            '<label for="t-exp">Expires in (days)</label><input id="t-exp" name="expiresInDays" type="number" min="1" max="366" value="90" required>',
          onOk: function (f) {
            return api('POST', '/tokens', { name: f.name.value.trim(), role: f.role.value, expiresInDays: parseInt(f.expiresInDays.value, 10) }).then(function (t) {
              render();
              setTimeout(function () {
                modal({ title: 'Token created', ok: 'Done', cancel: false,
                  html: '<p>Copy this token now. It will not be shown again.</p><div class="secret mono" tabindex="0">' + esc(t && (t.token || t.secret)) + '</div>' });
              }, 0);
            });
          } });
      });
      main.querySelectorAll('[data-revoke]').forEach(function (b) {
        b.addEventListener('click', function () {
          confirmAction('Revoke token', 'Clients using this token lose access immediately.', 'Revoke', function () {
            return api('DELETE', '/tokens/' + encodeURIComponent(b.dataset.revoke)).then(function () { toast('Token revoked'); render(); });
          });
        });
      });
    });
  };

  // ---------- shell ----------
  function setHeader(c, health) {
    if (c && (c.name || c.clusterId)) {
      $('#cluster-name').textContent = c.name || c.clusterId;
      document.title = (c.name || c.clusterId) + ' - Advanced Management';
    }
    if (health) {
      var hb = $('#health-badge'), tmp = document.createElement('span');
      tmp.innerHTML = badge(health.status); hb.className = tmp.firstChild.className; hb.textContent = tmp.firstChild.textContent;
      hb.title = 'Cluster health, updated ' + ts(health.updatedAt);
    }
  }
  function stopTimers() { state.timers.forEach(clearInterval); state.timers = []; }
  function every(ms, fn) { state.timers.push(setInterval(function () { if (!document.hidden && !state.expired && !$('#dialog').open) fn(); }, ms)); }

  var rendering = false;
  function render() {
    if (state.expired) return;
    var page = (location.hash || '#overview').slice(1);
    if (!pages[page]) page = 'overview';
    if (page === 'tokens' && !isAdmin()) page = 'overview';
    var changed = page !== state.page; state.page = page;
    document.querySelectorAll('.tabs a').forEach(function (a) {
      var on = a.dataset.page === page; a.classList.toggle('active', on);
      if (on) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current');
    });
    stopTimers();
    var main = $('#main');
    var scroll = window.scrollY;
    rendering = true;
    return pages[page](main).then(function () {
      applyBars(main);
      if (!changed) window.scrollTo(0, scroll); else main.focus({ preventScroll: true });
    }).catch(function (e) {
      if (!state.expired) main.innerHTML = '<div class="card"><div class="empty">Could not load: ' + esc(e.message) + '</div></div>';
    }).then(function () {
      rendering = false;
      // live refresh: jobs page polls the selected job log fast, others refresh slowly
      if (page === 'jobs') {
        every(2000, function () { if (state.selJob) loadJob(state.selJob); });
        every(10000, function () { if (!rendering) render(); });
      } else if (page !== 'tokens' && page !== 'backups') {
        every(15000, function () { if (!rendering && !document.activeElement.matches('input,select')) render(); });
      }
    });
  }

  function boot() {
    get('/me').then(function (me) {
      state.me = me || {};
      $('#me-name').textContent = (me.email || me.sub || '') + ' (' + (me.role || '?') + ')';
      if (isAdmin()) document.querySelectorAll('[data-admin]').forEach(function (e) { e.hidden = false; });
      get('/health').then(function (h) { setHeader(null, h); }).catch(function () {});
      get('/cluster').then(function (c) { state.cluster = c; setHeader(c, null); }).catch(function () {});
      window.addEventListener('hashchange', render);
      render();
    }).catch(function (e) {
      if (!state.expired) $('#main').innerHTML = '<div class="card"><div class="empty">Could not reach the control plane: ' + esc(e.message) + '</div></div>';
    });
    $('#logout').addEventListener('click', function () {
      var f = window.SFS_MOCK_FETCH || window.fetch.bind(window);
      f('/auth/logout', { method: 'POST', credentials: 'same-origin', headers: { 'X-SFS-CSRF': '1' } }).catch(function () {}).then(function () {
        sessionExpired();
        $('#banner').textContent = 'Signed out. Open Advanced Management again from the platform dashboard to sign in.';
        $('#main').innerHTML = '<div class="card"><div class="empty">Signed out.</div></div>';
      });
    });
    // 'close' fires async: do not wipe a dialog that was re-opened in the meantime
    $('#dialog').addEventListener('close', function () { if (!$('#dialog').open) $('#dialog-body').innerHTML = ''; });
    // the skip link must not change the hash (hash = route)
    $('.skip').addEventListener('click', function (ev) { ev.preventDefault(); $('#main').focus(); });
  }

  if (/[?&]mock=1(&|$)/.test(location.search)) {
    var s = document.createElement('script');
    s.src = 'mock.js'; s.onload = boot; s.onerror = function () { $('#main').textContent = 'mock.js failed to load'; };
    document.head.appendChild(s);
    var b = $('#banner'); b.className = 'banner warn'; b.textContent = 'Mock data (?mock=1) - not connected to a cluster.'; b.hidden = false;
  } else {
    boot();
  }
})();
