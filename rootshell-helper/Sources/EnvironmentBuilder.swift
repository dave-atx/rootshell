//
//  EnvironmentBuilder.swift
//  rootshell-helper
//
//  Builds shell environment variables matching Ghostty's setup.
//  Based on ghostty/src/termio/Exec.zig:614-737
//

import Foundation

/// Builds environment variables for shell processes
class EnvironmentBuilder {

    /// Configuration for environment building
    struct Config {
        /// Path to Ghostty resources directory (themes, terminfo, etc.)
        var resourcesDir: String?

        /// Path to Ghostty binary directory (for shell integration)
        var binDir: String?

        /// Ghostty version string
        var version: String = "1.0.0"

        /// App version including build number, e.g. "1.0.10-126".
        /// Falls back to `version` when the app didn't supply it.
        var versionWithBuild: String?

        /// Current working directory (nil = don't set PWD)
        var workingDirectory: String?

        /// Whether to enable shell integration
        var enableShellIntegration: Bool = false

        /// Shell integration resources path
        var shellIntegrationPath: String?

        /// Local SSH agent socket path supplied by the Catalyst app.
        var sshAuthSock: String?

        /// TERM chosen in the app's settings. nil keeps the default below.
        var termType: String?

        /// Stable pane identity supplied by the app for deterministic push
        /// notification routing.
        var paneToken: String?
    }

    private let config: Config

    init(config: Config) {
        self.config = config
    }

    /// Get the system locale in POSIX format (e.g., "en_US.UTF-8")
    /// Uses LocaleHelper for correct language+region pairing from preferredLanguages
    private var systemLocale: String {
        LocaleHelper.posixLocale
    }

