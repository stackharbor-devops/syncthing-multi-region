#!/usr/bin/env python3
"""Writes manifest.jps as JSON for the Nashorn harness (Nashorn has no YAML
parser): the unit tests run its inline scripts (onUninstall, the Configure
form's onBeforeInit) and check its wiring.

Usage: python3 tests/harness/extract.py manifest.jps > manifest.json
Needs PyYAML (the same as .github/scripts/check.py).
"""
import json
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    json.dump(yaml.safe_load(f), sys.stdout)
