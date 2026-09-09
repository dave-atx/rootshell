//
//  MoshServerSpawner.swift
//  rootshell
//
//  Spawns mosh-server via SSH connection
//

import Foundation
import Citadel
import NIOCore
import NIOSSH
import OSLog

/// Spawns mosh-server on a remote host via SSH
///
/// Flow:
/// 1. Connect to host via SSH using the pre-resolved IP address
/// 2. Execute mosh-server command with `-s` flag (bind to SSH interface)
/// 3. Parse "MOSH CONNECT <port> <key>" from output
/// 4. Return connection info
///
/// The `-s` flag makes mosh-server bind to the interface the SSH connection
/// came in on (from SSH_CONNECTION env var). This ensures the server binds
/// to the same address family as the SSH connection, keeping everything in sync.
@MainActor
final class MoshServerSpawner {

    // MARK: - Types

    /// Result of spawning mosh-server
    struct SpawnResult: Sendable {
        /// The UDP port mosh-server is listening on
        let port: Int

        /// The session key for encryption
        let key: MoshBase64Key

        /// The hostname to connect to (NOT resolved IP)
        /// Address resolution is done separately by DualStackResolver
        /// to support both IPv4 and IPv6 for reactive hole-punching
        let host: String

        /// Bootstrap SSH negotiated algorithms (captured before SSH closes)
        let sshKeyExchange: String?
        let sshHostKey: String?
        let sshCipher: String?
        let sshMac: String?

        /// Server auth banners (`SSH_MSG_USERAUTH_BANNER`) captured during the
        /// bootstrap SSH authentication, in arrival order.
        let authBanners: [String]
    }

    /// Delegate for spawn progress
    protocol Delegate: AnyObject {
        /// Called when spawn state changes
        @MainActor func spawner(_ spawner: MoshServerSpawner, didChangeState state: MoshSessionState)
    }

    // MARK: - Properties

    /// The mosh configuration
    let config: MoshConfig

    /// The delegate for spawn events
    weak var delegate: Delegate?

    /// Keyboard-interactive (RFC 4256) challenge callback for the SSH bootstrap
    /// that spawns mosh-server. Returns one response per prompt, or nil to cancel.
    var onKeyboardInteractiveChallenge: ((KeyboardInteractiveChallenge) async -> [String]?)?

    /// Host-key validation prompt for the SSH bootstrap. nil = strict (accept
    /// known/CA-signed keys, reject new or changed).
    var onHostKeyValidation: ((HostKeyValidationRequest) async -> HostKeyValidationResult)?

    /// Jump client reference for cleanup
    private var jumpClient: SSHClient?

    /// Bootstrap SSH negotiated algorithms (captured before SSH closes)
    private(set) var negotiatedKeyExchange: String?
    private(set) var negotiatedHostKey: String?
    private(set) var negotiatedCipher: String?
    private(set) var negotiatedMac: String?

    /// Server auth banners (`SSH_MSG_USERAUTH_BANNER`) captured from the NIO
    /// event loop during the bootstrap SSH authentication. Drained into the
    /// `SpawnResult` once spawning completes.
    private let authBannerBuffer = AuthBannerBuffer()

    /// Installs a live observer on the banner buffer so the owning session can
    /// mirror banners into the auth-banner card while spawn auth is pending.
    /// Set before `spawn` is called.
    func setAuthBannerObserver(_ handler: (@Sendable (AuthBannerBuffer.Event) -> Void)?) {
        authBannerBuffer.setObserver(handler)
    }

    /// Logger
    private nonisolated static let logger = Logger(
        subsystem: "com.kk2.rootshell",
        category: "MoshServerSpawner"
    )

    // MARK: - Initialization

    /// Creates a spawner with the given configuration
    init(config: MoshConfig) {
        self.config = config
    }

    // MARK: - Spawn

