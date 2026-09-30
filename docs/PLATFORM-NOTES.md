# Platform notes (Virtuozzo Application Platform / Jelastic)

Research notes for the JPS and node-side implementation. Every item gives the
verified fact, the source it was verified against and the snippet to use.
Status legend: **VERIFIED** (read in source, image or live-tested package),
**DOCS** (documented, not tried by us), **UNVERIFIED** (must be proven in the
live test plan).

Researched 2026-09-30. Local images inspected: `jelastic/storage:2.0-11.2-almalinux-9`,
`jelastic/nginxbalancer:1.30.5-almalinux-9` (both amd64 only on Docker Hub).
Dashboard bundle read: `https://app.jpc.infomaniak.com/optimum/js/690168266d9d707e0a424c6a3518f479.out.js`.

---

## 1. Storage nodes: `nodeType: storage`

**VERIFIED (image inspection, `docker inspect` + `docker run`):**

- Image labels: `nodeType=storage`, `cluster=true` (the stack supports the platform's
  auto-clustering), `VOLUME /data`, `sourceUrl=https://raw.githubusercontent.com/jelastic/icons/master/storage/`.
- OS: AlmaLinux 9.7, `/sbin/init -> systemd`.
- Tools present: `/usr/bin/python3` (**Python 3.9.25**, stdlib `sqlite3` 3.34.1, `ssl`
  linked to OpenSSL 3.5.1), `/usr/bin/openssl` (OpenSSL 3.5.1), `/usr/bin/curl`
  (7.76.1, OpenSSL backend), `systemctl`, `tar`, `gzip`.
- NOT present: `sqlite3` CLI, `fusermount`/`fuse3` package (only `fuse-libs` 2.9),
  `/dev/fuse` (irrelevant on storage nodes; `weed mount` runs on app nodes).
- GlusterFS 11.2 server packages are installed, but `glusterd` is **not enabled** by
  default. Enabled units: crond, nfs-server, rpcbind, nscd, rsyslog, sshd. So ports
  24007/2049/111 may be in use by NFS/rpcbind; our ports 9333/19333/8080/18080/8888/18888/8480
  are free.
- `/etc/jelastic/redeploy.conf` exists with a "CUSTOM FILES AND FOLDERS" section at
  the top; system list below it (`/etc/jelastic/redeploy.conf`, nftables files,
  `/var/lib/jelastic/keys`, `/root/.ssh`, ...). Append our paths to the file.

**VERIFIED (live, our GlusterFS package `scripts/storage-region.jps`):** `cluster: false`
on the node group keeps the platform's built-in storage auto-clustering from running
(the GlusterFS package runs its own volume logic with exactly this setting).

```yaml
nodes:
  - nodeType: storage
    nodeGroup: storage
    count: ${settings.nodes:3}
    cluster: false          # platform auto-clustering OFF
    fixedCloudlets: 1
    flexibleCloudlets: 16
    displayName: SeaweedFS Storage
```

Persist state across redeploy (idempotent, run as root). Paths only, no shell vars:

```yaml
- cmd[storage]: |-
    grep -qx '/etc/sfs' /etc/jelastic/redeploy.conf || echo '/etc/sfs' >> /etc/jelastic/redeploy.conf
    grep -qx '/var/lib/sfs' /etc/jelastic/redeploy.conf || echo '/var/lib/sfs' >> /etc/jelastic/redeploy.conf
    grep -qx '/usr/local/sbin/sfs-node' /etc/jelastic/redeploy.conf || echo '/usr/local/sbin/sfs-node' >> /etc/jelastic/redeploy.conf
  user: root
```

Note: `/var/lib/sfs` is a regular directory, not the image VOLUME `/data`. Keeping
data under `/var/lib/sfs` relies on redeploy.conf. Alternative with no redeploy.conf
dependency for bulk data: put volume data under `/data/sfs/volume` (image volume,
kept on redeploy). Contract (ARCHITECTURE.md section 2) keeps `/var/lib/sfs`; both work.
Control-plane dirs (`/etc/sfsctl`, `/var/lib/sfsctl`, `/opt/sfsctl`) must be added
the same way on the control-plane node.

