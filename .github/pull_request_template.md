## What this changes

<!-- A short summary of the change. -->

## Why

<!-- The problem it solves or the feature it adds. Link the issue if there is one: "Fixes #123". -->

## How it was tested

<!--
Which platform (Virtuozzo Application Platform / Jelastic version, hoster) and what you ran:
a fresh install, an upgrade of an existing cluster, or a single add-on.
Paste the relevant Tasks log lines for anything that runs on the nodes.
-->

- [ ] Fresh install
- [ ] Upgrade of an existing cluster
- [ ] Not tested on a platform (explain why)

## Checklist

- [ ] `python3 .github/scripts/check.py` passes (the same check runs automatically on this pull request)
- [ ] Every `baseUrl` points at `.../syncthing-multi-region/main` (a test-branch `baseUrl` must not be merged)
- [ ] `version:` bumped in `manifest.jps` and in any add-on `.jps` that changed
- [ ] `CHANGELOG.md` updated
- [ ] `README.md` updated if behaviour or a user-facing step changed
- [ ] No shell `${VAR}` inside `cmd` bodies of `.jps` files (write `$VAR`)
