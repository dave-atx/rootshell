//
//  ZmxExposeAdapterPreview.swift
//  rootshell
//
//  DEBUG-only preview harness for ZmxExposeAdapter.parseTick and focusScript.
//

import Foundation

// MARK: - Preview Harness

#if DEBUG
import SwiftUI

/// Builds complete, realistic `tickScript` OUTPUT for `ZmxExposeAdapter.parseTick`
/// and renders a pass/fail summary for each fixture in the Xcode canvas.
///
/// There is no unit-test target for app code, so this is the parser's coverage:
/// it needs no target changes, survives refactors, and gives every fixture below
/// a visual assertion. Fixtures are assembled with the real `MuxScript` framing
/// helpers (`begin`/`end`/`topology`/`panePrefix`) rather than hand-typed marker
/// strings, so they cannot drift out of sync with what `tickScript` actually
/// produces. `zmx list` row text and the `\t` separators below are copied from
/// the fixtures in `ZmxDiscoveryParser.swift`, and every `\t` is a real tab once
/// Swift parses the escape.
private enum ZmxTickFixtures {

    static let nonce = "PVW1"

    private static func ts(_ offset: TimeInterval) -> String {
        String(Int(Date().addingTimeInterval(offset).timeIntervalSince1970))
    }

    /// One `zmx list` row. Always carries the two-space prefix: this adapter
    /// never exports `ZMX_SESSION` on the listing call (see the doc comment on
    /// `ZmxExposeAdapter.prefix`), so the caller's own row is never arrow-marked.
    private static func sessionRow(
        name: String,
        pid: Int,
        clients: Int,
        createdOffset: TimeInterval,
        cwd: String? = nil,
        startDir: String? = nil,
        cmd: String? = nil
    ) -> String {
        var fields = ["name=\(name)", "pid=\(pid)", "clients=\(clients)", "created=\(ts(createdOffset))"]
        if let cwd { fields.append("cwd=\(cwd)") }
        if let startDir { fields.append("start_dir=\(startDir)") }
        if let cmd { fields.append("cmd=\(cmd)") }
        return "  " + fields.joined(separator: "\t")
    }

    /// The raw marker line `MuxScript.paneMarker` would `echo`, built from the
    /// same `panePrefix` helper so the framing cannot drift.
    private static func paneMarkerLine(id: String, extra: String = "") -> String {
        "\(MuxScript.panePrefix(nonce))\(id):\(extra)::"
    }

    /// Assembles one complete tick response: begin marker, optional prelude
    /// unsupported marker, topology marker, `::SESSIONS::` block, then one
    /// pane-marker + capture section per entry in `paneSections`, then the end
    /// marker (unless `includeEnd` is false, to simulate truncation).
    private static func response(
        unsupportedInPrelude: Bool = false,
        sessionLines: [String],
        paneSections: [(id: String, body: [String])] = [],
        includeEnd: Bool = true
    ) -> String {
        var lines: [String] = [MuxScript.begin(nonce)]
        if unsupportedInPrelude {
            lines.append(MuxScript.unsupportedMarker)
        }
        lines.append(MuxScript.topology(nonce))
        lines.append("::SESSIONS::")
        lines.append(contentsOf: sessionLines)
        for section in paneSections {
            lines.append(paneMarkerLine(id: section.id))
            lines.append(contentsOf: section.body)
        }
        if includeEnd {
            lines.append(MuxScript.end(nonce))
        }
        return lines.joined(separator: "\n")
    }

    /// Case 1: three sessions, two captured. `alpha` is zmx-HEAD shaped
    /// (`cwd=` as an OSC 7 URI), `gamma` is v0.7.0 shaped (`start_dir=`).
    static let threeSessions = response(
        sessionLines: [
            sessionRow(name: "alpha", pid: 100, clients: 1, createdOffset: -600, cwd: "file://fixture-host/home/tester/alpha"),
            sessionRow(name: "beta", pid: 200, clients: 0, createdOffset: -500, cwd: "file://fixture-host/home/tester/beta"),
            sessionRow(name: "gamma", pid: 300, clients: 2, createdOffset: -400, startDir: "/home/tester/gamma"),
        ],
        paneSections: [
            (id: "alpha", body: ["alpha screen line 1", "alpha screen line 2"]),
            (id: "gamma", body: ["gamma screen line 1"]),
        ]
    )

