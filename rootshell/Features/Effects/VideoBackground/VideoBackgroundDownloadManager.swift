//
//  VideoBackgroundDownloadManager.swift
//  rootshell
//
//  Manages downloading and caching of video background files
//

import Foundation
import UIKit
import os
import Combine

/// Manages video background downloads and local caching
@MainActor
final class VideoBackgroundDownloadManager: ObservableObject {
    static let shared = VideoBackgroundDownloadManager()

    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "VideoBackgroundDownloadManager"
    )

    // MARK: - Configuration

    static let baseURL = URL(string: "https://beta.rootshell.com/video-backgrounds/")!
    private static let maxRetries = 3
    private static let retryDelay: TimeInterval = 2.0

    // MARK: - Published State

    /// Download state for each video by ID
    @Published private(set) var downloadStates: [String: VideoDownloadState] = [:]

    /// Cached thumbnail images by video ID
    @Published private(set) var thumbnailCache: [String: UIImage] = [:]

    // MARK: - Internal State

    private var activeDownloadTasks: [String: URLSessionDownloadTask] = [:]
    private var downloadDelegates: [String: DownloadDelegate] = [:]
    private var resumeData: [String: Data] = [:]
    private var urlSession: URLSession!
    private var lifecycleObservers: [Any] = []
    private var cacheIndex: VideoBackgroundCacheIndex = VideoBackgroundCacheIndex()

    /// Callback when a download completes successfully
    var onDownloadCompleted: ((String) -> Void)?

    // MARK: - Storage Paths

    private let fileManager = FileManager.default

    private var cacheDirectory: URL {
        let documentsPath = ForkUITestConfiguration.documentsDirectoryURL
        return documentsPath
            .appendingPathComponent(".ghostty", isDirectory: true)
            .appendingPathComponent("video-backgrounds", isDirectory: true)
    }

    private var videosDirectory: URL {
        cacheDirectory.appendingPathComponent("videos", isDirectory: true)
    }

    private var thumbnailsDirectory: URL {
        cacheDirectory.appendingPathComponent("thumbnails", isDirectory: true)
    }

    private var cacheIndexURL: URL {
        cacheDirectory.appendingPathComponent("cache_index.json")
    }

    // MARK: - Initialization

    private init() {
        setupURLSession()
        ensureDirectoriesExist()
        loadCacheIndex()
        loadPersistedDownloadStates()
        setupLifecycleObservers()
    }

    private func setupURLSession() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600 // 10 minutes for large videos
        urlSession = URLSession(configuration: config)
    }

    private func ensureDirectoriesExist() {
        do {
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: videosDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("Failed to create cache directories: \(error.localizedDescription)")
        }
    }

    private func setupLifecycleObservers() {
        let backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pauseAllDownloads()
            }
        }

        let foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                ForegroundActivationGate.shared.runWhenSafe(reason: "videoDownloads.resume") {
                    self?.resumeAllPausedDownloads()
                }
            }
        }

        lifecycleObservers = [backgroundObserver, foregroundObserver]
    }

    // MARK: - Cache Index Persistence

    private func loadCacheIndex() {
        guard fileManager.fileExists(atPath: cacheIndexURL.path) else { return }

        do {
            let data = try Data(contentsOf: cacheIndexURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            cacheIndex = try decoder.decode(VideoBackgroundCacheIndex.self, from: data)

            // Verify all cached files still exist
            var removedIds: [String] = []
            for (id, entry) in cacheIndex.entries {
                let videoPath = videosDirectory.appendingPathComponent(entry.filename)
                if !fileManager.fileExists(atPath: videoPath.path) {
                    removedIds.append(id)
                }
            }
            for id in removedIds {
                cacheIndex.entries.removeValue(forKey: id)
            }

            // Update download states for cached videos
            for id in cacheIndex.entries.keys {
                downloadStates[id] = .completed
            }

            Self.logger.info("Loaded cache index with \(self.cacheIndex.entries.count) entries")
        } catch {
            Self.logger.error("Failed to load cache index: \(error.localizedDescription)")
        }
    }

    private func saveCacheIndex() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(cacheIndex)
            try data.write(to: cacheIndexURL, options: .atomic)
        } catch {
            Self.logger.error("Failed to save cache index: \(error.localizedDescription)")
        }
    }

    private func loadPersistedDownloadStates() {
        // Load any persisted paused download states
        let pausedKey = "videoBackgroundPausedDownloads"
        if let pausedData = UserDefaults.standard.dictionary(forKey: pausedKey) as? [String: Double] {
            for (id, progress) in pausedData {
                if downloadStates[id] == nil {
                    downloadStates[id] = .paused(progress: progress)
                }
            }
        }
    }

    private func persistPausedDownloads() {
        var pausedDownloads: [String: Double] = [:]
        for (id, state) in downloadStates {
            if case .paused(let progress) = state {
                pausedDownloads[id] = progress
            }
        }
        UserDefaults.standard.set(pausedDownloads, forKey: "videoBackgroundPausedDownloads")
    }

    // MARK: - Download Operations

    /// Start downloading a video
    func startDownload(for video: RemoteVideoBackground) {
        let videoId = video.id

        // Check if already downloading
        if activeDownloadTasks[videoId] != nil {
            Self.logger.debug("Download already in progress for \(videoId)")
            return
        }

        // Check if already completed
        if case .completed = downloadStates[videoId] {
            Self.logger.debug("Video \(videoId) already downloaded")
            return
        }

        Self.logger.info("Starting download for video: \(videoId)")

        // Check for resume data
        if let resumeData = resumeData[videoId] {
            resumeDownloadWithData(videoId: videoId, video: video, data: resumeData)
        } else {
            startFreshDownload(video: video)
        }
    }

    private func startFreshDownload(video: RemoteVideoBackground) {
        let videoId = video.id
        let url = video.videoURL(baseURL: Self.baseURL)

        downloadStates[videoId] = .downloading(progress: 0)

        let delegate = DownloadDelegate(videoId: videoId, video: video, videosDirectory: videosDirectory, manager: self)
        downloadDelegates[videoId] = delegate

        let session = URLSession(
            configuration: .default,
            delegate: delegate,
            delegateQueue: nil
        )
        let task = session.downloadTask(with: url)
        activeDownloadTasks[videoId] = task
        task.resume()
    }

    private func resumeDownloadWithData(videoId: String, video: RemoteVideoBackground, data: Data) {
        let delegate = DownloadDelegate(videoId: videoId, video: video, videosDirectory: videosDirectory, manager: self)
        downloadDelegates[videoId] = delegate

        let session = URLSession(
            configuration: .default,
            delegate: delegate,
            delegateQueue: nil
        )
        let task = session.downloadTask(withResumeData: data)
        activeDownloadTasks[videoId] = task
        resumeData.removeValue(forKey: videoId)

        if case .paused(let progress) = downloadStates[videoId] {
            downloadStates[videoId] = .downloading(progress: progress)
        } else {
            downloadStates[videoId] = .downloading(progress: 0)
        }

        task.resume()
    }

    /// Pause a specific download
    func pauseDownload(for videoId: String) {
        guard let task = activeDownloadTasks[videoId] else { return }

        task.cancel { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let data {
                    self.resumeData[videoId] = data
                }

                let currentProgress: Double
                if case .downloading(let progress) = self.downloadStates[videoId] {
                    currentProgress = progress
                } else {
                    currentProgress = 0
                }

                self.downloadStates[videoId] = .paused(progress: currentProgress)
                self.activeDownloadTasks.removeValue(forKey: videoId)
                self.downloadDelegates.removeValue(forKey: videoId)
                self.persistPausedDownloads()

                Self.logger.info("Paused download for \(videoId) at \(Int(currentProgress * 100))%")
            }
        }
    }

    /// Resume a paused download
    func resumeDownload(for videoId: String, video: RemoteVideoBackground) {
        guard case .paused = downloadStates[videoId] else {
            Self.logger.warning("Cannot resume - download not paused: \(videoId)")
            return
        }

        if let data = resumeData[videoId] {
            resumeDownloadWithData(videoId: videoId, video: video, data: data)
        } else {
            // No resume data - start fresh
            startFreshDownload(video: video)
        }
    }

    /// Cancel a download
    func cancelDownload(for videoId: String) {
        activeDownloadTasks[videoId]?.cancel()
        activeDownloadTasks.removeValue(forKey: videoId)
        downloadDelegates.removeValue(forKey: videoId)
        resumeData.removeValue(forKey: videoId)
        downloadStates[videoId] = .notDownloaded
        persistPausedDownloads()
    }

    /// Pause all active downloads (called when app enters background)
    private func pauseAllDownloads() {
        Self.logger.info("Pausing all downloads (app entering background)")

        for videoId in activeDownloadTasks.keys {
            pauseDownload(for: videoId)
        }
    }

    /// Resume all paused downloads (called when app returns to foreground)
    private func resumeAllPausedDownloads() {
        Self.logger.info("Resuming paused downloads (app entering foreground)")

        // We need the video metadata to resume - this is handled by VideoBackgroundManager
        // notifying us which videos to resume
    }

    /// Resume downloads that were paused (called by VideoBackgroundManager with video metadata)
    func resumePausedDownloads(videos: [RemoteVideoBackground]) {
        for video in videos {
            if case .paused = downloadStates[video.id] {
                resumeDownload(for: video.id, video: video)
            }
        }
    }

    // MARK: - Download Completion Handling

    nonisolated func handleDownloadProgress(videoId: String, progress: Double) {
        Task { @MainActor in
            self.downloadStates[videoId] = .downloading(progress: progress)
        }
    }

    /// Called after file has been successfully saved to permanent location
    nonisolated func handleDownloadSaved(
        videoId: String,
        video: RemoteVideoBackground,
        destinationURL: URL,
        fileSize: Int64
    ) {
        Task { @MainActor in
            // Update cache index
            let entry = VideoBackgroundCacheEntry(
                id: videoId,
                filename: video.filename,
                downloadedAt: Date(),
                fileSize: fileSize,
                metadata: video
            )
            self.cacheIndex.entries[videoId] = entry
            self.saveCacheIndex()

            // Update state
            self.downloadStates[videoId] = .completed
            self.activeDownloadTasks.removeValue(forKey: videoId)
            self.downloadDelegates.removeValue(forKey: videoId)

            Self.logger.info("Download completed for \(videoId)")

            // Notify completion
            self.onDownloadCompleted?(videoId)
        }
    }

    nonisolated func handleDownloadFailed(videoId: String, error: Error) {
        Task { @MainActor in
            Self.logger.error("Download failed for \(videoId): \(error.localizedDescription)")
            self.downloadStates[videoId] = .failed(error: error.localizedDescription)
            self.activeDownloadTasks.removeValue(forKey: videoId)
            self.downloadDelegates.removeValue(forKey: videoId)
        }
    }

    // MARK: - Delete Operations

    /// Delete a downloaded video
    func deleteDownloadedVideo(_ videoId: String) {
        guard let entry = cacheIndex.entries[videoId] else { return }

        let videoPath = videosDirectory.appendingPathComponent(entry.filename)

        do {
            if fileManager.fileExists(atPath: videoPath.path) {
                try fileManager.removeItem(at: videoPath)
            }

            // Also remove thumbnail
            let thumbPath = thumbnailsDirectory.appendingPathComponent(entry.metadata.thumbnail)
            if fileManager.fileExists(atPath: thumbPath.path) {
                try fileManager.removeItem(at: thumbPath)
            }

            cacheIndex.entries.removeValue(forKey: videoId)
            saveCacheIndex()

            downloadStates[videoId] = .notDownloaded
            thumbnailCache.removeValue(forKey: videoId)

            Self.logger.info("Deleted video: \(videoId)")
        } catch {
            Self.logger.error("Failed to delete video \(videoId): \(error.localizedDescription)")
        }
    }

    // MARK: - Thumbnail Operations

    /// Download and cache a thumbnail
    func downloadThumbnail(for video: RemoteVideoBackground) async {
        let videoId = video.id

        // Check if already cached in memory
        if thumbnailCache[videoId] != nil { return }

        // Check if cached on disk
        let localPath = thumbnailsDirectory.appendingPathComponent(video.thumbnail)
        if fileManager.fileExists(atPath: localPath.path),
           let image = UIImage(contentsOfFile: localPath.path) {
            thumbnailCache[videoId] = image
            return
        }

        // Download thumbnail
        let url = video.thumbnailURL(baseURL: Self.baseURL)

        do {
            let (data, _) = try await urlSession.data(from: url)

            guard let image = UIImage(data: data) else {
                Self.logger.warning("Failed to decode thumbnail for \(videoId)")
                return
            }

            // Save to disk
            try data.write(to: localPath, options: .atomic)

            // Cache in memory
            thumbnailCache[videoId] = image

            Self.logger.debug("Downloaded thumbnail for \(videoId)")
        } catch {
            Self.logger.warning("Failed to download thumbnail for \(videoId): \(error.localizedDescription)")
        }
    }

    // MARK: - Query Operations

    /// Get local URL for a downloaded video
    func getLocalVideoURL(for videoId: String) -> URL? {
        guard let entry = cacheIndex.entries[videoId] else { return nil }
        let path = videosDirectory.appendingPathComponent(entry.filename)
        return fileManager.fileExists(atPath: path.path) ? path : nil
    }

    /// Check if a video is downloaded
    func isDownloaded(_ videoId: String) -> Bool {
        getLocalVideoURL(for: videoId) != nil
    }

    /// Get cached metadata for a downloaded video
    func getCachedMetadata(for videoId: String) -> RemoteVideoBackground? {
        cacheIndex.entries[videoId]?.metadata
    }
}

