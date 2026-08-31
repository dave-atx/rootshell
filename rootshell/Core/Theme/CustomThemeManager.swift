//
//  CustomThemeManager.swift
//  rootshell
//
//  Manages CRUD operations for user-created custom themes with dual persistence:
//  - JSON metadata in Documents for app state
//  - Ghostty theme files in Application Support for GhosttyKit resolution
//

import Foundation
import Combine
import os

@MainActor
class CustomThemeManager: ObservableObject {
    static let shared = CustomThemeManager()

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "CustomThemeManager")

    @Published private(set) var customThemes: [CustomTheme] = []

    private let fileManager = FileManager.default

    private init() {
        loadThemes()
    }

    // MARK: - Directory Paths

    /// JSON metadata file: Documents/.ghostty/custom_themes.json
    private var metadataFileURL: URL? {
        let docs = ForkUITestConfiguration.documentsDirectoryURL
        let dir = docs.appendingPathComponent(".ghostty")
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("custom_themes.json")
    }

    /// Ghostty theme files directory: Application Support/ghostty/themes/
    private var ghosttyThemesDirectory: URL? {
        if ForkUITestConfiguration.isEnabled {
            let dir = ForkUITestConfiguration.processHomeDirectoryURL
                .appendingPathComponent(".config/ghostty/themes", isDirectory: true)
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        guard let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let dir = appSupport
            .appendingPathComponent("ghostty")
            .appendingPathComponent("themes")
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - CRUD Operations

    /// Save (create or update) a custom theme
    func saveTheme(_ theme: CustomTheme) {
        var updated = theme
        updated.modifiedDate = Date()

        if let index = customThemes.firstIndex(where: { $0.id == theme.id }) {
            // Update existing — handle rename
            let oldName = customThemes[index].name
            if oldName != updated.name {
                deleteGhosttyFile(named: oldName)

                // Update all name-based references to this theme

                // Active theme
                if ThemeManager.shared.currentTheme == oldName {
                    ThemeManager.shared.currentTheme = updated.name
                }

                // Favorites
                let favorites = FavoriteThemesManager.shared
                if favorites.isFavorite(oldName) {
                    favorites.removeFavorite(oldName)
                    favorites.addFavorite(updated.name)
                }

                // Day/night themes
                let dayNight = DayNightThemeManager.shared
                if dayNight.dayTheme == oldName {
                    dayNight.dayTheme = updated.name
                }
                if dayNight.nightTheme == oldName {
                    dayNight.nightTheme = updated.name
                }

                // Tab/window overrides
                let overrides = ThemeOverrideManager.shared
                for (tabId, name) in overrides.tabOverrides where name == oldName {
                    overrides.setTabTheme(tabId: tabId, themeName: updated.name)
                }
                for (windowId, name) in overrides.windowOverrides where name == oldName {
                    overrides.setWindowTheme(windowId: windowId, themeName: updated.name)
                }

                // Per-theme UI color overrides (keyed by theme name)
                ThemeUIOverridesManager.shared.renameOverrides(from: oldName, to: updated.name)
            }
            customThemes[index] = updated
        } else {
            // Create new
            customThemes.append(updated)
        }

        writeGhosttyFile(for: updated)
        persistMetadata()
        ThemeManager.shared.reloadThemes()
    }

    /// Delete a custom theme by ID
    func deleteTheme(id: UUID) {
        guard let index = customThemes.firstIndex(where: { $0.id == id }) else { return }
        let theme = customThemes[index]

        // If this is the active theme, revert to default
        let themeManager = ThemeManager.shared
        if themeManager.currentTheme == theme.name {
            themeManager.currentTheme = "Catppuccin Mocha"
        }
        let dayNight = DayNightThemeManager.shared
        if dayNight.dayTheme == theme.name {
            dayNight.dayTheme = "Catppuccin Mocha"
        }
        if dayNight.nightTheme == theme.name {
            dayNight.nightTheme = "Catppuccin Mocha"
        }

        // Drop UI color overrides — keying is by name, so a future theme
        // with the same name would otherwise inherit this one's overrides.
        ThemeUIOverridesManager.shared.clear(for: theme.name)

        deleteGhosttyFile(named: theme.name)
        customThemes.remove(at: index)
        persistMetadata()
        ThemeManager.shared.reloadThemes()
    }

    /// Import a Ghostty theme file and create a custom theme from it
    func importFromFile(url: URL, name: String) throws -> CustomTheme {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        let content = try String(contentsOf: url, encoding: .utf8)
        // fromGhosttyFileContent already creates a fresh UUID via defaultTheme()
        let theme = CustomTheme.fromGhosttyFileContent(content, name: name)

        saveTheme(theme)
        return theme
    }

    /// Duplicate a built-in theme as a custom theme
    func duplicateBuiltInTheme(_ info: ThemeManager.ThemeInfo) -> CustomTheme {
        // Parse the full theme file to get all colors
        let content = (try? String(contentsOf: info.filePath, encoding: .utf8)) ?? ""
        // fromGhosttyFileContent already creates a fresh UUID via defaultTheme()
        let theme = CustomTheme.fromGhosttyFileContent(content, name: "\(info.name) (Custom)")
        return theme
    }

    /// Return the URL to the Ghostty theme file for export/sharing
    func exportURL(for id: UUID) -> URL? {
        guard let theme = customThemes.first(where: { $0.id == id }),
              let dir = ghosttyThemesDirectory else {
            return nil
        }
        let url = dir.appendingPathComponent(theme.name)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Name Validation

    enum NameValidation {
        case valid
        case empty
        case containsPathSeparator
        case conflictsWithCustom
        case shadowsBuiltIn
    }

    func validateName(_ name: String, excludingId: UUID? = nil) -> NameValidation {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed.contains("/") || trimmed.contains("\\") { return .containsPathSeparator }

        // Check conflict with other custom themes
        let conflicts = customThemes.contains {
            $0.name == trimmed && $0.id != excludingId
        }
        if conflicts { return .conflictsWithCustom }

        // Check if it shadows a built-in theme. A file probe, not a catalog scan:
        // this runs on every keystroke in the editor and must be correct even
        // before the background load lands.
        if ThemeManager.shared.builtInThemeExists(named: trimmed) { return .shadowsBuiltIn }

        return .valid
    }

    // MARK: - Persistence

    private func loadThemes() {
        guard let url = metadataFileURL,
              fileManager.fileExists(atPath: url.path) else {
            return
        }
        do {
            let data = try Data(contentsOf: url)
            customThemes = try JSONDecoder().decode([CustomTheme].self, from: data)
            Self.logger.info("Loaded \(self.customThemes.count) custom themes")
        } catch {
            Self.logger.error("Failed to load custom themes: \(error)")
        }
    }

    private func persistMetadata() {
        guard let url = metadataFileURL else { return }
        do {
            let data = try JSONEncoder().encode(customThemes)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("Failed to save custom themes metadata: \(error)")
        }
    }

    private func writeGhosttyFile(for theme: CustomTheme) {
        guard let dir = ghosttyThemesDirectory else { return }
        let fileURL = dir.appendingPathComponent(theme.name)
        do {
            try theme.toGhosttyFileContent().write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            Self.logger.error("Failed to write Ghostty theme file: \(error)")
        }
    }

    private func deleteGhosttyFile(named name: String) {
        guard let dir = ghosttyThemesDirectory else { return }
        let fileURL = dir.appendingPathComponent(name)
        try? fileManager.removeItem(at: fileURL)
    }
}
