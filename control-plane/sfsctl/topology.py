"""Cluster / region / node views: control-plane records merged with live master data."""
import time

from sfsctl import seaweed

STICKY_STATUSES = ("draining", "drained", "removed")


def live_region(cfg, region, timeout=seaweed.HTTP_TIMEOUT):
    """-> seaweed.volume_list() of the region's reachable master, plus 'master'; None if unreachable."""
    m = seaweed.first_reachable(region.get("masters") or [], timeout)
    if not m:
        return None
    try:
        v = seaweed.volume_list(m, timeout)
    except Exception:
        return None
    v["master"] = m
    return v


def live_all(cfg, db, timeout=seaweed.HTTP_TIMEOUT):
    return {r["id"]: live_region(cfg, r, timeout) for r in db.list_regions()}


def _merge_node(n, live, now):
    n = dict(n)
    lv = None
    if live:
        for dn in live["nodes"]:
            if dn["host"] == n.get("ip"):
                lv = dn
                break
    if lv is not None:
        n["volumes"] = lv["volumes"]
        n["volumeServer"] = lv["url"]
    if n.get("status") not in STICKY_STATUSES:
        roles = n.get("roles") or []
        if lv is not None:
            n["status"] = "online"
        elif "volume" in roles or live is None:
            if n.get("status") != "joining":
                n["status"] = "offline"
        else:
            # filer/master-only node: fall back to heartbeat freshness
            fresh = n.get("lastSeen") and now - int(n["lastSeen"]) < 120
            n["status"] = "online" if fresh else "offline"
    n.setdefault("capacity", {})
    return n


def list_nodes(cfg, db, live=None):
    live = live if live is not None else live_all(cfg, db)
    now = int(time.time())
    return [_merge_node(n, live.get(n.get("region")), now) for n in db.list_nodes()]


def list_regions(cfg, db, live=None):
    live = live if live is not None else live_all(cfg, db)
    nodes = db.list_nodes()
    out = []
    for r in db.list_regions():
        lv = live.get(r["id"])
        status = r.get("status") or "pending"
        if status not in ("removing", "removed"):
            status = "online" if lv else ("offline" if r.get("masters") else "pending")
        out.append({
            "id": r["id"], "name": r.get("name", r["id"]), "envName": r.get("envName", ""), "status": status,
            "masters": r.get("masters") or [], "filers": r.get("filers") or [],
            "nodes": sum(1 for n in nodes if n.get("region") == r["id"] and n.get("status") != "removed"),
        })
    return out


def cluster_summary(cfg, db, live=None):
    live = live if live is not None else live_all(cfg, db)
    nodes = list_nodes(cfg, db, live)
    total = used = 0
    for n in nodes:
        if n.get("status") == "removed":
            continue
        cap = n.get("capacity") or {}
        total += int(cap.get("totalBytes", 0) or 0)
        used += int(cap.get("usedBytes", 0) or 0)
    volumes = sum(len(v["volumeIds"]) for v in live.values() if v)
    version = next((v["version"] for v in live.values() if v and v.get("version")), "")
    return {
        "clusterId": cfg.get("clusterId", ""), "name": cfg.get("clusterName", ""),
        "primaryRegion": cfg.get("primaryRegion", ""), "replication": cfg.get("replication", "010"),
        "capacity": {"totalBytes": total, "usedBytes": used, "freeBytes": max(total - used, 0)},
        "counts": {"regions": len(db.list_regions()), "nodes": len([n for n in nodes if n.get("status") != "removed"]),
                   "volumes": volumes},
        "version": version,
    }
