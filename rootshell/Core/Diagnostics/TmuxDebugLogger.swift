//
//  TmuxDebugLogger.swift
//  rootshell
//
//  File-based debug logger for tmux control mode (`tmux -CC`) diagnostics.
//  Off by default. Captures the reconcile decode/apply timeline, commands sent
//  to tmux, the resume probe watchdog, detach/abort, gateway report-filtering
//  byte COUNTS, and a low-rate live-state heartbeat (including a privacy-safe
//  snapshot of the GhosttyKit viewer's internals) to
//  Documents/.ghostty/tmux_debug.log. Companion to SSHDebugLogger /
//  ResumeDebugLogger / LifecycleDebugLogger: same persistence pattern (serial
//  queue, synchronizeFile() per write so entries survive force-quit, size
//  rotation to tmux_debug.1.log).
//
//  Toggle: UserDefaults["tmuxDebugLoggingEnabled"], checked on every write so it
//  takes effect at runtime without a rebootstrap. Every public method
//  early-returns when the toggle is off, so the logger is a no-op when disabled.
//
//  ─── PRIVACY (this log is designed to be shared by users with us) ──────────
//  NEVER LOG VERBATIM: terminal output (%output), capture-pane content,
//  window/tab/pane titles, send-keys payloads (user keystrokes), pasted text,
//  cwd/pwd, hostnames, usernames, or ANY byte-stream content. These can carry
//  passwords, file paths, and PII.
//
//  SAFE TO LOG: numeric tmux window/pane ids, terminal-UUID prefixes (first 8),
//  op-type names, cols/rows, byte COUNTS, durations/deltas, state-enum names,
//  error codes/descriptions (no payloads), boolean flags, collection counts,
//  and — for any private string — only its LENGTH plus a non-cryptographic
//  correlation HASH (see `redact` / `hashed`).
//
//  When in doubt, log a count or a hash — never the content.
//

import Foundation
import os

final class TmuxDebugLogger: Sendable {
    nonisolated static let shared = TmuxDebugLogger()

    /// UserDefaults key to enable/disable logging.
    nonisolated static let enabledKey = "tmuxDebugLoggingEnabled"

    /// Posted when the toggle flips so live `TmuxController` heartbeats can
    /// start/stop without polling UserDefaults.
    nonisolated static let enabledDidChange = Notification.Name("tmuxDebugLoggingEnabledDidChange")

    /// Max log file size before rotation (10 MB). Control mode is bursty during
    /// reconcile, but we log only counts/aggregates, so 10 MB holds many repro
    /// sessions before rotating to `tmux_debug.1.log`.
    nonisolated private static let maxFileSize: UInt64 = 10 * 1024 * 1024

    private let ioQueue = DispatchQueue(label: "com.rootshell.tmuxDebugLogger")
    private let logFileURL: URL
    private let rotatedLogFileURL: URL
    private let dateFormatter: DateFormatter

