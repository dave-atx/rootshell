//
//  GhosttyConfigImporter.swift
//  rootshell
//
//  Orchestrator for importing settings from a Ghostty config file. Reads the
//  file (security-scoped), runs the parser, resolves `config-file` includes,
//  builds a typed `MigrationPlan`, and on apply writes through the existing
//  manager singletons + BackupImporter.refreshAllManagers().
//

import Foundation
import os

@MainActor
final class GhosttyConfigImporter {
    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "GhosttyConfigImporter"
    )

    enum ImportError: LocalizedError {
        case cannotAccessFile
        case readFailed(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .cannotAccessFile:
                return String(localized: "Couldn't open the selected file. Try picking it again.",
                              comment: "Migration error: file access denied")
            case .readFailed(let detail):
                return String(localized: "Couldn't read the config file: \(detail)",
                              comment: "Migration error: file read failed")
            case .empty:
                return String(localized: "The selected file did not contain any Ghostty settings.",
                              comment: "Migration error: empty file")
            }
        }
    }

    private static let maxIncludeDepth = 3

    /// Existing Ghostty desktop config files in well-known locations on macOS,
    /// in priority order. Used by the Standalone Mac Catalyst build to offer
    /// one-tap quick imports — the sandboxed App Store build can't read these
    /// paths so it relies on the file picker.
    ///
    /// Excludes rootshell's own write path: on non-sandboxed Catalyst,
    /// `~/Library/Application Support/ghostty/config` is where rootshell itself
    /// generates its runtime config, and importing that back would just be a
    /// circular reflection of the user's current settings.
    static func discoverDefaultConfigs() -> [URL] {
        // Discovery intentionally probes Ghostty's desktop application data.
        // The disposable fork UI-test host must never cross that TCC boundary;
        // migration settings are outside the zmx/SSH test scope.
        guard !ForkUITestConfiguration.isEnabled else { return [] }

        let fm = FileManager.default
        // `homeDirectoryForCurrentUser` is unavailable on Mac Catalyst, but
        // `NSHomeDirectory()` returns the real user home on the non-sandboxed
        // Standalone build (this discovery is gated to that build by the UI).
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)

        // Path rootshell writes to (so we can skip it during discovery).
        let ownConfigPath: String? = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("ghostty/config")
            .standardizedFileURL
            .path

        let candidates: [URL] = [
            home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty/config.ghostty"),
            home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty/config"),
            home.appendingPathComponent(".config/ghostty/config.ghostty"),
            home.appendingPathComponent(".config/ghostty/config"),
        ]

        return candidates.filter { url in
            guard fm.fileExists(atPath: url.path) else { return false }
            if let own = ownConfigPath, url.standardizedFileURL.path == own { return false }
            return true
        }
    }

    /// Read the file (security-scoped), parse it, resolve includes, and build
    /// a `MigrationPlan` ready for preview. Does not mutate any settings.
    static func preview(from url: URL) throws -> MigrationPlan {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        var allEntries: [ParsedConfigEntry] = []
        var warnings: [String] = []
        var seenFiles: Set<URL> = []

        try collectEntries(
            from: url,
            depth: 0,
            entries: &allEntries,
            warnings: &warnings,
            seenFiles: &seenFiles
        )

        guard !allEntries.isEmpty else { throw ImportError.empty }

        var plan = MigrationPlan(sourceURL: url)
        plan.warnings = warnings

        // First pass: find font-family if any, since per-family features need it.
        let fontFamilyValue = allEntries
            .first(where: { $0.key == "font-family" })?
            .value

        var keybindLines: [String] = []

        for entry in allEntries {
            // Includes are processed during collectEntries; skip here so they
            // don't show up in the preview.
            if entry.key == "config-file" { continue }

            if entry.key == "keybind" {
                // Re-emit verbatim. The parser unquotes values, so the
                // canonical KeybindManager parser sees a clean
                // `keybind = trigger=action` form — the same shape it gets
                // when reading any imported config file directly.
                keybindLines.append("keybind = \(entry.value)")
                continue
            }

            apply(entry: entry, to: &plan, fontFamilyContext: fontFamilyValue)
        }

        if !keybindLines.isEmpty {
            // Aggregate all keybind lines (including those from resolved
            // `config-file = …` includes) into a single flattened blob so
            // KeybindManager — which doesn't itself resolve includes — gets
            // every binding the user expected to import.
            plan.keybindContent = keybindLines.joined(separator: "\n") + "\n"
            plan.keybindOriginalFilename = url.lastPathComponent
            plan.recognized.append(
                RecognizedChange(
                    category: .keybind,
                    key: "keybind",
                    summary: String(localized: "\(keybindLines.count) keybind(s) — imported via Keyboard Shortcuts",
                                    comment: "Migration preview: keybind count"),
                    payload: .keybindCount(keybindLines.count)
                )
            )
        }

        // Surface the cross-cutting day/night + overrides incompatibility once,
        // before the user hits Apply.
        if !plan.customThemeFields.isEmpty,
           plan.recognized.contains(where: { if case .dayNightTheme = $0.payload { return true } else { return false } }) {
            plan.warnings.append(
                String(localized: "Day/night theme can't be combined with color overrides — overrides will win.",
                       comment: "Migration warning: day/night vs overrides")
            )
        }

        return plan
    }

    /// Apply a previously-built plan. Writes through the manager singletons,
    /// then calls `BackupImporter.refreshAllManagers()` so any in-memory
    /// caches catch up. Returns a summary suitable for the post-import sheet.
    static func apply(_ plan: MigrationPlan) -> MigrationSummary {
        var registeredCustomThemeName: String? = nil

        // Find the parsed theme name (if any) so we can use it as a base when
        // color overrides are also present.
        let parsedThemeName: String? = plan.recognized
            .compactMap { change -> String? in
                if case .theme(let name) = change.payload { return name }
                return nil
            }
            .first

        // Color/palette overrides → register a derived custom theme. When a
        // named theme was also set, use that as the base so overrides layer on
        // top of it (matching Ghostty semantics: theme provides defaults,
        // individual color keys override).
        if !plan.customThemeFields.isEmpty {
            let themeName = customThemeName(for: plan.sourceURL)
            registerCustomTheme(named: themeName, from: plan.customThemeFields, base: parsedThemeName)
            registeredCustomThemeName = themeName
            // Always switch to the derived theme so overrides actually take
            // effect — previously this was gated on "no theme entry", which
            // silently swallowed the overrides whenever theme was also set.
            ThemeManager.shared.currentTheme = themeName
        }

        for change in plan.recognized {
            applyPayload(change.payload, plan: plan, hasOverrides: !plan.customThemeFields.isEmpty)
        }

        // Refresh in-memory caches so the running app sees the new values.
        BackupImporter.refreshAllManagers()

        // Hand keybinds to the existing live-source pipeline. Use the
        // content-based entry point so includes that contributed keybind
        // lines actually make it into the imported config.
        var keybindsImported = false
        if let content = plan.keybindContent {
            let displayName = plan.keybindOriginalFilename ?? plan.sourceURL.lastPathComponent
            KeybindManager.shared.importExternalConfig(content: content, originalFilename: displayName)
            keybindsImported = true
        }

        return MigrationSummary(
            appliedCount: plan.recognized.count,
            unsupportedCount: plan.unsupported.count,
            warnings: plan.warnings,
            registeredCustomThemeName: registeredCustomThemeName,
            keybindsImported: keybindsImported
        )
    }

    // MARK: - Include Resolution

    private static func collectEntries(
        from url: URL,
        depth: Int,
        entries: inout [ParsedConfigEntry],
        warnings: inout [String],
        seenFiles: inout Set<URL>
    ) throws {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        if seenFiles.contains(canonical) {
            warnings.append(String(localized: "Skipped duplicate include: \(url.lastPathComponent)",
                                   comment: "Migration warning: duplicate include"))
            return
        }
        seenFiles.insert(canonical)

        let contents: String
        do {
            contents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            if depth == 0 { throw ImportError.readFailed(error.localizedDescription) }
            warnings.append(String(localized: "Could not read include \(url.lastPathComponent): \(error.localizedDescription)",
                                   comment: "Migration warning: include read failed"))
            return
        }

        let parsed = GhosttyConfigParser.parse(contents, sourceFile: url)
        entries.append(contentsOf: parsed)

        guard depth < maxIncludeDepth else {
            if parsed.contains(where: { $0.key == "config-file" }) {
                warnings.append(String(localized: "Reached maximum include depth (\(maxIncludeDepth)) — deeper config-file entries skipped.",
                                       comment: "Migration warning: include depth"))
            }
            return
        }

        let parentDir = url.deletingLastPathComponent()
        for include in parsed where include.key == "config-file" {
            let (path, optional) = parseIncludeValue(include.value)
            guard !path.isEmpty else { continue }

            let resolved = resolveIncludePath(path, relativeTo: parentDir)
            if !FileManager.default.fileExists(atPath: resolved.path) {
                if !optional {
                    warnings.append(String(localized: "Include not found: \(path)",
                                           comment: "Migration warning: missing include"))
                }
                continue
            }

            do {
                try collectEntries(
                    from: resolved,
                    depth: depth + 1,
                    entries: &entries,
                    warnings: &warnings,
                    seenFiles: &seenFiles
                )
            } catch {
                warnings.append(String(localized: "Include failed: \(path) (\(error.localizedDescription))",
                                       comment: "Migration warning: include failed"))
            }
        }
    }

    private static func parseIncludeValue(_ raw: String) -> (path: String, optional: Bool) {
        var v = raw
        var optional = false
        if v.hasPrefix("?") {
            optional = true
            v.removeFirst()
        }
        return (v.trimmingCharacters(in: .whitespaces), optional)
    }

    private static func resolveIncludePath(_ path: String, relativeTo dir: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        return dir.appendingPathComponent(expanded)
    }

    // MARK: - Per-Entry Mapping (parse path)

    private static func apply(
        entry: ParsedConfigEntry,
        to plan: inout MigrationPlan,
        fontFamilyContext: String?
    ) {
        let key = entry.key
        let value = entry.value

        switch key {
        // MARK: Font

        case "font-family":
            plan.recognized.append(
                RecognizedChange(
                    category: .font, key: key,
                    summary: String(localized: "Font family → \(value)", comment: "Migration preview"),
                    payload: .fontFamily(value)
                )
            )

        case "font-size":
            if let size = Double(value), size > 0 {
                plan.recognized.append(
                    RecognizedChange(
                        category: .font, key: key,
                        summary: String(localized: "Font size → \(Int(size.rounded()))",
                                        comment: "Migration preview"),
                        payload: .fontSize(size)
                    )
                )
            } else {
                plan.unsupported.append(.init(key: key, reason: "value '\(value)' is not a number"))
            }

        case "font-feature":
            handleFontFeature(value: value, family: fontFamilyContext, plan: &plan)

        // MARK: Theme

        case "theme":
            handleTheme(value: value, plan: &plan)

        // MARK: Palette / Custom-theme aggregation

        case "palette":
            // value form: `N=#hex`
            if let eqIdx = value.firstIndex(of: "=") {
                let indexStr = value[value.startIndex..<eqIdx].trimmingCharacters(in: .whitespaces)
                let rawColor = value[value.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)
                if let index = Int(indexStr), index >= 0, index < 256,
                   let normalized = ColorParser.normalize(rawColor) {
                    plan.customThemeFields.palette[index] = normalized
                    plan.recognized.append(
                        RecognizedChange(
                            category: .palette, key: key,
                            summary: String(localized: "Palette \(index) → \(normalized)",
                                            comment: "Migration preview"),
                            payload: .paletteAggregated
                        )
                    )
                } else {
                    plan.unsupported.append(.init(key: key, reason: "couldn't parse '\(value)'"))
                }
            } else {
                plan.unsupported.append(.init(key: key, reason: "expected N=#hex form"))
            }

        case "background":
            if let normalized = ColorParser.normalize(value) {
                plan.customThemeFields.background = normalized
                plan.recognized.append(
                    RecognizedChange(
                        category: .palette, key: key,
                        summary: String(localized: "Background → \(normalized)",
                                        comment: "Migration preview"),
                        payload: .backgroundAggregated
                    )
                )
            } else {
                plan.unsupported.append(.init(key: key, reason: "color '\(value)' not recognized"))
            }

        case "foreground":
            if let normalized = ColorParser.normalize(value) {
                plan.customThemeFields.foreground = normalized
                plan.recognized.append(
                    RecognizedChange(
                        category: .palette, key: key,
                        summary: String(localized: "Foreground → \(normalized)",
                                        comment: "Migration preview"),
                        payload: .foregroundAggregated
                    )
                )
            } else {
                plan.unsupported.append(.init(key: key, reason: "color '\(value)' not recognized"))
            }

        // MARK: Cursor

        case "cursor-style":
            let mapped = value.lowercased().replacingOccurrences(of: "-", with: "_")
            if let style = CursorStyle(rawValue: mapped) {
                plan.recognized.append(
                    RecognizedChange(
                        category: .cursor, key: key,
                        summary: String(localized: "Cursor style → \(style.displayName)",
                                        comment: "Migration preview"),
                        payload: .cursorStyle(style)
                    )
                )
            } else {
                plan.unsupported.append(.init(key: key, reason: "unknown style '\(value)'"))
            }

        case "cursor-style-blink":
            if let b = parseBool(value) {
                plan.recognized.append(
                    RecognizedChange(
                        category: .cursor, key: key,
                        summary: String(localized: "Cursor blink → \(b ? "on" : "off")",
                                        comment: "Migration preview"),
                        payload: .cursorBlinkEnabled(b)
                    )
                )
            } else {
                plan.unsupported.append(.init(key: key, reason: "expected true/false"))
            }

        case "cursor-blink-mode":
            let mapped = value.lowercased().replacingOccurrences(of: "-", with: "_")
            if let mode = CursorBlinkMode(rawValue: mapped) {
                plan.recognized.append(
                    RecognizedChange(
                        category: .cursor, key: key,
                        summary: String(localized: "Cursor blink mode → \(mode.displayName)",
                                        comment: "Migration preview"),
                        payload: .cursorBlinkMode(mode)
                    )
                )
            } else {
                plan.unsupported.append(.init(key: key, reason: "unknown blink mode '\(value)'"))
            }

        case "cursor-color":
            if let normalized = ColorParser.normalize(value) {
                plan.recognized.append(
                    RecognizedChange(
                        category: .cursor, key: key,
                        summary: String(localized: "Cursor color → \(normalized)",
                                        comment: "Migration preview"),
                        payload: .cursorColor(normalized)
                    )
                )
            } else {
                plan.unsupported.append(.init(key: key, reason: "color '\(value)' not recognized"))
            }

        case "cursor-text":
            if let normalized = ColorParser.normalize(value) {
                plan.recognized.append(
                    RecognizedChange(
                        category: .cursor, key: key,
                        summary: String(localized: "Cursor text color → \(normalized)",
                                        comment: "Migration preview"),
                        payload: .cursorTextColor(normalized)
                    )
                )
            } else {
                plan.unsupported.append(.init(key: key, reason: "color '\(value)' not recognized"))
            }

        // MARK: Selection

        case "selection-background":
            if let withHash = ColorParser.normalize(value),
               let bare = ColorParser.normalizeBare(value) {
                plan.recognized.append(
                    RecognizedChange(
                        category: .selection, key: key,
                        summary: String(localized: "Selection background → \(withHash)",
                                        comment: "Migration preview"),
                        payload: .selectionBackgroundBareHex(bare)
                    )
                )
                plan.customThemeFields.selectionBackground = withHash
            } else {
                plan.unsupported.append(.init(key: key, reason: "color '\(value)' not recognized"))
            }

        case "selection-foreground":
            if let withHash = ColorParser.normalize(value),
               let bare = ColorParser.normalizeBare(value) {
                plan.recognized.append(
                    RecognizedChange(
                        category: .selection, key: key,
                        summary: String(localized: "Selection foreground → \(withHash)",
                                        comment: "Migration preview"),
                        payload: .selectionForegroundBareHex(bare)
                    )
                )
                plan.customThemeFields.selectionForeground = withHash
            } else {
                plan.unsupported.append(.init(key: key, reason: "color '\(value)' not recognized"))
            }

        // MARK: Transparency (Catalyst-only)

        case "background-opacity":
            #if targetEnvironment(macCatalyst)
            if let d = Double(value), (0.0...1.0).contains(d) {
                plan.recognized.append(
                    RecognizedChange(
                        category: .transparency, key: key,
                        summary: String(localized: "Background opacity → \(String(format: "%.2f", d))",
                                        comment: "Migration preview"),
                        payload: .backgroundOpacity(d)
                    )
                )
            } else {
                plan.unsupported.append(.init(key: key, reason: "expected 0.0–1.0"))
            }
            #else
            plan.unsupported.append(.init(key: key, reason: "transparency is Mac Catalyst only"))
            #endif

        case "background-blur":
            #if targetEnvironment(macCatalyst)
            if let style = parseGlassStyle(value) {
                plan.recognized.append(
                    RecognizedChange(
                        category: .transparency, key: key,
                        summary: String(localized: "Background blur → \(style.title)", comment: "Migration preview"),
                        payload: .backgroundBlurStyle(style.rawValue)
                    )
                )
            } else if let d = parseBlurValue(value) {
                let label: String = (d > 0)
                    ? String(localized: "Background blur → \(Int(d))", comment: "Migration preview")
                    : String(localized: "Background blur → off", comment: "Migration preview")
                plan.recognized.append(
                    RecognizedChange(
                        category: .transparency, key: key, summary: label,
                        payload: .backgroundBlur(radius: d > 0 ? d : nil)
                    )
                )
            } else {
                plan.unsupported.append(.init(key: key, reason: "couldn't parse blur value"))
            }
            #else
            plan.unsupported.append(.init(key: key, reason: "blur is Mac Catalyst only"))
            #endif

        // MARK: Behavior

        case "copy-on-select":
            if let b = parseBool(value) {
                plan.recognized.append(
                    RecognizedChange(
                        category: .behavior, key: key,
                        summary: String(localized: "Copy on select → \(b ? "on" : "off")",
                                        comment: "Migration preview"),
                        payload: .copyOnSelect(b)
                    )
                )
            } else {
                plan.unsupported.append(.init(key: key, reason: "expected true/false"))
            }

        case "macos-option-as-alt":
            #if targetEnvironment(macCatalyst)
            let normalized = value.lowercased()
            let stored: String?
            switch normalized {
            case "true": stored = "on"
            case "false": stored = "off"
            case "left", "right", "on", "off": stored = normalized
            default: stored = nil
            }
            if let stored {
                plan.recognized.append(
                    RecognizedChange(
                        category: .behavior, key: key,
                        summary: String(localized: "Option as Alt → \(stored)",
                                        comment: "Migration preview"),
                        payload: .optionAsAlt(stored)
                    )
                )
            } else {
                plan.unsupported.append(.init(key: key, reason: "expected true/false/left/right"))
            }
            #else
            plan.unsupported.append(.init(key: key, reason: "Catalyst only"))
            #endif

        // MARK: Explicitly unsupported (with friendlier reasons)

        case "window-padding-x", "window-padding-y", "window-padding-balance",
             "window-padding-color":
            plan.unsupported.append(
                .init(key: key, reason: "padding isn't user-customizable in rootshell yet")
            )

        case "shell-integration", "shell-integration-features", "term":
            plan.unsupported.append(
                .init(key: key, reason: "shell integration is handled automatically by GhosttyKit")
            )

        case "command", "working-directory":
            plan.unsupported.append(
                .init(key: key, reason: "command/working directory are managed by rootshell")
            )

        default:
            plan.unsupported.append(
                .init(key: key, reason: "no rootshell equivalent")
            )
        }
    }

    // MARK: - Theme parsing

    private static func handleTheme(value: String, plan: inout MigrationPlan) {
        // Day/night form: `light:Foo,dark:Bar`
        if value.contains(":") && value.contains(",") {
            let parts = value.split(separator: ",")
            var dayName: String? = nil
            var nightName: String? = nil
            for part in parts {
                let kv = part.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2 else { continue }
                switch kv[0].lowercased() {
                case "light": dayName = kv[1]
                case "dark": nightName = kv[1]
                default: break
                }
            }
            if let day = dayName, let night = nightName,
               ThemeManager.shared.themeInfo(for: day) != nil,
               ThemeManager.shared.themeInfo(for: night) != nil {
                plan.recognized.append(
                    RecognizedChange(
                        category: .theme, key: "theme",
                        summary: String(localized: "Day/Night → \(day) / \(night)",
                                        comment: "Migration preview"),
                        payload: .dayNightTheme(day: day, night: night)
                    )
                )
                return
            }
            plan.unsupported.append(
                .init(key: "theme", reason: "couldn't resolve day/night themes '\(value)'")
            )
            return
        }

        // Plain name
        if ThemeManager.shared.themeInfo(for: value) != nil {
            plan.recognized.append(
                RecognizedChange(
                    category: .theme, key: "theme",
                    summary: String(localized: "Theme → \(value)", comment: "Migration preview"),
                    payload: .theme(name: value)
                )
            )
        } else {
            plan.unsupported.append(
                .init(key: "theme", reason: "theme '\(value)' isn't bundled in rootshell")
            )
        }
    }

    // MARK: - Font feature parsing

    private static func handleFontFeature(value: String, family: String?, plan: inout MigrationPlan) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        // Ligature shortcuts that toggle the global ligaturesEnabled flag.
        let lower = trimmed.lowercased()
        let ligatureOnShortcuts: Set<String> = ["calt", "+calt", "liga", "+liga", "dlig", "+dlig"]
        let ligatureOffShortcuts: Set<String> = ["-calt", "-liga", "-dlig"]

        if ligatureOnShortcuts.contains(lower) {
            plan.recognized.append(
                RecognizedChange(
                    category: .font, key: "font-feature",
                    summary: String(localized: "Ligatures → on (\(lower))", comment: "Migration preview"),
                    payload: .ligaturesEnabled(true)
                )
            )
            return
        }
        if ligatureOffShortcuts.contains(lower) {
            plan.recognized.append(
                RecognizedChange(
                    category: .font, key: "font-feature",
                    summary: String(localized: "Ligatures → off (\(lower))", comment: "Migration preview"),
                    payload: .ligaturesEnabled(false)
                )
            )
            return
        }

        // Per-family stylistic features: only meaningful when font-family is set
        // in the same import (rootshell stores features per-family).
        guard let family = family else {
            plan.unsupported.append(
                .init(key: "font-feature",
                      reason: "feature '\(trimmed)' needs a font-family in the same config")
            )
            return
        }

        // Parse `+tag` / `-tag` / `tag` / `tag=value` (rootshell models on/off only).
        var raw = trimmed
        var enabled = true
        if raw.hasPrefix("+") {
            raw.removeFirst()
        } else if raw.hasPrefix("-") {
            enabled = false
            raw.removeFirst()
        }
        if let eq = raw.firstIndex(of: "=") {
            raw = String(raw[..<eq])
        }
        let cleanedTag = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !cleanedTag.isEmpty else {
            plan.unsupported.append(.init(key: "font-feature", reason: "couldn't parse '\(trimmed)'"))
            return
        }

        let summary = enabled
            ? String(localized: "Enable font feature \(cleanedTag) for \(family)",
                     comment: "Migration preview")
            : String(localized: "Disable font feature \(cleanedTag) for \(family)",
                     comment: "Migration preview")

        plan.recognized.append(
            RecognizedChange(
                category: .font, key: "font-feature",
                summary: summary,
                payload: .fontFeatureTag(family: family, tag: cleanedTag, enabled: enabled)
            )
        )
    }

    // MARK: - Apply (payload-driven)

    private static func applyPayload(
        _ payload: RecognizedPayload,
        plan: MigrationPlan,
        hasOverrides: Bool
    ) {
        switch payload {
        case .fontFamily(let family):
            FontManager.shared.currentFontFamily = family

        case .fontSize(let size):
            FontManager.shared.currentFontSize = size

        case .ligaturesEnabled(let on):
            FontManager.shared.ligaturesEnabled = on

        case .fontFeatureTag(let family, let tag, let enabled):
            FontManager.shared.setFeatureEnabled(tag, enabled: enabled, for: family)

        case .theme(let name):
            // When color overrides are also present, the registered "Imported:"
            // theme is already current — don't overwrite it with the named theme.
            if !hasOverrides {
                ThemeManager.shared.currentTheme = name
            }

        case .dayNightTheme(let day, let night):
            // Same rule: overrides win over day/night switching.
            if !hasOverrides {
                DayNightThemeManager.shared.dayTheme = day
                DayNightThemeManager.shared.nightTheme = night
                DayNightThemeManager.shared.enabled = true
            }

        case .paletteAggregated, .backgroundAggregated, .foregroundAggregated:
            // Handled via `customThemeFields` in `apply(_:)`.
            break

        case .cursorStyle(let style):
            CursorManager.shared.cursorStyle = style

        case .cursorBlinkEnabled(let on):
            CursorManager.shared.cursorBlinkEnabled = on

        case .cursorBlinkMode(let mode):
            CursorManager.shared.cursorBlinkMode = mode
            CursorManager.shared.cursorBlinkEnabled = true

        case .cursorColor(let hex):
            CursorManager.shared.cursorColor = hex

        case .cursorTextColor(let hex):
            CursorManager.shared.cursorTextColor = hex

        case .selectionForegroundBareHex(let bare):
            SelectionManager.shared.selectionMode = .custom
            SelectionManager.shared.customForegroundHex = bare

        case .selectionBackgroundBareHex(let bare):
            SelectionManager.shared.selectionMode = .custom
            SelectionManager.shared.customBackgroundHex = bare

        case .backgroundOpacity(let d):
            #if targetEnvironment(macCatalyst)
            TransparencyManager.shared.backgroundOpacity = d
            #else
            _ = d
            #endif

        case .backgroundBlur(let radius):
            #if targetEnvironment(macCatalyst)
            TransparencyManager.shared.blurStyle = .standard
            if let r = radius {
                TransparencyManager.shared.blurEnabled = true
                TransparencyManager.shared.backgroundBlurRadius = r
            } else {
                TransparencyManager.shared.blurEnabled = false
            }
            #else
            _ = radius
            #endif

        case .backgroundBlurStyle(let raw):
            #if targetEnvironment(macCatalyst)
            if let style = TransparencyManager.BlurStyle(rawValue: raw) {
                TransparencyManager.shared.blurStyle = style
            }
            #else
            _ = raw
            #endif

        case .copyOnSelect(let on):
            UserDefaults.standard.set(on, forKey: "copyOnSelect")

        case .optionAsAlt(let stored):
            #if targetEnvironment(macCatalyst)
            UserDefaults.standard.set(stored, forKey: "optionKeyAsAlt")
            #else
            _ = stored
            #endif

        case .keybindCount:
            // Routed separately through KeybindManager.importExternalConfig.
            break
        }
    }

    // MARK: - Custom theme aggregation

    private static func customThemeName(for sourceURL: URL) -> String {
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let cleaned = stem.isEmpty ? "config" : stem
        return "Imported: \(cleaned)"
    }

    /// Build a `CustomTheme` from `fields`, optionally using `baseThemeName`'s
    /// bundled palette as a starting point so individual overrides layer on
    /// top of the named theme (matching Ghostty's `theme + override` semantics).
    /// Re-importing the same source overwrites any existing record with the
    /// same name to keep the Custom Themes list tidy.
    private static func registerCustomTheme(
        named name: String,
        from fields: CustomThemeFields,
        base baseThemeName: String?
    ) {
        let manager = CustomThemeManager.shared

        var theme: CustomTheme
        if let baseName = baseThemeName,
           let info = ThemeManager.shared.themeInfo(for: baseName) {
            theme = manager.duplicateBuiltInTheme(info)
            theme.name = name
        } else {
            theme = CustomTheme.defaultTheme()
            theme.name = name
        }

        if let bg = fields.background { theme.background = bg }
        if let fg = fields.foreground { theme.foreground = fg }
        if let cc = fields.cursorColor { theme.cursorColor = cc }
        if let ct = fields.cursorText { theme.cursorText = ct }
        if let sb = fields.selectionBackground { theme.selectionBackground = sb }
        if let sf = fields.selectionForeground { theme.selectionForeground = sf }
        for (index, color) in fields.palette {
            if index < 16, index < theme.palette.count {
                theme.palette[index] = color
            } else {
                theme.extendedPalette[index] = color
            }
        }

        // Idempotency: re-importing the same source file should reuse the
        // existing custom theme record so the user doesn't accumulate
        // "Imported: config" duplicates.
        if let existing = manager.customThemes.first(where: { $0.name == name }) {
            theme = CustomTheme(
                id: existing.id,
                name: existing.name,
                createdDate: existing.createdDate,
                modifiedDate: Date(),
                background: theme.background,
                foreground: theme.foreground,
                cursorColor: theme.cursorColor,
                cursorText: theme.cursorText,
                selectionBackground: theme.selectionBackground,
                selectionForeground: theme.selectionForeground,
                palette: theme.palette,
                extendedPalette: theme.extendedPalette
            )
        }

        manager.saveTheme(theme)
    }

    // MARK: - Helpers

    private static func parseBool(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: return nil
        }
    }

    /// `background-blur = macos-glass-regular|macos-glass-clear`.
    private static func parseGlassStyle(_ raw: String) -> TransparencyManager.BlurStyle? {
        TransparencyManager.BlurStyle.allCases.first {
            $0.ghosttyConfigValue == raw.trimmingCharacters(in: .whitespaces)
        }
    }

    /// Ghostty's `background-blur` accepts true/false or an integer 0–255.
    private static func parseBlurValue(_ raw: String) -> Double? {
        if let b = parseBool(raw) {
            return b ? 30.0 : 0.0
        }
        if let n = Double(raw), n >= 0 {
            return n
        }
        return nil
    }
}
