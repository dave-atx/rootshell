//
//  VNCDebugLogger.swift
//  rootshell
//
//  File-based debug logger for Screen Sharing (VNC) diagnostics. Off by
//  default. Mirrors the rootshellVNC package's entire log stream to
//  Documents/.ghostty/vnc_debug.log. Companion to SSHDebugLogger /
//  LifecycleDebugLogger / ResumeDebugLogger.
//
//  Why a file: the package logs through os.log with `.private` privacy, so
//  none of it can be read back off a device. A session that drops mid-use and
//  reconnects is indistinguishable in the UI from any other cause, and the
//  lines that name the cause ("TCP state reported connection loss",
//  "Video bootstrap failed ... reconnecting", "Unsupported framebuffer
//  encoding", "Connection terminated: origin=...") only exist in os.log.
//
//  Toggle: UserDefaults["vncDebugLoggingEnabled"]. Checked on every write, so
//  it takes effect at runtime without a relaunch.
//
//  ─── SECURITY ────────────────────────────────────────────────────────────
//  NEVER LOG: VNC passwords, Keychain material, clipboard contents, remote
//  screen pixels.
//
//  SAFE TO LOG: hostnames, ports, usernames, negotiated protocol/security
//  facts, encoding names, error descriptions, traffic counters and timings.
//
//  The package sink below is a verbatim mirror of the package's own log
//  records, which follow the same contract.
//

import Foundation
import os
import rootshellVNC

/// File-based VNC debug logger. Persists across force-quit cycles via
/// `synchronizeFile()` after each write. Off by default; enable via the
/// hidden Debug Settings view.
final class VNCDebugLogger: Sendable {
    nonisolated static let shared = VNCDebugLogger()

    /// UserDefaults key to enable/disable logging
    nonisolated static let enabledKey = "vncDebugLoggingEnabled"

    /// Max log file size before rotation (10 MB). A High Performance session
    /// logs sparsely at info level, so this holds many hours plus the
    /// heartbeat trail leading into a drop.
    nonisolated private static let maxFileSize: UInt64 = 10 * 1024 * 1024

    /// Serial queue for thread-safe file I/O
    private let ioQueue = DispatchQueue(label: "com.rootshell.vncDebugLogger")

    /// Log file URL: Documents/.ghostty/vnc_debug.log
    private let logFileURL: URL

    /// Rotated log file URL
    private let rotatedLogFileURL: URL

    /// Date formatter for timestamps
    private let dateFormatter: DateFormatter

    /// Latch so the package sink is installed exactly once per process.
    private let bridgeInstalled = OSAllocatedUnfairLock<Bool>(initialState: false)

    private init() {
        let documentsURL = ForkUITestConfiguration.sterileHomeDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let ghosttyDir = documentsURL.appendingPathComponent(".ghostty", isDirectory: true)
        self.logFileURL = ghosttyDir.appendingPathComponent("vnc_debug.log")
        self.rotatedLogFileURL = ghosttyDir.appendingPathComponent("vnc_debug.1.log")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        self.dateFormatter = formatter

        try? FileManager.default.createDirectory(at: ghosttyDir, withIntermediateDirectories: true)
    }

    /// Whether logging is enabled (checked on each write)
    nonisolated var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    // MARK: - Public API

    /// Free-form log line. Prefer `event(_:_:)` for structured entries.
    nonisolated func log(_ message: String, source: String = #function, file: String = #file) {
        guard isEnabled else { return }
        let fileName = (file as NSString).lastPathComponent.replacingOccurrences(of: ".swift", with: "")
        write("[\(timestamp())] [\(fileName).\(source)] \(message)\n")
    }

    /// Categorized event line. App-side categories: PANE, HEARTBEAT. Package
    /// records arrive under their own categories (Session, TransportSession,
    /// TCPConnection, VideoStream, ...).
    nonisolated func event(_ category: String, _ message: String) {
        guard isEnabled else { return }
        write("[\(timestamp())] [\(category)] \(message)\n")
    }

    /// App lifecycle transition, mirrored into this log so a drop can be
    /// attributed without cross-referencing the lifecycle log.
    ///
    /// This is load-bearing for diagnosis, not colour. iOS suspends a process
    /// with no background assertion and reclaims its socket and hardware
    /// decoder when it does, so a Screen Sharing session that crosses a
    /// background window comes back with `ECONNABORTED` on the control channel
    /// and `kVTVideoDecoderMalfunctionErr` from VideoToolbox. Both read
    /// exactly like a network fault unless the transition is on the record
    /// next to them.
    nonisolated func lifecycle(_ event: String, _ details: [(String, Any)] = []) {
        guard isEnabled else { return }
        let rendered = details
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: " ")
        let suffix = rendered.isEmpty ? "" : " \(rendered)"
        write("[\(timestamp())] [LIFECYCLE] \(event)\(suffix)\n")
    }

    /// Session-boundary marker (APP LAUNCH / VNC CONNECT / etc.)
    nonisolated func logMarker(_ marker: String) {
        guard isEnabled else { return }
        let separator = String(repeating: "=", count: 60)
        write("\n\(separator)\n[\(timestamp())] >>> \(marker) <<<\n\(separator)\n\n")
    }

    // MARK: - Package Bridge

    /// Mirror the rootshellVNC package's log stream into this file. Install
    /// once per process from AppDelegate; the sink consults `isEnabled` on
    /// every record, so the toggle stays live without a re-install.
    nonisolated func installPackageBridgeIfNeeded() {
        let alreadyInstalled = bridgeInstalled.withLock { installed -> Bool in
            if installed { return true }
            installed = true
            return false
        }
        guard !alreadyInstalled else { return }

        // `info` deliberately: the media paths log per-frame detail at debug,
        // which would bury the connection lifecycle this file exists to show.
        VNCDebugLogging.install(minimumLevel: "info") { [weak self] level, category, message in
            guard let self, self.isEnabled else { return }
            self.event("\(category)/\(level)", message)
        }
    }

    // MARK: - Private I/O

    private nonisolated func timestamp() -> String {
        dateFormatter.string(from: Date())
    }

    private nonisolated func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        ioQueue.async { [self] in
            self.appendAndSync(data)
        }
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
              size > Self.maxFileSize else {
            return
        }
        try? FileManager.default.removeItem(at: rotatedLogFileURL)
        try? FileManager.default.moveItem(at: logFileURL, to: rotatedLogFileURL)
    }
}
