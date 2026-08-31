//
//  ShaderManager.swift
//  rootshell
//
//  Manages custom shader configuration for terminal cursor effects
//

import Foundation
import Observation
import os

@MainActor
@Observable
class ShaderManager {
    static let shared = ShaderManager()

    private static let logger = Logger(subsystem: "com.rootshell", category: "ShaderManager")

    // MARK: - Types

    struct CustomShader: Codable, Identifiable, Equatable {
        let id: UUID
        var name: String
        let filename: String
        let importDate: Date

        static func == (lhs: CustomShader, rhs: CustomShader) -> Bool {
            lhs.id == rhs.id
        }
    }

    enum AnimationMode: String, Codable, CaseIterable {
        case disabled = "false"
        case whenFocused = "true"
        case always = "always"

        var displayName: String {
            switch self {
            case .disabled:
                return String(localized: "Disabled", comment: "Shader animation: disabled")
            case .whenFocused:
                return String(localized: "When Focused", comment: "Shader animation: when focused")
            case .always:
                return String(localized: "Always", comment: "Shader animation: always")
            }
        }
    }

    // MARK: - UserDefaults Keys

    private static let enabledCustomKey = "enabledCustomShaders"
    private static let animationModeKey = "shaderAnimationMode"
    private static let customShadersKey = "customShadersList"

    // MARK: - Observable Properties

    var enabledCustomShaderIDs: Set<UUID> = [] {
        didSet {
            saveEnabledCustomShaders()
            notifyConfigChanged()
        }
    }

    var customShaders: [CustomShader] = [] {
        didSet {
            saveCustomShaders()
        }
    }

    var animationMode: AnimationMode = .whenFocused {
        didSet {
            saveAnimationMode()
            notifyConfigChanged()
        }
    }

    // MARK: - Initialization

    private init() {
        loadEnabledCustomShaders()
        loadCustomShaders()
        loadAnimationMode()
    }

    // MARK: - Path Resolution

    /// Returns the Documents path for a custom shader
    func documentsPathForCustomShader(_ filename: String) -> URL {
        let documentsURL = ForkUITestConfiguration.documentsDirectoryURL
        return documentsURL
            .appendingPathComponent(".ghostty", isDirectory: true)
            .appendingPathComponent("shaders", isDirectory: true)
            .appendingPathComponent(filename)
    }

    /// Returns the custom shaders directory, creating it if needed
    private var customShadersDirectory: URL {
        let documentsURL = ForkUITestConfiguration.documentsDirectoryURL
        let shadersDir = documentsURL
            .appendingPathComponent(".ghostty", isDirectory: true)
            .appendingPathComponent("shaders", isDirectory: true)

        if !FileManager.default.fileExists(atPath: shadersDir.path) {
            try? FileManager.default.createDirectory(at: shadersDir, withIntermediateDirectories: true)
        }

        return shadersDir
    }

    // MARK: - Import/Export

    /// Imports a shader from a URL, copying it to the Documents directory
    func importShader(from url: URL, name: String) throws -> CustomShader {
        // Start security-scoped access
        guard url.startAccessingSecurityScopedResource() else {
            throw ShaderImportError.accessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }

        // Generate unique filename to avoid conflicts
        let originalFilename = url.lastPathComponent
        let uniqueFilename = "\(UUID().uuidString)_\(originalFilename)"
        let destinationURL = documentsPathForCustomShader(uniqueFilename)

        // Ensure directory exists
        _ = customShadersDirectory

        // Copy the file
        try FileManager.default.copyItem(at: url, to: destinationURL)

        Self.logger.info("Imported shader: \(name) -> \(uniqueFilename)")

        let shader = CustomShader(
            id: UUID(),
            name: name,
            filename: uniqueFilename,
            importDate: Date()
        )

        customShaders.append(shader)
        return shader
    }

