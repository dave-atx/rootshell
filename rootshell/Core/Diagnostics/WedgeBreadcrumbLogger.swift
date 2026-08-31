//
//  WedgeBreadcrumbLogger.swift
//  rootshell
//
//  Minimal foreground-wedge breadcrumbs that do not depend on
//  LifecycleDebugLogger's async queue.
//

import Foundation
import os

final class WedgeBreadcrumbLogger: Sendable {
    nonisolated static let shared = WedgeBreadcrumbLogger()

    nonisolated private static let maxFileSize: UInt64 = 10 * 1024 * 1024

    private struct Breadcrumb: Sendable {
        let timestamp: Date
        let context: String
        let name: String
        let fields: [String]
    }

    private struct FileState: Sendable {
        var didCreateDirectory = false
        var sizeKnown = false
        var approximateSize: UInt64 = 0
    }

    private let queue = DispatchQueue(label: "com.rootshell.wedgeBreadcrumbLogger")
    private let writeLock = OSAllocatedUnfairLock<Void>(initialState: ())
    private let fileState = OSAllocatedUnfairLock<FileState>(initialState: FileState())
    private let logDirectoryURL: URL
    private let logFileURL: URL
    private let rotatedLogFileURL: URL

    private init() {
        // Avoid FileManager in init: the singleton is first touched from early
        // lifecycle callbacks, so all filesystem queries must stay on the
        // writer queue.
        let documentsURL = ForkUITestConfiguration.sterileHomeDirectory
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Documents", isDirectory: true)
        let ghosttyDir = documentsURL.appendingPathComponent(".ghostty", isDirectory: true)
        self.logDirectoryURL = ghosttyDir
        self.logFileURL = ghosttyDir.appendingPathComponent("wedge_breadcrumb.log")
        self.rotatedLogFileURL = ghosttyDir.appendingPathComponent("wedge_breadcrumb.1.log")
    }

    nonisolated var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: LifecycleDebugLogger.enabledKey)
    }

    /// Queue-backed breadcrumb for high-volume diagnostics.
    nonisolated func mark(_ name: String, _ kv: [(String, Any)] = []) {
        guard isEnabled else { return }
        let breadcrumb = makeBreadcrumb(name, kv)
        queue.async { [self] in
            self.appendAndSync(breadcrumb)
        }
    }

    /// Best-effort foreground breadcrumb for the first instruction of lifecycle
    /// callbacks.
    ///
    /// Do not do synchronous file-system work on the main thread here. This is
    /// called inside FrontBoard scene-update transactions; a prior synchronous
    /// `FileManager.attributesOfItem` rotation check was enough to put the main
    /// thread in the scene-update watchdog path.
    nonisolated func critical(_ name: String, _ kv: [(String, Any)] = []) {
        guard isEnabled else { return }
        let breadcrumb = makeBreadcrumb(name, kv)
        queue.async { [self] in
            self.appendAndSync(breadcrumb)
        }
    }

    private nonisolated func makeBreadcrumb(_ name: String, _ kv: [(String, Any)]) -> Breadcrumb {
        Breadcrumb(
            timestamp: Date(),
            context: threadContext(),
            name: name,
            fields: kv.map { "\($0.0)=\($0.1)" }
        )
    }

    private nonisolated func breadcrumbLine(_ breadcrumb: Breadcrumb) -> String {
        let timestamp = timestampString(breadcrumb.timestamp)
        var parts: [String] = [breadcrumb.name]
        parts.append(contentsOf: breadcrumb.fields)
        return "[\(timestamp)] [\(breadcrumb.context)] \(parts.joined(separator: " "))\n"
    }

    private nonisolated func timestampString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    private nonisolated func threadContext() -> String {
        if Thread.isMainThread { return "main" }
        if let label = String(validatingUTF8: __dispatch_queue_get_label(nil)), !label.isEmpty {
            if let lastDot = label.lastIndex(of: ".") {
                return String(label[label.index(after: lastDot)...])
            }
            return label
        }
        return "thread-\(pthread_mach_thread_np(pthread_self()))"
    }

    private nonisolated func appendAndSync(_ breadcrumb: Breadcrumb) {
        let text = breadcrumbLine(breadcrumb)
        writeLock.withLock {
            appendAndSyncUnlocked(text)
        }
    }

    private nonisolated func appendAndSyncUnlocked(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        ensureDirectoryExistsUnlocked()
        rotateIfNeededUnlocked()

        if FileManager.default.fileExists(atPath: logFileURL.path) {
            guard let handle = try? FileHandle(forWritingTo: logFileURL) else { return }
            handle.seekToEndOfFile()
            handle.write(data)
            handle.synchronizeFile()
            handle.closeFile()
            noteBytesWritten(UInt64(data.count))
        } else {
            do {
                try data.write(to: logFileURL, options: .atomic)
                noteBytesWritten(UInt64(data.count))
            } catch {
                return
            }
        }
    }

    private nonisolated func rotateIfNeededUnlocked() {
        let shouldRotate = fileState.withLock { state -> Bool in
            if !state.sizeKnown {
                let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path)
                state.approximateSize = attrs?[.size] as? UInt64 ?? 0
                state.sizeKnown = true
            }
            return state.approximateSize > Self.maxFileSize
        }
        guard shouldRotate else { return }

        if FileManager.default.fileExists(atPath: logFileURL.path) {
            try? FileManager.default.removeItem(at: rotatedLogFileURL)
            try? FileManager.default.moveItem(at: logFileURL, to: rotatedLogFileURL)
        }
        fileState.withLock {
            $0.sizeKnown = true
            $0.approximateSize = 0
        }
    }

    private nonisolated func ensureDirectoryExistsUnlocked() {
        let shouldCreate = fileState.withLock { state -> Bool in
            guard !state.didCreateDirectory else { return false }
            state.didCreateDirectory = true
            return true
        }
        if shouldCreate {
            try? FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)
        }
    }

    private nonisolated func noteBytesWritten(_ count: UInt64) {
        fileState.withLock {
            $0.sizeKnown = true
            $0.approximateSize &+= count
        }
    }
}