    /// Spawns mosh-server on the remote host
    ///
    /// Uses `-s` flag so mosh-server binds to the SSH connection's interface.
    /// The resolvedHost parameter ensures SSH connects via the preferred address,
    /// and mosh-server will bind to that same interface.
    ///
    /// - Parameter resolvedHost: The resolved IP address to use for SSH connection.
    ///   mosh-server with `-s` will bind to this interface via SSH_CONNECTION.
    /// - Returns: Connection information for the UDP transport
    /// - Throws: MoshError if spawning fails
    func spawn(resolvedHost: String) async throws -> SpawnResult {
        let host = config.host
        Self.logger.info("Spawning mosh-server on \(host) via \(resolvedHost)")

        // Create a temporary SSH session to spawn mosh-server
        // We'll use the exec channel, not a PTY
        let sshConfig = config.sshConfig

        // Update state - connecting
        if let jumpHost = sshConfig.jumpHost {
            delegate?.spawner(self, didChangeState: .connectingSSH(
                host: jumpHost.host,
                isJumpHost: true
            ))
        } else {
            delegate?.spawner(self, didChangeState: .connectingSSH(
                host: sshConfig.host,
                isJumpHost: false
            ))
        }

        // Build the mosh-server command with -s flag
        // -s makes mosh-server bind to the SSH connection's interface (from SSH_CONNECTION)
        // This ensures server binds to the same address family as our SSH connection
        let command = config.serverCommand()
        Self.logger.debug("Mosh-server command: \(command)")

        // Execute via SSH using the resolved host
        // mosh-server with -s will read SSH_CONNECTION and bind to this interface
        let output = try await executeSSHCommand(command, config: sshConfig, resolvedHost: resolvedHost)

        // Update state
        delegate?.spawner(self, didChangeState: .spawningServer)

        // Parse the MOSH CONNECT response
        let (port, key) = try MoshBase64Key.parseServerResponse(output)

        Self.logger.info("Mosh-server spawned on port \(port)")

        // Return hostname (not resolved IP) - DualStackResolver will handle resolution
        return SpawnResult(
            port: port,
            key: key,
            host: sshConfig.host,
            sshKeyExchange: negotiatedKeyExchange,
            sshHostKey: negotiatedHostKey,
            sshCipher: negotiatedCipher,
            sshMac: negotiatedMac,
            authBanners: authBannerBuffer.drain()
        )
    }

    // MARK: - SSH Execution