    /// Wall-clock of the last logged line, for the per-line `+Δms` delta that
    /// makes a hung log's tail show how long the previous phase ran before the
    /// stall. Lock-protected: writes come from main, the ghostty tick thread,
    /// and the off-main response queue.
    private let lastEventTime = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)

    /// Gateway response-pipe byte accumulators, bumped per chunk from the
    /// off-main response queue. Snapshot+reset by the live-state heartbeat.
    /// COUNTS ONLY — the bytes themselves are never stored or logged. Keyed by
    /// owner-surface identity so multiple simultaneous tmux gateways don't
    /// consume each other's counts.
    private nonisolated struct GatewayBytes {
        var raw = 0
        var filtered = 0
        var chunks = 0
        var lastAt: TimeInterval = 0
    }
    private let gatewayBytes = OSAllocatedUnfairLock<[Int: GatewayBytes]>(initialState: [:])

    /// Gateway INBOUND byte accumulators (session output ingested into the
    /// gateway surface, i.e. the tmux control stream as delivered by the
    /// transport). COUNTS ONLY, same keying as `gatewayBytes`. This is the
    /// other half of the picture the response-pipe counters miss: with only
    /// outbound counts, "transport delivered nothing" and "Swift swallowed it"
    /// were indistinguishable in a wedge log. ROOTSHELL-TMUX (id=tmux-gwin-counter)
    private nonisolated struct GatewayInbound {
        var bytes = 0
        var chunks = 0
        var lastAt: TimeInterval = 0
    }
    private let gatewayInbound = OSAllocatedUnfairLock<[Int: GatewayInbound]>(initialState: [:])

    private init() {
        let documentsURL = ForkUITestConfiguration.sterileHomeDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let ghosttyDir = documentsURL.appendingPathComponent(".ghostty", isDirectory: true)
        self.logFileURL = ghosttyDir.appendingPathComponent("tmux_debug.log")
        self.rotatedLogFileURL = ghosttyDir.appendingPathComponent("tmux_debug.1.log")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        self.dateFormatter = formatter

        try? FileManager.default.createDirectory(at: ghosttyDir, withIntermediateDirectories: true)
    }

    /// Whether logging is enabled (checked on each write).
    nonisolated var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    // MARK: - Public API

    /// Free-form line. Prefer the structured helpers below.
    nonisolated func log(_ message: String, source: String = #function, file: String = #file) {
        guard isEnabled else { return }
        let fileName = (file as NSString).lastPathComponent.replacingOccurrences(of: ".swift", with: "")
        emit("[\(fileName).\(source)] \(message)")
    }

    /// Categorized line, e.g. `event("RESUME", "probe attempt=3 controller=nil")`.
    /// Categories: RECONCILE, OP, CMD, RESUME, PROBE, DETACH, PANE, FILTER,
    /// RESTORE, PRUNE, FOCUS, END, STATE, ZIG.
    nonisolated func event(_ category: String, _ message: String) {
        guard isEnabled else { return }
        emit("[\(category)] \(message)")
    }

    /// A decoded reconcile op. Logs ids / sizes / counts only — callers must
    /// pass redacted descriptors for any string (titles).
    nonisolated func op(_ kind: String, _ kv: [(String, Any)] = []) {
        guard isEnabled else { return }
        emit("[OP] \(kind)\(Self.render(kv))")
    }

    /// A command sent to tmux via the gateway command channel. Logs the command
    /// KIND, target id, and byte COUNT only. NEVER pass the command text or the
    /// send-keys hex payload.
    nonisolated func command(kind: String, target: String? = nil, bytes: Int, _ kv: [(String, Any)] = []) {
        guard isEnabled else { return }
        var parts: [(String, Any)] = []
        if let target { parts.append(("target", target)) }
        parts.append(("bytes", bytes))
        parts.append(contentsOf: kv)
        emit("[CMD] \(kind)\(Self.render(parts))")
    }

    /// Boundary marker (TMUX GATEWAY ESTABLISHED / RESUME START / CONTROL MODE
    /// END / APP LAUNCH / etc.).
    nonisolated func marker(_ marker: String) {
        guard isEnabled else { return }
        let now = Date()
        recordEventTime(now)
        let separator = String(repeating: "=", count: 60)
        // Format on the serial ioQueue (DateFormatter is not thread-safe; this
        // is called concurrently from main, the ghostty tick, and the background
        // response queue). `now` is captured here so the line still reflects call
        // time even if the write is queued behind others.
        ioQueue.async { [self] in
            let ts = dateFormatter.string(from: now)
            appendAndSync(Data("\n\(separator)\n[\(ts)] >>> \(marker) <<<\n\(separator)\n\n".utf8))
        }
    }

    // MARK: - Gateway byte counters (off-main hot path)

    /// Accumulate gateway response-pipe byte counts for `owner` (the gateway's
    /// surface identity). Called per chunk from the off-main response queue
    /// (Catalyst fast path and the main-actor path). Intentionally NOT guarded
    /// by `isEnabled`: it is a single locked integer add (cheaper than a
    /// UserDefaults read on this hot path), never writes to disk, and never sees
    /// byte content. Snapshot+reset by that gateway's heartbeat.
    nonisolated func noteGatewayBytes(owner: Int, raw: Int, filtered: Int) {
        gatewayBytes.withLock {
            var e = $0[owner] ?? .init()
            e.raw += raw
            e.filtered += filtered
            e.chunks += 1
            e.lastAt = Date().timeIntervalSinceReferenceDate
            $0[owner] = e
        }
    }

    /// Snapshot and reset one gateway's byte counters for a heartbeat line.
    nonisolated func snapshotGatewayBytes(owner: Int) -> (raw: Int, filtered: Int, chunks: Int, msSinceLast: Double?) {
        gatewayBytes.withLock {
            guard var e = $0[owner] else { return (raw: 0, filtered: 0, chunks: 0, msSinceLast: nil) }
            let now = Date().timeIntervalSinceReferenceDate
            let since = e.lastAt == 0 ? nil : (now - e.lastAt) * 1000
            let out = (raw: e.raw, filtered: e.filtered, chunks: e.chunks, msSinceLast: since)
            e.raw = 0; e.filtered = 0; e.chunks = 0
            $0[owner] = e
            return out
        }
    }

    /// Reset one gateway's byte counters (call when that gateway is established
    /// so its first heartbeat doesn't report a backlog or stale data from a
    /// freed-then-reused surface pointer).
    nonisolated func resetGatewayBytes(owner: Int) {
        gatewayBytes.withLock { $0[owner] = .init() }
        gatewayInbound.withLock { $0[owner] = .init() }
    }

    /// Accumulate gateway INBOUND byte counts for `owner` — session output
    /// being ingested into the gateway surface (the tmux control stream as the
    /// transport delivered it). Same hot-path rationale as `noteGatewayBytes`:
    /// a single locked add, no `isEnabled` check, never sees content.
    /// ROOTSHELL-TMUX (id=tmux-gwin-counter)
    nonisolated func noteGatewayInbound(owner: Int, bytes: Int) {
        gatewayInbound.withLock {
            var e = $0[owner] ?? .init()
            e.bytes += bytes
            e.chunks += 1
            e.lastAt = Date().timeIntervalSinceReferenceDate
            $0[owner] = e
        }
    }

    /// Snapshot and reset one gateway's inbound counters for a heartbeat line.
    nonisolated func snapshotGatewayInbound(owner: Int) -> (bytes: Int, chunks: Int, msSinceLast: Double?) {
        gatewayInbound.withLock {
            guard var e = $0[owner] else { return (bytes: 0, chunks: 0, msSinceLast: nil) }
            let now = Date().timeIntervalSinceReferenceDate
            let since = e.lastAt == 0 ? nil : (now - e.lastAt) * 1000
            let out = (bytes: e.bytes, chunks: e.chunks, msSinceLast: since)
            e.bytes = 0; e.chunks = 0
            $0[owner] = e
            return out
        }
    }

    // MARK: - Gateway delivery-path gauges

    /// Point-in-time gauges from the gateway's Swift byte-delivery path
    /// (TerminalBufferedPipeWriter depth/total, scrollback-restore gate state),
    /// captured by a registered provider closure at heartbeat time. Together
    /// with gwIn (transport ingestion) and the Zig snapshot's read-thread
    /// counters, one wedge log pinpoints WHICH hop is eating bytes.
    /// COUNTS/FLAGS ONLY — never content. ROOTSHELL-TMUX (id=tmux-gw-gauges)
    struct GatewayGauges {
        var pipeBuffered: Int
        var pipeWritten: Int
        var pipeDropped: Int
        var gateEnabled: Bool
        var gateBuffered: Int
    }

    private let gatewayGauges = OSAllocatedUnfairLock<[Int: @Sendable () -> GatewayGauges]>(initialState: [:])

    /// Register the gauge provider for `owner` (the gateway's surface
    /// identity). The closure is called from the heartbeat; it must be cheap
    /// and thread-safe. ROOTSHELL-TMUX (id=tmux-gw-gauges)
    nonisolated func registerGatewayGauges(owner: Int, _ provider: @escaping @Sendable () -> GatewayGauges) {
        gatewayGauges.withLock { $0[owner] = provider }
    }

    nonisolated func unregisterGatewayGauges(owner: Int) {
        gatewayGauges.withLock { $0[owner] = nil }
    }

    nonisolated func snapshotGatewayGauges(owner: Int) -> GatewayGauges? {
        let provider = gatewayGauges.withLock { $0[owner] }
        return provider?()
    }

    // MARK: - Redaction helpers

    /// Safe descriptor for a PRIVATE string (title, payload, etc.): its byte
    /// length plus a short correlation hash, so two values can be compared
    /// across log lines without ever recording their content.
    /// e.g. `redact(title)` -> "(len=14 h=1a2b3c4d)".
    nonisolated static func redact(_ s: String) -> String {
        "(len=\(s.utf8.count) h=\(hashed(s)))"
    }

    /// 8-hex-char stable FNV-1a hash. Correlation only — NOT a security
    /// primitive. Same input -> same hash within and across sessions.
    nonisolated static func hashed(_ s: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            hash ^= UInt64(b)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%08x", UInt32(truncatingIfNeeded: hash))
    }

    // MARK: - Private

    private nonisolated static func render(_ kv: [(String, Any)]) -> String {
        guard !kv.isEmpty else { return "" }
        return " " + kv.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    }

    /// Emit a structured line: `[timestamp] <body> +Δms`. The timestamp is
    /// formatted on the serial ioQueue so the (non-thread-safe) DateFormatter is
    /// only ever touched by one thread; `now` is captured at call time so the
    /// line reflects when the event happened, not when it is flushed.
    private nonisolated func emit(_ body: String) {
        let now = Date()
        let nowTI = now.timeIntervalSinceReferenceDate
        let delta = lastEventTime.withLock { last -> Double in
            let d = last == 0 ? 0 : (nowTI - last) * 1000
            last = nowTI
            return d
        }
        ioQueue.async { [self] in
            let ts = dateFormatter.string(from: now)
            appendAndSync(Data(String(format: "[%@] %@ +%.1fms\n", ts, body, delta).utf8))
        }
    }

    private nonisolated func recordEventTime(_ now: Date) {
        lastEventTime.withLock { $0 = now.timeIntervalSinceReferenceDate }
    }

    private nonisolated func appendAndSync(_ data: Data) {
        rotateIfNeeded()
        if FileManager.default.fileExists(atPath: logFileURL.path) {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.synchronizeFile()
                handle.closeFile()
            }
        } else {
            try? data.write(to: logFileURL, options: .atomic)
        }
    }

    private nonisolated func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let size = attrs[.size] as? UInt64,
              size > Self.maxFileSize else { return }
        try? FileManager.default.removeItem(at: rotatedLogFileURL)
        try? FileManager.default.moveItem(at: logFileURL, to: rotatedLogFileURL)
    }
}
