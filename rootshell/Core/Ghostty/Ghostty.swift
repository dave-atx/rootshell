//
//  Ghostty.swift
//  rootshell
//
//  Base namespace for all Ghostty types
//

import Foundation
import OSLog
import GhosttyKit

/// Main namespace for all Ghostty types and functionality
enum Ghostty {
    /// Logger for Ghostty
    nonisolated static let logger = Logger(subsystem: "com.kk2.rootshell", category: "ghostty")

    /// Track whether ghostty has been initialized
    private static var _initialized = false

    /// Initialize the Ghostty library. Must be called before creating any configs or apps.
    static func initialize() {
        guard !_initialized else { return }

        // RootShellApp's stored properties can construct Ghostty before its
        // initializer body. Re-check the explicit fork argument here, before
        // Ghostty or Catalyst resolves any home/XDG path.
        ForkUITestConfiguration.activateIfRequested()

        // Set GHOSTTY_RESOURCES_DIR to the app bundle's Resources directory
        // so Ghostty can find theme files
        // On Mac Catalyst: Bundle.main.resourceURL points to Contents/Resources
        // On iOS/visionOS: Bundle.main.resourceURL points to the app bundle root
        // Ghostty will look for themes at: $GHOSTTY_RESOURCES_DIR/themes/
        guard let resourceURL = Bundle.main.resourceURL else {
            logger.error("Failed to get bundle resource URL")
            return
        }

        let resourcePath = resourceURL.path
        let themesPath = (resourcePath as NSString).appendingPathComponent("themes")

        // Verify themes directory exists. Deliberately no directory enumeration
        // here — ThemeManager already walks these files, off the main thread.
        if !FileManager.default.fileExists(atPath: themesPath) {
            logger.error("Themes directory not found at: \(themesPath)")
        }

        setenv("GHOSTTY_RESOURCES_DIR", resourcePath, 1)
        logger.info("Set GHOSTTY_RESOURCES_DIR to: \(resourcePath)")

        // Set XDG_CONFIG_HOME to Application Support directory
        // so Ghostty can find config files on iOS (which has no traditional home directory)
        // Ghostty will look for config at: XDG_CONFIG_HOME/ghostty/config
        if !ForkUITestConfiguration.isEnabled,
           let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            setenv("XDG_CONFIG_HOME", appSupport.path, 1)
            logger.info("Set XDG_CONFIG_HOME to: \(appSupport.path)")
        }

        // Mac Catalyst: Set up environment variables for PTY-based shell spawning
        // On Catalyst, Ghostty spawns the shell directly via PTY (like macOS) and needs
        // proper environment variables set before ghostty_init() is called.
        // On iOS/visionOS, these are handled by LocalShellSession via ios_setenv().
        #if targetEnvironment(macCatalyst)
        setupCatalystEnvironment()
        #endif

        // Call ghostty_init with empty arguments
        var argv: UnsafeMutablePointer<CChar>? = nil
        let result = ghostty_init(0, &argv)

        if result != GHOSTTY_SUCCESS {
            logger.error("ghostty_init failed with code: \(result)")
        } else {
            logger.info("ghostty initialized successfully")
        }

