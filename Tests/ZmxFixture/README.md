# Disposable zmx SSH fixture (fork-only)

`zmx-fixture.sh` builds the zmx checkout selected by `ZMX_REPO` (default
`../zmx`, relative to the rootshell repository) into a local Debian image and
runs it in rootless Podman. The fixture listens only on `127.0.0.1` and uses a
fresh Ed25519 key in a mode-700 temporary directory for every run. The key is
retained for coordinator control, while the application connects through the
real New Connection UI with SSH authentication set to `None`. The disposable
SSH service is published only on loopback and permits an empty password for
either fixture account (see below).

The image ships two accounts with different login shells, `helix`, `mosh`,
and a pinned prebuilt `tsshd` binary alongside `zmx`, so it doubles as a test
host for the SSH exec-channel/login-shell interaction, not just zmx sessions.

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

## Two accounts, two login shells

The container has always run `zmx` (login shell `/bin/bash`). It now also has
`zmxfish` (login shell `/usr/bin/fish`, whatever `command -v fish` resolves
to at image-build time), created the same way: `--create-home`, a mode-700
`.ssh` owned by the account. `sshd`'s `AllowUsers` lists both.

Every `start`/`run` provisions **both** accounts — installs the coordinator's
public key into each `authorized_keys` and clears each password — regardless
of which one that invocation selected. That means a single running container
can be driven against either account without a restart; `--shell` only picks
which one the coordinator (`seed`/`exec`/`env`/`stop`, and the printed
`ZMX_FIXTURE_USERNAME`) targets for that invocation:

```sh
Tests/ZmxFixture/zmx-fixture.sh start --shell fish --env-file "$TMPDIR/zmx.env"
# or: FIXTURE_SHELL=fish Tests/ZmxFixture/zmx-fixture.sh start --env-file ...
```

`--shell` defaults to `bash`, so every existing caller behaves exactly as
before. `FIXTURE_SHELL` is the environment-variable spelling of the same
knob; `--shell` wins if both are given.

The environment file always carries all of:

- `ZMX_FIXTURE_USERNAME` — the account this invocation selected (`zmx` or
  `zmxfish`), kept under its original name for compatibility with existing
  callers that only know one account.
- `ZMX_FIXTURE_SHELL` — `bash` or `fish`, i.e. which one `USERNAME` is.
- `ZMX_FIXTURE_BASH_USER` / `ZMX_FIXTURE_FISH_USER` — the fixed account names
  (`zmx` / `zmxfish`) regardless of selection, so a test can reach the other
  account without re-running `start`.

