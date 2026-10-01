# Contributing

Thanks for helping. Bug reports, testing on your own platform, ideas and pull requests
are all welcome.

## Ways to help

- **Test it.** Install it on a test environment, scale the layer in and out, redeploy a
  node, take a node offline and bring it back, and tell us what happened.
- **Report bugs** with the *Bug report* issue form. The Tasks log output of the failing
  step and the add-on's Status output are the most useful things to include.
- **Suggest features** or roadmap priorities with the *Feature request* form.
- **Send a pull request.** For anything larger than a small fix, open an issue first so
  we can agree on the approach.

## Testing a change on a platform

Every `.jps` file has a `baseUrl` that points at the **main** branch, and the platform
loads every other file from that URL. So a manifest imported from your branch would still
run the scripts from main. To test a branch:

1. Push your branch (to your fork or to this repository).
2. In the branch only, change every `baseUrl` from `.../syncthing-multi-region/main` to
   your branch (and your fork's owner, if you use a fork). Commit that as a separate
   commit named "TEST BRANCH ONLY".
3. Import the manifest from
   `https://raw.githubusercontent.com/<owner>/syncthing-multi-region/<branch>/manifest.jps`
   on a test environment.
4. Before the pull request is merged, drop the "TEST BRANCH ONLY" commit. The automatic
   check warns while a `baseUrl` does not point at main.

`raw.githubusercontent.com` caches files for about five minutes. To be sure the platform
gets your latest push, use the commit id instead of the branch name in the URL.

## Before you open a pull request

Run the same check that runs automatically on every pull request:

```bash
pip install pyyaml
python3 .github/scripts/check.py
```

It needs Python 3, Node.js and bash. It checks that every `.jps` is valid YAML, that the
JavaScript in `script:` blocks and `scripts/**/*.js` parses, that shell scripts parse, and
the first rule below.

A change to `scripts/` or `manifest.jps` should also pass the tests in `tests/` (unit,
node runner and end to end, with Docker); the commands are in the README's Tests section.

## Rules that have bitten us before

- **No shell `${VAR}` inside `cmd` bodies of `.jps` files.** The platform treats `${...}`
  as its own placeholder and replaces it. Write `$VAR`. Only real placeholders such as
  `${globals.x}`, `${settings.x}`, `${env.x}` and `${nodes.x}` may use braces.
- **Forms that launch an action need `submitUnchanged: true`**, or the Run button stays
  disabled until the user changes something.
- **Dialog `markup:` is plain text.** HTML is shown literally.
- **Keep settings in the add-on's own node-group data key,** never in keys other packages
  use, and never only on the nodes: a redeploy replaces everything on a node except the
  paths listed in `/etc/jelastic/redeploy.conf`.
- **Long node work must run detached.** A dashboard button gives up after about 19
  minutes, and a single command on a node is stopped after about an hour.
- **Never let a node that joins or rejoins overwrite the cluster.** New and cloned nodes
  join receive-only until they have the cluster's state.

## Versions and the changelog

- Bump `version:` in `manifest.jps` when you change it.
- Add an entry at the top of `CHANGELOG.md`: what changed, and why a user would care.
- Releases are tagged `vX.Y` on main.

## License

By contributing you agree that your contribution is licensed under the MIT License in
`LICENSE`.
