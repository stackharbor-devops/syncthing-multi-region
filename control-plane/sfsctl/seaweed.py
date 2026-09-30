"""SeaweedFS 4.48 client: master HTTP API + `weed shell` runner + filer HTTP helpers.

Formats verified against a real 4.48 cluster (fixtures in tests/fixtures/seaweed/):
  GET /cluster/status -> {"IsLeader": true, "Leader": "ip:9333.19333", "Peers": [...]}
  GET /dir/status     -> {"Topology": {"Max", "Free", "DataCenters": [{"Id", "Racks": [{"Id",
                          "DataNodes": [{"Url", "PublicUrl", "Volumes", "EcShards", "Max", "VolumeIds"}]}]}]},
                          "Version": "30GB 4.48 <sha>"}
  GET /vol/status     -> {"Version", "Volumes": {"DataCenters": {dc: {rack: {url: [volume...]}}}}}
                          volume: {"Id", "Collection", "ReplicaPlacement": {"dc"?, "rack"?, "node"?},
                          "Size", "FileCount", "ReadOnly", ...}
`weed shell` exits 0 even when a command fails; failures are printed as lines starting with
"error:" - shell() turns those into a non-zero rc.
"""
import json
import os
import subprocess
import urllib.parse
import urllib.request

HTTP_TIMEOUT = 5


def _url(addr, path):
    if not addr.startswith("http://") and not addr.startswith("https://"):
        addr = "http://" + addr
    return addr.rstrip("/") + path


def http_get_json(addr, path, timeout=HTTP_TIMEOUT, headers=None):
    req = urllib.request.Request(_url(addr, path), headers=dict(headers or {}, Accept="application/json"))
    with urllib.request.urlopen(req, timeout=timeout) as r:  # nosec - private network, fixed hosts
        return json.loads(r.read().decode("utf-8"))


def cluster_status(master, timeout=HTTP_TIMEOUT):
    return http_get_json(master, "/cluster/status", timeout)


def dir_status(master, timeout=HTTP_TIMEOUT):
    return http_get_json(master, "/dir/status", timeout)


def vol_status(master, timeout=HTTP_TIMEOUT):
    return http_get_json(master, "/vol/status", timeout)


def parse_version(version_str):
    """'30GB 4.48 530be3e...' -> '4.48'."""
    parts = (version_str or "").split()
    return parts[1] if len(parts) >= 2 else (parts[0] if parts else "")


def placement_str(rp):
    """ReplicaPlacement JSON ({"rack": 1}) -> '010' (dc, rack, node)."""
    rp = rp or {}
    return "%d%d%d" % (int(rp.get("dc", 0) or 0), int(rp.get("rack", 0) or 0), int(rp.get("node", 0) or 0))


def expected_copies(placement):
    return 1 + sum(int(c) for c in placement)


def parse_volume_ids(s):
    """DataNode.VolumeIds: ' 1 3 5-6' (ranges collapsed by the master) -> [1, 3, 5, 6]."""
    out = []
    for tok in (s or "").replace(",", " ").split():
        a, _, b = tok.partition("-")
        if a.isdigit() and (not b or b.isdigit()):
            out.extend(range(int(a), int(b or a) + 1))
    return out


def parse_dir_status(d):
    """-> list of data nodes {url, host, dataCenter, rack, volumes, ecShards, max, free, volumeIds}."""
    nodes = []
    topo = (d or {}).get("Topology") or {}
    for dc in topo.get("DataCenters") or []:
        for rack in dc.get("Racks") or []:
            for dn in rack.get("DataNodes") or []:
                url = dn.get("Url", "")
                vids = parse_volume_ids(dn.get("VolumeIds"))
                mx = int(dn.get("Max", 0) or 0)
                vols = int(dn.get("Volumes", 0) or 0)
                nodes.append({
                    "url": url, "host": url.rsplit(":", 1)[0], "dataCenter": dc.get("Id", ""),
                    "rack": rack.get("Id", ""), "volumes": vols, "ecShards": int(dn.get("EcShards", 0) or 0),
                    "max": mx, "free": max(mx - vols, 0), "volumeIds": vids,
                })
    return nodes


def parse_vol_status(d):
    """-> list of volume replicas {id, collection, server, dataCenter, rack, size, fileCount, readOnly, replication}."""
    out = []
    dcs = ((d or {}).get("Volumes") or {}).get("DataCenters") or {}
    for dc, racks in dcs.items():
        for rack, servers in (racks or {}).items():
            for server, vols in (servers or {}).items():
                for v in vols or []:
                    out.append({
                        "id": int(v.get("Id", 0)), "collection": v.get("Collection", ""), "server": server,
                        "dataCenter": dc, "rack": rack, "size": int(v.get("Size", 0) or 0),
                        "fileCount": int(v.get("FileCount", 0) or 0), "readOnly": bool(v.get("ReadOnly")),
                        "replication": placement_str(v.get("ReplicaPlacement")),
                    })
    return out