## 2. bl layer: `nodeType: nginx` and the env domain

**VERIFIED (image):** `jelastic/nginxbalancer:1.30.5-almalinux-9` labels
`nodeType=nginx-dockerized`, `nodeTypeAlias=nginx` -> JPS `nodeType: nginx`,
`nodeGroup: bl`. Has python3, openssl, curl. nginx 1.30.5, OpenSSL 3.5.8.

**VERIFIED (`nginx -V`): the balancer nginx is NOT built with
`--with-http_auth_request_module`.** `auth_request` is unavailable. Available:
`http_ssl`, `realip`, `sub`, `secure_link`, `headers-more`, `v2`, `v3`, and dynamic
modules in `/usr/share/nginx/modules/`: `ngx_http_js_module.so` (njs 0.9.0),
modsecurity, geoip2, image_filter, xslt, stream.

Decision needed (contract deviation, section 6.5 of ARCHITECTURE.md):
- **Recommended:** nginx does plain reverse proxy of `/`, `/ui/`, `/api/`, `/sso`,
  `/auth/` to the control plane over TLS; **sfsctl enforces the session itself** on
  `/ui/*` and `/api/*` (it already must, for bearer tokens). No auth_request.
- Alternative: `load_module modules/ngx_http_js_module.so;` in nginx.conf and an njs
  handler using `r.subrequest('/auth/check')`. More moving parts, nginx.conf edit
  (see below on regeneration). Not recommended for v0.

**VERIFIED (image templates):** the platform-generated balancer config
(`/etc/nginx/templates/nginx.conf.tpl`, written to `/etc/nginx/nginx-jelastic.conf`,
which `/etc/nginx/nginx.conf` includes) has, inside `http {}`, a default
`server { listen *:80; server_name _; ... }` that proxies to the app upstreams, and
at the end **`include /etc/nginx/conf.d/*.conf;`**. The balancer's
`/etc/jelastic/redeploy.conf` keeps `/etc/nginx/conf.d`, `/etc/nginx/nginx.conf`,
`/etc/nginx/nginx-jelastic.conf`, `/etc/nginx/upstreams`. The image also ships
`/etc/nginx/conf.d/ssl.conf.disabled` (443 server with `/var/lib/jelastic/SSL/jelastic.chain`,
enabled by the platform only when custom SSL / public IP is configured).

So the custom site goes into **`/etc/nginx/conf.d/sfs.conf`** (survives restart and
redeploy; not touched by the upstream regeneration which edits nginx-jelastic.conf).
Use a server block with the explicit env host name so it wins over `server_name _`:

**DOCS / UNVERIFIED live:** `https://<env>.<hoster-domain>/` is served by the
platform Shared Load Balancer, which terminates TLS with the platform wildcard cert
and forwards plain HTTP to port 80 of the env entry point (the bl node when a bl
layer exists), adding `X-Forwarded-For` / `X-Forwarded-Proto`. The template already
sets `set_real_ip_from 10.0.0.0/8 192.168.0.0/16 172.16.0.0/16; real_ip_header X-Forwarded-For`.
Cookies must still be `Secure` (browser sees https).

```nginx
# /etc/nginx/conf.d/sfs.conf  (written by manifest.jps on the bl node)
upstream sfsctl_backend { server CP_IP:8480; keepalive 8; }
server {
    listen 80;
    listen [::]:80;
    server_name ENV_DOMAIN;                 # ${env.domain}
    client_max_body_size 10m;
    location / {
        proxy_pass https://sfsctl_backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_ssl_trusted_certificate /etc/nginx/sfs-ca.pem;
        proxy_ssl_verify on;
        proxy_ssl_verify_depth 2;
        proxy_ssl_name CP_CERT_NAME;        # a name/IP present in the cp cert SAN
        proxy_ssl_server_name on;
        proxy_read_timeout 120s;
    }
}
```