    /// The launchd-provided per-user temp directory, or nil on failure.
    private static func darwinUserTempDir() -> String? {
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [Int8](repeating: 0, count: size)
        let result = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, size)
        guard result > 0, result <= size else { return nil }
        return String(cString: buffer)
    }

    /// Convenience initializer that auto-detects bundle paths
    convenience init(bundle: Bundle = .main, version: String = "1.0.0") {
        var config = Config()
        config.version = version

        // Try to find resources in bundle
        if let resourcesURL = bundle.resourceURL {
            config.resourcesDir = resourcesURL.path

            // Look for terminfo
            let terminfoPath = resourcesURL.appendingPathComponent("terminfo").path
            if FileManager.default.fileExists(atPath: terminfoPath) {
                // Will be set in build() method
            }

            // Look for shell integration scripts
            let shellPath = resourcesURL.appendingPathComponent("shell-integration").path
            if FileManager.default.fileExists(atPath: shellPath) {
                config.shellIntegrationPath = shellPath
            }
        }

        // Binary directory (typically Contents/MacOS for Mac apps)
        if let executableURL = bundle.executableURL {
            config.binDir = executableURL.deletingLastPathComponent().path
        }

        self.init(config: config)
    }

    /// Builds environment dictionary
    /// Based on ghostty/src/termio/Exec.zig:614-737
    func build(with overrideConfig: Config? = nil) -> [String: String] {
        // Use override config if provided, otherwise use instance config
        let config = overrideConfig ?? self.config

        // Start with EMPTY environment - don't inherit app/helper environment
        // This prevents iOS/Xcode-specific variables from breaking downstream
        // tools like openssl, python, etc. The login shell will set up the
        // rest of the environment via /etc/profile, ~/.zshrc, etc.
        var env: [String: String] = [:]

        // Essential user identity from system (not inheritance)
        if let testHome = ProcessInfo.processInfo.environment["ROOTSHELL_UI_TEST_HOME"],
           (testHome.hasPrefix("/private/tmp/rootshell-zmx-xcui-") ||
            testHome.hasPrefix("/tmp/rootshell-zmx-xcui-")),
           FileManager.default.fileExists(atPath: testHome) {
            // Only the disposable fork helper receives this environment
            // variable. Keep all shell state (including ssh known_hosts) out
            // of the real user profile.
            env["HOME"] = testHome
            env["ZDOTDIR"] = testHome
            env["XDG_CONFIG_HOME"] = (testHome as NSString).appendingPathComponent(".config")
            env["XDG_DATA_HOME"] = (testHome as NSString).appendingPathComponent(".local/share")
            env["XDG_CACHE_HOME"] = (testHome as NSString).appendingPathComponent(".cache")
            env["XDG_STATE_HOME"] = (testHome as NSString).appendingPathComponent(".local/state")
            env["TMPDIR"] = (testHome as NSString).appendingPathComponent("tmp") + "/"
            env["ROOTSHELL_UI_TEST"] = "1"
        } else if let pw = getpwuid(getuid()) {
            if let home = pw.pointee.pw_dir {
                env["HOME"] = String(cString: home)
            }
            if let user = pw.pointee.pw_name {
                env["USER"] = String(cString: user)
                env["LOGNAME"] = String(cString: user)
            }
            if let shell = pw.pointee.pw_shell {
                env["SHELL"] = String(cString: shell)
            }
        }

        // Minimal default PATH - login shell will extend this
        env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        // Multiplexer socket paths rely on launchd's per-user temp directory.
        if let tmpDir = Self.darwinUserTempDir() {
            env["TMPDIR"] = tmpDir
        }

        // TERM: an explicit value from the app's settings wins outright — the
        // user picked it, and honoring it is the whole point of the setting.
        if let termType = config.termType, !termType.isEmpty {
            env["TERM"] = termType
            // Still point at the bundled terminfo when we have one, so a
            // ghostty-family TERM can actually resolve.
            if let resourcesDir = config.resourcesDir {
                let terminfoPath = (resourcesDir as NSString).appendingPathComponent("terminfo")
                if FileManager.default.fileExists(atPath: terminfoPath) {
                    env["TERMINFO"] = terminfoPath
                }
            }
        }
        // No explicit value (an older app that predates the TERM setting):
        // use the bundled terminfo when it's there, else the safe default.
        // "xterm-ghostty" is the entry's primary name; "ghostty" is only an
        // alias, and some tools match on the primary name.
        else if let resourcesDir = config.resourcesDir {
            let terminfoPath = (resourcesDir as NSString).appendingPathComponent("terminfo")
            if FileManager.default.fileExists(atPath: terminfoPath) {
                env["TERM"] = "xterm-ghostty"
                env["TERMINFO"] = terminfoPath
            } else {
                env["TERM"] = "xterm-256color"
            }
        } else {
            env["TERM"] = "xterm-256color"
        }

        // COLORTERM: Indicate true color support
        env["COLORTERM"] = "truecolor"

        // LANG: Set locale for proper UTF-8 support
        // Only set LANG (not LC_ALL) to allow users to customize individual LC_* categories
        let locale = systemLocale
        env["LANG"] = locale

        // LANGUAGE: Set for gettext translation priority if available
        if let preferredLanguages = LocaleHelper.preferredLanguages {
            env["LANGUAGE"] = preferredLanguages
        }

        // GHOSTTY_RESOURCES_DIR: Path to resources
        // Only set if shell integration is enabled, otherwise bash will try to
        // source non-existent shell integration scripts
        if config.enableShellIntegration, let resourcesDir = config.resourcesDir {
            env["GHOSTTY_RESOURCES_DIR"] = resourcesDir
        }

        // GHOSTTY_SHELL_FEATURES: Comma-separated list of enabled features
        // Controls which shell integration features are active
        if config.enableShellIntegration {
            env["GHOSTTY_SHELL_FEATURES"] = "cursor,path,sudo,title"
        }

        // GHOSTTY_BIN_DIR: Path to binaries (for shell integration)
        // Only set if shell integration is enabled
        if config.enableShellIntegration, let binDir = config.binDir {
            env["GHOSTTY_BIN_DIR"] = binDir

            // Append to PATH
            if let path = env["PATH"] {
                env["PATH"] = "\(binDir):\(path)"
            } else {
                env["PATH"] = binDir
            }
        }

        // TERM_PROGRAM and VERSION
        env["TERM_PROGRAM"] = "ghostty"
        env["TERM_PROGRAM_VERSION"] = config.version

        // Product identity. LC_* is the only namespace stock ssh_config/sshd_config
        // forward, so this survives an ssh out of the local shell. Kept distinct from
        // TERM_PROGRAM, which stays "ghostty" for capability sniffing.
        env["LC_TERMINAL"] = "rootshell"
        env["LC_TERMINAL_VERSION"] = config.versionWithBuild ?? config.version
        if let paneToken = config.paneToken, !paneToken.isEmpty {
            env["LC_ROOTSHELL_PANE"] = paneToken
        }

        // Remove VTE_VERSION (we're not VTE-based)
        env.removeValue(forKey: "VTE_VERSION")

        // PWD: Set to working directory (preserves symbolic links)
        if let workingDirectory = config.workingDirectory {
            env["PWD"] = workingDirectory
        }

        if let sshAuthSock = config.sshAuthSock, !sshAuthSock.isEmpty {
            env["SSH_AUTH_SOCK"] = sshAuthSock
        }

        // macOS-specific: XDG_DATA_DIRS and MANPATH
        #if os(macOS)
        if let resourcesDir = config.resourcesDir {
            let shareDir = (resourcesDir as NSString).deletingLastPathComponent
            let xdgDataDir = (shareDir as NSString).appendingPathComponent("share")

            if FileManager.default.fileExists(atPath: xdgDataDir) {
                if let existing = env["XDG_DATA_DIRS"] {
                    env["XDG_DATA_DIRS"] = "\(xdgDataDir):\(existing)"
                } else {
                    env["XDG_DATA_DIRS"] = xdgDataDir
                }
            }

            let manDir = (shareDir as NSString).appendingPathComponent("man")
            if FileManager.default.fileExists(atPath: manDir) {
                if let existing = env["MANPATH"] {
                    env["MANPATH"] = "\(manDir):\(existing)"
                } else {
                    env["MANPATH"] = manDir
                }
            }
        }
        #endif

        // Shell integration environment
        if config.enableShellIntegration, let shellPath = config.shellIntegrationPath {
            env["GHOSTTY_SHELL_INTEGRATION_DIR"] = shellPath
        }

        return env
    }

    /// Detects shell type from shell path
    static func detectShellType(from shellPath: String) -> ShellType {
        let shell = (shellPath as NSString).lastPathComponent

        switch shell {
        case "bash":
            return .bash
        case "zsh":
            return .zsh
        case "fish":
            return .fish
        case "elvish":
            return .elvish
        default:
            return .unknown
        }
    }
}

/// Supported shell types for integration
enum ShellType {
    case bash
    case zsh
    case fish
    case elvish
    case unknown

    var integrationScriptName: String? {
        switch self {
        case .bash: return "bash.sh"
        case .zsh: return "zsh.sh"
        case .fish: return "fish.fish"
        case .elvish: return "elvish.elv"
        case .unknown: return nil
        }
    }
}
