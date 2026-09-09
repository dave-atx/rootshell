//
//  SSHConnectionHelper.swift
//  rootshell
//
//  Shared SSH connection utilities: auth method building, host key validation,
//  and SSH connection with jump host / .local / CGNAT support.
//

import Foundation
import Citadel
import NIOSSH
import NIOCore
import NIOTransportServices
import os.log

/// Shared helpers for building SSH auth methods, host key validators, and connections.
/// Used by SSHCopyID, SCPTransfer, SFTPSession, and other SSH-based features.
@MainActor
enum SSHConnectionHelper {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "SSHConnectionHelper")

    /// Hard cap on the NIO TCP-connect wait. Matches CitadelSSHSession's
    /// identical constant (see `45382c5a` for the rationale: 30s accommodates
    /// userspace VPN path setup like Tailscale WireGuard peer wake-up and
    /// DERP-relay fallback). With NIOTSConnectionBootstrap, NWConnection
    /// handles its own connect-timeout internally; this cap is defense in
    /// depth and an upper bound on the cancellation-blackout window for the
    /// pre-Channel phase of `bootstrap.connect(...).get()`.
    private static let tcpConnectTimeoutCap: TimeAmount = .seconds(30)

    /// Bound on Channel.close() / SSHClient.close() awaits. NIO's close future
    /// can park indefinitely waiting on a TCP teardown ACK that never arrives
    /// after the peer/network drops. Matches CitadelSSHSession.cleanupTimeoutSeconds.
    private static let closeTimeoutSeconds: TimeInterval = 2.0

    private static var publicKeyAuthMode: NIOSSHUserAuthenticationOffer.Offer.PrivateKey.AuthenticationMode {
        SettingsStore.shared.value(Settings.Connections.publicKeyAuthProbe) ? .probeThenSign : .signedRequest
    }

    // MARK: - PTY Defaults

    /// OpenSSH-compatible default terminal modes for `pty-req`.
    ///
    /// Mirrors `ssh_tty_make_modes()` in OpenSSH's `ttymodes.c` with the canonical cooked-mode
    /// values used when there is no local termios to read from. Strict servers (notably MikroTik
    /// RouterOS / ROSSSH) gate their CLI banner on seeing explicit `ECHO`, `ICANON`, and `OPOST`
    /// here; sending an empty modes blob causes them to start the shell but never emit the prompt.
    /// RFC 4254 §8 also tells the client to "put any modes it knows about in the stream."
    nonisolated static let defaultPTYTerminalModes: SSHTerminalModes = SSHTerminalModes([
        .VINTR: 3,
        .VQUIT: 28,
        .VERASE: 127,
        .VKILL: 21,
        .VEOF: 4,
        .VEOL: 0,
        .VEOL2: 0,
        .VSTART: 17,
        .VSTOP: 19,
        .VSUSP: 26,
        .VREPRINT: 18,
        .VWERASE: 23,
        .VLNEXT: 22,
        .ISIG: 1,
        .ICANON: 1,
        .ECHO: 1,
        .ECHOE: 1,
        .ECHOK: 1,
        .ECHONL: 0,
        .NOFLSH: 0,
        .IEXTEN: 1,
        .ECHOCTL: 1,
        .ECHOKE: 1,
        .ICRNL: 1,
        .IXON: 1,
        .IXANY: 0,
        .IXOFF: 0,
        .IMAXBEL: 1,
        .OPOST: 1,
        .ONLCR: 1,
        .CS8: 1,
        .TTY_OP_ISPEED: 38400,
        .TTY_OP_OSPEED: 38400,
    ])

    // MARK: - Auth Method Building

    /// Build a Citadel SSHAuthenticationMethod from SSHConfig.AuthMethod.
    ///
    /// `async` so encrypted-key parsing hops off the MainActor via the
    /// async ``SSHKeyManager/loadPrivateKey(id:)`` overload — without
    /// this the bcrypt KDF for password-protected keys runs on the UI
    /// thread for every new SSH connection.
    static func buildAuthMethod(
        username: String,
        authMethod: SSHConfig.AuthMethod,
        sessionName: String = "",
        onKeyboardInteractiveChallenge: ((KeyboardInteractiveChallenge) async -> [String]?)? = nil
    ) async throws -> SSHAuthenticationMethod {
        // When an interactive UI is wired, route every method through a single
        // composing delegate so keyboard-interactive (2FA/OTP/PAM) is reachable
        // even under password/key auth.
        if let onChallenge = onKeyboardInteractiveChallenge {
            let inner = try await makeInnerOfferDelegate(username: username, authMethod: authMethod)
            var autoAnswer: String? = nil
            if case .password(let password) = authMethod { autoAnswer = password }
            return .custom(KeyboardInteractiveAuthDelegate(
                username: username,
                sessionName: sessionName,
                inner: inner,
                autoAnswerPassword: autoAnswer,
                onChallenge: onChallenge
            ))
        }

        // No interactive UI: preserve the original, non-keyboard-interactive behavior.
        switch authMethod {
        case .password(let password):
            return .passwordBased(username: username, password: password)

        case .key(let keyID):
            // OpenPubkey keys: renew the PK-token certificate silently if the
            // ID token is (nearly) expired. No-op for ordinary keys.
            try await OpenPubkeyManager.shared.ensureFreshCertificate(forKeyID: keyID)
            let keyVariant = try await SSHKeyManager.shared.loadPrivateKey(id: keyID)
            let certifiedKey = SSHKeyManager.shared.usableCertifiedKey(forKeyID: keyID, username: username)

            // Citadel's .rsa shortcut cannot carry a certificate; keep it only for
            // the plain non-probe RSA path so existing behavior is unchanged.
            if certifiedKey == nil, case .rsa(let rsaKey) = keyVariant, publicKeyAuthMode != .probeThenSign {
                return .rsa(username: username, privateKey: rsaKey)
            }

            let candidate = SSHAuthKeyCandidate(variant: keyVariant, certifiedKey: certifiedKey)
            return .custom(NIOKeyAuthDelegate(
                username: username,
                privateKey: candidate.nioPrivateKey,
                legacyRSAKey: candidate.legacyRSAAuthenticationKey,
                certifiedKey: certifiedKey,
                publicKeyAuthMode: publicKeyAuthMode
            ))

        case .savedPassword:
            throw SSHError.invalidConfiguration("Saved password must be resolved before connection")

        case .none:
            return .custom(NoneAuthDelegate(username: username))

        case .keyboardInteractive:
            // Keyboard-interactive without an interactive UI cannot answer prompts.
            // Offer it but cancel any challenge so auth fails cleanly rather than hanging.
            return .custom(KeyboardInteractiveAuthDelegate(
                username: username, sessionName: sessionName, inner: nil,
                autoAnswerPassword: nil, onChallenge: { _ in nil }
            ))

        case .unknown(let rawType):
            throw SSHError.invalidConfiguration("Unsupported authentication method '\(rawType)'. Update the app to use this connection.")
        }
    }

    /// Build the primary (inner) offer delegate for the composing
    /// keyboard-interactive delegate. Returns nil for the explicit
    /// keyboard-interactive method (the composing delegate offers it directly).
    private static func makeInnerOfferDelegate(
        username: String,
        authMethod: SSHConfig.AuthMethod
    ) async throws -> NIOSSHClientUserAuthenticationDelegate? {
        switch authMethod {
        case .password(let password):
            // Route password through a custom delegate (not Citadel's `.user`
            // `.passwordBased`) so the keyboard-interactive challenge can be
            // forwarded to the same delegate object.
            return PasswordAuthDelegate(username: username, password: password)
        case .key(let keyID):
            try await OpenPubkeyManager.shared.ensureFreshCertificate(forKeyID: keyID)
            let keyVariant = try await SSHKeyManager.shared.loadPrivateKey(id: keyID)
            return makeKeyDelegate(username: username, keyID: keyID, variant: keyVariant)
        case .savedPassword:
            throw SSHError.invalidConfiguration("Saved password must be resolved before connection")
        case .none:
            return NoneAuthDelegate(username: username)
        case .keyboardInteractive:
            return nil
        case .unknown(let rawType):
            throw SSHError.invalidConfiguration("Unsupported authentication method '\(rawType)'. Update the app to use this connection.")
        }
    }

    /// Build a single-key offer delegate for any supported key variant.
    /// When the key has a usable certificate, it is offered before the plain key.
    private static func makeKeyDelegate(
        username: String,
        keyID: UUID,
        variant: SSHPrivateKeyVariant
    ) -> NIOSSHClientUserAuthenticationDelegate {
        let certifiedKey = SSHKeyManager.shared.usableCertifiedKey(forKeyID: keyID, username: username)
        let candidate = SSHAuthKeyCandidate(variant: variant, certifiedKey: certifiedKey)
        return NIOKeyAuthDelegate(
            username: username,
            privateKey: candidate.nioPrivateKey,
            legacyRSAKey: candidate.legacyRSAAuthenticationKey,
            certifiedKey: certifiedKey,
            publicKeyAuthMode: publicKeyAuthMode
        )
    }

    /// Build auth method from SSHConfig, with multi-key fallback support
    static func buildAuthMethod(
        for config: SSHConfig,
        sessionName: String? = nil,
        onKeyboardInteractiveChallenge: ((KeyboardInteractiveChallenge) async -> [String]?)? = nil
    ) async throws -> SSHAuthenticationMethod {
        let label = sessionName ?? config.displayName
        if case .key(let keyID) = config.authMethod,
           let fallbackIDs = config.fallbackKeyIDs, !fallbackIDs.isEmpty {
            return try await buildMultiKeyAuth(
                username: config.username,
                primaryKeyID: keyID,
                fallbackKeyIDs: fallbackIDs,
                sessionName: label,
                onKeyboardInteractiveChallenge: onKeyboardInteractiveChallenge
            )
        }
        return try await buildAuthMethod(
            username: config.username,
            authMethod: config.authMethod,
            sessionName: label,
            onKeyboardInteractiveChallenge: onKeyboardInteractiveChallenge
        )
    }

    /// Build auth method from JumpHostConfig, with multi-key fallback support
    static func buildAuthMethod(
        for jumpConfig: SSHConfig.JumpHostConfig,
        sessionName: String? = nil,
        onKeyboardInteractiveChallenge: ((KeyboardInteractiveChallenge) async -> [String]?)? = nil
    ) async throws -> SSHAuthenticationMethod {
        let label = sessionName ?? "[Jump Host] \(jumpConfig.displayName)"
        if case .key(let keyID) = jumpConfig.authMethod,
           let fallbackIDs = jumpConfig.fallbackKeyIDs, !fallbackIDs.isEmpty {
            return try await buildMultiKeyAuth(
                username: jumpConfig.username,
                primaryKeyID: keyID,
                fallbackKeyIDs: fallbackIDs,
                sessionName: label,
                onKeyboardInteractiveChallenge: onKeyboardInteractiveChallenge
            )
        }
        return try await buildAuthMethod(
            username: jumpConfig.username,
            authMethod: jumpConfig.authMethod,
            sessionName: label,
            onKeyboardInteractiveChallenge: onKeyboardInteractiveChallenge
        )
    }

    /// Build a multi-key auth method that tries primary key then fallbacks in order
    private static func buildMultiKeyAuth(
        username: String,
        primaryKeyID: UUID,
        fallbackKeyIDs: [UUID],
        sessionName: String = "",
        onKeyboardInteractiveChallenge: ((KeyboardInteractiveChallenge) async -> [String]?)? = nil
    ) async throws -> SSHAuthenticationMethod {
        var keysToTry: [SSHAuthKeyCandidate] = []

        try await OpenPubkeyManager.shared.ensureFreshCertificate(forKeyID: primaryKeyID)
        let primaryKey = try await SSHKeyManager.shared.loadPrivateKey(id: primaryKeyID)
        keysToTry.append(SSHAuthKeyCandidate(
            variant: primaryKey,
            certifiedKey: SSHKeyManager.shared.usableCertifiedKey(forKeyID: primaryKeyID, username: username)
        ))

        for fallbackID in fallbackKeyIDs {
            do {
                // A stale OpenPubkey fallback shouldn't kill the connection;
                // it just offers the plain key (which the server may reject).
                try? await OpenPubkeyManager.shared.ensureFreshCertificate(forKeyID: fallbackID)
                let fallbackKey = try await SSHKeyManager.shared.loadPrivateKey(id: fallbackID)
                keysToTry.append(SSHAuthKeyCandidate(
                    variant: fallbackKey,
                    certifiedKey: SSHKeyManager.shared.usableCertifiedKey(forKeyID: fallbackID, username: username)
                ))
            } catch {
                logger.warning("Failed to load fallback key \(fallbackID.uuidString): \(error.localizedDescription)")
            }
        }

        let multiKey = MultiKeyAuthDelegate(username: username, candidates: keysToTry, publicKeyAuthMode: publicKeyAuthMode)
        guard let onChallenge = onKeyboardInteractiveChallenge else {
            return .custom(multiKey)
        }
        // Wrap so the server can demand keyboard-interactive after the key (2FA).
        return .custom(KeyboardInteractiveAuthDelegate(
            username: username,
            sessionName: sessionName,
            inner: multiKey,
            autoAnswerPassword: nil,
            onChallenge: onChallenge
        ))
    }

    // MARK: - Host Key Validation

    /// Build a host key validator using CitadelHostKeyValidatorDelegate + KnownHostsManager.
    ///
    /// Resolves the trusted host CAs that apply to `host` (from `HostCAManager`)
    /// and hands them to the delegate, so a server presenting a CA-signed host
    /// certificate validates without prompting. CA validation is wired for every
    /// caller here; the matching connection must also advertise host-certificate
    /// algorithms (see `hostCertificateProtocolOptions(forHost:)`) for the server
    /// to actually send a certificate.
    static func buildHostKeyValidator(
        for host: String,
        port: Int,
        label: String? = nil,
        onValidation: ((HostKeyValidationRequest) async -> HostKeyValidationResult)?
    ) -> SSHHostKeyValidator {
        let trustedCAKeys = HostCAManager.shared.trustedCAKeys(forHost: host)
        let delegate = CitadelHostKeyValidatorDelegate(
            hostname: host,
            port: port,
            label: label,
            trustedCAKeys: trustedCAKeys,
            onValidation: onValidation
        )
        return .custom(delegate)
    }

    /// Protocol options that advertise OpenSSH host-certificate algorithms when a
    /// configured CA applies to `host`, so a certificate-capable server presents a
    /// host certificate. Empty when no CA matches, leaving negotiation unchanged.
    static func hostCertificateProtocolOptions(forHost host: String) -> Set<SSHProtocolOption> {
        HostCAManager.shared.hasCA(forHost: host) ? [.advertiseHostCertificateAlgorithms] : []
    }

    // MARK: - SSH Connection

    /// Connect to an SSH host with full support for jump hosts, .local resolution, and CGNAT detection.
    /// - Parameters:
    ///   - config: The SSH configuration
    ///   - onHostKeyValidation: Callback for host key validation prompts
    ///   - onKeyboardInteractiveChallenge: Callback for keyboard-interactive (RFC 4256)
    ///     prompts (2FA/OTP/PAM). Pass nil for non-interactive callers — keyboard-interactive
    ///     auth will then fail rather than prompt.
    /// - Returns: A tuple of (target SSH client, optional jump client for cleanup)
    static func connect(
        config: SSHConfig,
        onHostKeyValidation: ((HostKeyValidationRequest) async -> HostKeyValidationResult)?,
        onKeyboardInteractiveChallenge: ((KeyboardInteractiveChallenge) async -> [String]?)? = nil
    ) async throws -> (client: SSHClient, jumpClient: SSHClient?) {
        logger.info("Connecting to \(config.host):\(config.port)")

        if let jumpConfig = config.jumpHost {
            // Connect via jump host
            logger.info("Connecting via jump host: \(jumpConfig.host)")

            let jumpAuth = try await buildAuthMethod(for: jumpConfig, onKeyboardInteractiveChallenge: onKeyboardInteractiveChallenge)
            let jumpHostKeyValidator = buildHostKeyValidator(
                for: jumpConfig.host, port: jumpConfig.port, label: "[Jump Host]", onValidation: onHostKeyValidation
            )

            // Check for CGNAT on jump host
            let jumpConnectHost: String
            if let cgnatIP = await NetworkAddressUtils.resolveToCGNATIPv4(hostname: jumpConfig.host) {
                logger.info("Detected CGNAT for jump host, forcing IPv4: \(cgnatIP)")
                jumpConnectHost = cgnatIP
                SSHDebugLogger.shared.event("CONN", "jump resolve mode=cgnat ip=\(cgnatIP)")
            } else {
                jumpConnectHost = jumpConfig.host
                SSHDebugLogger.shared.event("CONN", "jump resolve mode=fallback host=\(jumpConfig.host)")
            }

            // Always route through MPTCPBootstrap.connectPlainChannel so we
            // hold a raw Channel handle in both MPTCP and non-MPTCP modes.
            // Citadel's `SSHClient.connect(to:)` hides the channel internally
            // and `EventLoopFuture.get()` ignores Swift Task cancellation, so
            // Ctrl-C during SSH handshake/auth would otherwise leak the
            // connection for the full loginTimeout. With a channel in hand,
            // the cancellation handler below can close it and fail the
            // connect future within an event-loop hop.
            let jumpChannel = try await MPTCPBootstrap.connectPlainChannel(
                host: jumpConnectHost,
                port: jumpConfig.port,
                timeout: tcpConnectTimeoutCap,
                deferReads: true
            )
            MPTCPBootstrap.armReadsWhenSSHHandlerInstalled(on: jumpChannel)
            if Task.isCancelled {
                try? await jumpChannel.close()
                throw CancellationError()
            }
            var jumpSettings = SSHClientSettings(
                host: jumpConnectHost,
                port: jumpConfig.port,
                authenticationMethod: { jumpAuth },
                hostKeyValidator: jumpHostKeyValidator
            )
            jumpSettings.algorithms = .all
            jumpSettings.loginTimeout = SSHTimeoutConfig.citadelLoginTimeout
            jumpSettings.protocolOptions = hostCertificateProtocolOptions(forHost: jumpConfig.host)
            let jumpChannelBox = CancellationChannelBox(jumpChannel)
            let jumpClient: SSHClient
            do {
                jumpClient = try await withTaskCancellationHandler {
                    try await SSHClient.connect(on: jumpChannel, settings: jumpSettings)
                } onCancel: {
                    _ = jumpChannelBox.channel.close()
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                // Non-cancellation failure (auth, host-key reject, KEX, etc.).
                // Citadel's connect(on:settings:) does NOT close the channel on
                // failure — ownership only transfers on success — so we still
                // own this caller-created channel and must close it. Bounded:
                // a half-dead channel can park NIO's close future indefinitely.
                try? await withTimeout(seconds: Self.closeTimeoutSeconds) {
                    try? await jumpChannel.close()
                }
                throw error
            }
            // Ownership tracking: anything between here and the final tuple
            // return that throws (or sees Task.isCancelled) must close the
            // jump client. `buildAuthMethod(for: config)` below can throw
            // (keychain/biometric/key-load failure) outside the jump(to:)
            // do/catch, leaving jumpClient leaked without this safety net.
            var jumpClientOwned: SSHClient? = jumpClient
            defer {
                if let owned = jumpClientOwned {
                    // Fire-and-forget bounded close — don't block the throw.
                    Task {
                        try? await withTimeout(seconds: Self.closeTimeoutSeconds) {
                            try? await owned.close()
                        }
                    }
                }
            }

            if Task.isCancelled {
                throw CancellationError()
            }

            // Jump to target — can throw before reaching the do/catch below.
            let targetAuth = try await buildAuthMethod(for: config, onKeyboardInteractiveChallenge: onKeyboardInteractiveChallenge)
            let targetHostKeyValidator = buildHostKeyValidator(
                for: config.host, port: config.port, label: "[Target]", onValidation: onHostKeyValidation
            )

            var targetSettings = SSHClientSettings(
                host: config.host,
                port: config.port,
                authenticationMethod: { targetAuth },
                hostKeyValidator: targetHostKeyValidator
            )
            targetSettings.algorithms = .all
            targetSettings.loginTimeout = SSHTimeoutConfig.citadelLoginTimeout
            targetSettings.protocolOptions = hostCertificateProtocolOptions(forHost: config.host)

            // jump(to:) awaits a DirectTCPIP child channel's handshake — same
            // cancellation gap. Closing the jump client cascades to the child.
            let jumpClientBox = CancellationSSHClientBox(jumpClient)
            let finalClient: SSHClient
            do {
                finalClient = try await withTaskCancellationHandler {
                    try await jumpClient.jump(to: targetSettings)
                } onCancel: {
                    Task { try? await jumpClientBox.client.close() }
                }
            } catch {
                // If we got here because of cancellation, the jump client has
                // already been closed by onCancel — clear ownership so the
                // defer doesn't try to close it again.
                if Task.isCancelled {
                    jumpClientOwned = nil
                    throw CancellationError()
                }
                // Non-cancellation failure — defer will close jumpClient.
                throw error
            }

            // Post-success cancellation race: matches the direct branch (and
            // CitadelSSHSession's post-jump check). If cancellation won
            // between jump(to:) returning and us reaching here, close the
            // freshly-connected target and let defer close the jump client.
            if Task.isCancelled {
                try? await withTimeout(seconds: Self.closeTimeoutSeconds) {
                    try? await finalClient.close()
                }
                throw CancellationError()
            }

            // Success: ownership of jumpClient transfers to the caller via
            // the tuple return. Clear the defer's close.
            jumpClientOwned = nil
            return (client: finalClient, jumpClient: jumpClient)
        } else {
            // Direct connection
            let connectHost: String

            if config.host.hasSuffix(".local") {
                if let ipv4 = await NetworkAddressUtils.resolveToRoutableIPv4(hostname: config.host) {
                    logger.info("Resolved \(config.host) to IPv4: \(ipv4)")
                    connectHost = ipv4
                    SSHDebugLogger.shared.event("CONN", "resolve mode=local ip=\(ipv4)")
                } else if let cachedIP = config.cachedIP {
                    logger.info("Using cached IP for \(config.host): \(cachedIP)")
                    connectHost = cachedIP
                    SSHDebugLogger.shared.event("CONN", "resolve mode=cached ip=\(cachedIP)")
                } else {
                    connectHost = config.host
                    SSHDebugLogger.shared.event("CONN", "resolve mode=fallback host=\(config.host)")
                }
            } else if let cgnatIP = await NetworkAddressUtils.resolveToCGNATIPv4(hostname: config.host) {
                logger.info("Detected CGNAT, forcing IPv4: \(cgnatIP)")
                connectHost = cgnatIP
                SSHDebugLogger.shared.event("CONN", "resolve mode=cgnat ip=\(cgnatIP)")
            } else {
                connectHost = config.host
                SSHDebugLogger.shared.event("CONN", "resolve mode=fallback host=\(config.host)")
            }

            let auth = try await buildAuthMethod(for: config, onKeyboardInteractiveChallenge: onKeyboardInteractiveChallenge)
            let hostKeyValidator = buildHostKeyValidator(
                for: config.host, port: config.port, onValidation: onHostKeyValidation
            )

            // See jump branch above for the cancellation rationale — always
            // route through MPTCPBootstrap.connectPlainChannel so we have a
            // Channel handle for both MPTCP and non-MPTCP.
            let directChannel = try await MPTCPBootstrap.connectPlainChannel(
                host: connectHost,
                port: config.port,
                timeout: tcpConnectTimeoutCap,
                deferReads: true
            )
            MPTCPBootstrap.armReadsWhenSSHHandlerInstalled(on: directChannel)
            if Task.isCancelled {
                try? await directChannel.close()
                throw CancellationError()
            }
            var settings = SSHClientSettings(
                host: connectHost,
                port: config.port,
                authenticationMethod: { auth },
                hostKeyValidator: hostKeyValidator
            )
            settings.algorithms = .all
            settings.loginTimeout = SSHTimeoutConfig.citadelLoginTimeout
            settings.protocolOptions = hostCertificateProtocolOptions(forHost: config.host)
            let directChannelBox = CancellationChannelBox(directChannel)
            let client: SSHClient
            do {
                client = try await withTaskCancellationHandler {
                    try await SSHClient.connect(on: directChannel, settings: settings)
                } onCancel: {
                    _ = directChannelBox.channel.close()
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                // Citadel does not close the channel on failure paths — see
                // jump branch above for the rationale.
                try? await withTimeout(seconds: Self.closeTimeoutSeconds) {
                    try? await directChannel.close()
                }
                throw error
            }
            if Task.isCancelled {
                try? await withTimeout(seconds: Self.closeTimeoutSeconds) {
                    try? await client.close()
                }
                throw CancellationError()
            }

            return (client: client, jumpClient: nil)
        }
    }
}
