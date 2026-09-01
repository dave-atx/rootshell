//
//  ZmxDiscoveryParser.swift
//  rootshell
//
//  Data model and parser for zmx session detection on SSH hosts. zmx is a
//  session attach/detach multiplexer: one session is exactly one PTY, with no
//  windows, tabs, splits or control protocol. `zmx list` is its only
//  enumeration primitive, and `zmx history <name> --vt` provides the preview.
//

import Foundation
import os

// MARK: - Data Model

struct ZmxSessionInfo: Identifiable, Equatable, Sendable {
    let name: String

    /// Attached interactive clients, excluding the probing connection.
    let clientCount: Int?

    let createdAt: Date?

    /// Decoded `cwd=` from current zmx, or bare `start_dir=` from v0.7.0.
    let cwd: String?

    /// Explicit command supplied to `zmx attach`, when present.
    let command: String?

    /// Labels from `zmx set` or `zmx attach --labels`.
    let labels: [String: String]

    var capturedContent: String?

    var id: String { name }

    var isAttached: Bool { (clientCount ?? 0) > 0 }

    /// Relative creation time, e.g. "Created 2 hr. ago", echoing the shape
    /// zellij rows already use in the picker. Empty when zmx gave no timestamp.
    ///
    /// zellij's equivalent is scraped verbatim out of zellij's own output
    /// (`[Created 2h ago]`), so there is no existing formatter to share; zmx
    /// reports a unix timestamp and this formats it.
    var createdAgo: String {
        guard let createdAt else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let relative = formatter.localizedString(for: createdAt, relativeTo: Date())
        return String(
            format: String(localized: "Created %@", comment: "zmx session age, e.g. 'Created 2 hr. ago'"),
            relative
        )
    }
}

// MARK: - Debug parser fixtures

#if DEBUG
import SwiftUI

/// Inline parser fixtures for checking current and legacy `zmx list` output in
/// the real picker. They are deliberately synthetic so this fork branch stays
/// safe to publish.
private enum ZmxParserFixtures {
    static let current = """
    ::SESSIONS::
      name=api\tpid=4821\tclients=0\tcreated=1700000000\tcwd=file://build-host/var/work/api\tproject=api
      name=worker-1\tpid=4990\tclients=2\tcreated=1700003600\tcwd=file://build-host/var/work/web%20app\trole=assistant
      name=task\tpid=5002\tclients=0\tcreated=1700005400\tcwd=file://build-host/tmp\tended=1700005500\texit_code=1
      name=cmdtest\tpid=5003\tclients=0\tcreated=1700005800\tcwd=file://build-host/var/work\tcmd=sh -c 'echo a=b; sleep infinity'
      name=shadow\tpid=5004\tclients=0\tcreated=1700005940\tcwd=file://build-host/var/work\tclients=99\terr=nope
      name=stale\terr=ConnectionRefused\tstatus=cleaning up
      name=frozen\terr=Timeout\tstatus=unreachable
    ::CAPTURES::
    ::CAPTURE:api::
    builder@build-host:/var/work/api$ ./run --watch
    listening on :8080
    ::CAPTURE:worker-1::
    \u{1B}[1m\u{1B}[38;5;4m● Working\u{1B}[0m on the parser
    """

    static let legacy = """
    ::SESSIONS::
      name=api\tpid=4821\tclients=0\tcreated=1700000000\tstart_dir=/var/work/api\tproject=api
      name=worker-1\tpid=4990\tclients=1\tcreated=1700003600\tstart_dir=/var/work/web app\trole=assistant
    """
}

private struct ZmxParserFixturePreview: View {
    let title: String
    let fixture: String
    @State private var attachMode: TmuxAutoMode = .regular
    @State private var selected = 0