`seed` creates zmx sessions over SSH, which only makes sense against an
account where `zmx` actually runs cleanly. It deliberately is not
special-cased to always use the bash account: it acts on whichever account
`--shell` selected, same as `exec`. Pointed at `zmxfish`, `seed` (and the
`stop`/cleanup path's session-listing step) can fail for the same reason
covered below — `zmx run ...`, `zmx list --short`, and `zmx kill --force ...`
are sent as `VAR=value command` lines, POSIX-sh syntax fish does not accept —
and cleanup already tolerates that (it treats a failed session listing as "no
sessions to kill" rather than an error). If a test needs `seed` to work, run
it with `--shell bash` (the default) even if the test's SSH exec commands
target `zmxfish` for the actual assertion.

Session setup is scoped to the generated `rs-xcui-<nonce>-` prefix:

```sh
Tests/ZmxFixture/zmx-fixture.sh seed "$ZMX_FIXTURE_STATE_DIR" picker-probe
Tests/ZmxFixture/zmx-fixture.sh exec "$ZMX_FIXTURE_STATE_DIR" zmx list --short
```

`self-check` performs a dependency, file, and shell-syntax check without
starting Podman or changing state, including the `--shell`/`--env-file`
argument-parsing helper and the new env-file keys — no Podman required.

## Reproducing the fish login-shell bug

`sshd` runs an SSH exec-channel command as `$SHELL -c '<command>'` — the
*login* shell of the account being connected to, not a fixed POSIX shell.
`TSSHConfig.serverCommand()` (and other exec-channel builders) used to hand
that channel a bare POSIX-sh PATH prelude, which fish rejects outright with
`Unsupported use of '='` before `tsshd` is ever reached. The fix
(`LoginShellCommand.runInPOSIXShell`, `rootshell/Core/Shell/LoginShellCommand.swift`)
wraps the payload as `sh -c '<script>'` so the login shell's only job is to
exec a real POSIX shell.

This fixture reproduces both the failure and the fix directly, without the
app, using the exact same string the app would build. Commands below are
POSIX sh; the `$ZMX_FIXTURE_*` variables come from `start`'s env file.

```sh
Tests/ZmxFixture/zmx-fixture.sh start --shell fish --env-file "$TMPDIR/zmx.env"
. "$TMPDIR/zmx.env"

SSHOPTS="-o BatchMode=yes -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile=$ZMX_FIXTURE_STATE_DIR/known_hosts \
  -i $ZMX_FIXTURE_PRIVATE_KEY -p $ZMX_FIXTURE_PORT"
```

**1. Confirm the accounts' login shells:**

```sh
$ ssh $SSHOPTS "$ZMX_FIXTURE_FISH_USER@$ZMX_FIXTURE_HOST" \
    'echo $version; status --is-login && echo IS_LOGIN_SHELL'
3.6.0
$ getent passwd zmxfish
zmxfish:x:1001:1001::/home/zmxfish:/usr/bin/fish
$ getent passwd zmx
zmx:x:1000:1000::/home/zmx:/bin/bash
```

(`echo $version` prints fish's version variable — bash would print a blank
line for an unset `$version` — confirming the exec channel really is parsed
by fish. `status --is-login` reports false: `sshd` invokes the exec-channel
shell as `$SHELL -c '<command>'`, without `-l`, so the *login shell program*
is in use non-interactively. That absence of `-l` is exactly why the PATH
prelude — which assumes a shell that groks `VAR=value`, `export`, `for` —
reaches fish/csh unmediated instead of going through a profile.)

**2. Build the exact payloads `LoginShellCommand` produces** (compiled, not
hand-assembled — `main.swift` must be named that; it is the file carrying
top-level statements):

```sh
$ cat > /tmp/lsc-driver-src/main.swift <<'SWIFT'
import Foundation
let tsshdScript = LoginShellCommand.pathPrefix + "exec tsshd --attachable --port 61000-61999 --quic"
print(tsshdScript)
print("---WRAPPED---")
print(LoginShellCommand.runInPOSIXShell(tsshdScript))
SWIFT
$ swiftc rootshell/Core/Shell/LoginShellCommand.swift /tmp/lsc-driver-src/main.swift -o /tmp/lsc-driver
$ /tmp/lsc-driver
_rsp=; _rsl=; [ "$(/usr/bin/uname -s 2>/dev/null)" = Darwin ] || _rsl="/home/linuxbrew/.linuxbrew/bin /snap/bin"; for _rsd in /opt/homebrew/bin /usr/local/bin "$HOME/go/bin" /usr/local/go/bin $_rsl /usr/bin /bin /usr/sbin /sbin; do [ -d "$_rsd" ] && _rsp="$_rsp$_rsd:"; done; export PATH="$_rsp$PATH"; exec tsshd --attachable --port 61000-61999 --quic
---WRAPPED---
sh -c '_rsp=; _rsl=; [ "$(/usr/bin/uname -s 2>/dev/null)" = Darwin ] || _rsl="/home/linuxbrew/.linuxbrew/bin /snap/bin"; for _rsd in /opt/homebrew/bin /usr/local/bin "$HOME/go/bin" /usr/local/go/bin $_rsl /usr/bin /bin /usr/sbin /sbin; do [ -d "$_rsd" ] && _rsp="$_rsp$_rsd:"; done; export PATH="$_rsp$PATH"; exec tsshd --attachable --port 61000-61999 --quic'
```

**3. Bare payload against `zmxfish` (fish): fails at the first token, before
`tsshd` is ever reached.**

```sh
$ ssh $SSHOPTS "$ZMX_FIXTURE_FISH_USER@$ZMX_FIXTURE_HOST" '<bare payload>'
fish: Unsupported use of '='. In fish, please use 'set _rsp '.
_rsp=; _rsl=; [ "$(/usr/bin/uname -s 2>/dev/null)" = Darwin ] || _rsl="/home/linuxbrew/.linuxbrew/bin /snap/bin"; for _rsd in /opt/homebrew/bin /usr/local/bin "$HOME/go/bin" /usr/local/go/bin $_rsl /usr/bin /bin /usr/sbin /sbin; do [ -d "$_rsd" ] && _rsp="$_rsp$_rsd:"; done; export PATH="$_rsp$PATH"; exec tsshd --attachable --port 61000-61999 --quic
^~~~^
```

**4. Wrapped payload against `zmxfish` (fish): `sh -c` runs it, `tsshd`
starts and prints its JSON handshake on stdout** (truncated below):

```sh
$ ssh $SSHOPTS "$ZMX_FIXTURE_FISH_USER@$ZMX_FIXTURE_HOST" '<wrapped payload>'
{"ServerVer":"0.1.9","ProtoVer":1,"Port":61306,"Mode":"QUIC","ServerCert":"...","ClientCert":"...","ClientKey":"...","ProxyKey":"...","ServerID":4635350478182043049}
```

**5. Both forms already succeed against the bash account (`zmx`), proving
the difference is specifically the login shell, not the payload** — same
JSON handshake either way:

```sh
$ ssh $SSHOPTS "$ZMX_FIXTURE_BASH_USER@$ZMX_FIXTURE_HOST" '<bare payload>'
{"ServerVer":"0.1.9", ...}
$ ssh $SSHOPTS "$ZMX_FIXTURE_BASH_USER@$ZMX_FIXTURE_HOST" '<wrapped payload>'
{"ServerVer":"0.1.9", ...}
```

`tsshd --attachable` is a long-running server (it waits for a QUIC client
after the JSON greeting), so a real run needs to background the `ssh`
invocation and kill it after capturing the greeting rather than waiting for
`ssh` to exit on its own.

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
