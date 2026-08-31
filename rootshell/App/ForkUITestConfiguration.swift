//
//  ForkUITestConfiguration.swift
//  rootshell
//
//  Fork-only seams for the local zmx XCUITest runner. This file is deliberately
//  kept out of the upstream product contract: every behavior below is inert
//  unless a Debug build is launched with the explicit test argument.
//

import Foundation
import SwiftUI
import UIKit
import os

enum ForkUITestConfiguration {
    /// The opt-in switch is intentionally an argument, rather than a persisted
    /// preference. A test runner must opt in on every launch.
    static let launchArgument = "-rootshell-zmx-ui-test"
    private static let socketDirectoryArgument = "-rootshell-zmx-ui-test-socket-directory"

    private static let didActivateKey = OSAllocatedUnfairLock(initialState: false)
    private static let sterileHomeDirectoryKey = OSAllocatedUnfairLock(initialState: URL?.none)
    private static let helperPIDFileName = "rootshell-helper.pid"

    /// Release builds can contain the references to this helper, but can never
    /// activate it. The explicit DEBUG gate is part of the safety boundary.
    static var isEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains(launchArgument)
        #else
        return false
        #endif
    }

    /// The per-launch shell home used by the disposable UI-test app and its
    /// helper. It is deliberately derived from the already validated socket
    /// directory, never from the real user home.
    static var sterileHomeDirectory: URL? {
        sterileHomeDirectoryKey.withLock { $0 }
    }

    /// Documents-equivalent storage for the disposable Catalyst launch.
    /// `FileManager.urls(for: .documentDirectory, ...)` resolves to the
    /// user's macOS Documents folder under Catalyst, so it cannot be used by
    /// fork tests even when the app's own sandbox is otherwise isolated.
    /// The emergency path remains private/tmp-only if setup failed: a test
    /// launch must never fall back to the real Documents directory.
    static var documentsDirectoryURL: URL {
        if isEnabled {
            let home = sterileHomeDirectory
                ?? URL(fileURLWithPath: "/private/tmp/rootshell-zmx-xcui-uninitialized/home", isDirectory: true)
            return home.appendingPathComponent("Documents", isDirectory: true)
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Process home used by Catalyst's PTY/config paths. This has the same
    /// no-real-home guarantee as `documentsDirectoryURL` even if a malformed
    /// test invocation omitted the socket-directory argument.
    static var processHomeDirectoryURL: URL {
        if isEnabled {
            return sterileHomeDirectory
                ?? URL(fileURLWithPath: "/private/tmp/rootshell-zmx-xcui-uninitialized/home", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// Records the helper owned by this disposable launch. The runner uses this
    /// marker only after independently confirming the process command line
    /// still names this exact socket directory, so an interrupted XCTest run
    /// can never kill a production helper or a helper from another run.
    static func recordLaunchedHelper(pid: pid_t) {
        guard isEnabled, pid > 0, let directory = AppGroupHelper.overrideContainerURL else { return }
        let marker = directory.appendingPathComponent(helperPIDFileName, isDirectory: false)
        do {
            try Data("\(pid)\n".utf8).write(to: marker, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        } catch {
            // The app's regular lifecycle cleanup still owns this helper. The
            // marker is a best-effort crash/interruption backstop for tests.
        }
    }

    static func clearLaunchedHelper(pid: pid_t) {
        guard isEnabled, pid > 0, let directory = AppGroupHelper.overrideContainerURL else { return }
        let marker = directory.appendingPathComponent(helperPIDFileName, isDirectory: false)
        guard let recorded = try? String(contentsOf: marker, encoding: .utf8),
              recorded.trimmingCharacters(in: .whitespacesAndNewlines) == String(pid) else {
            return
        }
        try? FileManager.default.removeItem(at: marker)
    }

    /// Installs only volatile argument-domain values. This gives test launches
    /// deterministic settings without changing the user's persisted defaults.
    /// Call before any SwiftUI scene or settings object is constructed.
    static func activateIfRequested() {
        guard isEnabled else { return }
        guard didActivateKey.withLock({ activated in
            guard !activated else { return false }
            activated = true
            return true
        }) else { return }

        // The UI-test host is deliberately kept out of the production app
        // group. Accept only the runner's narrowly named /private/tmp path so
        // an accidental ordinary launch cannot redirect helper IPC elsewhere.
        if let socketDirectory = argumentValue(after: socketDirectoryArgument),
           socketDirectory.hasPrefix("/private/tmp/rootshell-zmx-xcui-"),
           !socketDirectory.contains("/../") {
            // Do not standardize this URL: on macOS `/tmp` is a symlink to
            // `/private/tmp`, and standardizing changes the spelling passed to
            // the helper. The helper's isolation contract deliberately accepts
            // only the private path generated by the test runner.
            let socketURL = URL(
                fileURLWithPath: socketDirectory,
                isDirectory: true
            )
            AppGroupHelper.overrideContainerURL = socketURL
            configureSterileHome(under: socketURL)
        }

        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[TabExposeSettings.multiplexerEnabledKey] = true
        arguments["zmxSessionDiscoveryEnabled"] = true
        arguments["tabBarAnimationsDisabled"] = true
        // The real New Connection UI opens on the SSH form regardless of the
        // user's persisted last-used connection type.
        arguments["lastConnectionType"] = "SSH"
        // The fork suite covers terminal/SSH interaction only. Keep all
        // state that would otherwise initialize or write Documents-backed
        // stores out of this disposable process.
        arguments["sessionPersistenceEnabled"] = false
        arguments["scrollbackPersistenceEnabled"] = false
        arguments["agentDetectionEnabled"] = false
        arguments["taskDetectionEnabled"] = false
        arguments["agentUsageTrackingEnabled"] = false
        arguments["agentDetectionCaptureEnabled"] = false
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    private static func configureSterileHome(under socketDirectory: URL) {
        let home = socketDirectory.appendingPathComponent("home", isDirectory: true)
        let directories = [
            home,
            home.appendingPathComponent(".config", isDirectory: true),
            home.appendingPathComponent(".local/share", isDirectory: true),
            home.appendingPathComponent(".local/state", isDirectory: true),
            home.appendingPathComponent(".cache", isDirectory: true),
            home.appendingPathComponent("tmp", isDirectory: true),
            home.appendingPathComponent("Documents", isDirectory: true),
        ]

        do {
            for directory in directories {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
        } catch {
            // Do not point processes at a path we could not create. The test
            // will fail its normal helper startup rather than touching user state.
            return
        }

        sterileHomeDirectoryKey.withLock { $0 = home }
        setenv("HOME", home.path, 1)
        setenv("ZDOTDIR", home.path, 1)
        setenv("XDG_CONFIG_HOME", home.appendingPathComponent(".config").path, 1)
        setenv("XDG_DATA_HOME", home.appendingPathComponent(".local/share").path, 1)
        setenv("XDG_CACHE_HOME", home.appendingPathComponent(".cache").path, 1)
        setenv("XDG_STATE_HOME", home.appendingPathComponent(".local/state").path, 1)
        setenv("TMPDIR", home.appendingPathComponent("tmp").path + "/", 1)
    }

    private static func argumentValue(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    /// Test-only readiness is intentionally a value, not terminal output. The
    /// terminal remains otherwise opaque to automation and no credentials are
    /// placed in the accessibility tree.
    @MainActor
    static func markTerminal(_ terminal: Ghostty.TerminalView, state: String) {
        guard isEnabled else { return }
        terminal.isAccessibilityElement = true
        terminal.accessibilityIdentifier = "terminal-readiness"
        terminal.accessibilityLabel = "Terminal"
        terminal.accessibilityValue = state
    }
}

/// Adds an accessibility identifier only to the explicitly opted-in fork UI
/// test build. Upstream product accessibility remains unchanged; the helper is
/// intentionally inert in Release and in ordinary Debug launches.
private struct ForkUITestIdentifierModifier: ViewModifier {
    let identifier: String

    @ViewBuilder
    func body(content: Content) -> some View {
        #if DEBUG
        if ForkUITestConfiguration.isEnabled {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension View {
    func forkUITestIdentifier(_ identifier: String) -> some View {
        modifier(ForkUITestIdentifierModifier(identifier: identifier))
    }
}
