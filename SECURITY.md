# Security policy

## Reporting a vulnerability

Please do not report security problems in public issues.

Report them privately through GitHub:
[Security > Report a vulnerability](https://github.com/stackharbor-devops/syncthing-multi-region/security/advisories/new).
Include what an attacker could do, the affected version or commit, and steps to reproduce.
You should get a reply within a few working days.

## Scope

In scope: this package's JPS manifests and scripts, for example a way to reach a node's
Syncthing listener from outside the platform's private network, a command injection
through an add-on form, a way to join a cluster without being added by the package, or
files replicated to a node that should not receive them.

Out of scope: vulnerabilities in Syncthing or the Virtuozzo Application Platform itself.
Report those to their maintainers.

## Security model, in short

- Syncthing listens only on each node's private IP address. Nodes in other regions are
  reached over the platform's private network between regions.
- Nodes authenticate each other with certificates: a node only talks to the device IDs the
  package has added. Public discovery, relays and the web interface are turned off, and
  the local API listens on 127.0.0.1 only.
- The platform's network isolation and firewall decide which environments can reach each
  other. The package opens only the Syncthing port between cluster nodes.