def under_replicated(replicas):
    """replicas from parse_vol_status -> [{id, collection, replication, expected, actual, servers}]."""
    by_id = {}
    for r in replicas:
        e = by_id.setdefault((r["collection"], r["id"]), {"id": r["id"], "collection": r["collection"],
                                                          "replication": r["replication"], "servers": set()})
        e["servers"].add(r["server"])
    bad = []
    for e in by_id.values():
        exp = expected_copies(e["replication"])
        if len(e["servers"]) < exp:
            bad.append({"id": e["id"], "collection": e["collection"], "replication": e["replication"],
                        "expected": exp, "actual": len(e["servers"]), "servers": sorted(e["servers"])})
    return sorted(bad, key=lambda x: (x["collection"], x["id"]))


def volume_list(master, timeout=HTTP_TIMEOUT):
    """Parsed live view of one region cluster: {version, nodes, replicas, volumeIds, underReplicated}."""
    ds = dir_status(master, timeout)
    vs = vol_status(master, timeout)
    replicas = parse_vol_status(vs)
    return {
        "version": parse_version(ds.get("Version", "")),
        "nodes": parse_dir_status(ds),
        "replicas": replicas,
        "volumeIds": sorted({r["id"] for r in replicas}),
        "usedBytes": sum(r["size"] for r in replicas),
        "underReplicated": under_replicated(replicas),
    }


def first_reachable(masters, timeout=HTTP_TIMEOUT):
    """Return the first master address answering /cluster/status, or None."""
    for m in masters or []:
        try:
            cluster_status(m, timeout)
            return m
        except Exception:
            continue
    return None


def shell_errors(output):
    return [ln.strip() for ln in (output or "").splitlines() if ln.strip().lower().startswith("error")]


def shell(cfg, master, commands, timeout=600):
    """Run `weed shell` with commands fed on stdin. -> (rc, output).

    `master` may be one address or a list (joined with commas). The subprocess runs in the node's
    SeaweedFS config dir (cfg["weedConfigDir"], default /etc/sfs) so security.toml (gRPC mTLS)
    is picked up from the working directory, as weed searches "." first.
    """
    if isinstance(master, (list, tuple)):
        master = ",".join(master)
    weed = cfg.get("weedBin", "/usr/local/bin/weed")
    cwd = cfg.get("weedConfigDir", "/etc/sfs")
    if not os.path.isdir(cwd):
        cwd = None
    stdin = "\n".join(commands) + "\n"
    try:
        p = subprocess.run([weed, "shell", "-master=" + master], input=stdin, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, universal_newlines=True, timeout=timeout, cwd=cwd)
    except subprocess.TimeoutExpired as e:
        out = e.output if isinstance(e.output, str) else (e.output or b"").decode("utf-8", "replace")
        return 124, (out or "") + "\nerror: weed shell timed out after %ss" % timeout
    except OSError as e:
        return 127, "error: cannot run %s: %s" % (weed, e)
    rc = p.returncode
    if rc == 0 and shell_errors(p.stdout):
        rc = 1
    return rc, p.stdout


def locked(commands):
    return ["lock"] + list(commands) + ["unlock"]


# ---- filer HTTP helpers (used by backups) -------------------------------------------------

DIR_BIT = 1 << 31


def filer_list(filer, path, timeout=30):
    """Yield entries of a filer directory (paginated). Entry: {path, isDir, size, mtime, mode}."""
    last = ""
    base = path if path.endswith("/") else path + "/"
    while True:
        q = urllib.parse.urlencode({"limit": 1000, "lastFileName": last})
        d = http_get_json(filer, urllib.parse.quote(base) + "?" + q, timeout)
        for e in d.get("Entries") or []:
            mode = int(e.get("Mode", 0) or 0)
            yield {"path": e.get("FullPath", ""), "isDir": bool(mode & DIR_BIT), "size": int(e.get("FileSize", 0) or 0),
                   "mtime": e.get("Mtime", ""), "mode": mode & 0o7777}
        last = d.get("LastFileName", "")
        if not d.get("ShouldDisplayLoadMore") or not last:
            break


def filer_open(filer, path, timeout=60):
    return urllib.request.urlopen(_url(filer, urllib.parse.quote(path)), timeout=timeout)  # nosec


def filer_upload(filer, path, fileobj, timeout=120):
    """Upload one file to the filer (multipart POST, the form the 4.48 filer accepts)."""
    boundary = "sfs" + os.urandom(12).hex()
    name = os.path.basename(path) or "file"
    head = ("--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"%s\"\r\n"
            "Content-Type: application/octet-stream\r\n\r\n" % (boundary, name.replace('"', "_"))).encode()
    body = head + fileobj.read() + ("\r\n--%s--\r\n" % boundary).encode()
    # TODO(sfs): stream large files instead of reading them into memory (chunked upload).
    req = urllib.request.Request(_url(filer, urllib.parse.quote(path)), data=body, method="POST",
                                 headers={"Content-Type": "multipart/form-data; boundary=" + boundary})
    with urllib.request.urlopen(req, timeout=timeout) as r:  # nosec
        return json.loads(r.read().decode("utf-8") or "{}")
