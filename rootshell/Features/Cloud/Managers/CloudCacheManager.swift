import Foundation
import Combine
import os.log

// MARK: - Sync Status

/// Status of a sync operation for an account
enum CloudSyncStatus: Equatable {
    case idle
    case syncing
    case success(instanceCount: Int, clusterCount: Int)
    case error(String)

    var isLoading: Bool {
        if case .syncing = self { return true }
        return false
    }

    var displayText: String {
        switch self {
        case .idle:
            return "Not synced"
        case .syncing:
            return "Syncing..."
        case .success(let instances, let clusters):
            var parts: [String] = []
            if instances > 0 {
                parts.append("\(instances) VM\(instances == 1 ? "" : "s")")
            }
            if clusters > 0 {
                parts.append("\(clusters) cluster\(clusters == 1 ? "" : "s")")
            }
            if parts.isEmpty {
                return "No resources"
            }
            return parts.joined(separator: ", ")
        case .error(let message):
            return "Error: \(message)"
        }
    }
}

// MARK: - Cloud Cache Manager

/// Manages cached cloud resources with file-based persistence
@MainActor
class CloudCacheManager: ObservableObject {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "CloudCacheManager")

    static let shared = CloudCacheManager()

    // MARK: - Staleness Configuration

    /// Cache staleness threshold (1 hour)
    static let staleCacheThreshold: TimeInterval = 60 * 60

    // MARK: - Published State

    /// Cached instances by account ID
    @Published private(set) var instancesByAccount: [UUID: [CloudInstance]] = [:]

    /// Cached clusters by account ID
    @Published private(set) var clustersByAccount: [UUID: [CloudKubernetesCluster]] = [:]

    /// Sync status per account
    @Published private(set) var syncStatus: [UUID: CloudSyncStatus] = [:]

    /// Last sync date per account (for staleness checking)
    private(set) var lastSyncDate: [UUID: Date] = [:]

    /// Publisher for cache changes
    let cacheDidChange = PassthroughSubject<Void, Never>()

    /// Track if background refresh is in progress
    private var backgroundRefreshTask: Task<Void, Never>?

    // MARK: - Dependencies

    private let accountManager: CloudAccountManager
    private let fileManager: FileManager

    // MARK: - Cache Directory

    private var cacheDirectory: URL {
        let documentsPath = ForkUITestConfiguration.documentsDirectoryURL
        return documentsPath
            .appendingPathComponent(".ghostty", isDirectory: true)
            .appendingPathComponent("cloud_cache", isDirectory: true)
    }

    // MARK: - Initialization

    private init() {
        self.accountManager = CloudAccountManager.shared
        self.fileManager = .default
        ensureCacheDirectoryExists()
        loadAllCachedData()
    }

    private func ensureCacheDirectoryExists() {
        do {
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("Failed to create cache directory: \(error.localizedDescription)")
        }
    }

    // MARK: - Sync Operations

    /// Syncs all accounts
    func syncAllAccounts() async {
        Self.logger.info("Syncing all cloud accounts")
        await withTaskGroup(of: Void.self) { group in
            for account in accountManager.accounts {
                group.addTask { @MainActor in
                    await self.syncAccount(account.id)
                }
            }
        }
    }

    /// Check if the cache is stale (any account's data is older than threshold)
    /// - Returns: true if cache is stale or empty (when accounts exist), false if cache is fresh
    func isCacheStale() -> Bool {
        let accounts = accountManager.accounts
        guard !accounts.isEmpty else { return false }

        let now = Date()
        for account in accounts {
            // If we have no sync date for this account, it's stale
            guard let syncDate = lastSyncDate[account.id] else {
                Self.logger.debug("Account \(account.label) has no sync date - marking stale")
                return true
            }

            // Check if this account's cache is older than threshold
            if now.timeIntervalSince(syncDate) > Self.staleCacheThreshold {
                Self.logger.debug("Account \(account.label) cache is stale (last sync: \(syncDate))")
                return true
            }
        }

        return false
    }

    /// Refresh all accounts in background if the cache is stale
    /// Returns immediately - refresh happens asynchronously
    func refreshIfStale() {
        // Don't start another refresh if one is in progress
        guard backgroundRefreshTask == nil else {
            Self.logger.debug("Background refresh already in progress, skipping")
            return
        }

        guard isCacheStale() else {
            Self.logger.debug("Cache is fresh, skipping background refresh")
            return
        }

        Self.logger.info("Cache stale, triggering background refresh")
        backgroundRefreshTask = Task {
            await syncAllAccounts()
            backgroundRefreshTask = nil
        }
    }

    /// Syncs a specific account with automatic OAuth token refresh
    /// - Parameter accountID: The account to sync
    func syncAccount(_ accountID: UUID) async {
        guard let account = accountManager.account(for: accountID) else {
            Self.logger.warning("Cannot sync unknown account: \(accountID.uuidString)")
            return
        }

        Self.logger.info("Syncing account: \(account.label)")
        syncStatus[accountID] = .syncing

        // Attempt sync with automatic token refresh on failure
        var retryCount = 0
        let maxRetries = 2

        while retryCount <= maxRetries {
            do {
                // Check if OAuth token needs proactive refresh
                var credentials = try accountManager.getCredentials(for: accountID)
                if credentials.authMethod == .oauth && credentials.needsRefresh {
                    // Check if we have a refresh token
                    if credentials.oauthRefreshToken == nil {
                        // No refresh token - need to re-authenticate via Safari
                        Self.logger.info("OAuth token expired, no refresh token - launching re-authentication for \(account.label)")
                        credentials = try await reauthenticateOAuth(accountID: accountID, providerID: account.providerID)
                    } else {
                        Self.logger.info("Proactively refreshing OAuth token for \(account.label)")
                        credentials = try await refreshOAuthToken(credentials)
                    }
                }

                // Perform the actual sync
                try await performSync(accountID: accountID, account: account, credentials: credentials)
                return // Success - exit the retry loop

            } catch CloudAPIError.unauthorized {
                retryCount += 1
                if retryCount <= maxRetries {
                    Self.logger.info("Got 401, attempting token refresh (retry \(retryCount)/\(maxRetries))")
                    do {
                        let credentials = try accountManager.getCredentials(for: accountID)
                        if credentials.authMethod == .oauth {
                            // Check if we have a refresh token before attempting
                            if credentials.oauthRefreshToken == nil {
                                // No refresh token - need to re-authenticate via Safari
                                Self.logger.info("No refresh token - launching re-authentication for \(account.label)")
                                _ = try await reauthenticateOAuth(accountID: accountID, providerID: account.providerID)
                                continue // Retry with fresh token
                            }
                            _ = try await refreshOAuthToken(credentials)
                            continue // Retry with fresh token
                        }
                    } catch OAuthFlowManager.OAuthError.cancelled {
                        Self.logger.info("Re-authentication cancelled by user")
                        syncStatus[accountID] = .error("Re-authentication cancelled")
                        return
                    } catch {
                        Self.logger.error("Token refresh failed: \(error.localizedDescription)")
                    }
                }
                Self.logger.error("Authentication failed for \(account.label) after \(retryCount) retries")
                syncStatus[accountID] = .error("Authentication failed - please check your credentials")
                return

            } catch OAuthFlowManager.OAuthError.cancelled {
                Self.logger.info("Re-authentication cancelled by user for \(account.label)")
                syncStatus[accountID] = .error("Re-authentication cancelled")
                return

            } catch {
                Self.logger.error("Sync failed for \(account.label): \(error.localizedDescription)")
                syncStatus[accountID] = .error(error.localizedDescription)
                return
            }
        }
    }

    /// Refresh OAuth token and persist to keychain
    /// - Parameter credentials: The credentials to refresh
    /// - Returns: Updated credentials with fresh token
    private func refreshOAuthToken(_ credentials: CloudCredentials) async throws -> CloudCredentials {
        // Log credential state for debugging
        let hasRefreshToken = credentials.oauthRefreshToken != nil
        let accountIDString = credentials.accountID.uuidString
        Self.logger.info("Attempting OAuth refresh for \(accountIDString) - has refresh token: \(hasRefreshToken)")

        if !hasRefreshToken {
            Self.logger.error("No refresh token available for account \(accountIDString) - re-authentication required")
        }

        let oauthManager = OAuthFlowManager()
        let refreshed = try await oauthManager.refreshToken(credentials: credentials)
        try accountManager.updateCredentials(refreshed)
        Self.logger.info("Successfully refreshed OAuth token for account \(accountIDString)")
        return refreshed
    }

    /// Re-authenticate OAuth account via Safari (for providers without refresh tokens like Linode)
    /// - Parameters:
    ///   - accountID: The account ID to re-authenticate
    ///   - providerID: The provider ID (e.g., "linode", "digitalocean")
    /// - Returns: Updated credentials with fresh tokens
    private func reauthenticateOAuth(accountID: UUID, providerID: String) async throws -> CloudCredentials {
        Self.logger.info("Launching OAuth re-authentication for account \(accountID.uuidString) (provider: \(providerID))")

        let oauthManager = OAuthFlowManager()
        let refreshed: CloudCredentials

        switch providerID {
        case LinodeProvider.providerID:
            refreshed = try await oauthManager.reauthenticateLinode(existingAccountID: accountID)
        case DigitalOceanProvider.providerID:
            refreshed = try await oauthManager.reauthenticateDigitalOcean(existingAccountID: accountID)
        default:
            Self.logger.error("Unknown provider for re-authentication: \(providerID)")
            throw OAuthFlowManager.OAuthError.invalidConfiguration
        }

        try accountManager.updateCredentials(refreshed)
        Self.logger.info("Successfully re-authenticated account \(accountID.uuidString)")
        return refreshed
    }

    /// Perform the actual sync operations
    /// - Parameters:
    ///   - accountID: The account ID
    ///   - account: The account metadata
    ///   - credentials: The credentials to use
    private func performSync(accountID: UUID, account: CloudAccount, credentials: CloudCredentials) async throws {
        // Create API client with provided credentials
        guard let providerType = CloudProviderRegistry.shared.provider(for: account.providerID) else {
            throw CloudAccountManager.AccountError.unknownProvider(account.providerID)
        }
        let client = providerType.createAPIClient(credentials: credentials)

        // Fetch account info and update
        let accountInfo = try await client.getAccountInfo()
        accountManager.updateAccountInfo(
            accountID: accountID,
            providerAccountID: accountInfo.accountID,
            displayName: accountInfo.displayName ?? accountInfo.email
        )

        // Fetch instances if supported
        var instances: [CloudInstance] = []
        if let vmClient = client as? VMCapableProvider {
            instances = try await vmClient.listInstances()
            Self.logger.info("Fetched \(instances.count) instances for \(account.label)")
        }

        // Fetch clusters if supported
        var clusters: [CloudKubernetesCluster] = []
        if let k8sClient = client as? KubernetesCapableProvider {
            clusters = try await k8sClient.listClusters()
            Self.logger.info("Fetched \(clusters.count) clusters for \(account.label)")

            // Check import status for each cluster by matching server URL
            let kubernetesManager = KubernetesClusterManager.shared
            for i in 0..<clusters.count {
                if let apiEndpoint = clusters[i].apiEndpoint,
                   let localCluster = kubernetesManager.cluster(byServerURL: apiEndpoint) {
                    clusters[i].isImported = true
                    clusters[i].localClusterID = localCluster.id
                }
            }
        }

        // Update cache
        instancesByAccount[accountID] = instances
        clustersByAccount[accountID] = clusters
        syncStatus[accountID] = .success(instanceCount: instances.count, clusterCount: clusters.count)
        lastSyncDate[accountID] = Date()

        // Persist to disk
        saveCacheForAccount(accountID)
        cacheDidChange.send()

        Self.logger.info("Sync completed for \(account.label)")
    }

    // MARK: - Kubeconfig Import

    /// Import kubeconfig for a cloud cluster (first-time import)
    /// - Parameters:
    ///   - cluster: The cloud cluster to import kubeconfig from
    ///   - accountID: The cloud account ID
    /// - Returns: The newly created local KubernetesCluster
    /// - Throws: CloudAPIError or KubernetesImportError
    func importKubeconfig(for cluster: CloudKubernetesCluster, accountID: UUID) async throws -> KubernetesCluster {
        Self.logger.info("Importing kubeconfig for cluster: \(cluster.label)")

        // Get API client for the account
        let client = try accountManager.createAPIClient(for: accountID)

        guard let k8sClient = client as? KubernetesCapableProvider else {
            throw CloudAPIError.invalidResponse
        }

        // Fetch kubeconfig from cloud provider
        let kubeconfigYAML = try await k8sClient.getKubeconfig(clusterID: cluster.providerClusterID)

        // Import to local Kubernetes manager
        let kubernetesManager = KubernetesClusterManager.shared
        let localCluster = try kubernetesManager.importKubeconfig(kubeconfigYAML, label: cluster.label)

        // Update the cloud cluster's import status
        updateClusterImportStatus(
            providerClusterID: cluster.providerClusterID,
            accountID: accountID,
            isImported: true,
            localClusterID: localCluster.id
        )

        Self.logger.info("Successfully imported kubeconfig for cluster: \(cluster.label)")
        return localCluster
    }

    /// Refresh kubeconfig for an already-imported cloud cluster
    /// - Parameters:
    ///   - cluster: The cloud cluster to refresh kubeconfig from
    ///   - accountID: The cloud account ID
    /// - Throws: CloudAPIError or KubernetesImportError
    func refreshKubeconfig(for cluster: CloudKubernetesCluster, accountID: UUID) async throws {
        Self.logger.info("Refreshing kubeconfig for cluster: \(cluster.label)")

        // Find the local cluster by server URL (more reliable than cached localClusterID)
        let kubernetesManager = KubernetesClusterManager.shared
        guard let apiEndpoint = cluster.apiEndpoint,
              let localCluster = kubernetesManager.cluster(byServerURL: apiEndpoint) else {
            throw KubernetesImportError.clusterNotFound(cluster.label)
        }

        // Get API client for the account
        let client = try accountManager.createAPIClient(for: accountID)

        guard let k8sClient = client as? KubernetesCapableProvider else {
            throw CloudAPIError.invalidResponse
        }

        // Fetch fresh kubeconfig from cloud provider
        let kubeconfigYAML = try await k8sClient.getKubeconfig(clusterID: cluster.providerClusterID)

        // Update the existing local cluster's kubeconfig
        try kubernetesManager.updateKubeconfig(for: localCluster, newKubeconfigYAML: kubeconfigYAML)

        Self.logger.info("Successfully refreshed kubeconfig for cluster: \(cluster.label)")
    }

    /// Update the import status of a cached cluster
    private func updateClusterImportStatus(
        providerClusterID: String,
        accountID: UUID,
        isImported: Bool,
        localClusterID: UUID?
    ) {
        guard var clusters = clustersByAccount[accountID] else { return }

        if let index = clusters.firstIndex(where: { $0.providerClusterID == providerClusterID }) {
            clusters[index].isImported = isImported
            clusters[index].localClusterID = localClusterID
            clustersByAccount[accountID] = clusters
            saveCacheForAccount(accountID)
            cacheDidChange.send()
        }
    }

    // MARK: - Cache Access

    /// Get all instances across all accounts
    var allInstances: [CloudInstance] {
        instancesByAccount.values.flatMap { $0 }
    }

    /// Get all clusters across all accounts
    var allClusters: [CloudKubernetesCluster] {
        clustersByAccount.values.flatMap { $0 }
    }

    /// Get instances for a specific account
    func instances(for accountID: UUID) -> [CloudInstance] {
        instancesByAccount[accountID] ?? []
    }

    /// Get clusters for a specific account
    func clusters(for accountID: UUID) -> [CloudKubernetesCluster] {
        clustersByAccount[accountID] ?? []
    }

    /// Total instance count for an account
    func instanceCount(for accountID: UUID) -> Int {
        instancesByAccount[accountID]?.count ?? 0
    }

    /// Total cluster count for an account
    func clusterCount(for accountID: UUID) -> Int {
        clustersByAccount[accountID]?.count ?? 0
    }

    /// Get sync status for an account
    func status(for accountID: UUID) -> CloudSyncStatus {
        syncStatus[accountID] ?? .idle
    }

    // MARK: - Cache Management

    /// Clear cache for a specific account
    func clearCache(for accountID: UUID) {
        Self.logger.info("Clearing cache for account: \(accountID.uuidString)")
        instancesByAccount.removeValue(forKey: accountID)
        clustersByAccount.removeValue(forKey: accountID)
        syncStatus.removeValue(forKey: accountID)
        lastSyncDate.removeValue(forKey: accountID)

        // Delete cache file
        let cacheFile = cacheFileURL(for: accountID)
        try? fileManager.removeItem(at: cacheFile)

        cacheDidChange.send()
    }

    /// Clear all cached data
    func clearAllCache() {
        Self.logger.info("Clearing all cloud cache")
        instancesByAccount.removeAll()
        clustersByAccount.removeAll()
        syncStatus.removeAll()
        lastSyncDate.removeAll()

        // Delete all cache files
        if let files = try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
            for file in files {
                try? fileManager.removeItem(at: file)
            }
        }

        cacheDidChange.send()
    }

    // MARK: - File-Based Persistence

    private func cacheFileURL(for accountID: UUID) -> URL {
        cacheDirectory.appendingPathComponent("\(accountID.uuidString).json")
    }

    private func loadAllCachedData() {
        Self.logger.info("Loading cached cloud data")

        for account in accountManager.accounts {
            loadCacheForAccount(account.id)
        }

        Self.logger.info("Loaded cache for \(self.instancesByAccount.count) accounts")
    }

    private func loadCacheForAccount(_ accountID: UUID) {
        let cacheFile = cacheFileURL(for: accountID)

        guard fileManager.fileExists(atPath: cacheFile.path) else {
            syncStatus[accountID] = .idle
            return
        }

        do {
            let data = try Data(contentsOf: cacheFile)
            let cache = try JSONDecoder().decode(AccountCacheData.self, from: data)

            instancesByAccount[accountID] = cache.instances
            clustersByAccount[accountID] = cache.clusters
            syncStatus[accountID] = .success(
                instanceCount: cache.instances.count,
                clusterCount: cache.clusters.count
            )
            lastSyncDate[accountID] = cache.lastUpdated

            Self.logger.debug("Loaded cache for account \(accountID.uuidString): \(cache.instances.count) instances, \(cache.clusters.count) clusters, last sync: \(cache.lastUpdated)")
        } catch {
            Self.logger.error("Failed to load cache for account \(accountID.uuidString): \(error.localizedDescription)")
            syncStatus[accountID] = .idle
        }
    }

    private func saveCacheForAccount(_ accountID: UUID) {
        let cache = AccountCacheData(
            instances: instancesByAccount[accountID] ?? [],
            clusters: clustersByAccount[accountID] ?? [],
            lastUpdated: Date()
        )

        do {
            let data = try JSONEncoder().encode(cache)
            try data.write(to: cacheFileURL(for: accountID))
            Self.logger.debug("Saved cache for account \(accountID.uuidString)")
        } catch {
            Self.logger.error("Failed to save cache for account \(accountID.uuidString): \(error.localizedDescription)")
        }
    }
}

// MARK: - Cache Data Structure

/// Persisted cache data for an account
private struct AccountCacheData: Codable {
    let instances: [CloudInstance]
    let clusters: [CloudKubernetesCluster]
    let lastUpdated: Date
}
