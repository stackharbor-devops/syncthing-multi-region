#!/usr/bin/env bash
# Runs all e2e scenarios in order. Usage: WEED_BIN=/path/to/linux/weed tests/e2e/run-all.sh
cd "$(dirname "$0")"; rc=0
for s in s1-add-node.sh s2-node-failure.sh s3-master-failure.sh s4-cross-region.sh s5-integrity.sh; do
  echo "=== $s"; ./"$s" || { echo "=== $s FAILED"; rc=1; }
done
. ./lab.sh; [ "${KEEP_LAB:-0}" = 1 ] || lab_down
exit $rc