JPS to write it (placeholders only; no shell `${VAR}`), then test and reload:

```yaml
- cmd[bl]: |-
    cat > /etc/nginx/sfs-ca.pem <<'EOF'
    ${globals.caPem}
    EOF
    sed -e 's/CP_IP/${globals.cpIp}/' -e 's/ENV_DOMAIN/${env.domain}/' -e 's/CP_CERT_NAME/${globals.cpIp}/' \
      /tmp/sfs.conf.tpl > /etc/nginx/conf.d/sfs.conf
    nginx -t && (systemctl reload nginx || nginx -s reload)
  user: root
```

(Or fetch the template with `curl -fsSL ${baseUrl}/config/nginx/sfs.conf` first.)
If `proxy_ssl_name` is an IP, the cp cert must carry that IP in its SAN (it does
per contract: SAN IP). UNVERIFIED: whether `systemctl reload nginx` works on this
image vs `jem balancer rebuildCommon`; `nginx -t && nginx -s reload` is safe.

## 3. Handing the user a URL from a button

**VERIFIED (dashboard source, `Marketplace.Installation.ExecuteAction` callback):**

```js
// p = action response
if (p.result !== 0) { JApp.appstore.AppStore.showJpsResponseMessage(p, ...) }
else { q = p.successText || b.successText;   // b = the button config
       if (q) GOut.Info(getLocalizedText(q), {cls: "markdown"}) }
showJpsResponseMessage: function (f, i) {
  var h = JApp.appPopupTypes[f.type] || JApp.POPUP_TYPE_ERROR,   // {info, warning, error}
      g = f.message || GOut.ErrorText();
  GOut.showMessage(g, h, f, Ext.apply(i || {}, {cls: "markdown", autoHide: false})) }
```

Facts:
- There is **no openUrl / redirect / href response type**. The dashboard never
  navigates on a JPS response (no `window.open` in this path).
- A dynamic message is shown only through a non-zero result with a `type`: `info`,
  `warning`, `error` popups (anything else -> error styling). The popup has
  `autoHide: false` (stays until closed) and class `markdown`.
- On result 0 only the **static** button `successText` is shown.
- `type: success` is in the CS docs for install completion; for button actions the
  dashboard maps unknown types to the error popup, so do not use it for buttons.
- Memory (live-tested in our GlusterFS package): dynamic text via
  `{result: "info"|"warning", message}` works.
- **VERIFIED (bundle): the popup body is raw HTML.** `GOut.showMessage` runs the
  message through `JApp.TextProcessor.process4Output` (placeholder substitution only,
  no markdown rendering) and puts the result into `{xtype: "box", html: K}` of an
  `Ext.ToolTip`. `cls: "markdown"` is only a CSS class on the popup. So an HTML
  anchor `<a href="..." target="_blank" rel="noopener">` is clickable; a markdown
  `[text](url)` is shown literally. (The commonmark renderer `JApp.ux.util.Markdown`
  exists in the bundle but is used for install `successText`, notifications and region
  descriptions, not for this popup.)
- UNVERIFIED live: that the Cloud Scripting engine passes the returned `message`
  through unchanged (no HTML escaping) for a button action. Also put the bare URL on
  its own line so the user can copy it if the anchor is escaped.
- The grant is base64url + "." (no `<>"&{}`), so it is safe inside `href`.

Snippet (button -> action -> script; the grant is minted server side via ExecCmd):