    var body: some View {
        let sessions = ZmxDiscoveryParser.parse(output: fixture)
            .map { MultiplexerSession.from(zmx: $0) }
        VStack(spacing: 0) {
            Text(verbatim: "\(title) — \(sessions.count) sessions")
                .font(.caption.monospaced())
                .padding(6)
            SessionPickerOverlay(
                sessions: sessions,
                sessionTypes: [.zmx],
                selectedIndex: min(selected, max(sessions.count - 1, 0)),
                hasUserTyped: false,
                tmuxAttachMode: $attachMode,
                allowsTmuxControlAttach: false,
                onSelect: { _ in },
                onChangeSelection: { selected = $0 },
                onDismiss: {}
            )
        }
    }
}

/// Six live rows. This checks error-row rejection, URI decoding, label
/// boundaries, duplicate built-in keys, and commands containing `=`.
#Preview("zmx current parser fixture") {
    ZmxParserFixturePreview(title: "Current zmx output", fixture: ZmxParserFixtures.current)
}

/// Legacy `start_dir=` values are bare paths and must not be URI-decoded.
#Preview("zmx legacy parser fixture") {
    ZmxParserFixturePreview(title: "Legacy zmx output", fixture: ZmxParserFixtures.legacy)
}
#endif

// MARK: - Parser