    /// Case 2: a capture with two erase-display sequences. Only what follows
    /// the LAST one should survive — that is the scrollback-vs-screen trim.
    static let eraseDisplay = response(
        sessionLines: [
            sessionRow(name: "solo", pid: 400, clients: 0, createdOffset: -100, cwd: "file://fixture-host/home/tester/solo"),
        ],
        paneSections: [
            (id: "solo", body: [
                "old scrollback line 1",
                "old scrollback line 2 \u{1B}[2Jstill scrollback after first clear",
                "\u{1B}[2Jfinal screen line one",
                "final screen line two",
            ]),
        ]
    )

    /// Case 3: `MuxScript.unsupportedMarker` in the PRELUDE, before the
    /// topology marker — `parseTick` must return nil.
    static let unsupportedInPrelude = response(
        unsupportedInPrelude: true,
        sessionLines: [
            sessionRow(name: "irrelevant", pid: 1, clients: 0, createdOffset: -10, cwd: "file://fixture-host/home"),
        ]
    )

    /// Case 4: the unsupported marker appears inside CAPTURED PANE CONTENT
    /// instead of the prelude — a pane showing a log (or this source file)
    /// must not kill the feed, so `parseTick` must NOT return nil.
    static let unsupportedInPaneContent = response(
        sessionLines: [
            sessionRow(name: "logviewer", pid: 2, clients: 0, createdOffset: -20, cwd: "file://fixture-host/home/tester/logs"),
        ],
        paneSections: [
            (id: "logviewer", body: [
                "$ cat build.log",
                "grep for marker: \(MuxScript.unsupportedMarker)",
                "build finished",
            ]),
        ]
    )

    /// Case 5: truncated — the `end` marker is missing entirely. The last
    /// (incomplete) pane section must be dropped by `MuxScript.sections`
    /// while the earlier one survives.
    static let truncated = response(
        sessionLines: [
            sessionRow(name: "first", pid: 10, clients: 0, createdOffset: -50, cwd: "file://fixture-host/home/tester/first"),
            sessionRow(name: "second", pid: 20, clients: 0, createdOffset: -40, cwd: "file://fixture-host/home/tester/second"),
        ],
        paneSections: [
            (id: "first", body: ["first pane complete content"]),
            (id: "second", body: ["second pane got cut off mid"]),
        ],
        includeEnd: false
    )

    /// Case 6: an error row (`err=`/`status=`) mixed in with live rows. It
    /// must not become a tab.
    static let errorRowMixed = response(
        sessionLines: [
            sessionRow(name: "live", pid: 30, clients: 0, createdOffset: -5, cwd: "file://fixture-host/home/tester/live"),
            "  name=stale\terr=ConnectionRefused\tstatus=cleaning up",
        ]
    )

    /// Case 7: a session whose capture is empty. It must produce a tab but no
    /// frame entry.
    static let emptyCapture = response(
        sessionLines: [
            sessionRow(name: "emptycap", pid: 40, clients: 0, createdOffset: -15, cwd: "file://fixture-host/home/tester/emptycap"),
        ],
        paneSections: [
            (id: "emptycap", body: []),
        ]
    )
}

// MARK: - Check plumbing

/// One named assertion plus, on failure, the actual value observed.
private struct ZmxCheck {
    let name: String
    let passed: Bool
    let detail: String

    init(_ name: String, _ passed: Bool, detail: @autoclosure () -> String = "") {
        self.name = name
        self.passed = passed
        self.detail = passed ? "" : detail()
    }
}

/// Renders a list of checks with ✅/❌ and a pass/fail summary line, so a
/// human scanning the Xcode canvas can see at a glance whether every case
/// passed against the real `ZmxExposeAdapter` — no XCTest or swift-testing
/// involved, since there is no unit-test target for app code.
private struct ZmxCheckListView: View {
    let title: String
    let checks: [ZmxCheck]

