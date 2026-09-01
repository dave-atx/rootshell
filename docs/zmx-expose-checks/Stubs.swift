import Foundation
enum MultiplexerType: String, Sendable, Equatable, Hashable {
    case tmux, zellij, herdr, zmx
}
enum SSHConfig { static let remoteExecPathPrefix = "PATH=\"$PATH:/usr/local/bin\"; " }

/// Stand-in for `Core/Foundation/DisplayWidth.swift`, whose real
/// implementation calls into GhosttyKit's SIMD width table -- a framework
/// dependency this standalone harness deliberately does not link. Counting
/// `Character`s is exact for every fixture these checks use (plain ASCII
/// rows); it is not a general wcwidth substitute.
enum DisplayWidth {
    static func width(of string: String) -> Int { string.count }
}

/// Stand-in for `MultiplexerExposeFeed.collapseAgreeingBindings`. The real
/// declaration lives in `MultiplexerExposeFeed.swift`, which imports
/// GhosttyKit for the `Ghostty.TerminalView.RawMultiplexerBinding` type its
/// `detect()` builds candidates from -- another framework dependency this
/// harness does not link. The function is fully generic over `Equatable` and
/// touches no GhosttyKit type, so this is a verbatim copy of its body; keep
/// the two in sync. (id=zmx-fork-collapse)
func collapseAgreeingBindings<Binding: Equatable>(_ candidates: [Binding]) -> Binding? {
    guard let first = candidates.first, candidates.allSatisfy({ $0 == first }) else { return nil }
    return first
}

/// Minimal stand-in for `Ghostty.TerminalView.RawMultiplexerBinding` (see
/// `TerminalView.swift`), shaped just enough to exercise
/// `collapseAgreeingBindings` above without linking GhosttyKit.
struct FakeBinding: Equatable {
    var type: MultiplexerType
    var sessionName: String?
    var hasOwnedAltScreen: Bool
}

/// Stand-in for the command-echo and title-suppression filters on
/// `Ghostty.TerminalView` (see `TerminalView.swift`). The real
/// declarations live on a class that imports GhosttyKit for the terminal
/// surface itself -- a framework dependency this harness does not link.
/// Neither `consumesCommandEcho` nor `suppressesTitleUpdate` touches any
/// GhosttyKit type; both are verbatim copies of their bodies, plus the
/// constant and the two stored properties they read. Keep the two in sync.
/// (id=zmx-fork-command-echo)
final class FakeTitleTarget {
    static let commandEchoMatchPrefix = 16

    var pendingCommandEcho: (command: String, until: Date)?

    func consumesCommandEcho(_ title: String) -> Bool {
        guard let echo = pendingCommandEcho else { return false }
        guard Date() < echo.until else {
            pendingCommandEcho = nil
            return false
        }
        let reported = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reported.isEmpty else { return false }
        // A leading slice of the command, and never the reverse test this
        // replaces. `zmx attach "solo-a"` CONTAINS the session name, so
        // asking whether the command contains the reported title made the
        // one title worth keeping -- the session's own, which zmx replays
        // out of the session it just attached to (`getTitle`, util.zig) --
        // look exactly like the echo and get eaten, leaving behind the
        // garbage that had already been let through a moment earlier.
        let needle = String(echo.command.prefix(Self.commandEchoMatchPrefix))
        guard needle.count >= Self.commandEchoMatchPrefix else {
            // Too short to identify by a slice without risking a real
            // title; only an exact report can be trusted to be the echo.
            guard reported == echo.command else { return false }
            pendingCommandEcho = nil
            return true
        }
        guard reported.contains(needle) else { return false }
        pendingCommandEcho = nil
        return true
    }

    var titleSuppressedUntil: Date?

    func suppressesTitleUpdate() -> Bool {
        guard let until = titleSuppressedUntil else { return false }
        guard Date() < until else {
            titleSuppressedUntil = nil
            return false
        }
        return true
    }
}
