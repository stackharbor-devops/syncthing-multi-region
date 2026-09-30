"""Storage operations run as jobs: rebalance, heal, drain, remove.

Verified against SeaweedFS 4.48 `weed shell`:
  volume.balance            -> needs `-apply` to act (4.48 has no `-force`; without -apply it only plans)
  volume.fix.replication    -> needs `-apply`
  volume.check.disk         -> simulation unless `-apply`; used here as a read-only report
  volumeServer.evacuate     -> `-node host:port -apply`
All mutating commands run inside `lock` / `unlock`.
"""
import time

from sfsctl import seaweed, topology


class OpsError(ValueError):  # ValueError: server.py maps it to 409/400
    def __init__(self, status, message):
        ValueError.__init__(self, message)
        self.status = status
        self.message = message


def _log_output(job, out, limit=400):
    lines = (out or "").splitlines()
    for ln in lines[-limit:]:
        job.log(ln)


def _regions_with_master(cfg, db, job):
    res = []
    for r in db.list_regions():
        m = seaweed.first_reachable(r.get("masters") or [])
        if not m:
            job.log("region %s: no reachable master, skipped" % r["id"])
            continue
        res.append((r, m))
    if not res:
        raise OpsError(503, "no reachable master in any region")
    return res


def rebalance(cfg, db, job):
    result = {}
    for r, m in _regions_with_master(cfg, db, job):
        job.log("region %s: volume.balance via %s" % (r["id"], m))
        rc, out = seaweed.shell(cfg, m, seaweed.locked(["volume.balance -apply"]), timeout=3000)
        _log_output(job, out)
        result[r["id"]] = {"rc": rc, "errors": seaweed.shell_errors(out)}
        if rc != 0:
            raise OpsError(500, "volume.balance failed in region %s" % r["id"])
    return {"regions": result}


def heal(cfg, db, job):
    result = {}
    for r, m in _regions_with_master(cfg, db, job):
        before = len(seaweed.volume_list(m)["underReplicated"])
        job.log("region %s: %d under-replicated volume(s), running volume.fix.replication" % (r["id"], before))
        rc, out = seaweed.shell(cfg, m, seaweed.locked(["volume.fix.replication -apply"]), timeout=3000)
        _log_output(job, out)
        job.log("region %s: volume.check.disk report (read-only)" % r["id"])
        rc2, out2 = seaweed.shell(cfg, m, seaweed.locked(["volume.check.disk"]), timeout=3000)
        _log_output(job, out2)
        after = len(seaweed.volume_list(m)["underReplicated"])
        result[r["id"]] = {"underReplicatedBefore": before, "underReplicatedAfter": after, "fixRc": rc,
                           "checkRc": rc2, "checkIssues": seaweed.shell_errors(out2)}
        if rc != 0:
            raise OpsError(500, "volume.fix.replication failed in region %s" % r["id"])
    return {"regions": result}


def _node_volume_server(cfg, db, node):
    region = next((r for r in db.list_regions() if r["id"] == node.get("region")), None)
    if not region:
        raise OpsError(404, "region %s of node %s not found" % (node.get("region"), node["id"]))
    m = seaweed.first_reachable(region.get("masters") or [])
    if not m:
        raise OpsError(503, "no reachable master in region %s" % region["id"])
    nodes = seaweed.volume_list(m)["nodes"]
    want = "%s:%s" % (node.get("ip"), node.get("volumePort", 8080))
    for dn in nodes:
        if dn["url"] == want:
            return m, dn
    for dn in nodes:
        if dn["host"] == node.get("ip"):
            return m, dn
    return m, None


def _move_loop(cfg, job, master, source):
    """Move every volume off `source` with explicit volume.move, one at a time.

    Target: a live volume server that does not hold that volume yet, preferring a rack not already
    holding a replica (keeps 010 placement), then the most free slots.
    """
    lv = seaweed.volume_list(master)
    holders = {}
    for r in lv["replicas"]:
        holders.setdefault(r["id"], set()).add((r["server"], r["rack"]))
    free = {n["url"]: n["free"] for n in lv["nodes"]}
    racks = {n["url"]: n["rack"] for n in lv["nodes"]}
    for vid in sorted(v for v, hs in holders.items() if source in {h[0] for h in hs}):
        other_racks = {rk for srv, rk in holders[vid] if srv != source}
        cands = [u for u in free if u != source and u not in {h[0] for h in holders[vid]} and free[u] > 0]
        if not cands:
            job.log("volume %d: no target volume server with free slots" % vid)
            continue
        cands.sort(key=lambda u: (racks[u] in other_racks, -free[u]))
        tgt = cands[0]
        rc, out = seaweed.shell(cfg, master, seaweed.locked(
            ["volume.move -source %s -target %s -volumeId %d" % (source, tgt, vid)]), timeout=3300)
        _log_output(job, out, 20)
        if rc == 0:
            free[tgt] -= 1


def drain_node(cfg, db, job, node_id):
    node = db.get_node(node_id)
    if not node:
        raise OpsError(404, "node %s not found" % node_id)
    prev = node.get("status")
    node["status"] = "draining"
    db.upsert_node(node)
    try:
        m, dn = _node_volume_server(cfg, db, node)
        if dn is None:
            job.log("node %s (%s) is not registered as a volume server: nothing to move" % (node_id, node.get("ip")))
        else:
            job.log("evacuating %s (%d volume(s)) via %s" % (dn["url"], dn["volumes"], m))
            rc, out = seaweed.shell(cfg, m, seaweed.locked(["volumeServer.evacuate -node %s -apply" % dn["url"]]),
                                    timeout=3300)
            _log_output(job, out)
            if rc != 0:
                job.log("evacuate reported errors; falling back to a volume.move loop")
                _move_loop(cfg, job, m, dn["url"])
            left = None
            for _ in range(6):  # master learns about moves on the next volume-server heartbeat
                left = next((x for x in seaweed.volume_list(m)["nodes"] if x["url"] == dn["url"]), None)
                if not left or left["volumes"] == 0:
                    break
                time.sleep(5)
            remaining = left["volumes"] if left else 0
            if remaining:
                raise OpsError(500, "%d volume(s) still on %s after evacuate (rc %s)" % (remaining, dn["url"], rc))
        node = db.get_node(node_id) or node
        node["status"] = "drained"
        node["volumes"] = 0
        db.upsert_node(node)
        db.audit("system", "node.drained", node_id, "ok")
        return {"node": node_id, "status": "drained"}
    except Exception:
        node = db.get_node(node_id) or node
        node["status"] = prev or "online"
        db.upsert_node(node)
        raise


def remove_node(cfg, db, node_id, force=False):
    node = db.get_node(node_id)
    if not node:
        raise OpsError(404, "node %s not found" % node_id)
    live = topology.list_nodes(cfg, db)
    cur = next((n for n in live if n["id"] == node_id), node)
    status = cur.get("status")
    offline_long = status == "offline" and (time.time() - int(node.get("lastSeen") or 0)) > 24 * 3600
    if status != "drained" and not (force and offline_long):
        raise OpsError(409, "node %s is %s: drain it first, or it must be offline > 24h with force=1" % (node_id, status))
    db.delete_node(node_id)
    return {"ok": True, "node": node_id, "healRecommended": status != "drained"}
