#!/bin/bash
# DOCKER mode of the Nashorn harness: runs the real scripts/manage.js (or the
# manifest's onUninstall, op=uninstall) against containers, as the platform
# would. Options are described in cli.js.
#
#   tests/harness/manage.sh STATE_FILE key=value...
#
# Example (nodes download the runner from base and Syncthing from a local copy
# of the release; the runner still checks the pinned sha256):
#   tests/harness/manage.sh /tmp/st/state.json env=sta-e2e \
#     nodes=101:sta-e2e-n1:master,102:sta-e2e-n2 \
#     base=http://host.docker.internal:8765 \
#     'dockerenv=STSYNC_DOWNLOAD_BASE=http://host.docker.internal:8765/dl' \
#     op=apply phase=install path=/var/www/webroot/ROOT log=/tmp/st/install.log
#
# Needs python3 with PyYAML, and a JDK 11 jjs: the local one when `java
# -version` says 11, else the eclipse-temurin:11-jdk image, run with the
# Docker socket and with the repository and the state file's directory
# mounted at the same paths (so log= must be under that directory).
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
[ $# -ge 1 ] || { echo "usage: $0 STATE_FILE key=value..." >&2; exit 64; }
SDIR=$(mkdir -p "$(dirname "$1")" && cd "$(dirname "$1")" && pwd)
STATE=$SDIR/$(basename "$1")
shift
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
python3 "$REPO/tests/harness/extract.py" "$REPO/manifest.jps" > "$WORK/manifest.json"

if java -version 2>&1 | grep -q 'version "11\.' && command -v jjs > /dev/null; then
    jjs --no-deprecation-warning "$REPO/tests/harness/cli.js" -- "$REPO" "$WORK/manifest.json" "$STATE" "$@"
    exit $?
fi
docker run --rm -v "$REPO:$REPO:ro" -v "$WORK:$WORK:ro" -v "$SDIR:$SDIR" \
    -v /var/run/docker.sock:/var/run/docker.sock eclipse-temurin:11-jdk \
    jjs --no-deprecation-warning "$REPO/tests/harness/cli.js" -- "$REPO" "$WORK/manifest.json" "$STATE" "$@"
