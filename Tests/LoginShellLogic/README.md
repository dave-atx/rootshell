# LoginShellLogic tests

Fork-only standalone tests for dependency-free login-shell-command logic.

```sh
swift test --package-path Tests/LoginShellLogic
```

The file under `Sources/LoginShellLogic/` is a symlink to a production
source:

- `LoginShellCommand.swift` → `rootshell/Core/Shell/LoginShellCommand.swift`

This keeps the package out of the Xcode project while exercising the exact
rules used by the app. `LoginShellCommand` builds and quotes the POSIX-sh
snippets the app sends to somebody else's shell — SSH exec-channel requests
(`sshd` runs an exec command as `$SHELL -c '<command>'`, using the client's
*login* shell, which may not be POSIX at all — fish and csh both reject a
bare `export`/`for` script), the AI agent's local `$SHELL -l -c` wrapper, the
VPN tunnel extension, and local probe commands.

The tests spawn real `sh`, `bash`, `zsh`, and `fish` binaries (via
`Foundation.Process`) to syntax-check (`<shell> -n <file>`) and, for several
cases, actually run (`<shell> -c <command>`) the exact strings
`LoginShellCommand` produces — confirming both that the wrap is necessary
(fish rejects the unwrapped payload) and that it is sufficient (all four
shells accept, and correctly execute, the wrapped payload). Any shell not
present on the machine running the tests is skipped rather than failed.

## The fish/POSIX single-quote divergence, and the depth guarantee

`singleQuoted` escapes an embedded `'` as `'"'"'`, not the more familiar
`'\''`. Both idioms round-trip through a single level of `sh -c '...'`
nesting, but fish treats `\'` inside single quotes as an escaped quote where
POSIX sh does not, so `'\''` silently diverges from POSIX once nesting
compounds — measured to fail under fish at depth 3, which is exactly the
depth `MoshConfig.serverCommand` produces in production (mosh wrapping a
TERM override wrapping the zmx exec line). `'"'"'` contains no backslash, so
sh, bash, zsh, and fish agree on it at any depth. The "nesting depth" suite
checks depths 1 through 5 against all four shells (syntax and, for sh and
fish, actual execution); the "legacy escaping regression" suite pins the
`'\''` failure directly so nobody reintroduces it.

`doubleQuoted` escapes `\ " $` and a backtick. The single-quote divergence
above does not apply inside double quotes, with one exception the round-trip
suite pins: fish has no backtick substitution (it spells that `()`), so it
leaves the backslash attached to an escaped `` ` `` where a POSIX shell
strips it. Every call site routes `doubleQuoted` output through
`runInPOSIXShell` first, so `sh` — never the login shell — parses the
double-quoted region, and the suite asserts both halves of that: the bare
form diverges under fish, the wrapped form round-trips.

## What's covered

- The bare-payload hazard: an unwrapped PATH-prefix-plus-`exec` script is
  valid POSIX sh but is rejected outright by fish.
- `runInPOSIXShell` fixes it: the wrapped form parses under all four shells,
  and (suite 4) actually runs and prints the expected output under fish, zsh
  and bash.
- A mosh-shaped payload with two levels of nested `sh -c '...'` (zmx exec
  line, wrapped for a forced `TERM`, wrapped again as the mosh-server
  invocation) parses under all four shells.
- `singleQuoted` round-trips arbitrary bytes (quotes, `$`, backslashes,
  newlines) through `sh` byte-for-byte.
- `pathPrefix`'s shape: ends with `; ` for direct concatenation, and mentions
  every tool/system PATH entry.
- Nesting depths 1 through 5 of `sh -c '...'` around `singleQuoted`, checked
  under all four shells (syntax) and under sh/fish (actual execution).
- The legacy `'\''`-escaping idiom is pinned as REJECTED by fish at depth 3,
  so it can never quietly return.
- `doubleQuoted` round-trips `\ " $` backtick and spaces through all four
  shells byte-for-byte (backtick excepted, see below), and a
  dedicated case confirms `$HOME` inside a `doubleQuoted` value is never
  expanded — it always comes back literal.
