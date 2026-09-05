// Standalone syntax/runtime checks for `LoginShellCommand`'s remote-command
// strings: the ones the app hands to `sshd` as an exec-channel command
// (`$SHELL -c '<command>'`), where `$SHELL` may be fish, csh, or anything
// else, not necessarily a POSIX shell.
//
// TSSHConfig/MoshConfig/SSHConfig/AIAgentExecutor/UDPHolePuncher/
// SSHVPNTunnelProvider themselves are not importable here — they pull in the
// whole app (or, for the VPN tunnel extension, a different target entirely).
// The tests below instead reconstruct the exact payload shapes those
// builders produce (see the comment on each). If those builders change
// shape, these tests need to be updated to match — that is the point: a
// change to the real call site is only caught here if someone keeps this
// file in sync with it.
//
// `singleQuoted` escapes an embedded `'` as `'"'"'`, not the more familiar
// `'\''`. The two idioms agree at one level of `sh -c '...'` nesting but
// diverge at two: fish treats `\'` inside single quotes as an escaped quote,
// where POSIX sh does not, so `'\''` round-trips through sh/bash/zsh at any
// depth but is rejected by fish (`Unsupported use of '='`) once nesting
// reaches depth 3 — exactly the depth `MoshConfig.serverCommand` reaches in
// production (mosh wrapping a TERM override wrapping the zmx exec line).
// `'"'"'` contains no backslash, so sh, bash, zsh, and fish agree on it at
// every depth. Suite 7 below is the parameterised depth test that would have
// caught this; suite 8 pins the `'\''` regression directly.

import Foundation
import Testing
@testable import LoginShellLogic

// MARK: - Shell discovery

/// Absolute paths to the shells under test, resolved once. A shell that
/// isn't installed is `nil` and every test using it is skipped rather than
/// failed.
enum TestShells {
    static let sh = firstExisting(["/bin/sh"])
    static let bash = firstExisting(["/bin/bash", "/usr/local/bin/bash", "/opt/homebrew/bin/bash"])
    static let zsh = firstExisting(["/bin/zsh", "/usr/local/bin/zsh"])
    static let fish = firstExisting(["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"])

    /// All four, paired with a label for test output.
    static var all: [(name: String, path: String?)] {
        [("sh", sh), ("bash", bash), ("zsh", zsh), ("fish", fish)]
    }

    /// The three POSIX shells, for cases where fish is expected to differ.
    static var posixOnly: [(name: String, path: String?)] {
        [("sh", sh), ("bash", bash), ("zsh", zsh)]
    }

    private static func firstExisting(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

// MARK: - Process helpers

struct SyntaxCheckResult {
    let exitCode: Int32
    let stderr: String
}

struct RunResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

/// Runs `<shell> -n <tempfile>` containing `script`, returning the exit
/// status and captured stderr. A zero exit means the shell's parser accepted
/// the script without executing it.
func syntaxCheck(shellPath: String, script: String) throws -> SyntaxCheckResult {
    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("LoginShellCommandTests-\(UUID().uuidString).sh")
    try script.write(to: tempURL, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: shellPath)
    process.arguments = ["-n", tempURL.path]

    let stderrPipe = Pipe()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = stderrPipe

    try process.run()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
    return SyntaxCheckResult(exitCode: process.terminationStatus, stderr: stderr)
}

/// Runs `<shell> -c <string>`, capturing stdout/stderr and the exit status.
func run(shellPath: String, command: String) throws -> RunResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shellPath)
    process.arguments = ["-c", command]

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return RunResult(
        exitCode: process.terminationStatus,
        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
        stderr: String(data: stderrData, encoding: .utf8) ?? ""
    )
}

// MARK: - Payload shapes mirroring the app's builders

/// The bare tsshd-launch payload `TSSHConfig.serverCommand()` builds before
/// wrapping: `pathPrefix` followed directly by an `exec` of the target
/// binary. This is valid POSIX sh but NOT valid fish, which is exactly the
/// hazard `runInPOSIXShell` exists to fix.
let bareTsshdPayload = LoginShellCommand.pathPrefix + "exec tsshd --attachable --port 61000-61999 --quic"