    private var failCount: Int { checks.filter { !$0.passed }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // `verbatim:` keeps this debug-only preview label out of the
                // string catalog; it is developer chrome, not shipped UI.
                Text(verbatim: title)
                    .font(.headline.monospaced())

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(checks.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "\(item.passed ? "✅" : "❌") \(item.name)")
                                .font(.callout.monospaced())
                                .foregroundStyle(item.passed ? Color.primary : Color.red)
                            if !item.passed {
                                Text(verbatim: item.detail)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 24)
                            }
                        }
                    }
                }

                Text(verbatim: failCount == 0
                     ? "All \(checks.count) checks passed"
                     : "\(failCount) of \(checks.count) checks FAILED")
                    .font(.callout.bold().monospaced())
                    .foregroundStyle(failCount == 0 ? Color.green : Color.red)
                    .padding(.top, 4)
            }
            .padding(12)
        }
    }
}

// MARK: - Checks

private enum ZmxTickChecks {
    private static let adapter = ZmxExposeAdapter()

    static func threeSessions() -> [ZmxCheck] {
        guard let result = adapter.parseTick(
            output: ZmxTickFixtures.threeSessions, session: "gamma", nonce: ZmxTickFixtures.nonce
        ) else {
            return [ZmxCheck("parseTick returns non-nil", false, detail: "got nil")]
        }
        let tabs = result.snapshot.tabs
        return [
            ZmxCheck("parseTick returns non-nil", true),
            ZmxCheck("3 tabs", tabs.count == 3, detail: "got \(tabs.count)"),
            ZmxCheck(
                "tabs come back in list order [alpha, beta, gamma]",
                tabs.map(\.id) == ["alpha", "beta", "gamma"],
                detail: "got \(tabs.map(\.id))"
            ),
            ZmxCheck(
                "every tab's id/title is the session name",
                tabs.allSatisfy { $0.id == $0.title },
                detail: "got \(tabs.map { "\($0.id)/\($0.title)" })"
            ),
            ZmxCheck(
                "activeTabID follows session: (gamma)",
                result.snapshot.activeTabID == "gamma",
                detail: "got \(result.snapshot.activeTabID ?? "nil")"
            ),
            ZmxCheck(
                "gamma tab isActive == true",
                tabs.first(where: { $0.id == "gamma" })?.isActive == true,
                detail: "got \(String(describing: tabs.first(where: { $0.id == "gamma" })?.isActive))"
            ),
            ZmxCheck(
                "alpha/beta tabs isActive == false",
                tabs.filter { $0.id != "gamma" }.allSatisfy { !$0.isActive },
                detail: "got \(tabs.filter { $0.id != "gamma" }.map { "\($0.id):\($0.isActive)" })"
            ),
            ZmxCheck("frames[alpha] present (captured)", result.frames["alpha"] != nil),
            ZmxCheck("frames[gamma] present (captured)", result.frames["gamma"] != nil),
            ZmxCheck(
                "frames[beta] absent (not in fetch list)",
                result.frames["beta"] == nil,
                detail: "got \(String(describing: result.frames["beta"]))"
            ),
            ZmxCheck(
                "frames keyed by session name == MuxPane.id",
                tabs.allSatisfy { $0.panes.first?.id == $0.id }
            ),
        ]
    }

    static func eraseDisplay() -> [ZmxCheck] {
        guard let result = adapter.parseTick(
            output: ZmxTickFixtures.eraseDisplay, session: nil, nonce: ZmxTickFixtures.nonce
        ) else {
            return [ZmxCheck("parseTick returns non-nil", false, detail: "got nil")]
        }
        // parseTick appends a trailing SGR reset after `visibleScreen`'s trim.
        let expected = "final screen line one\nfinal screen line two\u{1B}[0m"
        let actual = result.frames["solo"]?.ansi
        return [
            ZmxCheck("parseTick returns non-nil", true),
            ZmxCheck(
                "visibleScreen keeps only what follows the LAST erase-display",
                actual == expected,
                detail: "got: \(String(reflecting: actual ?? "<missing>"))\nwant: \(String(reflecting: expected))"
            ),
        ]
    }

