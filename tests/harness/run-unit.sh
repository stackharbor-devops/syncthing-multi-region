#!/bin/bash
# Unit tests of scripts/manage.js and the manifest's inline scripts, in the
# Nashorn harness (FAKE mode: scripted nodes, no containers).
#
#   tests/harness/run-unit.sh
#
# Needs python3 with PyYAML, and a JDK 11 jjs: the local one when `java
# -version` says 11, else the eclipse-temurin:11-jdk Docker image.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
python3 "$REPO/tests/harness/extract.py" "$REPO/manifest.jps" > "$WORK/manifest.json"

if java -version 2>&1 | grep -q 'version "11\.' && command -v jjs > /dev/null; then
    exec jjs --no-deprecation-warning "$REPO/tests/harness/unit-tests.js" -- "$REPO" "$WORK/manifest.json"
fi
docker run --rm -v "$REPO:/repo:ro" -v "$WORK:/work:ro" eclipse-temurin:11-jdk \
    jjs --no-deprecation-warning /repo/tests/harness/unit-tests.js -- /repo /work/manifest.json
