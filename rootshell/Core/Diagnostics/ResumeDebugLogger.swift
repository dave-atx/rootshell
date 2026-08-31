//
//  ResumeDebugLogger.swift
//  rootshell
//
//  File-based debug logger for trzsz session resume diagnostics.
//  Writes to Documents/.ghostty/resume_debug.log and survives force-quit.
//

import Foundation

/// File-based debug logger that persists across force-quit cycles.
///
/// Writes to `Documents/.ghostty/resume_debug.log` with immediate file sync
/// after each write so entries survive iOS force-quit termination.
///
/// Thread-safe via serial DispatchQueue. All public API is `nonisolated`
/// so it can be called from any actor context.
final class ResumeDebugLogger: Sendable {
    nonisolated static let shared = ResumeDebugLogger()

    /// UserDefaults key to enable/disable logging
    nonisolated static let enabledKey = "resumeDebugLoggingEnabled"

    /// Max log file size before rotation (512KB)
    private static let maxFileSize: UInt64 = 512 * 1024

    /// Serial queue for thread-safe file I/O
    private let ioQueue = DispatchQueue(label: "com.rootshell.resumeDebugLogger")

    /// Log file URL: Documents/.ghostty/resume_debug.log
    private let logFileURL: URL

    /// Rotated log file URL
    private let rotatedLogFileURL: URL

    /// Date formatter for timestamps
    private let dateFormatter: DateFormatter

    private init() {
        // Fork UI tests must not resolve the Catalyst Documents directory:
        // doing so can trigger a macOS folder-privacy prompt before the test
        // has any chance to interact with the app. Their diagnostics, when
        // enabled, are disposable alongside the test shell state.
        let documentsURL = ForkUITestConfiguration.sterileHomeDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let ghosttyDir = documentsURL.appendingPathComponent(".ghostty", isDirectory: true)
        self.logFileURL = ghosttyDir.appendingPathComponent("resume_debug.log")
        self.rotatedLogFileURL = ghosttyDir.appendingPathComponent("resume_debug.1.log")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        self.dateFormatter = formatter

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: ghosttyDir, withIntermediateDirectories: true)
    }

    /// Whether logging is enabled (checked on each write)
    nonisolated var isEnabled: Bool {
        return UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    // MARK: - Public API

    /// Log a message with source context
    nonisolated func log(_ message: String, source: String = #function, file: String = #file) {
        guard isEnabled else { return }

        let fileName = (file as NSString).lastPathComponent.replacingOccurrences(of: ".swift", with: "")
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(fileName).\(source)] \(message)\n"

        ioQueue.async { [self] in
            self.appendAndSync(line)
        }
    }

    /// Log a session boundary marker (e.g., APP LAUNCH, APP BACKGROUND)
    nonisolated func logMarker(_ marker: String) {
        guard isEnabled else { return }

        let timestamp = dateFormatter.string(from: Date())
        let separator = String(repeating: "=", count: 60)
        let line = "\n\(separator)\n[\(timestamp)] >>> \(marker) <<<\n\(separator)\n\n"

        ioQueue.async { [self] in
            self.appendAndSync(line)
        }
    }

    // MARK: - Private

    /// Append text to log file and sync to disk
    private func appendAndSync(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        // Rotate if needed
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

    /// Rotate log file if it exceeds max size
    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let size = attrs[.size] as? UInt64,
              size > Self.maxFileSize else {
            return
        }

        // Remove old rotated file, rename current to .1
        try? FileManager.default.removeItem(at: rotatedLogFileURL)
        try? FileManager.default.moveItem(at: logFileURL, to: rotatedLogFileURL)
    }
}