```yaml
buttons:
  - caption: Open Advanced Management
    action: openAdvanced
    confirmText: Create a one-time sign-in link (valid 60 seconds)?
    loadingText: Creating sign-in link...

actions:
  openAdvanced:
    - script: |
        var env = "${env.name}", nodeId = "${globals.cpNodeId}", out = "", url = "";
        var x = jelastic.env.control.ExecCmdById(env, session, nodeId,
          toJSON([{ command: "/usr/local/bin/sfsctl sso-grant --sub '${user.uid}' --email '${user.email}' --role admin" }]),
          true, "root");
        if (x && x.responses && x.responses.length) out = String(x.responses[0].out || "");
        try { url = JSON.parse(out.split("\n").filter(function (l) { return l.charAt(0) == "{"; }).pop()).url; } catch (e) {}
        if (!url || !/^https:\/\//.test(url)) return { result: 99, type: "error", message: "Could not create the sign-in link. " + out };
        return { result: "info", message: "One-time sign-in link, valid 60 seconds:<br><br>" +
          "<a href=\"" + url + "\" target=\"_blank\" rel=\"noopener\">Open Advanced Management</a><br><br>" + url };
```

The `ExecCmdById(env, session, nodeId, toJSON([{command}]), true, "root")` call and
`x.responses[0].out` are VERIFIED in our GlusterFS package (`addons/backup.jps` line
~300, `scripts/backup/backup-task.js` line ~263, branch backup-v2). Reading the output
in the script avoids putting `${response.out}` (quotes, newlines) inside JS source.
`${user.uid}` / `${user.email}` are standard CS placeholders (DOCS). The grant never
appears in the Tasks log body except as the API call result; keep it 60 s single use.

## 4. Events

**DOCS (docs.cloudscripting.com/creating-manifest/events/) + VERIFIED usage in
jelastic-jps/mysql-cluster:**

| Event | params | response |
|---|---|---|
| `onAfterScaleOut[storage]` | `event.params.count`, `event.params.nodeGroup` | `event.response.nodes` = array of the **newly added** nodes (`id`, `intIP`, `nodeGroup`, ...). Runs once per layer. |
| `onBeforeScaleIn[storage]` | `count`, `nodeGroup` | `event.response.nodes` = the nodes **about to be removed** |
| `onAfterScaleIn[storage]` | `count`, `nodeGroup` | `event.response.nodes` = removed nodes |
| `onAfterRedeployContainer[storage]` | `nodeGroup`, `tag`, `sequential`, `useExistingVolumes`, `env` | docs list only `result`; our live GlusterFS package uses `${event.response.responses.join(nodeid,)}` successfully to get the redeployed node ids |
| `onBeforeDelete` | `session`, `appid`, `password`, `env` | none |

Source (jelastic-jps/mysql-cluster `scripts/galera.jps`, `scripts/proxy-configuration.jps`):

```yaml
onAfterScaleOut[storage]:
  - forEach(event.response.nodes):
      - enrollNode:
          nodeId: ${@i.id}
          ip: ${@i.intIP}

onBeforeScaleIn[storage]:
  - forEach(event.response.nodes):
      - drainNode:
          nodeId: ${@i.id}

onAfterRedeployContainer[storage]:
  - cmd[storage]: sfs-node install --version 4.48 && sfs-node start
    user: root
```

Notes:
- `onBeforeScaleIn` can block the scale-in with `stopEvent: {type: warning, message}`
  (VERIFIED: our GlusterFS cluster-logic.jps). Draining is long work: the event
  handler must not exceed the action limit; start the drain as a detached job and,
  if volumes are not yet moved, `stopEvent` with "drain started, retry scale-in
  when the card shows drained" rather than blocking for minutes.
- Events are bound only when the add-on/manifest defining them is installed on the
  env (for `type: update` add-ons: installed with `nodeGroup: storage`).
  Installed clusters keep old handlers until the add-on is reinstalled (memory).

## 5. Creating a region env in another region

**VERIFIED (live, our GlusterFS `manifest.jps` `createEnvs`):** install a child JPS
per region through `marketplace.jps.install` with a `region` parameter, returned
via `onAfterReturn` from a script:

```yaml
createRegionEnv:
  - script: |
      return { result: 0, onAfterReturn: { 'marketplace.jps.install': [{
        jps: "${baseUrl}/addons/region.jps?_r=${fn.random}",
        envName: "${settings.envName}-2",
        loggerName: "${settings.envName}-2",
        envGroups: "SeaweedFS ${settings.envName}",
        region: "${settings.region2}",
        settings: { nodes: "3", cpUrl: "${globals.cpUrl}", caFingerprint: "${globals.caFingerprint}" }
      }] } };
```

