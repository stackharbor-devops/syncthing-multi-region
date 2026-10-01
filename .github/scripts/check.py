#!/usr/bin/env python3
"""Static checks for this JPS package. Run locally with:  python3 .github/scripts/check.py

What it catches (each one has broken a live install of this package before):
  - a .jps file that is not valid YAML
  - a JavaScript syntax error in a .jps `script:` block or in scripts/**/*.js
  - shell ${VAR} inside a .jps `cmd` body (the JPS interpolator eats it; write $VAR)
  - a shell syntax error in scripts/**/*.sh
It also warns (without failing) when a .jps baseUrl does not point at the main
branch: installs load every file from that URL, so a test-branch baseUrl must be
dropped before merging into main.
Needs python3 with PyYAML, node and bash.
"""
import glob
import os
import re
import subprocess
import sys
import tempfile

import yaml

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
GHA = os.environ.get("GITHUB_ACTIONS") == "true"
MAIN_BASE = "https://raw.githubusercontent.com/stackharbor-devops/syncthing-multi-region/main"
# Real JPS placeholders. Anything else in ${...} inside a cmd body is a shell variable.
PLACEHOLDER = re.compile(r"(globals|settings|env|nodes|this|baseUrl|user|event|response|fn|targetNodes|app)\b")
# Known exceptions, keyed by (file, variable). Keep this empty unless a case is
# proven harmless on the platform.
ALLOWED_SHELL_VARS = set()

errors = 0
warnings = 0


def report(kind, path, msg, line=None):
    global errors, warnings
    if kind == "error":
        errors += 1
    else:
        warnings += 1
    if GHA:
        loc = "file=%s" % path + (",line=%d" % line if line else "")
        print("::%s %s::%s" % (kind, loc, msg))
    else:
        print("%s: %s%s: %s" % (kind.upper(), path, ":%d" % line if line else "", msg))


def line_of(text, needle):
    i = text.find(needle)
    return text.count("\n", 0, i) + 1 if i >= 0 else None


# The platform's script engine treats "//" as the start of a comment even inside a
# regular expression literal such as /\/\//, and then fails with "unterminated regular
# expression literal". Flag a backslash followed by two slashes in code lines.
REGEX_DOUBLE_SLASH = re.compile(r"\\//")


def platform_js_check(src, path, label, raw_text):
    for n, line in enumerate(src.splitlines(), 1):
        if line.strip().startswith("//"):
            continue
        if REGEX_DOUBLE_SLASH.search(line):
            report("error", path, "%s line %d: '//' inside a regular expression breaks the platform's script engine - "
                   "use indexOf or a {2} quantifier instead" % (label, n), line_of(raw_text, line.strip()) if label != "file" else n)


def node_check(src, path, label, raw_text):
    # ${...} placeholders are filled in by the platform before the script runs.
    code = re.sub(r"\$\{[^}]*\}", "0", src)
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as f:
        # Wrapped in a function: platform scripts may `return` at top level.
        f.write("(function(){\n" + code + "\n});\n")
        tmp = f.name
    try:
        r = subprocess.run(["node", "--check", tmp], capture_output=True, text=True)
    finally:
        os.unlink(tmp)
    if r.returncode:
        detail = [l for l in r.stderr.splitlines() if "SyntaxError" in l]
        # node reports "<tmpfile>:<line>"; line 1 of the temp file is the wrapper.
        at = re.search(re.escape(tmp) + r":(\d+)", r.stderr)
        line = None
        if at:
            line = int(at.group(1)) - 1
            if label != "file":   # a script block: offset by where the block starts in the .jps
                first = src.lstrip("\n").splitlines()[0] if src.strip() else ""
                start = line_of(raw_text, first) if first else None
                line = start + line - 1 if start else None
        report("error", path, "JavaScript syntax error in %s: %s" % (label, detail[0] if detail else r.stderr.strip()[:200]), line)


def walk(node, path, where, raw_text):
    if isinstance(node, dict):
        for k, v in node.items():
            here = "%s.%s" % (where, k) if where else str(k)
            if k == "script" and isinstance(v, str) and "\n" in v:
                node_check(v, path, here, raw_text)
                platform_js_check(v, path, here, raw_text)
            if isinstance(k, str) and (k == "cmd" or k.startswith("cmd[")):
                for c in (v if isinstance(v, list) else [v]):
                    if not isinstance(c, str):
                        continue
                    for m in re.finditer(r"\$\{([^}]*)\}", c):
                        var = m.group(1)
                        name = re.match(r"[A-Za-z_]\w*", var)
                        name = name.group(0) if name else var
                        if PLACEHOLDER.match(var) or (path, name) in ALLOWED_SHELL_VARS:
                            continue
                        report("error", path, "shell variable %s in a cmd body (%s): the JPS interpolator replaces it - write $%s"
                               % (m.group(0), here, name), line_of(raw_text, m.group(0)))
            walk(v, path, here, raw_text)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            walk(v, path, "%s[%d]" % (where, i), raw_text)


def main():
    os.chdir(ROOT)
    jps = sorted(p for p in glob.glob("**/*.jps", recursive=True) if not p.startswith("v.0.1/"))
    for p in jps:
        text = open(p, encoding="utf-8").read()
        try:
            doc = yaml.safe_load(text)
        except yaml.YAMLError as e:
            mark = getattr(e, "problem_mark", None)
            report("error", p, "not valid YAML: %s" % str(e).splitlines()[0], mark.line + 1 if mark else None)
            continue
        walk(doc, p, "", text)
        m = re.search(r"^baseUrl:\s*(\S+)", text, re.M)
        if m and m.group(1).rstrip("/") != MAIN_BASE:
            report("warning", p, "baseUrl is %s, not the main branch - fine on a test branch, but drop it before merging into main" % m.group(1),
                   line_of(text, m.group(0)))
    for p in sorted(glob.glob("scripts/**/*.js", recursive=True)):
        text = open(p, encoding="utf-8").read()
        node_check(text, p, "file", text)
        platform_js_check(text, p, "file", text)
    for p in sorted(glob.glob("scripts/**/*.sh", recursive=True)):
        r = subprocess.run(["bash", "-n", p], capture_output=True, text=True)
        if r.returncode:
            report("error", p, "shell syntax error: %s" % r.stderr.strip()[:300])
    print("checked %d .jps files: %d error(s), %d warning(s)" % (len(jps), errors, warnings))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
