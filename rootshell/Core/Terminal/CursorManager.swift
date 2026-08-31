//
//  CursorManager.swift
//  rootshell
//
//  Manages cursor appearance settings including style, blinking, and effects
//

import Foundation
import SwiftUI
import os

extension Notification.Name {
    static let cursorConfigChanged = Notification.Name("cursorConfigChanged")
}

enum CursorStyle: String, CaseIterable, Codable {
    case block
    case bar
    case underline
    case blockHollow = "block_hollow"

    var displayName: String {
        switch self {
        case .block: return String(localized: "Block", comment: "Cursor style: solid block")
        case .bar: return String(localized: "Bar", comment: "Cursor style: vertical bar")
        case .underline: return String(localized: "Underline", comment: "Cursor style: underline")
        case .blockHollow: return String(localized: "Hollow Block", comment: "Cursor style: hollow block outline")
        }
    }

    var configValue: String { rawValue }
}

enum CursorBlinkMode: String, CaseIterable, Codable {
    case normal
    case breathing
    case heartbeat
    case neonFlicker = "neon_flicker"
    case pulse
    case candle
    case rootshell

    var displayName: String {
        switch self {
        case .normal: return String(localized: "Normal", comment: "Cursor blink mode: standard on/off")
        case .breathing: return String(localized: "Breathing", comment: "Cursor blink mode: smooth fade")
        case .heartbeat: return String(localized: "Heartbeat", comment: "Cursor blink mode: double-pulse rhythm")
        case .neonFlicker: return String(localized: "Neon Flicker", comment: "Cursor blink mode: random brightness dips")
        case .pulse: return String(localized: "Pulse", comment: "Cursor blink mode: sharp snap, slow decay")
        case .candle: return String(localized: "Candle", comment: "Cursor blink mode: gentle irregular flicker")
        case .rootshell: return String(localized: "Rootshell", comment: "Cursor blink mode: # cursor with pulse")
        }
    }

    var description: String {
        switch self {
        case .normal: return String(localized: "Classic on/off blink", comment: "Cursor blink mode description")
        case .breathing: return String(localized: "Smooth fade in and out", comment: "Cursor blink mode description")
        case .heartbeat: return String(localized: "Double-pulse rhythm like a heartbeat", comment: "Cursor blink mode description")
        case .neonFlicker: return String(localized: "Random flickers like a neon sign", comment: "Cursor blink mode description")
        case .pulse: return String(localized: "Sharp flash then slow fade", comment: "Cursor blink mode description")
        case .candle: return String(localized: "Gentle irregular flicker like a candle", comment: "Cursor blink mode description")
        case .rootshell: return String(localized: "# symbol cursor with pulse animation", comment: "Cursor blink mode description")
        }
    }

    var configValue: String { rawValue }
}

enum CursorEffect: String, CaseIterable, Codable {
    case none
    case warp
    case sweep
    case tail
    case blaze
    case teslaCoil
    case neon
    case aurora
    case silk

    var displayName: String {
        switch self {
        case .none: return String(localized: "None", comment: "Cursor effect: no effect")
        case .warp: return String(localized: "Warp", comment: "Cursor effect: warp trail")
        case .sweep: return String(localized: "Sweep", comment: "Cursor effect: sweep trail")
        case .tail: return String(localized: "Tail", comment: "Cursor effect: comet tail")
        case .blaze: return String(localized: "Blaze", comment: "Cursor effect: fiery blaze")
        case .teslaCoil: return String(localized: "Tesla Coil", comment: "Cursor effect: electric arc")
        case .neon: return String(localized: "Neon", comment: "Cursor effect: glowing neon trail")
        case .aurora: return String(localized: "Aurora", comment: "Cursor effect: theme-aware aurora glow")
        case .silk: return String(localized: "Silk", comment: "Cursor effect: delicate ribbon of light")
        }
    }