    static func unsupportedInPrelude() -> [ZmxCheck] {
        let result = adapter.parseTick(
            output: ZmxTickFixtures.unsupportedInPrelude, session: nil, nonce: ZmxTickFixtures.nonce
        )
        return [
            ZmxCheck(
                "parseTick returns nil (unsupported marker before topology)",
                result == nil,
                detail: "got \(String(describing: result))"
            ),
        ]
    }

    static func unsupportedInPaneContent() -> [ZmxCheck] {
        let result = adapter.parseTick(
            output: ZmxTickFixtures.unsupportedInPaneContent, session: nil, nonce: ZmxTickFixtures.nonce
        )
        guard let result else {
            return [ZmxCheck(
                "parseTick does NOT return nil (marker is only in pane content)",
                false,
                detail: "got nil — a pane showing a log or this source would kill the feed"
            )]
        }
        return [
            ZmxCheck("parseTick does NOT return nil (marker is only in pane content)", true),
            ZmxCheck(
                "logviewer session still produced a tab",
                result.snapshot.tabs.contains { $0.id == "logviewer" },
                detail: "got \(result.snapshot.tabs.map(\.id))"
            ),
            ZmxCheck(
                "logviewer frame carries the marker text as plain content",
                result.frames["logviewer"]?.ansi.contains(MuxScript.unsupportedMarker) == true,
                detail: "got \(String(describing: result.frames["logviewer"]?.ansi))"
            ),
        ]
    }

    static func truncated() -> [ZmxCheck] {
        guard let result = adapter.parseTick(
            output: ZmxTickFixtures.truncated, session: nil, nonce: ZmxTickFixtures.nonce
        ) else {
            return [ZmxCheck("parseTick returns non-nil", false, detail: "got nil")]
        }
        return [
            ZmxCheck("parseTick returns non-nil", true),
            ZmxCheck("truncated == true", result.truncated == true, detail: "got \(result.truncated)"),
            ZmxCheck(
                "frames[first] present (earlier, complete section survives)",
                result.frames["first"] != nil,
                detail: "got \(String(describing: result.frames["first"]))"
            ),
            ZmxCheck(
                "frames[second] absent (last, incomplete section dropped)",
                result.frames["second"] == nil,
                detail: "got \(String(describing: result.frames["second"]))"
            ),
            ZmxCheck(
                "both tabs still listed (only the CAPTURE was truncated)",
                result.snapshot.tabs.map(\.id) == ["first", "second"],
                detail: "got \(result.snapshot.tabs.map(\.id))"
            ),
        ]
    }

    static func errorRowMixed() -> [ZmxCheck] {
        guard let result = adapter.parseTick(
            output: ZmxTickFixtures.errorRowMixed, session: nil, nonce: ZmxTickFixtures.nonce
        ) else {
            return [ZmxCheck("parseTick returns non-nil", false, detail: "got nil")]
        }
        return [
            ZmxCheck("parseTick returns non-nil", true),
            ZmxCheck(
                "1 tab (error row dropped)",
                result.snapshot.tabs.count == 1,
                detail: "got \(result.snapshot.tabs.count): \(result.snapshot.tabs.map(\.id))"
            ),
            ZmxCheck(
                "the surviving tab is 'live'",
                result.snapshot.tabs.first?.id == "live",
                detail: "got \(String(describing: result.snapshot.tabs.first?.id))"
            ),
            ZmxCheck(
                "no 'stale' tab (the err= row)",
                !result.snapshot.tabs.contains { $0.id == "stale" }
            ),
        ]
    }

    static func emptyCapture() -> [ZmxCheck] {
        guard let result = adapter.parseTick(
            output: ZmxTickFixtures.emptyCapture, session: nil, nonce: ZmxTickFixtures.nonce
        ) else {
            return [ZmxCheck("parseTick returns non-nil", false, detail: "got nil")]
        }
        return [
            ZmxCheck("parseTick returns non-nil", true),
            ZmxCheck(
                "emptycap still produced a tab",
                result.snapshot.tabs.contains { $0.id == "emptycap" },
                detail: "got \(result.snapshot.tabs.map(\.id))"
            ),
            ZmxCheck(
                "emptycap produced NO frame entry",
                result.frames["emptycap"] == nil,
                detail: "got \(String(describing: result.frames["emptycap"]))"
            ),
        ]
    }