- `runInPOSIXShell(login: true)` emits `sh -lc` (vs. plain `sh -c` by
  default) and the result parses under all four shells. The login form is
  never *executed* in these tests — `sh -lc` reads the developer's own
  profile, which would make a run-and-compare-stdout test flaky across
  machines.
- Real composed payloads, reconstructed as fixtures built from
  `LoginShellCommand` itself (see below), because the types that actually
  build them pull in the whole app.
- A `ProjectProbeCommand`-shaped payload for a path containing an apostrophe
  — the input that broke under the old `'\''` idiom once quoting was nested
  two levels deep (also a fixture reconstruction; see below).

## Payloads/types this package cannot import, and how they're covered instead

`TSSHConfig`, `MoshConfig`, `SSHConfig`, `AIAgentExecutor`, `UDPHolePuncher`,
and `SSHVPNTunnelProvider` are not importable here — they pull in the whole
app (or, for the VPN tunnel extension, a different target entirely). The
tests reconstruct the exact payload shapes those builders produce, each
fixture commented with the production site it mirrors so a future change
there is caught by review even though the compiler can't link them:

- the AI agent wrapper — mirrors `AIAgentExecutor.wrapForLoginShell`: a PATH
  prelude run by `sh`, which then `exec`s the login shell with the user's
  command single-quoted, `2>&1 || true` appended; tested with a
  `userCommand` that itself contains single quotes.
- the hole-punch payload — mirrors `UDPHolePuncher`'s reactive punch-back
  script: a bare POSIX script (`PEER_INFO=""`, `if ...; then ... fi`) sent
  *unwrapped*, asserted to fail under fish unwrapped and pass once wrapped
  through `runInPOSIXShell`.
- the tsshd bootstrap — mirrors both `TrzszConfig.serverCommand()` and
  `SSHVPNTunnelProvider.spawnTsshd`: `pathPrefix` plus an `exec` of `tsshd`,
  wrapped through `runInPOSIXShell`.

If those builders change shape, the reconstructions in
`LoginShellCommandTests.swift` need to be updated to match.

### `ProjectProbeCommand`

`ProjectProbeCommand.swift` (`rootshell/Features/SSH/Discovery/`) was
written to be dependency-free specifically so this package could symlink it
in directly — its `command`/`script` take `pathPrefix: String = ""` for
exactly that reason. It was tried: symlinking it in fails to compile,
because it references `TerminalIdentity.paneTokenVariable`
(`rootshell/Core/Terminal/TerminalIdentity.swift`, an app type) inside an
`if let paneToken` branch. Swift type-checks both branches of that `if`
regardless of which one a given call takes, so the reference is a compile
error even for calls that never pass a `paneToken`. Per the task, this was
not worked around by also symlinking or stubbing `TerminalIdentity` — the
symlink was dropped, and the composition is instead reconstructed as a
fixture (`projectProbeShapedPayload`) that applies `singleQuoted` at the same
two levels `ProjectProbeCommand.command()` does (once per probed path, once
more around the whole script), tested with a path containing an apostrophe.

`AgentUsageProbeCommand.swift` (`rootshell/Features/AgentUsage/`) was
assessed the same way: it calls through to `ProjectProbeCommand.singleQuoted`,
so it inherits the same `TerminalIdentity` compile failure and was likewise
left out of the package.

## Known findings

fish does not strip the backslash from an escaped backtick inside a
double-quoted string it parses itself:

```
/bin/sh   -c 'printf %s "\`echo hi\`"'   # => `echo hi`
/bin/bash -c 'printf %s "\`echo hi\`"'   # => `echo hi`
/bin/zsh  -c 'printf %s "\`echo hi\`"'   # => `echo hi`
fish      -c 'printf %s "\`echo hi\`"'   # => \`echo hi\`
```

`\`, `"` and `$` round-trip identically across all four. This never reaches
production — `TerminalView+Session.swift` and `MultiplexerExposeAdapter.swift`
both hand `doubleQuoted` output to `runInPOSIXShell` — and
`LoginShellCommand.doubleQuoted`'s doc comment states the limit explicitly.
The `Backtick diverges under fish` test would start failing if fish ever
gained backtick handling, which is the signal to revisit that comment.
