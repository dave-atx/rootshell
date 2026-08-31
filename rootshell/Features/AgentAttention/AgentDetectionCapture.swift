//
//  AgentDetectionCapture.swift
//  rootshell
//
//  Opt-in snapshot recorder for authoring agent-detection signatures.
//
//  Signatures are line-anchored regexes over bottom-anchored regions, so
//  they depend on EXACT row boundaries — and a screen copy-pasted out of
//  a terminal does not preserve those: wrapped rows join, runs of spaces
//  collapse, right-aligned status segments slide. Signatures authored
//  from a paste are guesses about where the line breaks were.
//
//  This writes what the detector actually reads: the post-`readBottomRows`
//  rows, verbatim, with the alt-screen flag, grid size, OSC title and the
//  identification/classification outcome beside them. Launch an agent with
//  capture on, then read the file back and author from real frames.
//
//  Off by default; nothing is created until the toggle is set. The file
//  rotates rather than stopping at its cap, because the frames worth
//  authoring from are always the most recent ones. Both files are excluded
//  from backups: the rows are verbatim terminal content, so they belong to
//  the debugging session that recorded them and nowhere else.
//

import Foundation
import os.log

@MainActor
final class AgentDetectionCapture {
    static let shared = AgentDetectionCapture()

    /// UserDefaults key. Also settable from the debug section of the
    /// Coding Agents settings.
    nonisolated static let enabledKey = "agentDetectionCaptureEnabled"

    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    private nonisolated static let logger = Logger(
        subsystem: "com.kk2.rootshell", category: "AgentAttention")

    /// One JSON object per line, appended. Lives in `.ghostty/` beside the
    /// app's other internal state rather than loose in the rootshell
    /// folder.
    nonisolated static var fileURL: URL? {
        let docs = ForkUITestConfiguration.documentsDirectoryURL
        return docs
            .appendingPathComponent(".ghostty", isDirectory: true)
            .appendingPathComponent("agent-detection-captures.jsonl")
    }

    /// The previous window, kept when the live file rotates.
    nonisolated static var rotatedFileURL: URL? {
        fileURL?.deletingLastPathComponent()
            .appendingPathComponent("agent-detection-captures.1.jsonl")
    }

    /// Cap per file so a forgotten toggle cannot fill the container. Two
    /// files, so the ceiling on disk is the same 4 MB it always was.
    private static let byteLimit = 2 * 1024 * 1024

    /// Last recorded screen per pane: identical frames are skipped, so a
    /// static idle screen writes one record, not one per scan.
    private var lastRecorded: [UUID: Int] = [:]
    private var handle: FileHandle?
    private var written = 0

    private init() {}

