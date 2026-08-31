//
//  LocalVideoBackgroundManager.swift
//  rootshell
//
//  Manages user-imported local video backgrounds: import, list, delete, rename.
//

import Foundation
import UIKit
import AVFoundation
import os
import Combine

/// Errors thrown by local video import.
enum LocalVideoImportError: LocalizedError {
    case accessDenied
    case copyFailed(String)
    case noVideoTrack
    case probeFailed(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Couldn't access the selected file."
        case .copyFailed(let detail):
            return "Couldn't copy the video into the app: \(detail)"
        case .noVideoTrack:
            return "That file doesn't contain a playable video track."
        case .probeFailed(let detail):
            return "Couldn't read the video: \(detail)"
        }
    }
}

/// Manages the on-device library of user-imported video backgrounds.
@MainActor
final class LocalVideoBackgroundManager: ObservableObject {
    static let shared = LocalVideoBackgroundManager()

    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "LocalVideoBackgroundManager"
    )

    // MARK: - Published State

    @Published private(set) var localVideos: [LocalVideoBackground] = []
    @Published private(set) var thumbnailCache: [String: UIImage] = [:]

    // MARK: - Callbacks

    /// Called after a successful import. EffectManager listens to register and activate.
    var onVideoImported: ((LocalVideoBackground) -> Void)?

    /// Called when a video is deleted. Provides the deleted video ID.
    var onVideoDeleted: ((String) -> Void)?

    /// Called when a video's looping mode or crossfade duration changes.
    var onLoopingModeChanged: ((String) -> Void)?

    /// Called when a video is renamed. Provides the renamed video ID.
    var onVideoRenamed: ((String) -> Void)?

    // MARK: - Storage

    private let fileManager = FileManager.default
    private var store = LocalVideoBackgroundStore()

    private var rootDirectory: URL {
        let documents = ForkUITestConfiguration.documentsDirectoryURL
        return documents
            .appendingPathComponent(".ghostty", isDirectory: true)
            .appendingPathComponent("video-backgrounds", isDirectory: true)
    }

    private var videosDirectory: URL {
        rootDirectory.appendingPathComponent("local-videos", isDirectory: true)
    }

    private var thumbnailsDirectory: URL {
        rootDirectory.appendingPathComponent("local-thumbnails", isDirectory: true)
    }

    private var indexURL: URL {
        rootDirectory.appendingPathComponent("local_index.json")
    }

    // MARK: - Init

    private init() {
        ensureDirectoriesExist()
        loadIndex()
    }

    private func ensureDirectoriesExist() {
        do {
            try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: videosDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
        } catch {
            let message = error.localizedDescription
            Self.logger.error("Failed to create local video directories: \(message)")
        }
    }

    // MARK: - Index Persistence

    private func loadIndex() {
        guard fileManager.fileExists(atPath: indexURL.path) else { return }
        do {
            let data = try Data(contentsOf: indexURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            store = try decoder.decode(LocalVideoBackgroundStore.self, from: data)

            // Drop entries whose video file is missing on disk.
            var removed: [String] = []
            for (id, entry) in store.entries {
                let path = videosDirectory.appendingPathComponent(entry.filename).path
                if !fileManager.fileExists(atPath: path) {
                    removed.append(id)
                }
            }
            for id in removed { store.entries.removeValue(forKey: id) }
            if !removed.isEmpty { saveIndex() }

            refreshPublishedList()

            let count = store.entries.count
            Self.logger.info("Loaded local video index with \(count) entries")
        } catch {
            let message = error.localizedDescription
            Self.logger.error("Failed to load local video index: \(message)")
        }
    }

    private func saveIndex() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(store)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            let message = error.localizedDescription
            Self.logger.error("Failed to save local video index: \(message)")
        }
    }

    private func refreshPublishedList() {
        localVideos = store.entries.values.sorted { $0.importedAt > $1.importedAt }
    }

    // MARK: - Bridge to VideoBackgroundInfo

    /// All imported local videos as VideoBackgroundInfo for effect registration.
    var availableVideos: [VideoBackgroundInfo] {
        localVideos.compactMap { videoInfo(for: $0.id) }
    }

    func videoInfo(for id: String) -> VideoBackgroundInfo? {
        guard let entry = store.entries[id] else { return nil }
        let url = videosDirectory.appendingPathComponent(entry.filename)
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        return VideoBackgroundInfo(
            id: entry.id,
            displayName: entry.displayName,
            description: entry.originalFilename,
            videoURL: url,
            aspectMode: entry.aspectMode,
            aspectAlignment: entry.aspectAlignment,
            seamlessLoop: entry.seamlessLoop,
            crossfadeDuration: entry.crossfadeDuration,
            defaultIntensity: entry.defaultIntensity,
            previewIcon: "film",
            category: "local"
        )
    }

    func localVideo(for id: String) -> LocalVideoBackground? {
        store.entries[id]
    }

    func thumbnail(for id: String) -> UIImage? {
        if let cached = thumbnailCache[id] { return cached }
        let path = thumbnailsDirectory.appendingPathComponent("\(id).jpg")
        guard fileManager.fileExists(atPath: path.path),
              let image = UIImage(contentsOfFile: path.path) else { return nil }
        thumbnailCache[id] = image
        return image
    }

    // MARK: - Import

    /// Import a movie file from a security-scoped URL (typically from .fileImporter).
    /// Copies the file into the app sandbox, probes duration, generates a thumbnail,
    /// persists metadata, and notifies `onVideoImported`.
    func importVideo(from sourceURL: URL) async throws -> LocalVideoBackground {
        let needsScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsScope { sourceURL.stopAccessingSecurityScopedResource() } }

        let id = UUID().uuidString
        let originalName = sourceURL.lastPathComponent
        let ext = sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension
        let storedFilename = "\(id).\(ext)"
        let destination = videosDirectory.appendingPathComponent(storedFilename)

        // Copy into sandbox.
        do {
            try fileManager.createDirectory(at: videosDirectory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: sourceURL, to: destination)
        } catch {
            throw LocalVideoImportError.copyFailed(error.localizedDescription)
        }

        // File size.
        let fileSize: Int64
        do {
            let attrs = try fileManager.attributesOfItem(atPath: destination.path)
            fileSize = (attrs[.size] as? Int64) ?? 0
        } catch {
            fileSize = 0
        }

        // Probe duration + verify a video track exists.
        let asset = AVURLAsset(url: destination)
        let duration: Double
        do {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard !videoTracks.isEmpty else {
                try? fileManager.removeItem(at: destination)
                throw LocalVideoImportError.noVideoTrack
            }
            let cmDuration = try await asset.load(.duration)
            duration = CMTimeGetSeconds(cmDuration)
        } catch let error as LocalVideoImportError {
            throw error
        } catch {
            try? fileManager.removeItem(at: destination)
            throw LocalVideoImportError.probeFailed(error.localizedDescription)
        }

        // Generate a thumbnail from the first frame (best-effort — failure is non-fatal).
        await generateThumbnail(for: id, asset: asset)

        let entry = LocalVideoBackground(
            id: id,
            filename: storedFilename,
            displayName: LocalVideoBackground.defaultDisplayName(from: originalName),
            originalFilename: originalName,
            importedAt: Date(),
            fileSize: fileSize,
            duration: duration,
            aspectMode: .fill,
            aspectAlignment: .center,
            seamlessLoop: true,
            crossfadeDuration: 0.5,
            defaultIntensity: 0.35
        )

        store.entries[id] = entry
        saveIndex()
        refreshPublishedList()

        Self.logger.info("Imported local video: \(originalName, privacy: .public) as \(id, privacy: .public)")

        onVideoImported?(entry)
        return entry
    }

    private func generateThumbnail(for id: String, asset: AVURLAsset) async {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)

        do {
            let (cgImage, _) = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
            let image = UIImage(cgImage: cgImage)
            if let data = image.jpegData(compressionQuality: 0.8) {
                let path = thumbnailsDirectory.appendingPathComponent("\(id).jpg")
                try? data.write(to: path, options: .atomic)
            }
            thumbnailCache[id] = image
        } catch {
            let message = error.localizedDescription
            Self.logger.warning("Thumbnail generation failed for \(id, privacy: .public): \(message)")
        }
    }

    // MARK: - Mutations

    func rename(id: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var entry = store.entries[id] else { return }
        entry.displayName = trimmed
        store.entries[id] = entry
        saveIndex()
        refreshPublishedList()
        onVideoRenamed?(id)
    }

    func setLoopingMode(id: String, seamless: Bool, crossfadeDuration: Double = 0.5) {
        guard var entry = store.entries[id] else { return }
        entry.seamlessLoop = seamless
        entry.crossfadeDuration = crossfadeDuration
        store.entries[id] = entry
        saveIndex()
        refreshPublishedList()
        onLoopingModeChanged?(id)
    }

    func delete(id: String) {
        guard let entry = store.entries[id] else { return }
        let videoPath = videosDirectory.appendingPathComponent(entry.filename)
        let thumbPath = thumbnailsDirectory.appendingPathComponent("\(id).jpg")
        try? fileManager.removeItem(at: videoPath)
        try? fileManager.removeItem(at: thumbPath)

        store.entries.removeValue(forKey: id)
        thumbnailCache.removeValue(forKey: id)
        saveIndex()
        refreshPublishedList()

        Self.logger.info("Deleted local video: \(id, privacy: .public)")
        onVideoDeleted?(id)
    }
}