enum ZmxDiscoveryParser {

    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "ZmxDiscoveryParser"
    )

    /// Built-in field order; later duplicate keys are user labels.
    private nonisolated static let builtInOrder = [
        "pid", "clients", "created", "cwd", "cmd", "ended", "exit_code",
    ]

    /// v0.7.0's name for the `cwd` slot. Same position, different shape.
    private nonisolated static let legacyCwdKey = "start_dir"

    nonisolated static func parse(output: String) -> [ZmxSessionInfo] {
        guard let sessionsMarker = lineMarkerRange("::SESSIONS::", in: output) else { return [] }
        let remainder = output[sessionsMarker.upperBound...]
        let capturesMarker = lineMarkerRange(
            "::CAPTURES::",
            in: output,
            range: remainder.startIndex..<remainder.endIndex
        )
        let sessionsBlock = String(remainder[..<(capturesMarker?.lowerBound ?? remainder.endIndex)])
        let capturesBlock = capturesMarker.map { String(output[$0.upperBound...]) } ?? ""

        let capturesBySession = parseCaptures(block: capturesBlock)

        var sessions: [ZmxSessionInfo] = []
        // Keep SwiftUI identities unique if malformed output repeats a name.
        var indexByName: [String: Int] = [:]

        for rawLine in sessionsBlock.split(whereSeparator: \.isNewline) {
            guard let session = parseLine(String(rawLine)) else { continue }
            let enriched = ZmxSessionInfo(
                name: session.name,
                clientCount: session.clientCount,
                createdAt: session.createdAt,
                cwd: session.cwd,
                command: session.command,
                labels: session.labels,
                capturedContent: capturesBySession[session.name]
            )
            if let existing = indexByName[session.name] {
                sessions[existing] = enriched
            } else {
                indexByName[session.name] = sessions.count
                sessions.append(enriched)
            }
        }

        let count = sessions.count
        logger.info("Parsed \(count) zmx sessions")
        return sessions
    }

    /// Parses one `zmx list` row. Returns nil for anything that is not a live
    /// session: blank lines, stray shell output, and genuine error rows.
    private nonisolated static func parseLine(_ rawLine: String) -> ZmxSessionInfo? {
        // Current-session rows use an arrow prefix; other rows use spaces.
        var line = rawLine
        if line.hasPrefix("→ ") {
            line = String(line.dropFirst(2))
        }
        // Also drop a trailing CR, so CRLF-terminated output parses.
        if line.hasSuffix("\r") {
            line = String(line.dropLast())
        }
        line = line.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }

        // Commands may contain `=`, so split each field only once.
        let fields = line.components(separatedBy: "\t").map(splitField)

        guard let first = fields.first, first.key == "name", !first.value.isEmpty else {
            return nil
        }

        // Live rows always begin with name then pid. Requiring that shape also
        // rejects names containing tabs/newlines, which this format cannot
        // represent without ambiguity.
        guard fields.count > 1, fields[1].key == "pid" else { return nil }

        var values: [String: String] = [:]
        var labels: [String: String] = [:]
        var cursor = 0
        var inLabels = false
        // Which spelling filled the cwd slot; the two shapes decode differently.
        var cwdIsURI = false

        for field in fields.dropFirst() {
            if !inLabels {
                // `start_dir` (v0.7.0) occupies the same slot as `cwd` (HEAD).
                let normalized = field.key == legacyCwdKey ? "cwd" : field.key
                if let offset = builtInOrder[cursor...].firstIndex(of: normalized) {
                    values[normalized] = field.value
                    if normalized == "cwd" {
                        cwdIsURI = field.key == "cwd"
                    }
                    cursor = offset + 1
                    continue
                }
                // First out-of-sequence key: everything from here on is a label.
                inLabels = true
            }
            if !field.key.isEmpty {
                labels[field.key] = field.value
            }
        }

        let cwd = decodeWorkingDirectory(values["cwd"], isURI: cwdIsURI)

        return ZmxSessionInfo(
            name: first.value,
            clientCount: values["clients"].flatMap(Int.init),
            createdAt: values["created"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)),
            cwd: cwd,
            command: values["cmd"].flatMap { $0.isEmpty ? nil : $0 },
            labels: labels,
            capturedContent: nil
        )
    }

    /// Splits `key=value` on the first `=` only. A field with no `=` becomes a
    /// key with an empty value, which the callers treat as uninteresting.
    private nonisolated static func splitField(_ field: String) -> (key: String, value: String) {
        guard let separator = field.firstIndex(of: "=") else {
            return (field, "")
        }
        return (
            String(field[field.startIndex..<separator]),
            String(field[field.index(after: separator)...])
        )
    }

    /// HEAD's `cwd=` is an OSC 7 URI; v0.7.0's `start_dir=` is a bare path.
    private nonisolated static func decodeWorkingDirectory(
        _ value: String?,
        isURI: Bool
    ) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return isURI ? WorkingDirectoryURI.path(value) : value
    }

    /// Finds a marker only when it occupies a complete line, so command output
    /// containing the same text cannot split the protocol payload.
    private nonisolated static func lineMarkerRange(
        _ marker: String,
        in text: String,
        range: Range<String.Index>? = nil
    ) -> Range<String.Index>? {
        let searchRange = range ?? text.startIndex..<text.endIndex
        var start = searchRange.lowerBound
        while start < searchRange.upperBound,
              let found = text.range(of: marker, range: start..<searchRange.upperBound) {
            let startsLine = found.lowerBound == text.startIndex
                || text[text.index(before: found.lowerBound)].isNewline
            let endsLine = found.upperBound == text.endIndex
                || text[found.upperBound].isNewline
            if startsLine && endsLine { return found }
            start = found.upperBound
        }
        return nil
    }

    /// Parses `::CAPTURE:<session>::` chunks of raw ANSI content.
    private nonisolated static func parseCaptures(block: String) -> [String: String] {
        guard !block.isEmpty else { return [:] }
        var capturesBySession: [String: String] = [:]
        for chunk in block.components(separatedBy: "::CAPTURE:") {
            guard let markerEnd = chunk.range(of: "::\n") ?? chunk.range(of: "::\r\n") else { continue }
            let sessionName = String(chunk[chunk.startIndex..<markerEnd.lowerBound])
            guard !sessionName.isEmpty else { continue }
            let content = trimToVisibleScreen(String(chunk[markerEnd.upperBound...]))
            let trimmed = content.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            if !trimmed.isEmpty {
                capturesBySession[sessionName] = trimmed
            }
        }
        return capturesBySession
    }

    /// Keeps content after the final screen clear, when present.
    private nonisolated static func trimToVisibleScreen(_ content: String) -> String {
        guard let lastClear = content.range(of: "\u{1B}[2J", options: .backwards) else {
            return content
        }
        return String(content[lastClear.upperBound...])
    }
}