    /// Executes a command via SSH and returns the output
    /// - Parameters:
    ///   - command: The command to execute
    ///   - config: SSH configuration
    ///   - resolvedHost: The pre-resolved IP address to connect to
    private func executeSSHCommand(_ command: String, config: SSHConfig, resolvedHost: String) async throws -> String {
        // Create the SSH client using Citadel
        let client = try await createSSHClient(config: config, resolvedHost: resolvedHost)
        defer {
            Task {
                try? await client.close()
                try? await self.jumpClient?.close()
            }
        }

        // Capture negotiated algorithms before SSH closes
        if let algos = try? await client.getNegotiatedAlgorithms() {
            self.negotiatedKeyExchange = algos.keyExchange
            self.negotiatedHostKey = algos.hostKey
            self.negotiatedCipher = algos.cipher
            self.negotiatedMac = algos.mac
        }

        // Execute the command
        Self.logger.debug("Executing command via SSH: \(command)")

        // Use executeCommandStream to handle stdout/stderr separately
        // This avoids throwing when mosh-server writes version info to stderr
        let streams = try await client.executeCommandStream(command)

        var stdout = ""
        var stderr = ""
        var commandError: Error?

        // Citadel throws CommandFailed when exit status is non-zero, but we need
        // to analyze stdout/stderr to provide a better error message. Catch the
        // error and analyze the output before re-throwing.
        do {
            for try await event in streams {
                switch event {
                case .stdout(let buffer):
                    if let str = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) {
                        stdout += str
                    }
                case .stderr(let buffer):
                    if let str = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) {
                        stderr += str
                    }
                case .exitStatus(let status):
                    Self.logger.debug("SSH command exit status: \(status)")
                }
            }
        } catch {
            // Save the error - we'll analyze output first, then throw appropriate error
            commandError = error
            Self.logger.debug("Command stream error: \(error.localizedDescription)")
        }

        Self.logger.debug("SSH stdout: \(stdout)")
        Self.logger.debug("SSH stderr: \(stderr)")

        // Combine output - MOSH CONNECT goes to stdout, but check both for errors
        let combinedOutput = stdout + stderr

        // Check for success - mosh-server outputs "MOSH CONNECT <port> <key>" to stdout
        if !stdout.contains("MOSH CONNECT") {
            // Check for mosh-server not installed
            if Self.isMoshServerNotFound(in: combinedOutput) {
                throw MoshError.moshServerNotFound
            } else if combinedOutput.contains("Permission denied") {
                throw MoshError.serverSpawnFailed(reason: "Permission denied")
            } else if let error = commandError {
                // Re-throw original error if we couldn't determine a better one
                // but include any output we collected
                let reason = combinedOutput.isEmpty
                    ? error.localizedDescription
                    : combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                throw MoshError.serverSpawnFailed(reason: reason)
            } else {
                throw MoshError.serverSpawnFailed(
                    reason: stdout.isEmpty ? "No MOSH CONNECT response received" : stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }

        return stdout
    }

    /// Creates an SSH client for command execution
    /// - Parameters:
    ///   - config: SSH configuration
    ///   - resolvedHost: The pre-resolved IP address to connect to (for direct connections)
    private func createSSHClient(config: SSHConfig, resolvedHost: String) async throws -> SSHClient {
        // Update state based on auth method
        delegate?.spawner(self, didChangeState: .authenticatingSSH(
            host: config.host,
            isJumpHost: config.jumpHost != nil
        ))

        let port = config.port

        // Build authentication method
        let authMethod = try await buildAuthMethod(for: config)

        // Handle jump host if configured
        if let jumpHost = config.jumpHost {
            delegate?.spawner(self, didChangeState: .connectingSSH(
                host: jumpHost.host,
                isJumpHost: true
            ))

            // Build auth for jump host
            let jumpAuth = try await buildAuthMethod(for: jumpHost)

            // Pre-resolve jump host to CGNAT IPv4 if applicable, so NWConnection
            // gets an IP literal (no Happy Eyeballs IPv6/IPv4 ambiguity and
            // downstream `cachedIP` invariants are preserved).
            let jumpConnectHost: String
            if let cgnatIP = await NetworkAddressUtils.resolveToCGNATIPv4(hostname: jumpHost.host) {
                jumpConnectHost = cgnatIP
            } else {
                jumpConnectHost = jumpHost.host
            }

            // Route through MPTCPBootstrap (NIOTSConnectionBootstrap /
            // NWConnection) — POSIX `connect()` races against Tailscale's
            // DERP/WireGuard path setup for NAT'd targets and intermittently
            // fails outside the home network. NWConnection's pre-flight path
            // evaluation drives that setup before the first SYN.
            let jumpChannel = try await MPTCPBootstrap.connectPlainChannel(
                host: jumpConnectHost,
                port: jumpHost.port,
                deferReads: true
            )
            MPTCPBootstrap.armReadsWhenSSHHandlerInstalled(on: jumpChannel)
            var jumpSettings = SSHClientSettings(
                host: jumpConnectHost,
                port: jumpHost.port,
                authenticationMethod: { jumpAuth },
                hostKeyValidator: SSHConnectionHelper.buildHostKeyValidator(
                    for: jumpHost.host,
                    port: jumpHost.port,
                    label: "[Jump Host]",
                    onValidation: onHostKeyValidation
                )
            )
            jumpSettings.algorithms = .all
            jumpSettings.loginTimeout = SSHTimeoutConfig.citadelLoginTimeout
            jumpSettings.protocolOptions = SSHConnectionHelper.hostCertificateProtocolOptions(forHost: jumpHost.host)
            jumpSettings.onUserAuthBanner = { [authBannerBuffer = self.authBannerBuffer, jumpHostName = jumpHost.host] message, _ in
                authBannerBuffer.append(message, source: jumpHostName)
            }
            let jumpClientConnection: SSHClient
            do {
                jumpClientConnection = try await SSHClient.connect(on: jumpChannel, settings: jumpSettings)
            } catch {
                try? await jumpChannel.close()
                throw error
            }
            self.jumpClient = jumpClientConnection

            delegate?.spawner(self, didChangeState: .connectingToTarget(host: config.host))

            // Jump to target using resolved IP
            var targetSettings = SSHClientSettings(
                host: resolvedHost,
                port: port,
                authenticationMethod: { authMethod },
                hostKeyValidator: SSHConnectionHelper.buildHostKeyValidator(
                    for: config.host,
                    port: port,
                    label: "[Target]",
                    onValidation: onHostKeyValidation
                )
            )
            targetSettings.algorithms = .all
            targetSettings.loginTimeout = SSHTimeoutConfig.citadelLoginTimeout
            targetSettings.protocolOptions = SSHConnectionHelper.hostCertificateProtocolOptions(forHost: config.host)
            targetSettings.onUserAuthBanner = { [authBannerBuffer = self.authBannerBuffer] message, _ in
                authBannerBuffer.append(message)
            }
            return try await jumpClientConnection.jump(to: targetSettings)
        }

        // Direct connection using pre-resolved IP
        let directChannel = try await MPTCPBootstrap.connectPlainChannel(
            host: resolvedHost,
            port: port,
            deferReads: true
        )
        MPTCPBootstrap.armReadsWhenSSHHandlerInstalled(on: directChannel)
        var settings = SSHClientSettings(
            host: resolvedHost,
            port: port,
            authenticationMethod: { authMethod },
            // Keyed by the configured hostname, not the resolved IP — same
            // identity the terminal validates against.
            hostKeyValidator: SSHConnectionHelper.buildHostKeyValidator(
                for: config.host,
                port: port,
                onValidation: onHostKeyValidation
            )
        )
        settings.algorithms = .all
        settings.loginTimeout = SSHTimeoutConfig.citadelLoginTimeout
        settings.protocolOptions = SSHConnectionHelper.hostCertificateProtocolOptions(forHost: config.host)
        settings.onUserAuthBanner = { [authBannerBuffer = self.authBannerBuffer] message, _ in
            authBannerBuffer.append(message)
        }
        do {
            return try await SSHClient.connect(on: directChannel, settings: settings)
        } catch {
            try? await directChannel.close()
            throw error
        }
    }

    // MARK: - Authentication Helpers

    /// Builds authentication method for main config, resolving savedPassword inline from keychain.
    /// Threads the keyboard-interactive callback so a mosh-server bootstrap to a
    /// 2FA/OTP/PAM server can prompt the user.
    private func buildAuthMethod(for config: SSHConfig) async throws -> SSHAuthenticationMethod {
        var authMethod = config.authMethod
        if case .savedPassword = authMethod {
            let connectionKey = "\(config.host):\(config.port):\(config.username)"
            guard let password = try? KeychainManager.shared.loadSSHPassword(
                connectionKey: connectionKey,
                authRequirement: .none,
                context: nil
            ) else {
                throw MoshError.sshConnectionFailed(reason: "Saved password not found in keychain")
            }
            // Resolve to inline password so it also serves as the auto-answer for
            // a single hidden keyboard-interactive prompt.
            authMethod = .password(password)
        }
        return try await SSHConnectionHelper.buildAuthMethod(
            username: config.username,
            authMethod: authMethod,
            sessionName: config.displayName,
            onKeyboardInteractiveChallenge: onKeyboardInteractiveChallenge
        )
    }

    /// Builds authentication method for jump host config, resolving savedPassword inline from keychain
    private func buildAuthMethod(for jumpHost: SSHConfig.JumpHostConfig) async throws -> SSHAuthenticationMethod {
        var authMethod = jumpHost.authMethod
        if case .savedPassword = authMethod {
            let connectionKey = "\(jumpHost.host):\(jumpHost.port):\(jumpHost.username)"
            guard let password = try? KeychainManager.shared.loadSSHPassword(
                connectionKey: connectionKey,
                authRequirement: .none,
                context: nil
            ) else {
                throw MoshError.sshConnectionFailed(reason: "Jump host saved password not found")
            }
            authMethod = .password(password)
        }
        return try await SSHConnectionHelper.buildAuthMethod(
            username: jumpHost.username,
            authMethod: authMethod,
            sessionName: "[Jump Host] \(jumpHost.displayName)",
            onKeyboardInteractiveChallenge: onKeyboardInteractiveChallenge
        )
    }

    // MARK: - Error Detection Helpers

    /// Checks if the server output indicates mosh-server is not installed
    ///
    /// Different shells have different "not found" messages:
    /// - Bash: "mosh-server: command not found"
    /// - Zsh: "mosh-server: command not found" or "command not found: mosh-server"
    /// - Fish: "Unknown command: mosh-server" or "fish: Unknown command"
    /// - Sh/dash: "mosh-server: not found"
    /// - Tcsh/csh: "mosh-server: Command not found"
    private static func isMoshServerNotFound(in output: String) -> Bool {
        let lowercased = output.lowercased()
        let patterns = [
            "command not found",
            "not found",
            "unknown command",
            "no such file or directory"
        ]
        return patterns.contains { lowercased.contains($0) }
    }
}
