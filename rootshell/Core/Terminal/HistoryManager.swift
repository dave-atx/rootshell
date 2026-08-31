import Foundation

/// Manages command history with persistent storage
@MainActor
class HistoryManager {
    // MARK: - Properties

    /// Maximum number of commands to store
    private let maxHistorySize = 5000

    /// Commands stored in memory
    private var commands: [String] = []

    /// Current position in history navigation (nil = not navigating)
    private var navigationIndex: Int?

    /// Temporary buffer for command being edited before history navigation
    private var editBuffer: String = ""

    /// Path to history file
    private let historyFilePath: URL
    private let ioQueue = DispatchQueue(label: "com.rootshell.history.io", qos: .utility)

    // MARK: - Initialization

    init() {
        // Store history in .ghostty directory. The fork UI-test host has no
        // reason to touch the user's Catalyst Documents directory; resolving
        // that URL can raise a folder-privacy prompt before the test starts.
        let documentsPath = ForkUITestConfiguration.isEnabled
            ? ForkUITestConfiguration.documentsDirectoryURL
            : FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let ghosttyDir = documentsPath.appendingPathComponent(".ghostty", isDirectory: true)
        try? FileManager.default.createDirectory(at: ghosttyDir, withIntermediateDirectories: true)
        historyFilePath = ghosttyDir.appendingPathComponent("shell_history.txt")

        // Migrate from old location if needed
        let oldPath = documentsPath.appendingPathComponent("shell_history.txt")
        if FileManager.default.fileExists(atPath: oldPath.path) &&
           !FileManager.default.fileExists(atPath: historyFilePath.path) {
            try? FileManager.default.moveItem(at: oldPath, to: historyFilePath)
        }

        loadHistory()
    }

    // MARK: - History Management

    /// Add command to history (with de-duplication)
    func addCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)

        // Don't save empty commands or commands starting with space
        guard !trimmed.isEmpty && !trimmed.hasPrefix(" ") else { return }

        // Remove if it's the same as the last command (de-duplication)
        if commands.last == trimmed {
            return
        }

        // Remove any previous occurrence of this exact command
        commands.removeAll { $0 == trimmed }

        // Add to end
        commands.append(trimmed)

        // Trim to max size
        if commands.count > maxHistorySize {
            commands.removeFirst(commands.count - maxHistorySize)
        }

        // Reset navigation
        navigationIndex = nil
        editBuffer = ""

        // Save to disk
        saveHistory()
    }

    /// Clear all history
    func clearHistory() {
        commands.removeAll()
        navigationIndex = nil
        editBuffer = ""
        saveHistory()
    }

    // MARK: - History Navigation

    /// Start history navigation session with current edit buffer
    func startNavigation(currentBuffer: String) {
        editBuffer = currentBuffer
        navigationIndex = nil
    }

    /// Navigate to previous command (up arrow)
    func navigatePrevious() -> String? {
        guard !commands.isEmpty else { return nil }

        if let index = navigationIndex {
            // Already navigating, go further back
            if index > 0 {
                navigationIndex = index - 1
                return commands[index - 1]
            }
            return nil  // Already at oldest
        } else {
            // Start navigation from most recent
            navigationIndex = commands.count - 1
            return commands.last
        }
    }

    /// Navigate to next command (down arrow)
    func navigateNext() -> String? {
        guard let index = navigationIndex else {
            // Not navigating
            return nil
        }

        if index < commands.count - 1 {
            // Move forward in history
            navigationIndex = index + 1
            return commands[index + 1]
        } else {
            // Reached end, return to edit buffer
            navigationIndex = nil
            return editBuffer
        }
    }

    /// Stop navigation and reset state
    func stopNavigation() {
        navigationIndex = nil
        editBuffer = ""
    }

    /// Check if currently navigating history
    var isNavigating: Bool {
        navigationIndex != nil
    }

    // MARK: - Search

    /// Search history for commands containing the search term
    func search(term: String) -> [String] {
        guard !term.isEmpty else { return [] }

        return commands.reversed().filter { $0.contains(term) }
    }

    /// Get all commands (most recent first)
    var allCommands: [String] {
        Array(commands.reversed())
    }

    /// Get recent commands (most recent first, limited count)
    func recentCommands(limit: Int = 20) -> [String] {
        let start = max(0, commands.count - limit)
        return Array(commands[start...].reversed())
    }

    // MARK: - Persistence

    private func loadHistory() {
        let historyFilePath = historyFilePath
        let maxHistorySize = maxHistorySize

        ioQueue.async { [weak self] in
            guard FileManager.default.fileExists(atPath: historyFilePath.path) else {
                return
            }

            do {
                let content = try String(contentsOf: historyFilePath, encoding: .utf8)
                var loaded = content.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }

                // Ensure we don't exceed max size
                if loaded.count > maxHistorySize {
                    loaded = Array(loaded.suffix(maxHistorySize))
                }

                guard let strongSelf = self else { return }
                let loadedCommands = loaded
                Task { @MainActor in
                    // Merge: keep any commands added before load completed
                    let added = strongSelf.commands.filter { !loadedCommands.contains($0) }
                    strongSelf.commands = loadedCommands + added
                }
            } catch {
                print("Failed to load history: \(error)")
            }
        }
    }

    private func saveHistory() {
        let historyFilePath = historyFilePath
        let content = commands.joined(separator: "\n")
        ioQueue.async {
            do {
                try content.write(to: historyFilePath, atomically: true, encoding: .utf8)
            } catch {
                print("Failed to save history: \(error)")
            }
        }
    }

    // MARK: - Statistics

    /// Total number of commands in history
    var count: Int {
        commands.count
    }

    /// Check if history is empty
    var isEmpty: Bool {
        commands.isEmpty
    }
}