/// A mosh-shaped payload with two levels of nested `sh -c '...'`, mirroring
/// `SSHConfig.zmxExecCommandLine` (innermost) wrapped the way
/// `MoshConfig.moshSessionCommandWithTerm` wraps a session command to force
/// `TERM`, and then wrapped once more via `runInPOSIXShell` the way
/// `MoshConfig.serverCommand(shell:)` wraps its whole exec-channel command.
func nestedMoshShapedPayload() -> String {
    // Innermost: the zmx attach-or-create line (SSHConfig.zmxExecCommandLine),
    // reconstructed with `singleQuoted` instead of the hand-quoted literal the
    // production code uses (safe there only because session names are
    // pre-validated to exclude quotes).
    let zmxInner = LoginShellCommand.pathPrefix
        + "command -v zmx >/dev/null && ZMX_SESSION_PREFIX= exec zmx attach main || exec $SHELL"
    let zmxCommand = "sh -c \(LoginShellCommand.singleQuoted(zmxInner))"

    // Middle: MoshConfig.moshSessionCommandWithTerm forcing TERM around the
    // session command.
    let moshMiddle = "export TERM=xterm-256color; exec \(zmxCommand)"
    let moshCommand = "sh -c \(LoginShellCommand.singleQuoted(moshMiddle))"

    // Outer: the mosh-server invocation line, as MoshConfig.serverCommand
    // assembles it, ready for runInPOSIXShell.
    return LoginShellCommand.pathPrefix
        + "exec mosh-server new -s -p 60000:61000 -c 256 -- \(moshCommand)"
}

// MARK: - 1. The hazard is real

@Suite("LoginShellCommand hazard")
struct LoginShellCommandHazardTests {
    @Test("Bare payload parses clean under sh, bash, zsh")
    func bareParsesUnderPosixShells() throws {
        for (name, path) in [("sh", TestShells.sh), ("bash", TestShells.bash), ("zsh", TestShells.zsh)] {
            guard let path else { continue }
            let result = try syntaxCheck(shellPath: path, script: bareTsshdPayload)
            #expect(result.exitCode == 0, "\(name) rejected the bare payload: \(result.stderr)")
        }
    }

    @Test("Bare payload is REJECTED by fish — this is why runInPOSIXShell exists")
    func bareFailsUnderFish() throws {
        guard let fish = TestShells.fish else { return }
        let result = try syntaxCheck(shellPath: fish, script: bareTsshdPayload)
        #expect(result.exitCode != 0, "expected fish to reject the bare POSIX-sh payload, but it parsed clean")
    }
}

// MARK: - 2. The wrap fixes it

@Suite("LoginShellCommand wrap")
struct LoginShellCommandWrapTests {
    @Test("Wrapped payload parses clean under all four shells")
    func wrappedParsesEverywhere() throws {
        let wrapped = LoginShellCommand.runInPOSIXShell(bareTsshdPayload)
        for (name, path) in TestShells.all {
            guard let path else { continue }
            let result = try syntaxCheck(shellPath: path, script: wrapped)
            #expect(result.exitCode == 0, "\(name) rejected the wrapped payload: \(result.stderr)")
        }
    }
}

// MARK: - 3. Nested quoting round-trips

@Suite("LoginShellCommand nested quoting")
struct LoginShellCommandNestedQuotingTests {
    @Test("Mosh-shaped double-nested sh -c payload parses clean under all four shells")
    func nestedPayloadParsesEverywhere() throws {
        let wrapped = LoginShellCommand.runInPOSIXShell(nestedMoshShapedPayload())
        for (name, path) in TestShells.all {
            guard let path else { continue }
            let result = try syntaxCheck(shellPath: path, script: wrapped)
            #expect(result.exitCode == 0, "\(name) rejected the nested payload: \(result.stderr)")
        }
    }
}

// MARK: - 4. Runtime, not just syntax

@Suite("LoginShellCommand runtime")
struct LoginShellCommandRuntimeTests {
    @Test("runInPOSIXShell payload actually runs and prints OK under fish, zsh, bash")
    func wrappedPayloadRunsUnderLoginShells() throws {
        let wrapped = LoginShellCommand.runInPOSIXShell(LoginShellCommand.pathPrefix + "exec echo OK")
        for (name, path) in [("fish", TestShells.fish), ("zsh", TestShells.zsh), ("bash", TestShells.bash)] {
            guard let path else { continue }
            let result = try run(shellPath: path, command: wrapped)
            #expect(result.exitCode == 0, "\(name) exited \(result.exitCode): \(result.stderr)")
            #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "OK",
                    "\(name) printed \(result.stdout.debugDescription) instead of OK")
        }
    }
}

