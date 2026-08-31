# Disposable zmx SSH fixture (fork-only)

`zmx-fixture.sh` builds the zmx checkout selected by `ZMX_REPO` (default
`../zmx`, relative to the rootshell repository) into a local Debian image and
runs it in rootless Podman. The fixture listens only on `127.0.0.1` and uses a
fresh Ed25519 key in a mode-700 temporary directory for every run. The key is
retained for coordinator control, while the application connects through the
real New Connection UI with SSH authentication set to `None`. The disposable
SSH service is published only on loopback and permits an empty password for
the fixture-only `zmx` account.

The normal UI-test runner can wrap its command so cleanup is unconditional:

```sh
Tests/ZmxFixture/zmx-fixture.sh run --env-file "$TMPDIR/zmx.env" -- \
  xcodebuild test ...
```

The environment file contains the loopback host/port, SSH username, private
key path, unique session prefix, container ID, state directory, and zmx git
revision. The private key is coordinator-only: it is never passed to the app
or placed in its connection history. The key file is removed with the fixture
state on successful cleanup. `start` can be used when a caller needs to
control the test lifecycle explicitly, followed by `stop STATE_DIR`.

Session setup is scoped to the generated `rs-xcui-<nonce>-` prefix:

```sh
Tests/ZmxFixture/zmx-fixture.sh seed "$ZMX_FIXTURE_STATE_DIR" picker-probe
Tests/ZmxFixture/zmx-fixture.sh exec "$ZMX_FIXTURE_STATE_DIR" zmx list --short
```

`self-check` performs a dependency, file, and shell-syntax check without
starting Podman or changing state.

## Maintaining the fork branch

The harness lives on `zmx-fork-tests`, never on the upstream PR branch. Keep
it current by rebasing onto upstream and force-pushing with a lease:

```sh
git switch zmx-fork-tests
git fetch upstream main
git rebase upstream/main
git push --force-with-lease origin zmx-fork-tests
```

Until the zmx PR merges, the branch contains the PR's two commits followed by
the harness commit. After the PR lands upstream, rebase should retain only the
fork-only harness delta.