// MARK: - Download Delegate

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let videoId: String
    let video: RemoteVideoBackground
    let videosDirectory: URL
    weak var manager: VideoBackgroundDownloadManager?

    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "VideoBackgroundDownloadDelegate"
    )

    init(videoId: String, video: RemoteVideoBackground, videosDirectory: URL, manager: VideoBackgroundDownloadManager) {
        self.videoId = videoId
        self.video = video
        self.videosDirectory = videosDirectory
        self.manager = manager
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        manager?.handleDownloadProgress(videoId: videoId, progress: progress)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // IMPORTANT: Move file synchronously before this method returns!
        // The temp file at `location` is deleted when this callback exits.
        let fileManager = FileManager.default
        let destinationURL = videosDirectory.appendingPathComponent(video.filename)

        do {
            // Ensure videos directory exists
            try fileManager.createDirectory(at: videosDirectory, withIntermediateDirectories: true)

            // Remove existing file if present
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            // Move downloaded file to permanent location (must happen synchronously!)
            try fileManager.moveItem(at: location, to: destinationURL)

            // Get file size
            let attrs = try fileManager.attributesOfItem(atPath: destinationURL.path)
            let fileSize = attrs[.size] as? Int64 ?? 0

            Self.logger.info("Saved video \(self.videoId) to \(destinationURL.path)")

            // Now notify manager to update state (can be async)
            manager?.handleDownloadSaved(
                videoId: videoId,
                video: video,
                destinationURL: destinationURL,
                fileSize: fileSize
            )

        } catch {
            Self.logger.error("Failed to save video \(self.videoId): \(error.localizedDescription)")
            manager?.handleDownloadFailed(videoId: videoId, error: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error, (error as NSError).code != NSURLErrorCancelled {
            manager?.handleDownloadFailed(videoId: videoId, error: error)
        }
    }
}
