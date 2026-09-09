//
//  TSSHSpawnHelper.swift
//  rootshell
//
//  Shared tsshd spawn logic extracted from TrzszSession.
//  Used by both interactive sessions and background tunnels.
//

import Citadel
import Foundation
import NIOCore
import NIOSSH
import OSLog

/// Shared helper for spawning tsshd via SSH and returning server info + SSH clients.
@MainActor
enum TrzszSpawnHelper {

    private nonisolated static let logger = Logger(
        subsystem: "com.kk2.rootshell",
        category: "TrzszSpawnHelper"
    )

    /// Result from spawning tsshd.
    struct SpawnResult {
        let serverInfo: TrzszServerInfo
        let sshClient: SSHClient
        let jumpClient: SSHClient?

        /// Bootstrap SSH negotiated algorithms (captured before SSH closes)
        let sshKeyExchange: String?
        let sshHostKey: String?
        let sshCipher: String?
        let sshMac: String?

        /// Server auth banners (`SSH_MSG_USERAUTH_BANNER`) captured during the
        /// bootstrap SSH authentication, in arrival order.
        let authBanners: [String]
    }

    /// Spawns tsshd via SSH and returns the server info + SSH clients.
    /// Caller is responsible for closing SSH clients after transport connects.
    /// - Parameters:
    ///   - config: The trzsz configuration (contains SSHConfig + server command)
    ///   - resolvedHost: Pre-resolved hostname/IP for the SSH connection
    ///   - onHostKeyValidation: Optional host key validation callback
    /// - Returns: SpawnResult with server info and SSH clients
    static func spawnTsshd(
        config: TrzszConfig,
        resolvedHost: String,
        onHostKeyValidation: ((HostKeyValidationRequest) async -> HostKeyValidationResult)?,
        onKeyboardInteractiveChallenge: ((KeyboardInteractiveChallenge) async -> [String]?)? = nil,
        authBannerObserver: (@Sendable (AuthBannerBuffer.Event) -> Void)? = nil
    ) async throws -> SpawnResult {
        let command = config.serverCommand()
        logger.info("Spawning tsshd: \(command)")

        // Captures server auth banners (`SSH_MSG_USERAUTH_BANNER`) from the NIO
        // event loop during authentication. Cleared at the start of each connect
        // attempt (in `createSSHClient`) so only the successful attempt's banners
        // remain after the retry loop — the per-attempt clear also resets the
        // live observer's card between attempts.
        let authBannerBuffer = AuthBannerBuffer()
        authBannerBuffer.setObserver(authBannerObserver)

        // Connect SSH with bounded retry on transient connection failures.
        // The per-attempt `timeout` drives only the retry cadence here; the
        // login phase uses the fixed `citadelLoginTimeout` (createSSHClient's
        // default) so slow keyboard-interactive / OTP entry can't trip an
        // absolute, non-pausable Citadel login deadline mid-prompt.
        let (sshClient, jumpClient) = try await InitialConnectRetry.run(
            config: .interactive,
            label: "trzsz-spawn:\(config.sshConfig.displayName)",
            isPermanent: InitialConnectRetry.isPermanentConnectErrorApp
        ) { attempt, timeout in
            if attempt > 1 {
                let timeoutSec = Double(timeout.nanoseconds) / 1_000_000_000
                logger.info("trzsz spawn SSH connect retry attempt \(attempt) (timeout=\(timeoutSec)s)")
            }
            return try await createSSHClient(
                sshConfig: config.sshConfig,
                resolvedHost: resolvedHost,
                onHostKeyValidation: onHostKeyValidation,
                onKeyboardInteractiveChallenge: onKeyboardInteractiveChallenge,
                // loginTimeout omitted → fixed citadelLoginTimeout (covers OTP entry)
                authBannerBuffer: authBannerBuffer
            )
        }

        // Capture negotiated algorithms before SSH closes
        var sshKeyExchange: String?
        var sshHostKey: String?
        var sshCipher: String?
        var sshMac: String?
        if let algos = try? await sshClient.getNegotiatedAlgorithms() {
            sshKeyExchange = algos.keyExchange
            sshHostKey = algos.hostKey
            sshCipher = algos.cipher
            sshMac = algos.mac
        }

        // Execute tsshd command
        logger.debug("Executing tsshd command via SSH")
        let streams = try await sshClient.executeCommandStream(command)

        var stdout = ""
        var stderr = ""
        var serverInfo: TrzszServerInfo?
        var commandError: Error?

        do {
            for try await event in streams {
                switch event {
                case .stdout(let buffer):
                    if let str = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) {
                        stdout += str
                        if serverInfo == nil, stdout.contains("{"), stdout.contains("}") {
                            if let parsed = try? TrzszServerInfo.parse(fromOutput: stdout) {
                                serverInfo = parsed
                                break
                            }
                        }
                    }
                case .stderr(let buffer):
                    if let str = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) {
                        stderr += str
                    }
                case .exitStatus:
                    break
                }
                if serverInfo != nil { break }
            }
        } catch {
            commandError = error
            logger.debug("tsshd command stream error: \(error.localizedDescription)")
        }

        if serverInfo == nil {
            serverInfo = try? TrzszServerInfo.parse(fromOutput: stdout)
        }

        guard let serverInfo else {
            // Close clients before throwing
            try? await sshClient.close()
            if let jumpClient { try? await jumpClient.close() }

            let combinedOutput = stdout + stderr
            let trimmedOutput = combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)

            // Truncate very long output (Go panics, etc.) to avoid flooding terminal
            let maxOutputLength = 500
            let truncatedOutput: String
            if trimmedOutput.count > maxOutputLength {
                truncatedOutput = String(trimmedOutput.prefix(maxOutputLength)) + "... (truncated)"
            } else {
                truncatedOutput = trimmedOutput
            }

            if isTsshdNotFound(in: combinedOutput) {
                throw TrzszError.tsshNotFound
            } else if combinedOutput.contains("Permission denied") {
                let reason = truncatedOutput.isEmpty
                    ? "Permission denied"
                    : truncatedOutput
                throw TrzszError.serverSpawnFailed(reason: reason)
            } else if let error = commandError {
                let reason = truncatedOutput.isEmpty
                    ? error.localizedDescription
                    : truncatedOutput
                throw TrzszError.serverSpawnFailed(reason: reason)
            } else if trimmedOutput.isEmpty {
                throw TrzszError.invalidServerInfo(reason: "No output from tsshd command")
            } else {
                throw TrzszError.serverSpawnFailed(reason: truncatedOutput)
            }
        }

        logger.info("Parsed tsshd output: port=\(serverInfo.port), mode=\(serverInfo.mode.rawValue)")
        return SpawnResult(
            serverInfo: serverInfo,
            sshClient: sshClient,
            jumpClient: jumpClient,
            sshKeyExchange: sshKeyExchange,
            sshHostKey: sshHostKey,
            sshCipher: sshCipher,
            sshMac: sshMac,
            authBanners: authBannerBuffer.drain()
        )
    }

    // MARK: - Private Helpers

    private static func createSSHClient(
        sshConfig: SSHConfig,
        resolvedHost: String,
        onHostKeyValidation: ((HostKeyValidationRequest) async -> HostKeyValidationResult)?,
        onKeyboardInteractiveChallenge: ((KeyboardInteractiveChallenge) async -> [String]?)? = nil,
        loginTimeout: TimeAmount = SSHTimeoutConfig.citadelLoginTimeout,
        authBannerBuffer: AuthBannerBuffer? = nil
    ) async throws -> (SSHClient, SSHClient?) {
        // Fresh per attempt: drop any banners from a prior failed attempt so the
        // returned set reflects only this (successful) connection.
        authBannerBuffer?.clear()
        let authMethod = try await buildAuthMethod(for: sshConfig, onKeyboardInteractiveChallenge: onKeyboardInteractiveChallenge)

        if let jumpHost = sshConfig.jumpHost {
            logger.debug("Connecting via jump host: \(jumpHost.host)")

            let jumpAuth = try await buildAuthMethod(for: jumpHost, onKeyboardInteractiveChallenge: onKeyboardInteractiveChallenge)
            let jumpHostKeyValidator = SSHConnectionHelper.buildHostKeyValidator(
                for: jumpHost.host, port: jumpHost.port, label: "[Jump Host]",
                onValidation: onHostKeyValidation
            )

            // Pre-resolve jump host CGNAT IPv4 to keep NWConnection on a
            // single, deterministic family (see CitadelSSHSession for the
            // rationale).
            let jumpConnectHost: String
            if let cgnatIP = await NetworkAddressUtils.resolveToCGNATIPv4(hostname: jumpHost.host) {
                jumpConnectHost = cgnatIP
            } else {
                jumpConnectHost = jumpHost.host
            }

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
                hostKeyValidator: jumpHostKeyValidator
            )
            jumpSettings.algorithms = .all
            jumpSettings.loginTimeout = loginTimeout
            jumpSettings.protocolOptions = SSHConnectionHelper.hostCertificateProtocolOptions(forHost: jumpHost.host)
            if let authBannerBuffer {
                jumpSettings.onUserAuthBanner = { [authBannerBuffer, jumpHostName = jumpHost.host] message, _ in
                    authBannerBuffer.append(message, source: jumpHostName)
                }
            }
            let jumpClient: SSHClient
            do {
                jumpClient = try await SSHClient.connect(on: jumpChannel, settings: jumpSettings)
            } catch {
                try? await jumpChannel.close()
                throw error
            }

            let targetHostKeyValidator = SSHConnectionHelper.buildHostKeyValidator(
                for: sshConfig.host, port: sshConfig.port, label: "[Target]",
                onValidation: onHostKeyValidation
            )
            var targetSettings = SSHClientSettings(
                host: resolvedHost,
                port: sshConfig.port,
                authenticationMethod: { authMethod },
                hostKeyValidator: targetHostKeyValidator
            )
            targetSettings.algorithms = .all
            targetSettings.loginTimeout = loginTimeout
            targetSettings.protocolOptions = SSHConnectionHelper.hostCertificateProtocolOptions(forHost: sshConfig.host)
            if let authBannerBuffer {
                targetSettings.onUserAuthBanner = { [authBannerBuffer] message, _ in
                    authBannerBuffer.append(message)
                }
            }
            let targetClient: SSHClient
            do {
                targetClient = try await jumpClient.jump(to: targetSettings)
            } catch {
                try? await jumpClient.close()
                throw error
            }
            return (targetClient, jumpClient)
        }

        let hostKeyValidator = SSHConnectionHelper.buildHostKeyValidator(
            for: sshConfig.host, port: sshConfig.port,
            onValidation: onHostKeyValidation
        )
        let directChannel = try await MPTCPBootstrap.connectPlainChannel(
            host: resolvedHost,
            port: sshConfig.port,
            deferReads: true
        )
        MPTCPBootstrap.armReadsWhenSSHHandlerInstalled(on: directChannel)
        var settings = SSHClientSettings(
            host: resolvedHost,
            port: sshConfig.port,
            authenticationMethod: { authMethod },
            hostKeyValidator: hostKeyValidator
        )
        settings.algorithms = .all
        settings.loginTimeout = loginTimeout
        settings.protocolOptions = SSHConnectionHelper.hostCertificateProtocolOptions(forHost: sshConfig.host)
        if let authBannerBuffer {
            settings.onUserAuthBanner = { [authBannerBuffer] message, _ in
                authBannerBuffer.append(message)
            }
        }
        let client: SSHClient
        do {
            client = try await SSHClient.connect(on: directChannel, settings: settings)
        } catch {
            try? await directChannel.close()
            throw error
        }
        return (client, nil)
    }

    /// Builds SSH auth method, resolving savedPassword from keychain. The
    /// keyboard-interactive callback is threaded through so a tsshd bootstrap to
    /// a 2FA/OTP/PAM server can prompt the user.
    private static func buildAuthMethod(
        for sshConfig: SSHConfig,
        onKeyboardInteractiveChallenge: ((KeyboardInteractiveChallenge) async -> [String]?)?
    ) async throws -> SSHAuthenticationMethod {
        var authMethod = sshConfig.authMethod
        if case .savedPassword = authMethod {
            let connectionKey = "\(sshConfig.host):\(sshConfig.port):\(sshConfig.username)"
            guard let password = try? KeychainManager.shared.loadSSHPassword(
                connectionKey: connectionKey,
                authRequirement: .none,
                context: nil
            ) else {
                throw TrzszError.sshConnectionFailed(reason: "Saved password not found")
            }
            // Resolve to inline password so it also serves as the auto-answer for
            // a single hidden keyboard-interactive prompt (PAM password servers).
            authMethod = .password(password)
        }
        return try await SSHConnectionHelper.buildAuthMethod(
            username: sshConfig.username,
            authMethod: authMethod,
            sessionName: sshConfig.displayName,
            onKeyboardInteractiveChallenge: onKeyboardInteractiveChallenge
        )
    }

    /// Builds SSH auth method for jump host, resolving savedPassword from keychain.
    private static func buildAuthMethod(
        for jumpHost: SSHConfig.JumpHostConfig,
        onKeyboardInteractiveChallenge: ((KeyboardInteractiveChallenge) async -> [String]?)?
    ) async throws -> SSHAuthenticationMethod {
        var authMethod = jumpHost.authMethod
        if case .savedPassword = authMethod {
            let connectionKey = "\(jumpHost.host):\(jumpHost.port):\(jumpHost.username)"
            guard let password = try? KeychainManager.shared.loadSSHPassword(
                connectionKey: connectionKey,
                authRequirement: .none,
                context: nil
            ) else {
                throw TrzszError.sshConnectionFailed(reason: "Jump host saved password not found")
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

    private static func isTsshdNotFound(in output: String) -> Bool {
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