// MARK: - 5. singleQuoted escaping

@Suite("LoginShellCommand singleQuoted")
struct LoginShellCommandSingleQuotedTests {
    @Test(
        "Round-trips special characters through sh byte-for-byte",
        arguments: [
            "it's a test",
            "she said \"hi\"",
            "$HOME and $(pwd)",
            "back\\slash",
            "line one\nline two",
            "mix: ' \" $ \\ \n done"
        ]
    )
    func roundTrips(payload: String) throws {
        guard let sh = TestShells.sh else { return }
        let command = "printf '%s' \(LoginShellCommand.singleQuoted(payload))"
        let result = try run(shellPath: sh, command: command)
        #expect(result.exitCode == 0, "sh exited \(result.exitCode): \(result.stderr)")
        #expect(result.stdout == payload)
    }
}

// MARK: - 6. pathPrefix shape

@Suite("LoginShellCommand pathPrefix")
struct LoginShellCommandPathPrefixTests {
    @Test("Ends with '; ' so callers can concatenate a command directly")
    func endsWithSeparator() {
        #expect(LoginShellCommand.pathPrefix.hasSuffix("; "))
    }

    @Test("Mentions each tool and system PATH entry")
    func mentionsAllEntries() {
        let prefix = LoginShellCommand.pathPrefix
        for entry in LoginShellCommand.toolPathEntries + LoginShellCommand.systemPathEntries {
            #expect(prefix.contains(entry), "pathPrefix does not mention \(entry)")
        }
    }
}

// MARK: - 7. Nesting depth is unbounded

/// Wraps `payload` in `sh -c <LoginShellCommand.singleQuoted(...)>` `depth`
/// times, mirroring how each additional layer of `runInPOSIXShell`/`sh -c`
/// nesting is built in production (mosh wraps a TERM override which wraps
/// the zmx exec line, each via `singleQuoted`).
func nestedWrap(_ payload: String, depth: Int) -> String {
    var current = payload
    for _ in 0..<depth {
        current = "sh -c \(LoginShellCommand.singleQuoted(current))"
    }
    return current
}

@Suite("LoginShellCommand nesting depth")
struct LoginShellCommandNestingDepthTests {
    /// A payload of bare `VAR=value` assignments — the shape that is valid
    /// POSIX sh but exposes exactly the fish quoting hazard `singleQuoted`
    /// exists to avoid (see the legacy-escaping regression test below).
    static let depthPayload = "A=1; B=2; echo OK"

    @Test("sh -c nesting parses clean under sh, bash, zsh, and fish at depths 1-5",
          arguments: 1...5)
    func nestingParsesAtEveryDepth(depth: Int) throws {
        let wrapped = nestedWrap(Self.depthPayload, depth: depth)
        for (name, path) in TestShells.all {
            guard let path else { continue }
            let result = try syntaxCheck(shellPath: path, script: wrapped)
            #expect(result.exitCode == 0, "\(name) rejected depth \(depth): \(result.stderr)")
        }
    }

    @Test("sh -c nesting actually runs and prints OK under sh -c and fish -c at depths 1-5",
          arguments: 1...5)
    func nestingRunsAtEveryDepth(depth: Int) throws {
        let wrapped = nestedWrap(Self.depthPayload, depth: depth)
        for (name, path) in [("sh", TestShells.sh), ("fish", TestShells.fish)] {
            guard let path else { continue }
            let result = try run(shellPath: path, command: wrapped)
            #expect(result.exitCode == 0, "\(name) exited \(result.exitCode) at depth \(depth): \(result.stderr)")
            #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "OK",
                    "\(name) printed \(result.stdout.debugDescription) instead of OK at depth \(depth)")
        }
    }
}

// MARK: - 8. Legacy '\''-escaping regression (documents why NOT to "simplify" singleQuoted)

/// The `'\''`-based single-quoting idiom `singleQuoted` used before this fix
/// (close quote, escaped quote, reopen quote). Deliberately reimplemented
/// here, and ONLY here — it must never reappear in `LoginShellCommand`
/// itself. POSIX shells treat the `\'` inside as a literal backslash followed
/// by the quote that reopens the string, which happens to also close and
/// reopen the quoted section correctly. fish instead treats `\'` as an
/// *escaped quote* even inside single quotes, so this idiom only survives
/// nesting by coincidence at shallow depth, and breaks once nesting compounds
/// enough escaped sequences for fish's reading to diverge from POSIX's.
func legacySingleQuoted(_ string: String) -> String {
    "'\(string.replacingOccurrences(of: "'", with: "'\\''"))'"
}

