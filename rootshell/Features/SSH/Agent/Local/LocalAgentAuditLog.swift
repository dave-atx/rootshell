#if targetEnvironment(macCatalyst) && STANDALONE

import Foundation
import Observation
import os.log

nonisolated struct LocalAgentAuditEvent: Codable, Identifiable, Hashable, Sendable {
    enum Action: String, Codable, CaseIterable, Sendable {
        case list
        case sign
        case add
        case remove
        case lock
        case unlock
        case deny
        case sessionBind

        var displayName: String {
            switch self {
            case .list:
                return String(localized: "List", comment: "Local SSH agent audit action")
            case .sign:
                return String(localized: "Sign", comment: "Local SSH agent audit action")
            case .add:
                return String(localized: "Add", comment: "Local SSH agent audit action")
            case .remove:
                return String(localized: "Remove", comment: "Local SSH agent audit action")
            case .lock:
                return String(localized: "Lock", comment: "Local SSH agent audit action")
            case .unlock:
                return String(localized: "Unlock", comment: "Local SSH agent audit action")
            case .deny:
                return String(localized: "Deny", comment: "Local SSH agent audit action")
            case .sessionBind:
                return String(localized: "Session Bind", comment: "Local SSH agent audit action")
            }
        }
    }

    enum Outcome: String, Codable, CaseIterable, Sendable {
        case allowed
        case denied
        case promptedAllowed
        case promptedDenied
        case timeout
        case failed

        var displayName: String {
            switch self {
            case .allowed:
                return String(localized: "Allowed", comment: "Local SSH agent audit outcome")
            case .denied:
                return String(localized: "Denied", comment: "Local SSH agent audit outcome")
            case .promptedAllowed:
                return String(localized: "Prompted: Allowed", comment: "Local SSH agent audit outcome")
            case .promptedDenied:
                return String(localized: "Prompted: Denied", comment: "Local SSH agent audit outcome")
            case .timeout:
                return String(localized: "Timed Out", comment: "Local SSH agent audit outcome")
            case .failed:
                return String(localized: "Failed", comment: "Local SSH agent audit outcome")
            }
        }
    }

    let id: UUID
    var timestamp: Date
    var clientName: String
    var clientIdentity: String
    var action: Action
    var keyName: String?
    var destination: String?
    var destinationFingerprint: String?
    var outcome: Outcome
    var detail: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        clientName: String,
        clientIdentity: String,
        action: Action,
        keyName: String? = nil,
        destination: String? = nil,
        destinationFingerprint: String? = nil,
        outcome: Outcome,
        detail: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.clientName = clientName
        self.clientIdentity = clientIdentity
        self.action = action
        self.keyName = keyName
        self.destination = destination
        self.destinationFingerprint = destinationFingerprint
        self.outcome = outcome
        self.detail = detail
    }
}

@MainActor
@Observable
final class LocalAgentAuditLog {
    static let shared = LocalAgentAuditLog()

    private static let logger = Logger(subsystem: "com.rootshell", category: "LocalAgentAudit")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let maxEvents = 500

    private(set) var events: [LocalAgentAuditEvent] = []

    private init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        load()
    }

    func append(_ event: LocalAgentAuditEvent) {
        events.insert(event, at: 0)
        if events.count > maxEvents {
            events.removeLast(events.count - maxEvents)
        }
        save()
    }

    func clear() {
        events.removeAll()
        save()
    }

    var seenDestinationFingerprints: [String] {
        Array(Set(events.compactMap(\.destinationFingerprint))).sorted()
    }

    private var fileURL: URL? {
        ForkUITestConfiguration.documentsDirectoryURL
            .appendingPathComponent(".ghostty", isDirectory: true)
            .appendingPathComponent("local_agent_audit.json")
    }

    private func load() {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([LocalAgentAuditEvent].self, from: data) else {
            return
        }
        events = Array(decoded.prefix(maxEvents))
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(events)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            Self.logger.warning("Failed to persist local agent audit log: \(error.localizedDescription)")
        }
    }
}

#endif
