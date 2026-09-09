//
//  MPTCPBootstrap.swift
//  rootshell
//
//  Network.framework-backed TCP bootstrap for SSH connections, with optional
//  Multipath TCP. Every SSH TCP connect goes through NIOTSConnectionBootstrap
//  (NWConnection under the hood) so we get VPN on-demand triggering and
//  VPN-scoped path evaluation — necessary for Tailscale `.ts.net` and any
//  other on-demand NetworkExtension VPN where POSIX `connect()` to the
//  CGNAT IPv4 is racy against WireGuard peer wake-up. The "MPTCP" name is
//  retained for historical continuity; the user-facing toggle only controls
//  whether `.withMultipath(.interactive)` is appended.
//

import Foundation
import Network
import NIOCore
import NIOSSH
import NIOTransportServices
import os.log

enum MPTCPBootstrap {
    private static let logger = Logger(subsystem: "com.rootshell", category: "MPTCPBootstrap")

    /// Shared event loop group for all SSH connections.
    /// Must be kept alive for the lifetime of any channels created on it.
    ///
    /// `loopCount` is bumped above the default of 1: NIOSSH's
    /// `NIOSSHPrivateKeyProtocol.signature(for:)` is a synchronous API,
    /// and the YubiKey / Apple-FIDO2 bridges in
    /// `YubiKeyNIOSSHPrivateKey` and `AppleFIDO2NIOSSHPrivateKey`
    /// translate that into a `DispatchSemaphore.wait()` while the
    /// hardware-token / Face-ID prompt is on screen. With a
    /// single-loop group, that wait stalls the event loop for the
    /// duration of the prompt, freezing every other live SSH session
    /// (Citadel keep-alives, in-flight channel reads, the lot).
    /// Spreading sessions across multiple loops bounds the blast
    /// radius: only sessions that happen to land on the blocked loop
    /// stall, others continue to drive their channels normally.
    private static let tsEventLoopGroup: NIOTSEventLoopGroup = {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let loopCount = max(2, min(cores, 4))
        return NIOTSEventLoopGroup(loopCount: loopCount)
    }()

    static var isEnabled: Bool {
        SettingsStore.shared.value(Settings.Roam.multipathTCP)
    }

    private static var shouldForceIPv4: Bool {
        SettingsStore.shared.value(Settings.Connections.forceIPv4)
    }

    private static func isIPv6Literal(_ host: String) -> Bool {
        host.contains(":")
    }

    /// Create a pre-connected channel suitable for passing to SSHClient.connect(on:).
    /// No SSH handlers are added — Citadel adds those itself.
    ///
    /// Callers are responsible for pre-resolving CGNAT/`.local` hostnames to an
    /// IPv4 literal before invoking this function (see CitadelSSHSession and
    /// SSHConnectionHelper). Passing an IP literal disables NWConnection's
    /// Happy Eyeballs v2, which is what we want — Mosh's UDP hole-puncher binds
    /// its local socket to the same address family as the SSH session, so a
    /// silent IPv6-ULA preference here would regress Mosh-over-Tailscale.
    ///
    /// Pass `deferReads: true` when the caller installs its pipeline handlers
    /// *after* this returns, which is every SSH caller: see `armReadsWhenSSHHandlerInstalled`
    /// for why that is otherwise a silent, fatal race.
    static func connectPlainChannel(
        host: String,
        port: Int,
        timeout: TimeAmount = .seconds(30),
        deferReads: Bool = false
    ) async throws -> Channel {
        var bootstrap = NIOTSConnectionBootstrap(group: tsEventLoopGroup)
            .connectTimeout(timeout)
        if deferReads {
            // Applied before the channel is registered or connected
            // (NIOTSConnectionBootstrap.connect applies channel options, then
            // the initializer, then register, then connect), so `becomeActive0`'s
            // `readIfNeeded0()` is a no-op and not one byte is read until
            // `armReadsWhenSSHHandlerInstalled` re-enables it.
            bootstrap = bootstrap.channelOption(ChannelOptions.autoRead, value: false)
        }
        let mode: String
        if isEnabled {
            bootstrap = bootstrap.withMultipath(.interactive)
            mode = "niots+multipath"
        } else {
            mode = "niots"
        }
        if shouldForceIPv4 && !isIPv6Literal(host) {
            bootstrap = bootstrap.configureNWParameters { parameters in
                if let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                    ipOptions.version = .v4
                }
            }
        }
        logger.info("\(mode) connect \(host):\(port) timeout=\(timeout.nanoseconds / 1_000_000_000)s")
        let channel = try await bootstrap.connect(host: host, port: port).get()
        let local = channel.localAddress?.description ?? "?"
        let remote = channel.remoteAddress?.description ?? "?"
        logger.info("\(mode) connected local=\(local) remote=\(remote)")
        return channel
    }

    /// Start reading on a channel connected with `deferReads: true`, once the
    /// SSH handlers are in its pipeline. Fire-and-forget; runs on the channel's
    /// own event loop.
    ///
    /// A channel from `NIOTSConnectionBootstrap` is already active by the time
    /// `connect` returns: `becomeActive0` succeeds the connect promise and then
    /// calls `readIfNeeded0()`, so under the default `autoRead` the first read
    /// is issued before the caller can install a single handler. Whatever the
    /// server has already said is then fired down an empty pipeline and dropped
    /// at `StateManagedNWConnectionChannel.channelRead0`, whose body is
    /// literally "drop the data, do nothing".
    ///
    /// For SSH that is fatal and silent. OpenSSH sends its banner and KEXINIT
    /// unprompted, within ~20ms on a local link, and Citadel installs
    /// `NIOSSHHandler`/`ClientHandshakeHandler` asynchronously from inside
    /// `SSHClient.connect(on:settings:)`. Lose that race and the banner is gone
    /// for good — `NIOSSHHandler` builds its parser in `init`, so there is no
    /// replay. The client then writes its own identification string, the server
    /// has nothing left to send, and both ends wait for each other until
    /// `loginTimeout` (300s here). Observed on loopback as an indefinite hang
    /// with the socket ESTABLISHED, 2458 bytes received and 23 sent.
    ///
    /// Citadel exposes no hook for "handlers are installed", so poll the
    /// pipeline on the event loop. Each check is a walk of a pipeline a few
    /// entries long and costs nothing next to a network round trip. Setting
    /// `autoRead` back to true issues the first read immediately — NIOTS's
    /// `setOption0` calls `readIfNeeded0()` — so nothing is missed.
    ///
    /// If the handler never appears the reads are armed anyway at `limit`,
    /// leaving such a caller with exactly the behaviour it had before this
    /// option existed rather than a deterministic hang.
    nonisolated static func armReadsWhenSSHHandlerInstalled(
        on channel: Channel,
        within limit: TimeAmount = .seconds(10)
    ) {
        let deadline = NIODeadline.now() + limit
        channel.eventLoop.scheduleRepeatedTask(initialDelay: .zero, delay: .milliseconds(1)) { task in
            guard channel.isActive else {
                task.cancel()
                return
            }
            let installed = (try? channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)) != nil
            let expired = NIODeadline.now() >= deadline
            guard installed || expired else { return }
            task.cancel()
            if !installed {
                logger.error("arming reads after \(limit.nanoseconds / 1_000_000)ms without an SSH handler")
            }
            channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { error in
                logger.error("failed to arm reads: \(String(describing: error))")
            }
        }
    }
}
