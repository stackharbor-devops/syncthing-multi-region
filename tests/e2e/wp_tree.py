#!/usr/bin/env python3
"""WordPress-like test trees for tests/e2e/run.sh. Runs inside a node:

  docker exec -i <node> python3 - make ROOT VARIANT < wp_tree.py
  docker exec -i <node> python3 - list ROOT shared|all < wp_tree.py

make writes a deterministic tree (the same path and variant always give the same
bytes), as root; the caller chowns it to the web user.
  site    the master's current site: core, theme, plugins, uploads (one 6 MB
          file, a name with a space and a non-ASCII letter), an empty
          directory, and per-node files the default ignore rules keep local
          (page cache, debug.log)
  stale   an older copy, 3 hours old: every fifth text file has old content,
          wp-config.php has another mode, this month's uploads are missing,
          plus files and a plugin only this node has, and its own cache and log
  other   a partial copy: only the theme, with style.css edited here LATER
          than the master's (mtime 1 hour ahead), a file only this node has,
          and its own ignored files
  stale and other also share files the master lacks (an upload and a
  plugin, the same bytes on both): what a broken lsyncd setup leaves behind.
  Two joiners holding the same file used to keep it on one of them.

list prints one sorted line per entry: "D <mode> <path>" or
"F <sha256> <mode> <path>", paths relative to ROOT. Syncthing's markers
(.stfolder, .stignore, temporary files) are never listed; "shared" also leaves
out what the ignore rules of the test keep local - the part every node must
agree on.

  docker exec -i <node> python3 - kept STORE B64 < wp_tree.py

kept checks that every "<sha256>  <path>" line of the base64 text B64 is in
the version store STORE with that content: under its own path, or as a
conflict copy of it (name.sync-conflict-<date>-<time>-<device>.ext). A joining
node's file that differs from the cluster's is first moved aside as a conflict
copy, then the revert moves that copy into the version store.
"""
import base64
import hashlib
import os
import random
import re
import stat
import sys
import time
import zlib

CONFLICT = re.compile(r"\.sync-conflict-\d{8}-\d{6}-[A-Z0-9]{7}")
MARKERS = re.compile(r"^(\.stfolder(/|$)|\.stignore$)|(^|/)\.syncthing\.[^/]*\.tmp$")
# The default rules plus what the e2e Configure step adds (*.tmp, wp-content/backups).
LOCAL = re.compile(r"^wp-content/(cache|upgrade|backups)(/|$)|\.(log|tmp)$|(^|/)(\.DS_Store|Thumbs\.db)$")


def rnd(key):
    return random.Random(zlib.crc32(key.encode()))


def php(path, ver):
    r = rnd(path + "@" + ver)
    lines = ["$wp_%d = '%032x';" % (i, r.getrandbits(128)) for i in range(r.randint(20, 150))]
    return ("<?php\n/* %s (%s) */\n%s\n" % (path, ver, "\n".join(lines))).encode()


def blob(path, size):
    return rnd(path).randbytes(size)


def site():
    """path -> (content, mode); texts: the paths with text content."""
    texts = ["index.php", "wp-config.php", "wp-settings.php", "wp-login.php", "wp-cron.php",
             "xmlrpc.php", "license.txt", "readme.html", ".htaccess", "wp-content/index.php"]
    texts += ["wp-admin/includes/admin-%02d.php" % i for i in range(40)]
    texts += ["wp-admin/css/admin-%02d.css" % i for i in range(10)]
    texts += ["wp-admin/js/admin-%02d.js" % i for i in range(10)]
    texts += ["wp-includes/class-wp-%02d.php" % i for i in range(60)]
    texts += ["wp-includes/js/script-%02d.js" % i for i in range(30)]
    texts += ["wp-includes/blocks/block-%02d/block.json" % i for i in range(20)]
    theme = "wp-content/themes/twentytwentysix/"
    texts += [theme + "style.css", theme + "functions.php"]
    texts += [theme + "templates/tpl-%02d.html" % i for i in range(10)]
    texts += [theme + "parts/part-%02d.html" % i for i in range(5)]
    texts += ["wp-content/plugins/akismet/akismet-%02d.php" % i for i in range(10)]
    texts += ["wp-content/plugins/woocommerce/includes/wc-%02d.php" % i for i in range(30)]
    files = {p: (php(p, "v2"), 0o644) for p in texts}
    files["wp-config.php"] = (files["wp-config.php"][0], 0o640)
    for i in range(3):
        p = theme + "assets/fonts/font-%d.woff2" % i
        files[p] = (blob(p, 30000), 0o644)
    for month in ("08", "09"):
        for i in range(10):
            p = "wp-content/uploads/2026/%s/photo-%02d.jpg" % (month, i)
            files[p] = (blob(p, 20000 + i * 15000), 0o644)
    for p, size in (("wp-content/uploads/2026/09/café menu.pdf", 300000),
                    ("wp-content/uploads/2026/09/video.mp4", 6 * 1024 * 1024)):
        files[p] = (blob(p, size), 0o644)
    return files, set(texts)


