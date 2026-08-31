//
//  SyncMigrationManager.swift
//  rootshell
//
//  Handles migration of legacy storage formats to sync-ready format
//

import Foundation
import os.log

/// Manages migration of legacy storage formats to sync-ready per-record files
@MainActor
final class SyncMigrationManager {
    private static let logger = Logger(subsystem: "com.rootshell", category: "SyncMigration")

    /// Base directory for sync data
    private static var syncDirectory: URL {
        ForkUITestConfiguration.documentsDirectoryURL
            .appendingPathComponent(".ghostty", isDirectory: true)
            .appendingPathComponent("sync", isDirectory: true)
    }

    /// Backup directory for legacy data
    private static var backupDirectory: URL {
        syncDirectory.appendingPathComponent("backup", isDirectory: true)
    }

    /// Version tracking file
    private static var versionURL: URL {
        syncDirectory.appendingPathComponent("version.json")
    }

    /// Mapping file for known hosts legacy ID → UUID
    private static var knownHostsMappingURL: URL {
        syncDirectory.appendingPathComponent("known_hosts_mapping.json")
    }

    // MARK: - Public API

    /// Force re-migration of SSH history from UserDefaults
    /// Use this if legacy data exists but wasn't properly migrated
    static func forceMigrateSSHHistory() {
        logger.info("Force migrating SSH history from UserDefaults")

        do {
            try createDirectoriesIfNeeded()
            if let backup = try migrateSSHConnectionHistory() {
                logger.info("Force migration complete, backup at: \(backup)")
            } else {
                logger.info("No legacy data found to migrate")
            }
        } catch {
            logger.error("Force migration failed: \(error.localizedDescription)")
        }
    }

    /// Force re-migration of Known Hosts from legacy JSON
    static func forceMigrateKnownHosts() {
        logger.info("Force migrating known hosts from legacy JSON")

        do {
            try createDirectoriesIfNeeded()
            if let backup = try migrateKnownHosts() {
                logger.info("Force migration complete, backup at: \(backup)")
            } else {
                logger.info("No legacy data found to migrate")
            }
        } catch {
            logger.error("Force migration failed: \(error.localizedDescription)")
        }
    }

