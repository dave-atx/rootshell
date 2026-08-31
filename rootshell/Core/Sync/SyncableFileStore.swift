//
//  SyncableFileStore.swift
//  rootshell
//
//  Generic file-based store for syncable records
//

import Foundation
import os.log

/// Generic file-based store for syncable records
///
/// Stores each record as a separate JSON file in a dedicated directory,
/// enabling efficient per-record sync operations.
///
/// Directory structure:
/// ```
/// Documents/.ghostty/sync/{storeName}/
///   {uuid1}.json
///   {uuid2}.json
///   ...
/// ```
@MainActor
struct SyncableFileStore<T: SyncableRecord> {
    private nonisolated static var logger: Logger {
        Logger(subsystem: "com.rootshell", category: "SyncableFileStore")
    }

    /// All records indexed by ID (includes soft-deleted records)
    private(set) var records: [UUID: T] = [:]

    /// Whether the last load failed to list the store directory (as opposed
    /// to the directory simply being empty). Lets callers distinguish "no
    /// data" from "data unreadable" when records is empty.
    private(set) var lastLoadFailed = false

    /// Directory where record files are stored
    let directoryURL: URL

    /// Name of this store (used for logging)
    let storeName: String

    /// Callback when a record is modified locally (for sync integration)
    var onLocalChange: ((T, SyncOperation) -> Void)?

    /// JSON encoder with consistent formatting
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// JSON decoder
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Initialize a new file store
    /// - Parameter storeName: Name of the store (used for directory name)
    init(storeName: String) {
        self.storeName = storeName

        let documentsURL = ForkUITestConfiguration.documentsDirectoryURL
        self.directoryURL = documentsURL
            .appendingPathComponent(".ghostty", isDirectory: true)
            .appendingPathComponent("sync", isDirectory: true)
            .appendingPathComponent(storeName, isDirectory: true)

        createDirectoryIfNeeded()
        loadAllRecords()
    }

    // MARK: - Public API

    /// All non-deleted records as an array
    var activeRecords: [T] {
        records.values.filter { !$0.isDeleted }
    }

    /// All records including tombstones (for sync)
    var allRecords: [T] {
        Array(records.values)
    }

    /// Get a record by ID
    func record(for id: UUID) -> T? {
        records[id]
    }

    /// Save a record (creates or updates)
    /// - Parameter record: The record to save
    /// - Parameter updateTimestamp: Whether to update modifiedAt (default: true)
    /// - Parameter notifySync: Whether to notify sync callback (false for remote changes to avoid loop)
    mutating func save(_ record: T, updateTimestamp: Bool = true, notifySync: Bool = true) throws {
        let storeName = self.storeName
        var mutableRecord = record

        if updateTimestamp {
            mutableRecord.modifiedAt = Date()
        }

        let fileURL = fileURL(for: mutableRecord.id)
        let recordIDString = mutableRecord.id.uuidString

        let data: Data
        do {
            data = try encoder.encode(mutableRecord)
        } catch {
            let desc = error.localizedDescription
            Self.logger.error("Encode failed for \(storeName)/\(recordIDString): \(desc)")
            throw error
        }

        do {
            try writeAtomically(data: data, to: fileURL)
        } catch {
            let destination = fileURL.path
            let desc = error.localizedDescription
            Self.logger.error("Write failed for \(storeName)/\(recordIDString) at \(destination): \(desc)")
            throw error
        }

        let isNew = records[mutableRecord.id] == nil
        records[mutableRecord.id] = mutableRecord

        Self.logger.debug("Saved record \(recordIDString) to \(storeName)")

        // Only notify sync for local changes, not when applying remote changes
        if notifySync {
            onLocalChange?(mutableRecord, isNew ? .create : .update)
        }
    }

    /// Soft delete a record (marks as deleted for sync tombstone)
    mutating func softDelete(id: UUID) throws {
        let storeName = self.storeName
        guard var record = records[id] else {
            Self.logger.warning("Attempted to delete non-existent record \(id.uuidString)")
            return
        }

        record.isDeleted = true
        record.modifiedAt = Date()
        try save(record, updateTimestamp: false)

        Self.logger.info("Soft deleted record \(id.uuidString) from \(storeName)")
        onLocalChange?(record, .delete)
    }