    var description: String {
        switch self {
        case .none: return String(localized: "No cursor effect", comment: "Cursor effect description")
        case .warp: return String(localized: "Neovide-like trail effect", comment: "Cursor effect description")
        case .sweep: return String(localized: "Animated shrinking trail", comment: "Cursor effect description")
        case .tail: return String(localized: "Comet-like trail (kitty-style)", comment: "Cursor effect description")
        case .blaze: return String(localized: "Fiery blaze effect", comment: "Cursor effect description")
        case .teslaCoil: return String(localized: "Electric arc with branching", comment: "Cursor effect description")
        case .neon: return String(localized: "Glowing neon trail with color pulse", comment: "Cursor effect description")
        case .aurora: return String(localized: "Theme-aware glow with color-shifting trail", comment: "Cursor effect description")
        case .silk: return String(localized: "A delicate ribbon of light that follows your cursor", comment: "Cursor effect description")
        }
    }

    /// Bundle filename for static shaders, nil for dynamically generated ones
    var filename: String? {
        switch self {
        case .none: return nil
        case .warp: return "cursor_warp.glsl"
        case .sweep: return "cursor_sweep.glsl"
        case .tail: return "cursor_tail.glsl"
        case .blaze: return "cursor_blaze.glsl"
        case .teslaCoil: return "cursor_tesla_coil.glsl"
        case .neon: return "cursor_neon.glsl"
        case .aurora: return nil // Generated dynamically from theme palette
        case .silk: return "cursor_silk.glsl"
        }
    }
}

@MainActor
@Observable
class CursorManager {
    static let shared = CursorManager()

    private static let logger = Logger(subsystem: "com.rootshell", category: "CursorManager")

    // MARK: - Settings keys

    private static let ownedKeys: Set<String> = [
        Settings.Cursor.blinkEnabled.name, Settings.Cursor.blinkMode.name, Settings.Cursor.style.name,
        Settings.Cursor.effect.name, Settings.Cursor.color.name, Settings.Cursor.textColor.name,
        Settings.Cursor.opacity.name, Settings.Cursor.thickness.name, Settings.Cursor.height.name,
    ]

    /// True while `reload(keys:)` re-assigns properties from the store.
    @ObservationIgnored private var isReloading = false

    // MARK: - Observable Properties