    func record(
        paneUUID: UUID,
        lines: [String],
        cols: Int,
        gridRows: Int,
        altScreenActive: Bool,
        oscTitle: String,
        oscProgress: String,
        agentID: String?,
        state: String?,
        matchedRuleID: String?
    ) {
        guard Self.isEnabled else { return }

        var hasher = Hasher()
        hasher.combine(lines.map(Self.fingerprint))
        hasher.combine(altScreenActive)
        hasher.combine(oscTitle)
        hasher.combine(agentID)
        hasher.combine(matchedRuleID)
        let digest = hasher.finalize()
        guard lastRecorded[paneUUID] != digest else { return }
        lastRecorded[paneUUID] = digest

        let record: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "pane": String(paneUUID.uuidString.prefix(8)),
            "cols": cols,
            "gridRows": gridRows,
            "altScreen": altScreenActive,
            "oscTitle": oscTitle,
            "oscProgress": oscProgress,
            "agent": agentID ?? NSNull(),
            "state": state ?? NSNull(),
            "rule": matchedRuleID ?? NSNull(),
            // Verbatim rows, in order, exactly as the rules see them.
            "lines": lines,
        ]
        append(record)
    }

    /// Spinner glyphs that animate in place: claude's sparkle cycle, its
    /// in-progress bullet, copilot's pulse, and the braille wheel several
    /// agents use — which this comment has always claimed and the set never
    /// contained. A copilot capture spent five of its sixteen records on one
    /// static working screen before the pulse was listed here.
    ///
    /// The circle pair is also copilot's transcript status bullet, so a row
    /// whose bullet alone flips pending->done no longer writes a record. That
    /// is the right trade: a completing tool row rewrites its tail in the same
    /// repaint, so real completions still record.
    private static let spinnerGlyphs: Set<Character> = [
        "·", "✢", "✳", "✶", "✻", "✽", "∗", "✱", "⏺",
        "◉", "◎", "●", "○",
        "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏",
    ]

    /// Segments that tick on their own while the screen says the same
    /// thing: an elapsed/token parenthetical, a statusline clock, a
    /// context percentage.
    private static let volatilePatterns: [Regex<AnyRegexOutput>] = [
        try! Regex(#"\((?:\d+h )?(?:\d+m )?\d+(?:\.\d+)?s[^)]*\)"#),
        try! Regex(#"\d{1,2}:\d{2}(?::\d{2})?"#),
        try! Regex(#"\d+%"#),
    ]

    /// What makes two frames the SAME screen for authoring purposes. A
    /// spinner turning and a counter ticking redraw the whole snapshot
    /// every second; hashing them verbatim spent 43% of the capture
    /// budget on animation frames that teach a signature author nothing.
    private static func fingerprint(_ line: String) -> String {
        var value = line
        for pattern in volatilePatterns {
            value = value.replacing(pattern, with: "⧗")
        }
        guard let start = value.firstIndex(where: { $0 != " " && $0 != "\t" }) else {
            return value
        }
        let next = value.index(after: start)
        if spinnerGlyphs.contains(value[start]),
           next == value.endIndex || value[next] == " " {
            value.replaceSubrange(start...start, with: "⧗")
        }
        return value
    }

    private func append(_ record: [String: Any]) {
        guard let url = Self.fileURL,
              let data = try? JSONSerialization.data(
                  withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return }

        openIfNeeded(url)
        guard handle != nil else { return }

        var line = data
        line.append(0x0A)
        // Rotate BEFORE the write that would overflow, so every file is a
        // whole number of records. Rotating rather than stopping is the
        // point: the frames worth authoring from are the ones that just
        // happened, and a recorder that stops keeps the OLDEST 4 MB and
        // silently drops every session after it. A forgotten toggle then
        // costs nothing but the previous window.
        if written + line.count > Self.byteLimit {
            rotate(url)
            openIfNeeded(url)
            guard handle != nil else { return }
        }
        written += line.count
        try? handle?.write(contentsOf: line)
    }

    private func openIfNeeded(_ url: URL) {
        guard handle == nil else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: url.path, contents: nil)
            Self.excludeFromBackup(url)
        }
        handle = try? FileHandle(forWritingTo: url)
        if let handle { _ = try? handle.seekToEnd() }
        let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
        written = (size as? Int) ?? 0
    }

    private func rotate(_ url: URL) {
        try? handle?.close()
        handle = nil
        written = 0
        guard let previous = Self.rotatedFileURL else { return }
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
        // Re-applied rather than assumed: the flag is a resource value on the
        // item, and the rotated window holds the same verbatim rows.
        Self.excludeFromBackup(previous)
        Self.logger.info("capture file rotated; recording continues in a fresh file")
    }

    /// Keeps verbatim terminal rows out of iCloud and Finder backups. The
    /// recorder is a debugging tool, so its output should not outlive the
    /// device it was recorded on.
    private nonisolated static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Called when the toggle flips so a new session starts clean.
    func reset() {
        try? handle?.close()
        handle = nil
        written = 0
        lastRecorded.removeAll()
        for url in [Self.fileURL, Self.rotatedFileURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
