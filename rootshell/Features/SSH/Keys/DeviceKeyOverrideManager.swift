//
//  DeviceKeyOverrideManager.swift
//  rootshell
//
//  Manages per-device key overrides. Storage is local-only (never synced via CloudKit).
//  File: Documents/.ghostty/device_key_overrides.json
//

import Foundation
import os.log

@MainActor
@Observable
final class DeviceKeyOverrideManager {
    static let shared = DeviceKeyOverrideManager()

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "DeviceKeyOverride")

    private(set) var overrides: [DeviceKeyOverride] = []

    private let fileURL: URL

    private init() {
        let documentsDir = ForkUITestConfiguration.documentsDirectoryURL
        let ghosttyDir = documentsDir.appendingPathComponent(".ghostty", isDirectory: true)

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: ghosttyDir, withIntermediateDirectories: true)

        self.fileURL = ghosttyDir.appendingPathComponent("device_key_overrides.json")
        load()
    }

    // MARK: - Lookup

    /// Find an override for a specific profile
    func override(forProfile profileID: UUID) -> DeviceKeyOverride? {
        overrides.first { $0.target == .profile(profileID) }
    }

    /// Find an override for a connection identity string
    func override(forConnectionIdentity identity: String) -> DeviceKeyOverride? {
        overrides.first { $0.target == .connectionIdentity(identity) }
    }

    /// Find an override for either a profile or connection identity
    func override(forTarget target: OverrideTarget) -> DeviceKeyOverride? {
        overrides.first { $0.target == target }
    }

    // MARK: - CRUD

    /// Save or update an override
    func save(_ override: DeviceKeyOverride) {
        if let index = overrides.firstIndex(where: { $0.target == override.target }) {
            overrides[index] = override
        } else {
            overrides.append(override)
        }
        persist()
    }

    /// Remove an override by target
    func remove(forTarget target: OverrideTarget) {
        overrides.removeAll { $0.target == target }
        persist()
    }

    /// Remove an override by ID
    func remove(id: UUID) {
        overrides.removeAll { $0.id == id }
        persist()
    }

    /// Check if an override is stale (source profile was modified after override was created)
    func isStale(_ override: DeviceKeyOverride, currentSourceModifiedAt: Date?) -> Bool {
        guard let sourceDate = override.sourceModifiedAt,
              let currentDate = currentSourceModifiedAt else {
            return false
        }
        return currentDate > sourceDate
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            overrides = try JSONDecoder().decode([DeviceKeyOverride].self, from: data)
            Self.logger.info("Loaded \(self.overrides.count) device key overrides")
        } catch {
            Self.logger.error("Failed to load device key overrides: \(error.localizedDescription)")
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(overrides)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("Failed to save device key overrides: \(error.localizedDescription)")
        }
    }
}