    var cursorBlinkEnabled: Bool {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            if !isReloading { SettingsStore.shared.set(Settings.Cursor.blinkEnabled, cursorBlinkEnabled) }
            NotificationCenter.default.post(name: .cursorConfigChanged, object: nil)
        }
    }

    var cursorBlinkMode: CursorBlinkMode {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            if !isReloading { SettingsStore.shared.set(Settings.Cursor.blinkMode, cursorBlinkMode) }
            NotificationCenter.default.post(name: .cursorConfigChanged, object: nil)
        }
    }

    var cursorStyle: CursorStyle {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            if !isReloading { SettingsStore.shared.set(Settings.Cursor.style, cursorStyle) }
            NotificationCenter.default.post(name: .cursorConfigChanged, object: nil)
        }
    }

    var cursorEffect: CursorEffect {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            if !isReloading { SettingsStore.shared.set(Settings.Cursor.effect, cursorEffect) }
            notifyEffectChanged()
        }
    }

    /// Custom cursor color as hex string (e.g. "#FF0000"), nil for default
    var cursorColor: String? {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            if !isReloading {
                if let color = cursorColor {
                    SettingsStore.shared.set(Settings.Cursor.color, color)
                } else {
                    SettingsStore.shared.reset(Settings.Cursor.color)
                }
            }
            NotificationCenter.default.post(name: .cursorConfigChanged, object: nil)
        }
    }

    /// Custom cursor text color as hex string, nil for default
    var cursorTextColor: String? {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            if !isReloading {
                if let color = cursorTextColor {
                    SettingsStore.shared.set(Settings.Cursor.textColor, color)
                } else {
                    SettingsStore.shared.reset(Settings.Cursor.textColor)
                }
            }
            NotificationCenter.default.post(name: .cursorConfigChanged, object: nil)
        }
    }

    /// Cursor opacity (0.0–1.0)
    var cursorOpacity: Double {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            if !isReloading { SettingsStore.shared.set(Settings.Cursor.opacity, cursorOpacity) }
            NotificationCenter.default.post(name: .cursorConfigChanged, object: nil)
        }
    }

    /// Cursor thickness adjustment in pixels (0 = default)
    var cursorThickness: Int {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            if !isReloading { SettingsStore.shared.set(Settings.Cursor.thickness, cursorThickness) }
            NotificationCenter.default.post(name: .cursorConfigChanged, object: nil)
        }
    }

    /// Cursor height adjustment in pixels (0 = default)
    var cursorHeight: Int {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            if !isReloading { SettingsStore.shared.set(Settings.Cursor.height, cursorHeight) }
            NotificationCenter.default.post(name: .cursorConfigChanged, object: nil)
        }
    }


    // MARK: - Cursor Effect State

    /// Returns true if a cursor effect is enabled
    var hasActiveEffect: Bool {
        cursorEffect != .none
    }

    // MARK: - Initialization

    private init() {
        let store = SettingsStore.shared
        self.cursorBlinkEnabled = store.get(Settings.Cursor.blinkEnabled)
        self.cursorBlinkMode = store.get(Settings.Cursor.blinkMode)
        self.cursorStyle = store.get(Settings.Cursor.style)

        // Legacy ShaderManager migration only runs when the effect key was never written
        if UserDefaults.standard.object(forKey: Settings.Cursor.effect.name) != nil {
            self.cursorEffect = store.get(Settings.Cursor.effect)
        } else {
            self.cursorEffect = Self.migrateFromShaderManager() ?? Settings.Cursor.effect.defaultValue
        }

        self.cursorColor = store.get(Settings.Cursor.color)
        self.cursorTextColor = store.get(Settings.Cursor.textColor)
        self.cursorOpacity = store.get(Settings.Cursor.opacity)
        self.cursorThickness = store.get(Settings.Cursor.thickness)
        self.cursorHeight = store.get(Settings.Cursor.height)

        SettingsRefreshHub.shared.register(keys: Self.ownedKeys) { [weak self] keys in
            self?.reload(keys: keys)
        }
    }

    // MARK: - External refresh

    /// Re-reads owned keys after an external batch (iCloud, restore, config file).
    func reload(keys: Set<String>) {
        isReloading = true
        defer { isReloading = false }
        let store = SettingsStore.shared
        if keys.contains(Settings.Cursor.blinkEnabled.name) { cursorBlinkEnabled = store.get(Settings.Cursor.blinkEnabled) }
        if keys.contains(Settings.Cursor.blinkMode.name) { cursorBlinkMode = store.get(Settings.Cursor.blinkMode) }
        if keys.contains(Settings.Cursor.style.name) { cursorStyle = store.get(Settings.Cursor.style) }
        if keys.contains(Settings.Cursor.effect.name) { cursorEffect = store.get(Settings.Cursor.effect) }
        if keys.contains(Settings.Cursor.color.name) { cursorColor = store.get(Settings.Cursor.color) }
        if keys.contains(Settings.Cursor.textColor.name) { cursorTextColor = store.get(Settings.Cursor.textColor) }
        if keys.contains(Settings.Cursor.opacity.name) { cursorOpacity = store.get(Settings.Cursor.opacity) }
        if keys.contains(Settings.Cursor.thickness.name) { cursorThickness = store.get(Settings.Cursor.thickness) }
        if keys.contains(Settings.Cursor.height.name) { cursorHeight = store.get(Settings.Cursor.height) }
    }

    // MARK: - Migration

    /// Migrates cursor effect from old ShaderManager storage
    private static func migrateFromShaderManager() -> CursorEffect? {
        // Check for old single-select format
        if let oldID = UserDefaults.standard.string(forKey: "enabledBuiltInShaders") {
            logger.info("Migrating cursor effect from ShaderManager: \(oldID)")
            let effect = CursorEffect(rawValue: oldID) ?? .none
            // Clear old key after migration
            UserDefaults.standard.removeObject(forKey: "enabledBuiltInShaders")
            return effect
        }

        // Check for old array format (from earlier multi-select)
        if let array = UserDefaults.standard.stringArray(forKey: "enabledBuiltInShaders"),
           let firstID = array.first {
            logger.info("Migrating cursor effect from ShaderManager array: \(firstID)")
            let effect = CursorEffect(rawValue: firstID) ?? .none
            UserDefaults.standard.removeObject(forKey: "enabledBuiltInShaders")
            return effect
        }

        return nil
    }

    // MARK: - Path Resolution

    /// Returns the bundle path for a cursor effect shader
    func bundlePathForEffect(_ effect: CursorEffect) -> URL? {
        guard let filename = effect.filename else { return nil }

        // Try multiple possible locations depending on platform
        // iOS: rootshell.app/shaders/
        // Mac Catalyst: rootshell.app/Contents/Resources/shaders/
        let possiblePaths: [URL?] = [
            // iOS path
            Bundle.main.bundleURL.appendingPathComponent("shaders/\(filename)"),
            // Mac Catalyst path via resourceURL
            Bundle.main.resourceURL?.appendingPathComponent("shaders/\(filename)"),
            // Mac Catalyst explicit path
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/shaders/\(filename)"),
            // Fallback paths
            Bundle.main.bundleURL.appendingPathComponent("Resources/shaders/\(filename)"),
        ]

        for path in possiblePaths.compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: path.path) {
                Self.logger.info("Found cursor effect shader at: \(path.path)")
                return path
            }
        }

        Self.logger.warning("Could not find cursor effect shader: \(filename)")
        return nil
    }

    // MARK: - Config Generation

    /// Generates config lines for the cursor effect shader
    func generateEffectConfigLines() -> [String] {
        guard cursorEffect != .none else { return [] }

        // Aurora is generated dynamically from theme palette
        if cursorEffect == .aurora {
            guard let path = generateAuroraShader() else {
                Self.logger.error("Failed to generate aurora shader")
                return []
            }
            Self.logger.info("Generated aurora cursor effect at \(path.path)")
            return ["custom-shader = \(path.path)"]
        }

        guard let path = bundlePathForEffect(cursorEffect) else {
            Self.logger.error("Failed to find path for cursor effect: \(self.cursorEffect.rawValue)")
            return []
        }

        Self.logger.info("Generated cursor effect config: \(self.cursorEffect.rawValue) at \(path.path)")
        return ["custom-shader = \(path.path)"]
    }

    // MARK: - Aurora Shader Generation

    /// Picks two vibrant, hue-separated colors from the theme palette for the aurora effect
    private func pickAuroraColors() -> (primary: Color, secondary: Color) {
        let themeColors = ThemeManager.shared.currentThemeInfo?.colors
        let palette = themeColors?.palette ?? []
        let bgHex = themeColors?.background ?? "#1e1e2e"
        let isDarkBg = Color(hex: bgHex)?.luminance ?? 0.0 < 0.5

        // Collect saturated palette colors (indices 1-6, skip black/white)
        let candidates: [(color: Color, saturation: CGFloat, hue: CGFloat)] = palette.enumerated()
            .filter { $0.offset >= 1 && $0.offset <= 6 }
            .compactMap { (_, hex) -> (Color, CGFloat, CGFloat)? in
                guard let color = Color(hex: hex), color.saturation >= 0.20 else { return nil }
                return (color, color.saturation, color.hue)
            }
            .sorted { $0.1 > $1.1 }  // Most saturated first

        // Pick COLOR_A: most saturated
        guard let colorA = candidates.first else {
            // Fallback for monochrome/desaturated themes
            if isDarkBg {
                return (Color(hex: "#7dcfff") ?? .cyan, Color(hex: "#bb9af7") ?? .purple)
            } else {
                return (Color(hex: "#d75f5f") ?? .red, Color(hex: "#d7875f") ?? .orange)
            }
        }

        // Pick COLOR_B: next most saturated with hue separation >= 0.1 (~36 degrees)
        let colorB = candidates.dropFirst().first { candidate in
            let hueDiff = abs(candidate.hue - colorA.hue)
            let wrappedDiff = min(hueDiff, 1.0 - hueDiff)
            return wrappedDiff >= 0.1
        }

        if let colorB {
            return (colorA.color, colorB.color)
        }

        // No good second color — synthesize one by rotating hue ~65 degrees
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(colorA.color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let rotatedHue = (h + 0.18).truncatingRemainder(dividingBy: 1.0)
        let synthesized = Color(hue: rotatedHue, saturation: min(s * 1.15, 1.0), brightness: b)
        return (colorA.color, synthesized)
    }

    /// Converts a SwiftUI Color to a GLSL vec4 string
    private func colorToGLSLVec4(_ color: Color) -> String {
        let uiColor = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "vec4(%.3f, %.3f, %.3f, 1.0)", r, g, b)
    }

    /// Generates the aurora shader with theme palette colors baked in
    private func generateAuroraShader() -> URL? {
        // Load template from bundle
        let possibleTemplatePaths: [URL?] = [
            Bundle.main.bundleURL.appendingPathComponent("shaders/cursor_aurora_template.glsl"),
            Bundle.main.resourceURL?.appendingPathComponent("shaders/cursor_aurora_template.glsl"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/shaders/cursor_aurora_template.glsl"),
            Bundle.main.bundleURL.appendingPathComponent("Resources/shaders/cursor_aurora_template.glsl"),
        ]

        var templateSource: String?
        for path in possibleTemplatePaths.compactMap({ $0 }) {
            if let source = try? String(contentsOf: path, encoding: .utf8) {
                templateSource = source
                break
            }
        }

        guard let template = templateSource else {
            Self.logger.error("Could not find cursor_aurora_template.glsl in bundle")
            return nil
        }

        // Pick colors from theme palette
        let (primary, secondary) = pickAuroraColors()
        let colorAStr = colorToGLSLVec4(primary)
        let colorBStr = colorToGLSLVec4(secondary)

        // Substitute placeholders
        let generated = template
            .replacingOccurrences(of: "{{COLOR_A}}", with: colorAStr)
            .replacingOccurrences(of: "{{COLOR_B}}", with: colorBStr)

        // Write to Documents/.ghostty/shaders/
        let documentsURL = ForkUITestConfiguration.documentsDirectoryURL
        let shadersDir = documentsURL
            .appendingPathComponent(".ghostty", isDirectory: true)
            .appendingPathComponent("shaders", isDirectory: true)

        if !FileManager.default.fileExists(atPath: shadersDir.path) {
            try? FileManager.default.createDirectory(at: shadersDir, withIntermediateDirectories: true)
        }

        let outputURL = shadersDir.appendingPathComponent("cursor_aurora_generated.glsl")

        do {
            try generated.write(to: outputURL, atomically: true, encoding: .utf8)
            Self.logger.info("Wrote aurora shader with colors A=\(colorAStr), B=\(colorBStr)")
            return outputURL
        } catch {
            let desc = error.localizedDescription
            Self.logger.error("Failed to write aurora shader: \(desc)")
            return nil
        }
    }

    // MARK: - Cursor Config Generation

    /// Generates config lines for all cursor settings
    func generateCursorConfigLines() -> [String] {
        var lines: [String] = []
        lines.append("cursor-style = \(cursorStyle.configValue)")
        lines.append("cursor-style-blink = \(cursorBlinkEnabled)")
        if cursorBlinkEnabled {
            // Animated blink modes wake the renderer at ~30fps continuously;
            // in battery saver, fall back to classic blink (600ms toggles)
            // without persisting the override — the user's choice returns
            // when the saver tier lifts.
            let effectiveMode: CursorBlinkMode =
                PowerManager.shared.throttleAnimatedCursor ? .normal : cursorBlinkMode
            lines.append("cursor-blink-mode = \(effectiveMode.configValue)")
        }
        lines.append("cursor-opacity = \(cursorOpacity)")

        if let color = cursorColor {
            lines.append("cursor-color = \(color)")
        }
        if let textColor = cursorTextColor {
            lines.append("cursor-text = \(textColor)")
        }
        if cursorThickness != 0 {
            lines.append("adjust-cursor-thickness = \(cursorThickness)")
        }
        if cursorHeight != 0 {
            lines.append("adjust-cursor-height = \(cursorHeight)")
        }
        return lines
    }

    // MARK: - Notifications

    private func notifyEffectChanged() {
        // Post shader config changed for config reload
        NotificationCenter.default.post(name: .shaderConfigChanged, object: nil)
    }
}