@Suite("LoginShellCommand legacy escaping regression")
struct LoginShellCommandLegacyEscapingRegressionTests {
    @Test("Legacy '\\'' escaping at depth 3 is accepted by sh/bash/zsh but REJECTED by fish")
    func legacyEscapingDivergesAtDepthThree() throws {
        guard let fish = TestShells.fish else { return }

        var wrapped = "A=1; B=2; echo OK"
        for _ in 0..<3 {
            wrapped = "sh -c \(legacySingleQuoted(wrapped))"
        }

        for (name, path) in [("sh", TestShells.sh), ("bash", TestShells.bash), ("zsh", TestShells.zsh)] {
            guard let path else { continue }
            let result = try syntaxCheck(shellPath: path, script: wrapped)
            #expect(result.exitCode == 0, "\(name) unexpectedly rejected the legacy depth-3 payload: \(result.stderr)")
        }

        // This is the fish/POSIX divergence `singleQuoted`'s `'"'"'` idiom
        // exists to avoid: at depth 3, fish's own quoting rules disagree with
        // POSIX's about where the single-quoted sections end, and it rejects
        // the payload with "Unsupported use of '='" rather than parsing it.
        // If this test starts failing because fish now accepts the payload,
        // that is NOT license to revert `singleQuoted` to this idiom — it
        // would mean fish's behavior changed, not that the hazard is gone.
        let fishResult = try syntaxCheck(shellPath: fish, script: wrapped)
        #expect(fishResult.exitCode != 0,
                "expected fish to reject the legacy '\\''-escaped depth-3 payload, but it parsed clean")
    }
}

// MARK: - 9. doubleQuoted escaping

@Suite("LoginShellCommand doubleQuoted")
struct LoginShellCommandDoubleQuotedTests {
    /// Backtick is deliberately absent from this list. POSIX shells strip the
    /// backslash from `` \` `` inside double quotes; fish, which has no
    /// backtick substitution at all, leaves it in place. `backtickDivergesUnderFish`
    /// below pins that difference rather than pretending it away.
    @Test(
        "Round-trips special characters through sh/bash/zsh/fish byte-for-byte",
        arguments: [
            "back\\slash",
            "she said \"hi\"",
            "a $HOME that must not expand",
            "mix: ' \" $ \\ and spaces",
            "no special characters at all",
            "trailing backslash\\"
        ]
    )
    func roundTrips(payload: String) throws {
        for (name, path) in TestShells.all {
            guard let path else { continue }
            let command = "printf %s \(LoginShellCommand.doubleQuoted(payload))"
            let result = try run(shellPath: path, command: command)
            #expect(result.exitCode == 0, "\(name) exited \(result.exitCode): \(result.stderr)")
            #expect(result.stdout == payload,
                    "\(name) produced \(result.stdout.debugDescription) instead of \(payload.debugDescription)")
        }
    }

    /// The documented limit of `doubleQuoted`: a backslash-escaped backtick
    /// round-trips under every POSIX shell, but fish hands it back with the
    /// backslash still attached. Production is unaffected because every caller
    /// passes the result to `runInPOSIXShell` first, so `sh` parses the
    /// double-quoted region — which the second half of this test pins.
    @Test("Backtick diverges under fish, and the sh -c wrap fixes it")
    func backtickDivergesUnderFish() throws {
        let payload = "`echo hi` stays literal"
        let bare = "printf %s \(LoginShellCommand.doubleQuoted(payload))"

        for (name, path) in TestShells.posixOnly {
            guard let path else { continue }
            let result = try run(shellPath: path, command: bare)
            #expect(result.stdout == payload, "\(name) produced \(result.stdout.debugDescription)")
        }

        guard let fish = TestShells.fish else { return }
        let unwrapped = try run(shellPath: fish, command: bare)
        #expect(unwrapped.stdout != payload,
                "fish unexpectedly matched POSIX here — if fish gained backtick handling, update doubleQuoted's doc comment")

        let wrapped = try run(shellPath: fish, command: LoginShellCommand.runInPOSIXShell(bare))
        #expect(wrapped.stdout == payload,
                "wrapped form produced \(wrapped.stdout.debugDescription) under fish")
    }
}

// MARK: - 10. runInPOSIXShell(login: true)

