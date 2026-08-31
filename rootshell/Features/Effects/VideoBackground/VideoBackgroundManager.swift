//
//  VideoBackgroundManager.swift
//  rootshell
//
//  Manages video background remote index and local cache
//

import Foundation
import os
import Combine

// MARK: - Video Background Info

/// Aspect ratio scaling mode for video backgrounds
enum VideoAspectMode: String, Codable, CaseIterable, Sendable {
    case fill     // Crop to fill (no letterboxing) - resizeAspectFill
    case fit      // Letterbox to fit - resizeAspect
    case stretch  // Distort to fill - resize

    var displayName: String {
        switch self {
        case .fill: return "Fill (Crop)"
        case .fit: return "Fit (Letterbox)"
        case .stretch: return "Stretch"
        }
    }
}

/// Vertical alignment for fit mode when letterboxing
enum VideoAspectAlignment: String, Codable, CaseIterable, Sendable {
    case top
    case center
    case bottom

    var displayName: String {
        switch self {
        case .top: return "Top"
        case .center: return "Center"
        case .bottom: return "Bottom"
        }
    }
}

/// Information about a video background for playback
struct VideoBackgroundInfo: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let description: String
    let videoURL: URL
    let aspectMode: VideoAspectMode
    let aspectAlignment: VideoAspectAlignment
    let seamlessLoop: Bool
    let crossfadeDuration: TimeInterval
    let defaultIntensity: Double
    let previewIcon: String
    let category: String

    static func == (lhs: VideoBackgroundInfo, rhs: VideoBackgroundInfo) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Video Background Manager

/// Manages video background remote index fetching and bridging to VideoBackgroundInfo
@MainActor
final class VideoBackgroundManager: ObservableObject {
    static let shared = VideoBackgroundManager()

    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "VideoBackgroundManager"
    )

    // MARK: - Configuration

    private static let indexCacheFilename = "index_cache.json"

    // MARK: - Published State

    /// Remote videos from index.json
    @Published private(set) var remoteVideos: [RemoteVideoBackground] = []

    /// Whether we're currently fetching the index
    @Published private(set) var isLoadingIndex: Bool = false

    /// Error message if index fetch failed
    @Published private(set) var indexError: String?

    /// When the index was last fetched
    @Published private(set) var lastIndexFetch: Date?

    // MARK: - Properties

    private let fileManager = FileManager.default
    private var indexCacheURL: URL {
        let documentsPath = ForkUITestConfiguration.documentsDirectoryURL
        return documentsPath
            .appendingPathComponent(".ghostty", isDirectory: true)
            .appendingPathComponent("video-backgrounds", isDirectory: true)
            .appendingPathComponent(Self.indexCacheFilename)
    }

    // MARK: - Computed Properties

    /// All downloaded video backgrounds as VideoBackgroundInfo (for effect registration)
    var availableVideos: [VideoBackgroundInfo] {
        remoteVideos.compactMap { videoInfo(for: $0.id) }
    }

    // MARK: - Initialization

    private init() {
        // Load cached index on startup
        loadCachedIndex()

        // Setup download completion callback
        VideoBackgroundDownloadManager.shared.onDownloadCompleted = { [weak self] videoId in
            self?.handleDownloadCompleted(videoId)
        }
    }

    // MARK: - Remote Index Fetching

    /// Fetch the remote video index
    func fetchRemoteIndex() async {
        guard !isLoadingIndex else { return }

        isLoadingIndex = true
        indexError = nil

        let indexURL = VideoBackgroundDownloadManager.baseURL.appendingPathComponent("index.json")

        do {
            let (data, response) = try await URLSession.shared.data(from: indexURL)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw URLError(.badServerResponse)
            }

            let decoder = JSONDecoder()
            let index = try decoder.decode(VideoBackgroundIndex.self, from: data)

            remoteVideos = index.backgrounds
            lastIndexFetch = Date()

            // Cache the index
            persistIndex(data: data)

            Self.logger.info("Fetched remote index with \(index.backgrounds.count) videos")

            // Resume any paused downloads now that we have metadata
            let downloadManager = VideoBackgroundDownloadManager.shared
            downloadManager.resumePausedDownloads(videos: remoteVideos)

        } catch {
            Self.logger.error("Failed to fetch remote index: \(error.localizedDescription)")
            indexError = error.localizedDescription

            // Fall back to cached index if available
            if remoteVideos.isEmpty {
                loadCachedIndex()
            }
        }

        isLoadingIndex = false
    }

    // MARK: - Index Caching

    private func loadCachedIndex() {
        guard fileManager.fileExists(atPath: indexCacheURL.path) else {
            Self.logger.debug("No cached index found")
            return
        }

        do {
            let data = try Data(contentsOf: indexCacheURL)
            let decoder = JSONDecoder()
            let index = try decoder.decode(VideoBackgroundIndex.self, from: data)

            remoteVideos = index.backgrounds
            Self.logger.info("Loaded cached index with \(index.backgrounds.count) videos")

        } catch {
            Self.logger.warning("Failed to load cached index: \(error.localizedDescription)")
        }
    }

    private func persistIndex(data: Data) {
        do {
            // Ensure directory exists
            let directory = indexCacheURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            try data.write(to: indexCacheURL, options: .atomic)
            Self.logger.debug("Persisted index cache")
        } catch {
            Self.logger.warning("Failed to persist index cache: \(error.localizedDescription)")
        }
    }

    // MARK: - Video Info Bridge

    /// Get VideoBackgroundInfo for a video by ID (returns nil if not downloaded)
    func videoInfo(for id: String) -> VideoBackgroundInfo? {
        guard let remote = remoteVideos.first(where: { $0.id == id }) else {
            return nil
        }

        // Must be downloaded to get VideoBackgroundInfo
        let downloadManager = VideoBackgroundDownloadManager.shared
        guard let localURL = downloadManager.getLocalVideoURL(for: id) else {
            return nil
        }

        return VideoBackgroundInfo(
            id: remote.id,
            displayName: remote.displayName,
            description: remote.description,
            videoURL: localURL,
            aspectMode: VideoAspectMode(rawValue: remote.aspectRatio.mode) ?? .fill,
            aspectAlignment: VideoAspectAlignment(rawValue: remote.aspectRatio.alignment) ?? .center,
            seamlessLoop: remote.loop.seamless,
            crossfadeDuration: remote.loop.crossfadeDuration,
            defaultIntensity: remote.defaultIntensity,
            previewIcon: remote.previewIcon,
            category: remote.category
        )
    }

    /// Get remote video metadata by ID
    func remoteVideo(for id: String) -> RemoteVideoBackground? {
        remoteVideos.first { $0.id == id }
    }

    // MARK: - Download Completion

    private func handleDownloadCompleted(_ videoId: String) {
        Self.logger.info("Video download completed: \(videoId)")
        // EffectManager will be notified separately to register the new effect
        objectWillChange.send()
    }
}
