//
//  HeadlessSSHExecutor.swift
//  rootshell
//
//  Runs a single command on a remote SSH host without any UI: connect,
//  execute, return output. Host keys validate strictly against known hosts
//  and trusted CAs with no prompt — an unknown or changed key rejects.
//  Shared by the MCP ssh_execute tool and the Run Command Shortcuts intent.
//

import Foundation
import Citadel
import NIOCore
import NIOSSH
import os.log

@MainActor
enum HeadlessSSHExecutor {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "HeadlessSSHExecutor")

    /// Bound on every close — a half-dead channel can park NIO's close
    /// future indefinitely (see AsyncTimeout.swift).
    private static let closeTimeoutSeconds: TimeInterval = 2.0

    struct CommandOutput: Sendable {
        /// nil when the command was forcibly terminated after exceeding the
        /// output cap, so no exit status ever arrived — do not report such a
        /// run as having succeeded.
        let exitCode: Int?
        let stdout: String
        let stderr: String
        let durationMs: Int
        /// Output exceeded the byte cap and was cut off during collection.
        let truncated: Bool
    }

    /// Marker so errors thrown by caller-supplied auth builders surface
    /// unchanged (the MCP tool throws typed MCPErrors with their own
    /// JSON-RPC codes) instead of being folded into `connectionFailed`.
    private struct AuthBuilderFailure: Error {
        let underlying: Error
    }

    enum ExecError: Error, CustomLocalizedStringResourceConvertible {
        case connectionFailed(String)
        case hostKeyUntrusted(host: String, port: Int)
        case commandFailed(String)
        case timedOut(seconds: Int)

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .connectionFailed(let message):
                return "SSH connection failed: \(message)"
            case .hostKeyUntrusted(let host, let port):
                return "The host key for \(host):\(port) is not trusted (unknown or changed key). Open a terminal session to this host once to verify and save its host key, then retry."
            case .commandFailed(let message):
                return "Command failed: \(message)"
            case .timedOut(let seconds):
                return "Command timed out after \(seconds) seconds."
            }
        }
    }

    typealias TargetAuthBuilder = @MainActor (SSHConfig) async throws -> SSHAuthenticationMethod
    typealias JumpAuthBuilder = @MainActor (SSHConfig.JumpHostConfig) async throws -> SSHAuthenticationMethod

    /// Both live clients for a session; the jump client must outlive the
    /// target client and be closed with it.
    private struct Connection {
        let client: SSHClient
        let jumpClient: SSHClient?
    }

    /// Connects to `config`'s host (directly or via its jump host), runs
    /// `command`, and returns its output. `timeout` bounds the command
    /// execution; connection setup is separately bounded by the login
    /// timeout. Custom auth builders let callers layer their own fallback
    /// policy (the MCP tool substitutes a default key for password auth);
    /// by default the config's configured auth method is used as-is.
    static func execute(
        config: SSHConfig,
        command: String,
        timeout: Int,
        logLabel: String,
        maxOutputBytes: Int = 4 * 1024 * 1024,
        buildTargetAuth: TargetAuthBuilder? = nil,
        buildJumpAuth: JumpAuthBuilder? = nil
    ) async throws -> CommandOutput {
        let timeout = max(1, timeout)
        let maxOutputBytes = max(1024, maxOutputBytes)
        let targetAuthBuilder = buildTargetAuth ?? { try await SSHConnectionHelper.buildAuthMethod(for: $0) }
        let jumpAuthBuilder = buildJumpAuth ?? { try await SSHConnectionHelper.buildAuthMethod(for: $0) }

        let connection: Connection
        do {
            if let jumpConfig = config.jumpHost {
                connection = try await connectViaJumpHost(
                    config: config,
                    jumpConfig: jumpConfig,
                    logLabel: logLabel,
                    buildTargetAuth: targetAuthBuilder,
                    buildJumpAuth: jumpAuthBuilder
                )
            } else {
                connection = Connection(
                    client: try await connectDirect(
                        config: config,
                        logLabel: logLabel,
                        buildTargetAuth: targetAuthBuilder
                    ),
                    jumpClient: nil
                )
            }
        } catch let error as ExecError {
            throw error
        } catch let failure as AuthBuilderFailure {
            // Auth builders throw caller-typed errors — pass them through.
            throw failure.underlying
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.logger.error("SSH connection failed: \(error.localizedDescription)")
            if error is HostKeyRejectedError || error is InvalidHostKey {
                throw ExecError.hostKeyUntrusted(host: config.host, port: config.port)
            }
            throw ExecError.connectionFailed(error.localizedDescription)
        }

        // SSHClient is thread-safe via its event loop but not marked
        // Sendable; boxes carry the references into the @Sendable timeout
        // and cancellation closures (see SSHCancellationBoxes.swift).
        let clientBox = CancellationSSHClientBox(connection.client)
        let jumpClientBox = connection.jumpClient.map { CancellationSSHClientBox($0) }

        func closeConnection() async {
            await closeQuietly(clientBox)
            if let jumpClientBox {
                await closeQuietly(jumpClientBox)
            }
        }

        let startTime = Date()
        do {
            // withTimeout doesn't propagate surrounding-task cancellation
            // (see AsyncTimeout.swift) — the handler closes the clients so a
            // cancelled Shortcut doesn't leave the remote command running.
            let collected = try await withTaskCancellationHandler {
                try await withTimeout(seconds: TimeInterval(timeout)) {
                    try await collectOutput(clientBox: clientBox, command: command, maxOutputBytes: maxOutputBytes)
                }
            } onCancel: {
                Task { @MainActor in
                    await closeQuietly(clientBox)
                    if let jumpClientBox {
                        await closeQuietly(jumpClientBox)
                    }
                }
            }
            // Closing the channel from onCancel can end the stream normally
            // — don't let a cancelled run fall through the success path.
            try Task.checkCancellation()
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            await closeConnection()
            return CommandOutput(
                exitCode: collected.exitCode,
                stdout: String(buffer: collected.stdout),
                stderr: String(buffer: collected.stderr),
                durationMs: durationMs,
                truncated: collected.truncated
            )
        } catch is TimeoutError {
            Self.logger.error("Command timed out after \(timeout)s")
            await closeConnection()
            throw ExecError.timedOut(seconds: timeout)
        } catch is CancellationError {
            // onCancel already closed the clients; close again is a no-op.
            await closeConnection()
            throw CancellationError()
        } catch {
            Self.logger.error("Command execution failed: \(error.localizedDescription)")
            await closeConnection()
            throw ExecError.commandFailed(error.localizedDescription)
        }
    }

    // MARK: - Output Collection

    private struct CollectedOutput: Sendable {
        /// nil when no exit status arrived before collection ended.
        let exitCode: Int?
        let stdout: ByteBuffer
        let stderr: ByteBuffer
        let truncated: Bool
    }

    /// Streams the command's output, keeping at most `maxOutputBytes` per
    /// stream. On cap breach the command channel is closed immediately —
    /// Citadel's stream has no backpressure, so a fast producer would
    /// otherwise keep queuing chunks upstream faster than a drain loop can
    /// discard them. Closing forfeits the exit status; the truncated result
    /// reports the partial output.
    private nonisolated static func collectOutput(
        clientBox: CancellationSSHClientBox,
        command: String,
        maxOutputBytes: Int
    ) async throws -> CollectedOutput {
        let (channel, stream) = try await clientBox.client.executeCommandBidirectional(command)
        var stdout = ByteBuffer()
        var stderr = ByteBuffer()
        var exitCode: Int?
        var truncated = false

        func append(_ chunk: ByteBuffer, to buffer: inout ByteBuffer) {
            let room = maxOutputBytes - buffer.readableBytes
            if chunk.readableBytes <= room {
                buffer.writeImmutableBuffer(chunk)
            } else {
                if room > 0 {
                    var partial = chunk
                    if let slice = partial.readSlice(length: room) {
                        buffer.writeImmutableBuffer(slice)
                    }
                }
                truncated = true
            }
        }

        do {
            for try await chunk in stream {
                switch chunk {
                case .stdout(let buffer):
                    append(buffer, to: &stdout)
                case .stderr(let buffer):
                    append(buffer, to: &stderr)
                case .exitStatus(let status):
                    exitCode = status
                }
                if truncated {
                    // Kill the command at the source; fire-and-forget so a
                    // parked close future can't hang collection.
                    channel.close(promise: nil)
                    break
                }
            }
        } catch let failure as SSHClient.CommandFailed {
            // Non-zero exit finishes the stream throwing; the status itself
            // was already yielded, but take it from the error to be safe.
            exitCode = failure.exitCode
        } catch {
            // A close triggered by truncation can surface as a stream error;
            // the partial output is still the result.
            if !truncated { throw error }
        }

        // A normal finish without an explicit status is success; after a
        // truncation close the status is genuinely unknown — leave it nil.
        if exitCode == nil && !truncated {
            exitCode = 0
        }
        return CollectedOutput(exitCode: exitCode, stdout: stdout, stderr: stderr, truncated: truncated)
    }

    // MARK: - Connection

    private static func connectDirect(
        config: SSHConfig,
        logLabel: String,
        buildTargetAuth: TargetAuthBuilder
    ) async throws -> SSHClient {
        let authMethod: SSHAuthenticationMethod
        do {
            authMethod = try await buildTargetAuth(config)
        } catch {
            throw AuthBuilderFailure(underlying: error)
        }

        // Pre-resolve CGNAT IPv4 and route through MPTCPBootstrap
        // (NWConnection) so Tailscale's NAT/DERP path is set up before the
        // first SYN — POSIX races this for NAT'd targets outside the home
        // network.
        let resolved = config.cachedIP ?? config.host
        let connectHost: String
        if let cgnatIP = await NetworkAddressUtils.resolveToCGNATIPv4(hostname: resolved) {
            connectHost = cgnatIP
        } else {
            connectHost = resolved
        }
        let directChannel = try await MPTCPBootstrap.connectPlainChannel(
            host: connectHost, port: config.port,
            deferReads: true
        )
        MPTCPBootstrap.armReadsWhenSSHHandlerInstalled(on: directChannel)
        var settings = SSHClientSettings(
            host: connectHost,
            port: config.port,
            authenticationMethod: { authMethod },
            // Headless strict: known/CA-signed keys pass, new or changed
            // keys reject. Keyed by the configured hostname, not the
            // resolved dial host.
            hostKeyValidator: SSHConnectionHelper.buildHostKeyValidator(
                for: config.host,
                port: config.port,
                label: logLabel,
                onValidation: nil
            )
        )
        settings.algorithms = .all
        settings.loginTimeout = SSHTimeoutConfig.citadelLoginTimeout
        settings.protocolOptions = SSHConnectionHelper.hostCertificateProtocolOptions(forHost: config.host)
        let directChannelBox = CancellationChannelBox(directChannel)
        if Task.isCancelled {
            await closeQuietly(directChannelBox)
            throw CancellationError()
        }
        do {
            // Cancellation during the handshake closes the channel so a
            // cancelled Shortcut doesn't wait out the login timeout.
            return try await withTaskCancellationHandler {
                try await SSHClient.connect(on: directChannel, settings: settings)
            } onCancel: {
                _ = directChannelBox.channel.close()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            await closeQuietly(directChannelBox)
            throw error
        }
    }

    private static func connectViaJumpHost(
        config: SSHConfig,
        jumpConfig: SSHConfig.JumpHostConfig,
        logLabel: String,
        buildTargetAuth: TargetAuthBuilder,
        buildJumpAuth: JumpAuthBuilder
    ) async throws -> Connection {
        let jumpAuth: SSHAuthenticationMethod
        do {
            jumpAuth = try await buildJumpAuth(jumpConfig)
        } catch {
            throw AuthBuilderFailure(underlying: error)
        }

        // Pre-resolve jump host to CGNAT IPv4 and route through
        // MPTCPBootstrap so the TCP setup goes via NWConnection (same
        // Tailscale-NAT rationale as the direct path).
        let jumpConnectHost: String
        if let cgnatIP = await NetworkAddressUtils.resolveToCGNATIPv4(hostname: jumpConfig.host) {
            jumpConnectHost = cgnatIP
        } else {
            jumpConnectHost = jumpConfig.host
        }
        let jumpChannel = try await MPTCPBootstrap.connectPlainChannel(
            host: jumpConnectHost, port: jumpConfig.port,
            deferReads: true
        )
        MPTCPBootstrap.armReadsWhenSSHHandlerInstalled(on: jumpChannel)
        var jumpSettings = SSHClientSettings(
            host: jumpConnectHost,
            port: jumpConfig.port,
            authenticationMethod: { jumpAuth },
            hostKeyValidator: SSHConnectionHelper.buildHostKeyValidator(
                for: jumpConfig.host,
                port: jumpConfig.port,
                label: "\(logLabel) Jump",
                onValidation: nil
            )
        )
        jumpSettings.algorithms = .all
        jumpSettings.loginTimeout = SSHTimeoutConfig.citadelLoginTimeout
        jumpSettings.protocolOptions = SSHConnectionHelper.hostCertificateProtocolOptions(forHost: jumpConfig.host)
        let jumpChannelBox = CancellationChannelBox(jumpChannel)
        if Task.isCancelled {
            await closeQuietly(jumpChannelBox)
            throw CancellationError()
        }
        let jumpClient: SSHClient
        do {
            // Cancellation during the handshake closes the channel so a
            // cancelled Shortcut doesn't wait out the login timeout.
            jumpClient = try await withTaskCancellationHandler {
                try await SSHClient.connect(on: jumpChannel, settings: jumpSettings)
            } onCancel: {
                _ = jumpChannelBox.channel.close()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            await closeQuietly(jumpChannelBox)
            // Attribute a rejected key to the jump host, not the target the
            // outer catch would name.
            if error is HostKeyRejectedError || error is InvalidHostKey {
                throw ExecError.hostKeyUntrusted(host: jumpConfig.host, port: jumpConfig.port)
            }
            throw error
        }

        do {
            let targetAuth: SSHAuthenticationMethod
            do {
                targetAuth = try await buildTargetAuth(config)
            } catch {
                throw AuthBuilderFailure(underlying: error)
            }

            let targetHost = config.cachedIP ?? config.host
            var targetSettings = SSHClientSettings(
                host: targetHost,
                port: config.port,
                authenticationMethod: { targetAuth },
                hostKeyValidator: SSHConnectionHelper.buildHostKeyValidator(
                    for: config.host,
                    port: config.port,
                    label: logLabel,
                    onValidation: nil
                )
            )
            targetSettings.algorithms = .all
            targetSettings.loginTimeout = SSHTimeoutConfig.citadelLoginTimeout
            targetSettings.protocolOptions = SSHConnectionHelper.hostCertificateProtocolOptions(forHost: config.host)

            // Closing the jump client on cancel cascades to the DirectTCPIP
            // child channel carrying the target handshake.
            let jumpClientBox = CancellationSSHClientBox(jumpClient)
            let targetClient = try await withTaskCancellationHandler {
                try await jumpClient.jump(to: targetSettings)
            } onCancel: {
                Task { try? await jumpClientBox.client.close() }
            }
            return Connection(client: targetClient, jumpClient: jumpClient)
        } catch {
            await closeQuietly(CancellationSSHClientBox(jumpClient))
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    // MARK: - Bounded Cleanup

    private static func closeQuietly(_ box: CancellationSSHClientBox) async {
        try? await withTimeout(seconds: closeTimeoutSeconds) {
            try? await box.client.close()
        }
    }

    private static func closeQuietly(_ box: CancellationChannelBox) async {
        try? await withTimeout(seconds: closeTimeoutSeconds) {
            try? await box.channel.close()
        }
    }
}