@Suite("LoginShellCommand runInPOSIXShell login form")
struct LoginShellCommandRunInPOSIXShellLoginTests {
    @Test("login: true emits sh -lc, default emits sh -c")
    func emitsExpectedFlag() {
        let loginForm = LoginShellCommand.runInPOSIXShell("echo hi", login: true)
        #expect(loginForm.hasPrefix("sh -lc "), "expected 'sh -lc ...', got \(loginForm.debugDescription)")

        let plainForm = LoginShellCommand.runInPOSIXShell("echo hi")
        #expect(plainForm.hasPrefix("sh -c "), "expected 'sh -c ...', got \(plainForm.debugDescription)")
    }

    // Deliberately NOT executed: `sh -lc` reads the developer's own profile,
    // so a run-and-check-stdout test here would be flaky across machines.
    // Syntax-checking is enough to confirm the shape is well-formed.
    @Test("login: true result parses clean under all four shells")
    func loginFormParsesEverywhere() throws {
        let wrapped = LoginShellCommand.runInPOSIXShell(LoginShellCommand.pathPrefix + "exec echo OK", login: true)
        for (name, path) in TestShells.all {
            guard let path else { continue }
            let result = try syntaxCheck(shellPath: path, script: wrapped)
            #expect(result.exitCode == 0, "\(name) rejected the login-form payload: \(result.stderr)")
        }
    }
}

// MARK: - 11. Real composed payloads (app-coupled builders, reconstructed here)
//
// TSSHConfig, AIAgentExecutor, UDPHolePuncher and SSHVPNTunnelProvider all
// pull in the whole app (or, for the tunnel extension, a separate target),
// so none of them can be imported by this standalone package. Each fixture
// below is built from `LoginShellCommand` alone but mirrors, byte-for-shape,
// what the named production call site actually sends over the wire. If that
// call site's composition changes, whoever changes it needs to update the
// matching fixture here — that's the point of naming it in the comment: a
// silent shape drift is a review miss, not a compiler error.

/// Mirrors `AIAgentExecutor.wrapForLoginShell(_:)`
/// (rootshell/Features/AIAgent/Core/AIAgentExecutor.swift): a PATH prelude
/// run by `sh`, which then `exec`s the user's login shell with their command
/// single-quoted, stderr folded into stdout, and a `|| true` so a non-zero
/// exit never throws a transport-level "command failed" error.
func aiAgentWrapperPayload(userCommand: String) -> String {
    let shell = "/opt/homebrew/bin/fish"
    let script = "\(LoginShellCommand.pathPrefix)exec \(shell) -l -c \(LoginShellCommand.singleQuoted(userCommand))"
    return LoginShellCommand.runInPOSIXShell(script) + " 2>&1 || true"
}

/// Mirrors the reactive punch-back script `UDPHolePuncher.buildReactivePunchCommand`
/// (rootshell/Features/Mosh/HolePunch/UDPHolePuncher.swift) sends unwrapped
/// today: a bare POSIX script (`PEER_INFO=""` assignment, `if ...; then ...
/// fi` control flow) with no `runInPOSIXShell` wrap around it.
let holePunchShapedPayload = """
PEER_INFO=""
if command -v tcpdump >/dev/null 2>&1; then
  PEER_INFO=$(timeout 5 tcpdump -i any -c 1 -nn "udp dst port 60001" 2>/dev/null | head -1)
fi
if [ -z "$PEER_INFO" ]; then
  echo "no peer discovered" >&2
fi
"""

/// Mirrors `TrzszConfig.serverCommand()` (rootshell/Features/TSSH/Config/TSSHConfig.swift)
/// and `SSHVPNTunnelProvider.spawnTsshd` (VPNTunnelExtension/SSHVPNTunnelProvider.swift):
/// the PATH prelude followed by an `exec` of `tsshd`, wrapped once through
/// `runInPOSIXShell` so a non-POSIX login shell can still parse it.
let tsshdBootstrapPayload = LoginShellCommand.runInPOSIXShell(
    "\(LoginShellCommand.pathPrefix)exec tsshd --attachable --port 61000-61999 --quic"
)