    static func focusScript() -> [ZmxCheck] {
        let switching = adapter.focusScript(session: "alpha", tabID: "beta")
        let noSession = adapter.focusScript(session: nil, tabID: "beta")
        let emptySession = adapter.focusScript(session: "", tabID: "beta")
        let sameSession = adapter.focusScript(session: "beta", tabID: "beta")
        return [
            ZmxCheck(
                "session set, different tabID: contains ZMX_SESSION=",
                switching.contains("ZMX_SESSION="),
                detail: "got: \(switching)"
            ),
            ZmxCheck(
                "session set, different tabID: contains ZMX_SESSION_PREFIX=",
                switching.contains("ZMX_SESSION_PREFIX="),
                detail: "got: \(switching)"
            ),
            ZmxCheck(
                "session set, different tabID: contains 'zmx attach'",
                switching.contains("zmx attach"),
                detail: "got: \(switching)"
            ),
            ZmxCheck(
                "session == nil: inert 'true' form, no 'zmx attach'",
                noSession.contains("true") && !noSession.contains("zmx attach"),
                detail: "got: \(noSession)"
            ),
            ZmxCheck(
                "session == \"\": inert 'true' form, no 'zmx attach'",
                emptySession.contains("true") && !emptySession.contains("zmx attach"),
                detail: "got: \(emptySession)"
            ),
            ZmxCheck(
                "session == tabID: inert 'true' form, no 'zmx attach'",
                sameSession.contains("true") && !sameSession.contains("zmx attach"),
                detail: "got: \(sameSession)"
            ),
        ]
    }
}

// MARK: - Previews

/// Expect 11/11: tabs in list order, `gamma` (the `session:` argument) active
/// and the only one flagged, `alpha`/`gamma` framed and `beta` not.
#Preview("zmx tick — three sessions, two captured") {
    ZmxCheckListView(title: "Three sessions, two captured", checks: ZmxTickChecks.threeSessions())
}

/// Expect 2/2: the frame keeps only what follows the SECOND `\e[2J`, not the
/// first.
#Preview("zmx tick — erase-display trim") {
    ZmxCheckListView(title: "Erase-display trim (scrollback vs. screen)", checks: ZmxTickChecks.eraseDisplay())
}

/// Expect 1/1: an unsupported marker ahead of the topology marker kills the
/// whole tick.
#Preview("zmx tick — unsupported in prelude") {
    ZmxCheckListView(title: "Unsupported marker in prelude → nil", checks: ZmxTickChecks.unsupportedInPrelude())
}

/// Expect 3/3: the same marker text INSIDE a capture is just bytes; a pane
/// showing a log (or this source file) must not kill the feed.
#Preview("zmx tick — unsupported in pane content") {
    ZmxCheckListView(
        title: "Unsupported marker text inside pane content → NOT nil",
        checks: ZmxTickChecks.unsupportedInPaneContent()
    )
}

/// Expect 5/5: no end marker at all; `truncated` is set and the last
/// (incomplete) pane section is dropped while the earlier one survives.
#Preview("zmx tick — truncated response") {
    ZmxCheckListView(title: "Truncated (end marker missing)", checks: ZmxTickChecks.truncated())
}

/// Expect 3/3: `err=`/`status=` row never becomes a tab.
#Preview("zmx tick — error row mixed with live rows") {
    ZmxCheckListView(title: "Error row mixed with live rows", checks: ZmxTickChecks.errorRowMixed())
}

/// Expect 2/2: a session with nothing in its capture still gets a tab, just
/// no frame.
#Preview("zmx tick — empty capture") {
    ZmxCheckListView(title: "Session with empty capture", checks: ZmxTickChecks.emptyCapture())
}

/// Expect 6/6: `focusScript` only emits the real switch when there is a
/// current session, a target tabID, and they differ.
#Preview("zmx focusScript") {
    ZmxCheckListView(title: "focusScript branches", checks: ZmxTickChecks.focusScript())
}
#endif