Region list for a form: `regionlist` field type, or
`jelastic.environment.control.GetRegions(appid, session)` in `onBeforeInit`
(VERIFIED in GlusterFS manifest.jps lines 47-66; values are hardware node group
`uniqueName`s).

Node IPs of another env (script, same user session):

```js
var r = jelastic.env.control.GetEnvInfo("${settings.envName}-2", session);
if (r.result != 0) return r;
var ips = [];
for (var i = 0; i < r.nodes.length; i++)
  if (r.nodes[i].nodeGroup == "storage") ips.push({ id: r.nodes[i].id, ip: r.nodes[i].intIP });
return { result: 0, nodes: ips };
```

Env discovery by name prefix: `jelastic.environment.control.GetEnvs(appid, session)`
(VERIFIED: GlusterFS `scripts/getClusterEnvs.js`). Cross-region traffic uses the
internal IPs (platform GRE routing between regions of the same platform; VERIFIED
live by the GlusterFS package, which uses no public IPs).

To run commands on a node of ANOTHER env from a script:
`jelastic.env.control.ExecCmdById(otherEnv, session, nodeId, toJSON([{command: "...", params: ""}]), true, "root")`.

## 6. Firewall rules

**VERIFIED (live, GlusterFS `scripts/cluster-logic.jps` `setupFirewall`,
branch fix-cluster-logic):** `jelastic.environment.security.AddRule(envName, session,
rule, nodeGroup)`; ONE port or ONE range per rule (no comma lists); skip when the
firewall feature is off for the account; best effort.

```yaml
setupFirewall:
  - script: |
      var envName = "${env.name}";
      try {
        if (jelastic.environment.security) {
          var q = jelastic.billing.account.GetOwnerQuotas(appid, session, "firewall.enabled");
          var enabled = (q && q.array && q.array[0]) ? q.array[0].value : 0;
          if (enabled) {
            var inbound = [["sfs-master", "9333"], ["sfs-master-grpc", "19333"],
                           ["sfs-volume", "8080"], ["sfs-volume-grpc", "18080"],
                           ["sfs-filer", "8888"], ["sfs-filer-grpc", "18888"],
                           ["sfs-ctl", "8480"]];
            for (var i = 0; i < inbound.length; i++)
              jelastic.environment.security.AddRule(envName, session,
                { direction: "INPUT", name: inbound[i][0], protocol: "TCP", ports: inbound[i][1],
                  src: "ALL", priority: 1080, action: "ALLOW" }, "storage");
            jelastic.environment.security.AddRule(envName, session,
              { direction: "OUTPUT", name: "sfs-out", protocol: "ALL", ports: "", dst: "ALL",
                priority: 1000, action: "ALLOW" }, "storage");
          }
        }
      } catch (e) { /* best effort */ }
      return { result: 0 };
```

Security note: `src: "ALL"` opens the port to every source that can route to the
node; the platform only routes private IPs internally, and our protection is mTLS +
JWT (ARCHITECTURE section 3). Tighter: `src` as a CIDR (UNVERIFIED which src
formats the API accepts besides `ALL`; GlusterFS memory notes "firewall range too
narrow" was a real bug, so keep port ranges exact). Do not open 8480 on the bl layer;
the bl node is a client.

## Open items (for the live test plan)

1. SLB -> bl port 80 with `X-Forwarded-Proto: https` (UNVERIFIED live).
2. CS engine passes an HTML `<a>` in the `info` popup message through unescaped (bundle side VERIFIED, engine UNVERIFIED).
3. `event.response.nodes` shape on `onBeforeScaleIn` for storage (docs + mysql-cluster
   usage; not run by us).
4. nginx reload command on the balancer image (`nginx -s reload` vs systemd).
5. AddRule `src` CIDR support.