    /// Run all migrations if needed
    static func migrateIfNeeded() {
        do {
            try createDirectoriesIfNeeded()

            let currentVersion = loadVersion()?.version ?? 0

            if currentVersion < SyncStorageVersion.current {
                logger.info("Starting migration from version \(currentVersion) to \(SyncStorageVersion.current)")

                var backupPaths: [String] = []

                // Migration v0 → v1: Move from UserDefaults/JSON to per-record files
                if currentVersion < 1 {
                    if let historyBackup = try migrateSSHConnectionHistory() {
                        backupPaths.append(historyBackup)
                    }
                    if let hostsBackup = try migrateKnownHosts() {
                        backupPaths.append(hostsBackup)
                    }
                }

                // Save new version
                let newVersion = SyncStorageVersion(
                    version: SyncStorageVersion.current,
                    migratedAt: Date(),
                    backupPaths: backupPaths
                )
                try saveVersion(newVersion)

                logger.info("Migration complete to version \(SyncStorageVersion.current)")
            } else {
                logger.debug("Storage already at version \(currentVersion), no migration needed")
            }
        } catch {
            logger.error("Migration failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Version Management

    private static func loadVersion() -> SyncStorageVersion? {
        guard FileManager.default.fileExists(atPath: versionURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: versionURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(SyncStorageVersion.self, from: data)
        } catch {
            logger.warning("Failed to load version file: \(error.localizedDescription)")
            return nil
        }
    }

    private static func saveVersion(_ version: SyncStorageVersion) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(version)
        try data.write(to: versionURL, options: .atomic)
    }

    private static func createDirectoriesIfNeeded() throws {
        try FileManager.default.createDirectory(at: syncDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
    }

    // MARK: - SSH Connection History Migration

    /// Migrate SSH connection history from UserDefaults to per-record files
    /// - Returns: Backup file path if migration occurred, nil if no data to migrate
    private static func migrateSSHConnectionHistory() throws -> String? {
        let storageKey = "ssh_connection_history"

        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            logger.info("No SSH history in UserDefaults, skipping migration")
            return nil
        }

        // 1. Backup the raw data
        let backupURL = backupDirectory.appendingPathComponent("ssh_history_backup_\(formattedTimestamp()).json")
        try data.write(to: backupURL)
        logger.info("Backed up SSH history to \(backupURL.lastPathComponent)")

        // 2. Decode legacy entries
        let decoder = JSONDecoder()
        let legacyEntries: [SSHConnectionHistoryEntry]
        do {
            legacyEntries = try decoder.decode([SSHConnectionHistoryEntry].self, from: data)
        } catch {
            logger.error("Failed to decode legacy SSH history: \(error.localizedDescription)")
            return backupURL.path
        }

        logger.info("Migrating \(legacyEntries.count) SSH history entries")

        // 3. Deduplicate by connection identity (keep most recent)
        var identityToEntry: [String: SSHConnectionHistoryEntry] = [:]

        for entry in legacyEntries {
            let identity = connectionIdentity(for: entry)

            if let existing = identityToEntry[identity] {
                // Keep the one with more recent lastUsed
                if entry.lastUsed > existing.lastUsed {
                    identityToEntry[identity] = entry
                }
            } else {
                identityToEntry[identity] = entry
            }
        }

        logger.info("After deduplication: \(identityToEntry.count) unique entries")

        // 4. Write to per-record files
        let historyDir = syncDirectory.appendingPathComponent("ssh_history", isDirectory: true)
        try FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        for (_, entry) in identityToEntry {
            let fileURL = historyDir.appendingPathComponent("\(entry.id.uuidString).json")
            let entryData = try encoder.encode(entry)
            try entryData.write(to: fileURL, options: .atomic)
        }

        logger.info("Migrated \(identityToEntry.count) SSH history entries to per-record files")

        // Clean up legacy UserDefaults after successful migration
        // Backup was already created, so it's safe to remove
        UserDefaults.standard.removeObject(forKey: storageKey)
        logger.info("Cleaned up legacy SSH history from UserDefaults")

        return backupURL.path
    }

    /// Generate a connection identity string for deduplication
    private static func connectionIdentity(for entry: SSHConnectionHistoryEntry) -> String {
        var identity = "\(entry.username)@\(entry.host):\(entry.port)"

        if let jumpHost = entry.jumpHost, let jumpUsername = entry.jumpUsername {
            let jumpPort = entry.jumpPort ?? 22
            identity += " via \(jumpUsername)@\(jumpHost):\(jumpPort)"
        }

        return identity
    }

    // MARK: - Known Hosts Migration

    /// Migrate known hosts from legacy JSON file to per-record files
    /// - Returns: Backup file path if migration occurred, nil if no data to migrate
    private static func migrateKnownHosts() throws -> String? {
        let documentsURL = ForkUITestConfiguration.documentsDirectoryURL
        let legacyURL = documentsURL
            .appendingPathComponent(".ghostty", isDirectory: true)
            .appendingPathComponent("known_hosts.json")

        guard FileManager.default.fileExists(atPath: legacyURL.path) else {
            logger.info("No legacy known_hosts.json, skipping migration")
            return nil
        }

        // 1. Read legacy file
        let data = try Data(contentsOf: legacyURL)

        // 2. Backup the raw data
        let backupURL = backupDirectory.appendingPathComponent("known_hosts_backup_\(formattedTimestamp()).json")
        try data.write(to: backupURL)
        logger.info("Backed up known_hosts.json to \(backupURL.lastPathComponent)")

        // 3. Decode legacy entries
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let storage: KnownHostsStorage
        do {
            storage = try decoder.decode(KnownHostsStorage.self, from: data)
        } catch {
            logger.error("Failed to decode legacy known_hosts: \(error.localizedDescription)")
            return backupURL.path
        }

        logger.info("Migrating \(storage.hosts.count) known hosts")

        // 4. Create mapping from legacy ID to new UUID
        var legacyToUUID: [String: UUID] = [:]

        // 5. Write to per-record files
        let hostsDir = syncDirectory.appendingPathComponent("known_hosts", isDirectory: true)
        try FileManager.default.createDirectory(at: hostsDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        for host in storage.hosts {
            // Legacy entries don't have UUID - they get a new one from the decoder
            // (since we updated KnownHost to generate UUID if not present)
            legacyToUUID[host.legacyId] = host.id

            let fileURL = hostsDir.appendingPathComponent("\(host.id.uuidString).json")
            let hostData = try encoder.encode(host)
            try hostData.write(to: fileURL, options: .atomic)
        }

        // 6. Save the legacy ID → UUID mapping for reference
        let mappingData = try encoder.encode(legacyToUUID)
        try mappingData.write(to: knownHostsMappingURL, options: .atomic)

        logger.info("Migrated \(storage.hosts.count) known hosts with ID mapping saved")

        // Clean up legacy file after successful migration
        // Backup was already created, so it's safe to remove
        try FileManager.default.removeItem(at: legacyURL)
        logger.info("Cleaned up legacy known_hosts.json")

        return backupURL.path
    }

    // MARK: - Utilities

    private static func formattedTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    // MARK: - Cleanup (to be called after validation period)

    /// Remove legacy storage after validation period (call after ~30 days)
    static func cleanupLegacyStorage() {
        // Remove UserDefaults key
        UserDefaults.standard.removeObject(forKey: "ssh_connection_history")
        logger.info("Removed legacy SSH history from UserDefaults")

        // Remove legacy known_hosts.json
        let documentsURL = ForkUITestConfiguration.documentsDirectoryURL
        let legacyURL = documentsURL
            .appendingPathComponent(".ghostty", isDirectory: true)
            .appendingPathComponent("known_hosts.json")

        if FileManager.default.fileExists(atPath: legacyURL.path) {
            do {
                try FileManager.default.removeItem(at: legacyURL)
                logger.info("Removed legacy known_hosts.json")
            } catch {
                logger.warning("Failed to remove legacy known_hosts.json: \(error.localizedDescription)")
            }
        }
    }

    /// Load the legacy ID → UUID mapping for known hosts
    static func loadKnownHostsMapping() -> [String: UUID]? {
        guard FileManager.default.fileExists(atPath: knownHostsMappingURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: knownHostsMappingURL)
            return try JSONDecoder().decode([String: UUID].self, from: data)
        } catch {
            logger.warning("Failed to load known hosts mapping: \(error.localizedDescription)")
            return nil
        }
    }
}