        _initialized = true
    }

    #if targetEnvironment(macCatalyst)
    /// Set up environment variables for Mac Catalyst PTY-based shells
    private static func setupCatalystEnvironment() {
        logger.info("Setting up Mac Catalyst environment for PTY shells...")

        // Test launches point every shell/XDG lookup at the disposable home
        // prepared from the private socket directory. Ordinary launches keep
        // the real macOS home directory.
        // Note: On Catalyst, NSHomeDirectory() returns the real macOS home (e.g., /Users/example)
        // not the sandboxed Documents directory like on iOS
        let homeDir = ForkUITestConfiguration.processHomeDirectoryURL.path
        setenv("HOME", homeDir, 1)
        logger.info("   Set HOME=\(homeDir)")

        // Set USER to current username
        let username = NSUserName()
        setenv("USER", username, 1)
        logger.info("   Set USER=\(username)")

        // Set SHELL from environment or default to the user's shell from passwd
        // First check if SHELL is already set, otherwise use default
        if let shellEnv = getenv("SHELL"), let shellPath = String(validatingUTF8: shellEnv) {
            logger.info("   SHELL already set: \(shellPath)")
        } else {
            // Try to get shell from passwd, otherwise default to zsh
            let shell = "/bin/zsh"  // Modern macOS default
            setenv("SHELL", shell, 1)
            logger.info("   Set SHELL=\(shell)")
        }

        // Set TERM for proper terminal capabilities, plus TERMINFO so the
        // bundled xterm-ghostty entry resolves. ncurses checks TERMINFO first
        // and then falls through to the system database, so pointing at a
        // directory holding only xterm-ghostty leaves other names working.
        let termType = TerminalTypeSettings.local
        setenv("TERM", termType, 1)
        logger.info("   Set TERM=\(termType)")

        if let terminfoPath = TerminalTypeSettings.terminfoPath {
            setenv("TERMINFO", terminfoPath, 1)
            logger.info("   Set TERMINFO=\(terminfoPath)")
        }

        // Set terminal identification for apps that check capabilities
        // Apps like Claude Code use TERM_PROGRAM to detect notification support
        setenv("TERM_PROGRAM", "ghostty", 1)
        setenv("TERM_PROGRAM_VERSION", TerminalIdentity.shortVersion, 1)
        setenv("COLORTERM", "truecolor", 1)
        logger.info("   Set TERM_PROGRAM=ghostty, COLORTERM=truecolor")

        // Product identity, matching what the local shell and remote sessions advertise
        for envVar in TerminalIdentity.forwardedVariables {
            setenv(envVar.name, envVar.value, 1)
        }

        // Set locale for UTF-8 support
        setenv("LANG", "en_US.UTF-8", 1)
        logger.info("   Set LANG=en_US.UTF-8")

        // Set PATH - preserve existing PATH if present, otherwise use defaults
        if let pathEnv = getenv("PATH"), let pathValue = String(validatingUTF8: pathEnv) {
            logger.info("   PATH already set: \(pathValue)")
        } else {
            let paths = [
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
                "/usr/sbin",
                "/sbin",
                "/opt/homebrew/bin"  // Add Homebrew for Apple Silicon Macs
            ]
            setenv("PATH", paths.joined(separator: ":"), 1)
            logger.info("   Set PATH=\(paths.joined(separator: ":"))")
        }

        logger.info("Mac Catalyst environment setup complete")
    }
    #endif
}

/// Helper to wrap allocated C strings from ghostty
extension Ghostty {
    struct AllocatedString {
        let string: String

        init(_ cString: UnsafeMutablePointer<CChar>?) {
            guard let cString = cString else {
                self.string = ""
                return
            }

            self.string = String(cString: cString)
            free(cString)
        }
    }
}

/// UUID conversion helpers
/// TODO: Enable when ghostty_uuid_t is available in headers
/*
extension UUID {
    init(ghosttyUUID: ghostty_uuid_t) {
        var uuid = ghostty_uuid_t()
        uuid = ghosttyUUID
        let bytes = withUnsafeBytes(of: &uuid) { Data($0) }
        self.init(uuid: uuid_t(
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    var ghosttyUUID: ghostty_uuid_t {
        var result = ghostty_uuid_t()
        withUnsafeBytes(of: uuid) { buffer in
            withUnsafeMutableBytes(of: &result) { resultBuffer in
                resultBuffer.copyBytes(from: buffer)
            }
        }
        return result
    }
}
*/

/// Shell escaping utilities (matches macOS Ghostty.Shell)
extension Ghostty {
    // nonisolated: pure string helpers, also called from off-main clipboard transforms.
    nonisolated struct Shell {
        /// Characters that need escaping in shell commands
        static let escapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

        /// Escape shell-sensitive characters in a string.
        /// Used when dropping files/URLs into the terminal to ensure paths with
        /// spaces and special characters work correctly.
        static func escape(_ str: String) -> String {
            var result = str
            for char in escapeCharacters {
                result = result.replacingOccurrences(
                    of: String(char),
                    with: "\\\(char)"
                )
            }
            return result
        }
    }
}

/// Ghostty actions and related types
extension Ghostty {
    enum Action {
        /// Scrollbar state from the terminal
        struct Scrollbar {
            let total: UInt64   // Total rows (scrollback + active area)
            let offset: UInt64  // First visible row (0 = top of history)
            let len: UInt64     // Number of visible rows (viewport height)
        }
    }
}

#if os(iOS)
typealias OSSize = CGSize
#elseif os(macOS)
typealias OSSize = NSSize
#endif