    /// Deletes a custom shader
    func deleteCustomShader(id: UUID) {
        guard let index = customShaders.firstIndex(where: { $0.id == id }) else { return }

        let shader = customShaders[index]
        let fileURL = documentsPathForCustomShader(shader.filename)

        // Remove from enabled set
        enabledCustomShaderIDs.remove(id)

        // Delete the file
        try? FileManager.default.removeItem(at: fileURL)

        // Remove from list
        customShaders.remove(at: index)

        Self.logger.info("Deleted shader: \(shader.name)")
    }

    // MARK: - Config Generation

    /// Generates config lines for GhosttyConfig (includes cursor effects from CursorManager)
    func generateConfigLines() -> [String] {
        var lines: [String] = []

        let cursorEffect = CursorManager.shared.cursorEffect
        Self.logger.info("Generating shader config. Cursor effect: \(cursorEffect.rawValue), enabled custom: \(self.enabledCustomShaderIDs)")

        // Add cursor effect shader from CursorManager
        lines.append(contentsOf: CursorManager.shared.generateEffectConfigLines())

        // Add enabled custom shaders
        for shader in customShaders where enabledCustomShaderIDs.contains(shader.id) {
            let path = documentsPathForCustomShader(shader.filename)
            if FileManager.default.fileExists(atPath: path.path) {
                lines.append("custom-shader = \(path.path)")
                Self.logger.info("Added custom shader: \(shader.filename) at \(path.path)")
            } else {
                Self.logger.error("Custom shader file not found: \(path.path)")
            }
        }

        // Ghostty owns shader cadence. Its renderer uses the platform display
        // link while available and a finite timer fallback otherwise.
        lines.append("custom-shader-animation = \(animationMode.rawValue)")
        Self.logger.info("Configured Ghostty shader animation mode: \(self.animationMode.rawValue)")

        Self.logger.info("Generated \(lines.count) shader config lines")
        return lines
    }

    /// Returns the total number of enabled shaders (custom only, cursor effects tracked by CursorManager)
    var enabledShaderCount: Int {
        enabledCustomShaderIDs.count
    }

    /// Returns true if any custom shaders are currently enabled
    var hasActiveShaders: Bool {
        enabledShaderCount > 0
    }

    /// Returns true if any shaders (cursor effects or custom) are active
    var hasAnyShadersActive: Bool {
        CursorManager.shared.hasActiveEffect || hasActiveShaders
    }

    // MARK: - Persistence

    private func saveEnabledCustomShaders() {
        let array = enabledCustomShaderIDs.map { $0.uuidString }
        UserDefaults.standard.set(array, forKey: Self.enabledCustomKey)
    }

    private func loadEnabledCustomShaders() {
        if let array = UserDefaults.standard.stringArray(forKey: Self.enabledCustomKey) {
            enabledCustomShaderIDs = Set(array.compactMap { UUID(uuidString: $0) })
        }
    }

    private func saveAnimationMode() {
        UserDefaults.standard.set(animationMode.rawValue, forKey: Self.animationModeKey)
    }

    private func loadAnimationMode() {
        if let rawValue = UserDefaults.standard.string(forKey: Self.animationModeKey),
           let mode = AnimationMode(rawValue: rawValue) {
            animationMode = mode
        }
    }

    private func saveCustomShaders() {
        if let data = try? JSONEncoder().encode(customShaders) {
            UserDefaults.standard.set(data, forKey: Self.customShadersKey)
        }
    }

    private func loadCustomShaders() {
        if let data = UserDefaults.standard.data(forKey: Self.customShadersKey),
           let shaders = try? JSONDecoder().decode([CustomShader].self, from: data) {
            customShaders = shaders
        }
    }

    // MARK: - Config Change Notification

    private func notifyConfigChanged() {
        // Post notification for config reload
        NotificationCenter.default.post(name: .shaderConfigChanged, object: nil)
    }
}

// MARK: - Errors

enum ShaderImportError: LocalizedError {
    case accessDenied
    case copyFailed(Error)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Access denied to the selected file"
        case .copyFailed(let error):
            return "Failed to copy shader: \(error.localizedDescription)"
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let shaderConfigChanged = Notification.Name("shaderConfigChanged")
}