    /// Permanently remove a record (use sparingly - breaks sync)
    mutating func hardDelete(id: UUID) throws {
        let storeName = self.storeName
        let fileURL = fileURL(for: id)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }

        records.removeValue(forKey: id)
        Self.logger.info("Hard deleted record \(id.uuidString) from \(storeName)")
    }

    /// Get records modified after a given date
    func recordsModifiedAfter(_ date: Date) -> [T] {
        records.values.filter { $0.modifiedAt > date }
    }

    /// Apply changes from remote sync
    /// - Parameter remoteRecords: Records received from CloudKit
    /// - Returns: Number of records that were updated locally
    @discardableResult
    mutating func applyRemoteChanges(_ remoteRecords: [T]) throws -> Int {
        let storeName = self.storeName
        var updatedCount = 0

        for remote in remoteRecords {
            if let local = records[remote.id] {
                // Last-write-wins
                if remote.modifiedAt > local.modifiedAt {
                    try save(remote, updateTimestamp: false)
                    updatedCount += 1
                }
            } else {
                // New record from remote
                try save(remote, updateTimestamp: false)
                updatedCount += 1
            }
        }

        Self.logger.info("Applied \(updatedCount) remote changes to \(storeName)")
        return updatedCount
    }

    /// Purge soft-deleted records older than a given date
    /// - Parameter olderThan: Date threshold
    /// - Returns: Number of records purged
    @discardableResult
    mutating func purgeTombstones(olderThan date: Date) throws -> Int {
        let storeName = self.storeName
        let toPurge = records.values.filter { $0.isDeleted && $0.modifiedAt < date }
        var purgedCount = 0

        for record in toPurge {
            try hardDelete(id: record.id)
            purgedCount += 1
        }

        Self.logger.info("Purged \(purgedCount) tombstones from \(storeName)")
        return purgedCount
    }

    /// Reload all records from disk
    mutating func reload() {
        records.removeAll()
        loadAllRecords()
    }

    // MARK: - Private Helpers

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json")
    }

    private func createDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            Self.logger.error("Failed to create directory for \(self.storeName): \(error.localizedDescription)")
        }
    }

    private mutating func loadAllRecords() {
        let storeName = self.storeName
        let fileURLs: [URL]
        do {
            fileURLs = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            lastLoadFailed = false
        } catch {
            // On the non-sandboxed macOS build this directory lives in the
            // real ~/Documents, which is TCC-protected — a denied or racing
            // grant surfaces here as NSCocoaErrorDomain 257 / EPERM, not as
            // a missing directory.
            lastLoadFailed = true
            let nsError = error as NSError
            let path = directoryURL.path
            let dirExists = FileManager.default.fileExists(atPath: path)
            let domain = nsError.domain
            let code = nsError.code
            let desc = nsError.localizedDescription
            Self.logger.error("Failed to list \(storeName) at \(path) (directory exists: \(dirExists)): \(domain) \(code) — \(desc)")
            return
        }

        var loadedCount = 0
        var errorCount = 0

        for fileURL in fileURLs where fileURL.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: fileURL)
                let record = try decoder.decode(T.self, from: data)
                records[record.id] = record
                loadedCount += 1
            } catch {
                let fileName = fileURL.lastPathComponent
                let desc = error.localizedDescription
                Self.logger.error("Failed to load record \(storeName)/\(fileName): \(desc)")
                errorCount += 1
            }
        }

        Self.logger.info("Loaded \(loadedCount) records from \(storeName) (\(errorCount) errors)")
    }

    private func writeAtomically(data: Data, to url: URL) throws {
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")

        try data.write(to: tempURL, options: [.atomic])

        // Atomic rename
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tempURL, to: url)
    }
}

// MARK: - Convenience Extensions

extension SyncableFileStore {
    /// Check if a record exists
    func contains(id: UUID) -> Bool {
        records[id] != nil
    }

    /// Count of all records (including deleted)
    var totalCount: Int {
        records.count
    }

    /// Count of active (non-deleted) records
    var activeCount: Int {
        records.values.filter { !$0.isDeleted }.count
    }

    /// Count of deleted records (tombstones)
    var tombstoneCount: Int {
        records.values.filter { $0.isDeleted }.count
    }
}