final class ForegroundWedgeWatchdog: Sendable {
    nonisolated static let shared = ForegroundWedgeWatchdog()

    private struct State: Sendable {
        var nextToken: UInt64 = 0
        var servicedToken: UInt64 = 0
        var lastMainActorService: TimeInterval = 0
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    private init() {}

    nonisolated func noteForegroundNotification(_ source: String, _ kv: [(String, Any)] = []) {
        let token = state.withLock { state -> UInt64 in
            state.nextToken &+= 1
            return state.nextToken
        }

        Task { @MainActor in
            self.noteMainActorServiced("foregroundPing.\(source)", token: token)
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) { [self] in
            let snapshot = state.withLock { state in
                (
                    servicedToken: state.servicedToken,
                    lastServiceAgeMs: state.lastMainActorService > 0
                        ? (Date().timeIntervalSinceReferenceDate - state.lastMainActorService) * 1000
                        : -1
                )
            }
            guard snapshot.servicedToken < token else { return }
            WedgeBreadcrumbLogger.shared.critical("FG.mainActor.timeout", [
                ("source", source),
                ("token", token),
                ("servicedToken", snapshot.servicedToken),
                ("lastServiceAgeMs", String(format: "%.2f", snapshot.lastServiceAgeMs)),
            ])
        }

        var fields: [(String, Any)] = [("token", token)]
        fields.append(contentsOf: kv)
        WedgeBreadcrumbLogger.shared.critical("FG.notification.\(source)", fields)
    }

    nonisolated func noteMainActorServiced(_ source: String, token: UInt64? = nil) {
        let servicedToken = state.withLock { state -> UInt64 in
            if let token {
                state.servicedToken = max(state.servicedToken, token)
            }
            state.lastMainActorService = Date().timeIntervalSinceReferenceDate
            return state.servicedToken
        }

        var fields: [(String, Any)] = [
            ("source", source),
            ("servicedToken", servicedToken),
        ]
        if let token {
            fields.append(("token", token))
        }
        WedgeBreadcrumbLogger.shared.critical("FG.mainActor.serviced", fields)
    }
}