@Suite("Real composed payloads (fixture reconstructions)")
struct RealComposedPayloadTests {
    @Test("AI agent wrapper payload, with a userCommand containing single quotes, parses clean everywhere")
    func aiAgentWrapperParsesEverywhere() throws {
        let userCommand = "echo 'hello world' && git status; echo 'done'"
        let payload = aiAgentWrapperPayload(userCommand: userCommand)
        for (name, path) in TestShells.all {
            guard let path else { continue }
            let result = try syntaxCheck(shellPath: path, script: payload)
            #expect(result.exitCode == 0, "\(name) rejected the AI agent wrapper payload: \(result.stderr)")
        }
    }

    @Test("Hole-punch payload is REJECTED by fish unwrapped")
    func holePunchFailsUnderFishUnwrapped() throws {
        guard let fish = TestShells.fish else { return }
        let result = try syntaxCheck(shellPath: fish, script: holePunchShapedPayload)
        #expect(result.exitCode != 0, "expected fish to reject the unwrapped hole-punch payload, but it parsed clean")
    }

    @Test("Hole-punch payload PASSES under all four shells once wrapped")
    func holePunchPassesWrapped() throws {
        let wrapped = LoginShellCommand.runInPOSIXShell(holePunchShapedPayload)
        for (name, path) in TestShells.all {
            guard let path else { continue }
            let result = try syntaxCheck(shellPath: path, script: wrapped)
            #expect(result.exitCode == 0, "\(name) rejected the wrapped hole-punch payload: \(result.stderr)")
        }
    }

    @Test("tsshd bootstrap payload parses clean under all four shells")
    func tsshdBootstrapParsesEverywhere() throws {
        for (name, path) in TestShells.all {
            guard let path else { continue }
            let result = try syntaxCheck(shellPath: path, script: tsshdBootstrapPayload)
            #expect(result.exitCode == 0, "\(name) rejected the tsshd bootstrap payload: \(result.stderr)")
        }
    }
}

// MARK: - 12. ProjectProbeCommand-shaped payload (fixture reconstruction)
//
// `ProjectProbeCommand.swift` (rootshell/Features/SSH/Discovery/ProjectProbeCommand.swift)
// is deliberately dependency-free EXCEPT for one path: when `paneToken` is
// non-nil it references `TerminalIdentity.paneTokenVariable`
// (rootshell/Core/Terminal/TerminalIdentity.swift), an app type. That
// reference is compiled unconditionally even though it only executes when a
// pane token is supplied, so symlinking `ProjectProbeCommand.swift` into
// this package fails with "cannot find 'TerminalIdentity' in scope" — Swift
// compiles both branches of an `if let`, not just the ones a given call
// exercises. Per the task instructions this was not worked around by also
// symlinking or stubbing `TerminalIdentity`; the composition is reconstructed
// as a fixture instead.
//
// `ProjectProbeCommand.command(paths:paneToken:pathPrefix:)` applies
// `singleQuoted` at two levels: once per probed path (for the `git -C
// <path>` invocations inside the script), and once more around the whole
// script (`sh -lc <singleQuoted(script)>`). A path containing an apostrophe
// is exactly the input that broke under the old `'\''` idiom at this second
// level of nesting.

/// Mirrors `ProjectProbeCommand.command(paths:pathPrefix:)`'s two-level
/// quoting shape for a single probed path (paneToken omitted, since that
/// argument is the one that pulls in `TerminalIdentity`).
func projectProbeShapedPayload(path: String) -> String {
    let quotedPath = LoginShellCommand.singleQuoted(path)
    let innerScript = "printf '%s\\n' \(quotedPath); "
        + "if command -v git >/dev/null 2>&1; then "
        + "printf '%s\\t%s\\t%s\\n' \(quotedPath) "
        + "\"$(git -C \(quotedPath) rev-parse --show-toplevel 2>/dev/null)\" "
        + "\"$(git -C \(quotedPath) symbolic-ref --short -q HEAD 2>/dev/null)\"; "
        + "fi"
    return "sh -lc \(LoginShellCommand.singleQuoted(innerScript))"
}

@Suite("ProjectProbeCommand-shaped payload (fixture reconstruction)")
struct ProjectProbeShapedPayloadTests {
    @Test("A probed path containing an apostrophe parses clean under all four shells")
    func apostrophePathParsesEverywhere() throws {
        let payload = projectProbeShapedPayload(path: "/Users/dave/Dave's Repo")
        for (name, path) in TestShells.all {
            guard let path else { continue }
            let result = try syntaxCheck(shellPath: path, script: payload)
            #expect(result.exitCode == 0, "\(name) rejected the apostrophe-path payload: \(result.stderr)")
        }
    }
}