# Files the "stale" and "other" copies both have and the master does not.
COMMON = {"wp-content/uploads/2026/06/on-two-nodes.jpg": blob("on-two-nodes", 30000),
          "wp-content/plugins/extra-plugin/extra.php": php("extra-plugin", "v1")}


def write(root, rel, content, mode, mtime=None):
    full = os.path.join(root, rel)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "wb") as f:
        f.write(content)
    os.chmod(full, mode)
    if mtime is not None:
        os.utime(full, (mtime, mtime))


def make(root, variant):
    files, texts = site()
    now = time.time()
    if variant == "site":
        for rel, (content, mode) in files.items():
            write(root, rel, content, mode)
        for i in range(5):
            write(root, "wp-content/cache/page-%d.html" % i, b"<html>cached on the master</html>\n", 0o644)
        write(root, "wp-content/debug.log", b"master log\n", 0o644)
        for d in ("wp-content/languages", "wp-content/upgrade"):
            os.makedirs(os.path.join(root, d), exist_ok=True)
    elif variant == "stale":
        old = now - 3 * 3600
        for rel, (content, mode) in files.items():
            if rel.startswith("wp-content/uploads/2026/09/"):
                continue
            if rel in texts and zlib.crc32(rel.encode()) % 5 == 0:
                content = php(rel, "v1")
            write(root, rel, content, 0o644, old)
        write(root, "wp-content/uploads/2026/07/stale-only.jpg", blob("stale-only", 50000), 0o644, old)
        write(root, "wp-content/plugins/old-plugin/old-plugin.php", php("old-plugin", "v1"), 0o644, old)
        write(root, "wp-content/plugins/old-plugin/readme.txt", b"an old plugin\n", 0o644, old)
        write(root, "wp-content/cache/stale-page.html", b"<html>cached on the stale node</html>\n", 0o644)
        write(root, "wp-content/debug.log", b"stale node log\n", 0o644)
        for rel, content in COMMON.items():
            write(root, rel, content, 0o644, old)
    elif variant == "other":
        for rel, (content, mode) in files.items():
            if rel.startswith("wp-content/themes/"):
                write(root, rel, content, mode)
        style = "wp-content/themes/twentytwentysix/style.css"
        write(root, style, php(style, "v3 edited on this node"), 0o644, now + 3600)
        write(root, "notes-only-here.txt", b"notes that only this node has\n", 0o644)
        write(root, "wp-content/upgrade/plugin-upgrade.zip", blob("upgrade", 40000), 0o644)
        write(root, ".DS_Store", b"\0\0\0\1Bud1", 0o644)
        for rel, content in COMMON.items():
            write(root, rel, content, 0o644, now - 3 * 3600)
    else:
        sys.exit("unknown variant " + variant)


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def kept(store, wanted):
    have = {}
    for d, _, names in os.walk(store):
        for name in names:
            rel = os.path.relpath(os.path.join(d, name), store)
            have.setdefault((sha256(os.path.join(store, rel)), CONFLICT.sub("", rel)), []).append(rel)
    missing, renamed, n = [], 0, 0
    for line in wanted.splitlines():
        if not line.strip():
            continue
        n += 1
        sha, rel = line.split("  ", 1)
        got = have.get((sha, rel))
        if not got:
            missing.append(rel)
        elif rel not in got:
            renamed += 1
    print("%d of %d kept (%d as conflict copies)%s" % (n - len(missing), n, renamed,
                                                      "; missing: " + ", ".join(missing[:5]) if missing else ""))
    sys.exit(1 if missing or not n else 0)


def listing(root, mode):
    out = []
    for d, dirs, names in os.walk(root):
        for name in dirs + names:
            full = os.path.join(d, name)
            rel = os.path.relpath(full, root)
            if MARKERS.search(rel) or (mode == "shared" and LOCAL.search(rel)):
                continue
            st = os.lstat(full)
            if stat.S_ISDIR(st.st_mode):
                out.append("D %o %s" % (st.st_mode & 0o7777, rel))
            else:
                out.append("F %s %o %s" % (sha256(full), st.st_mode & 0o7777, rel))
    print("\n".join(sorted(out)))


if __name__ == "__main__":
    cmd, root, arg = sys.argv[1:4]
    if cmd == "make":
        make(root, arg)
    elif cmd == "list":
        listing(root, arg)
    elif cmd == "kept":
        kept(root, base64.b64decode(arg).decode())
    else:
        sys.exit("usage: wp_tree.py make ROOT site|stale|other | list ROOT shared|all | kept STORE B64")
