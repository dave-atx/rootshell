import Foundation
import Combine
import CoreText
import UIKit
import UniformTypeIdentifiers
import os

/// An OpenType font feature discovered from a font via CoreText
struct FontFeature: Identifiable, Hashable {
    let tag: String           // "ss01", "zero", etc.
    let name: String          // Human-readable name from font name table
    let aatTypeID: Int        // AAT feature type identifier
    let aatSelectorOn: Int    // AAT selector to enable the feature
    let aatSelectorOff: Int   // AAT selector to disable the feature
    var id: String { tag }
}

/// Manages font selection and registration for the app
@MainActor
class FontManager: ObservableObject {
    static let shared = FontManager()

    /// Information about a bundled font family
    struct FontFamilyInfo: Identifiable, Equatable {
        let id: String
        let displayName: String
        let configName: String  // Name to use in Ghostty config
        let sampleFont: UIFont?  // For preview rendering

        static func == (lhs: FontFamilyInfo, rhs: FontFamilyInfo) -> Bool {
            lhs.id == rhs.id
        }
    }

    /// Per-font cell box adjustments (percentage deltas).
    /// Maps to Ghostty `adjust-cell-width` / `adjust-cell-height` config keys.
    struct CellAdjustments: Codable, Equatable {
        var widthPercent: Int = 0
        var heightPercent: Int = 0

        var isZero: Bool { widthPercent == 0 && heightPercent == 0 }

        static let zero = CellAdjustments()
    }

    /// Sentinel key for cell adjustments stored against the Ghostty default font (nil family).
    static let defaultFontKey = "__default__"

    /// A user-imported custom font family with one or more style variants
    struct CustomFontFamily: Codable, Identifiable, Equatable {
        let id: UUID
        var displayName: String
        let configName: String
        var fontFiles: [FontFile]
        let importDate: Date

        struct FontFile: Codable, Equatable {
            let filename: String       // UUID-prefixed filename in Documents
            let originalName: String   // Original filename for display
            let styleName: String?     // "Regular", "Bold", "Italic", etc.
        }
    }

    /// Errors that can occur during font import
    enum FontImportError: LocalizedError {
        case accessDenied
        case invalidFormat(String)
        case invalidFont(String)
        case registrationFailed(String)
        case noFontsFound
        case reservedFamily(String)

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "Could not access the selected file"
            case .invalidFormat(let name):
                return "\(name) is not a valid font file (TTF or OTF required)"
            case .invalidFont(let name):
                return "\(name) could not be read as a font"
            case .registrationFailed(let name):
                return "Failed to register \(name) with the system"
            case .noFontsFound:
                return "No valid font files were found in the selection"
            case .reservedFamily(let name):
                return "\(name) is reserved for the app's interface and cannot be imported"
            }
        }
    }

    // MARK: - Keys

    private static let fontSizeKey = "fontSize"
    private static let fontFamilyKey = "fontFamily"
    private static let ligaturesEnabledKey = "ligaturesEnabled"
    private static let customFontFamiliesKey = "customFontFamilies"
    private static let replacedBundledFamiliesKey = "replacedBundledFamilies"
    private static let nerdFontMigrationKey = "nerdFontFamilyMigrationDone"
    private static let fontFeaturePrefsKey = "fontFeaturePrefs"
    private static let cellAdjustmentsKey = "cellAdjustmentPrefs"
    private static let defaultFontSize: Double = 13.0
    private static let defaultLigaturesEnabled: Bool = true

    /// Maps old Nerd Font Mono family names to their unpatched replacements.
    /// Used for one-time migration when users had a nerd font family selected.
    private static let nerdFontFamilyMigration: [String: String] = [
        "0xProto Nerd Font Mono": "0xProto",
        "FiraCode Nerd Font Mono": "Fira Code",
        "GeistMono Nerd Font Mono": "Geist Mono",
    ]

    /// Bundled fonts used only for UI glyph rendering (profile icons, etc.).
    /// Registered with CoreText but never offered as terminal fonts.
    private static let hiddenUtilityFontFamilies: Set<String> = [
        "Symbols Nerd Font Mono",
    ]

    // MARK: - Published Properties

    /// All available bundled font families
    @Published private(set) var availableFamilies: [FontFamilyInfo] = []

    /// User-imported custom font families
    @Published private(set) var customFontFamilies: [CustomFontFamily] = []

    /// System-installed monospace font families (e.g., from Font Case)
    @Published private(set) var systemFontFamilies: [FontFamilyInfo] = []

    /// Bundled font families that have been replaced by custom imports
    private(set) var replacedBundledFamilies: Set<String> = []

    /// Currently selected font size
    @Published var currentFontSize: Double {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            saveFontSize()
            fontSizeDidChange.send(currentFontSize)
        }
    }

    /// Currently selected font family (nil = Ghostty default)
    @Published var currentFontFamily: String? {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            saveFontFamily()
            fontFamilyDidChange.send(currentFontFamily)
        }
    }

    /// Whether font ligatures are enabled
    @Published var ligaturesEnabled: Bool {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            saveLigaturesEnabled()
            ligaturesDidChange.send(ligaturesEnabled)
        }
    }

    /// Per-font enabled feature tags: [fontFamilyName: Set<tag>]
    @Published private(set) var enabledFontFeatures: [String: Set<String>] = [:]

    /// Per-font cell box adjustments. Key is font family configName, or
    /// `defaultFontKey` for the Ghostty default font (nil family).
    @Published private(set) var cellAdjustments: [String: CellAdjustments] = [:]

    // MARK: - Publishers

    let fontSizeDidChange = PassthroughSubject<Double, Never>()
    let fontFamilyDidChange = PassthroughSubject<String?, Never>()
    let ligaturesDidChange = PassthroughSubject<Bool, Never>()
    let fontFeaturesDidChange = PassthroughSubject<Void, Never>()
    let cellAdjustmentsDidChange = PassthroughSubject<Void, Never>()

    private let logger = Logger(subsystem: "com.rootshell", category: "FontManager")
    private var fontRegistrationObserver: NSObjectProtocol?

    // MARK: - Initialization

    private init() {
        // Load saved font size
        let savedSize = UserDefaults.standard.double(forKey: Self.fontSizeKey)
        self.currentFontSize = savedSize > 0 ? savedSize : Self.defaultFontSize

        // Load saved font family (nil = use Ghostty default)
        self.currentFontFamily = UserDefaults.standard.string(forKey: Self.fontFamilyKey)

        // Load saved ligatures enabled state or default to true
        if UserDefaults.standard.object(forKey: Self.ligaturesEnabledKey) != nil {
            self.ligaturesEnabled = UserDefaults.standard.bool(forKey: Self.ligaturesEnabledKey)
        } else {
            self.ligaturesEnabled = Self.defaultLigaturesEnabled
        }

        // Load saved font feature preferences
        // Clean up any previously-seeded legacy defaults (from earlier migration code)
        if UserDefaults.standard.bool(forKey: "fontFeatureMigrationV1Done") {
            UserDefaults.standard.removeObject(forKey: Self.fontFeaturePrefsKey)
            UserDefaults.standard.removeObject(forKey: "fontFeatureMigrationV1Done")
        }
        if let data = UserDefaults.standard.data(forKey: Self.fontFeaturePrefsKey),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            self.enabledFontFeatures = decoded.mapValues { Set($0) }
        }

        // Load saved cell adjustments
        if let data = UserDefaults.standard.data(forKey: Self.cellAdjustmentsKey),
           let decoded = try? JSONDecoder().decode([String: CellAdjustments].self, from: data) {
            self.cellAdjustments = decoded
        }

        // One-time migration: map old Nerd Font Mono family names to unpatched equivalents.
        // Skip when protected data is unavailable — bool(forKey:) returns false (not migrated)
        // which would write the migration-done flag to an empty/encrypted plist.
        if ProtectedDataGuard.isAvailable,
           !UserDefaults.standard.bool(forKey: Self.nerdFontMigrationKey) {
            if let current = self.currentFontFamily,
               let migrated = Self.nerdFontFamilyMigration[current] {
                self.currentFontFamily = migrated
                UserDefaults.standard.set(migrated, forKey: Self.fontFamilyKey)
            }
            UserDefaults.standard.set(true, forKey: Self.nerdFontMigrationKey)
        }

        // Load replaced bundled families before registration
        if let saved = UserDefaults.standard.stringArray(forKey: Self.replacedBundledFamiliesKey) {
            replacedBundledFamilies = Set(saved)
        }

        // Register bundled fonts with iOS, then custom fonts, then load available families
        registerBundledFonts()
        let registeredCustomFamilies = registerCustomFonts()

        // Reconcile: prune replacement markers where the custom family failed to register
        // any files (missing files, corruption, incompatible fonts). This recovers bundled
        // fonts that would otherwise stay permanently suppressed.
        let staleReplacements = replacedBundledFamilies.subtracting(registeredCustomFamilies)
        if !staleReplacements.isEmpty {
            for family in staleReplacements {
                logger.warning("Stale bundled replacement for '\(family)' — restoring bundled font")
                reregisterBundledFontsForFamily(family)
            }
            saveReplacedBundledFamilies()
        }

        loadAvailableFamilies()
        loadSystemFonts()
        setupFontRegistrationObserver()
    }

    // MARK: - Font Registration

    /// Register all bundled TTF fonts with iOS so they can be discovered by CoreText
    private func registerBundledFonts() {
        guard let fontsURL = findFontsDirectory() else {
            logger.warning("Fonts directory not found in bundle")
            return
        }

        let fileManager = FileManager.default
        var registeredCount = 0

        guard let enumerator = fileManager.enumerator(
            at: fontsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            logger.error("Failed to create enumerator for fonts directory")
            return
        }

        for case let fileURL as URL in enumerator {
            // Only process TTF and OTF font files
            let ext = fileURL.pathExtension.lowercased()
            guard ext == "ttf" || ext == "otf" else { continue }

            let filename = fileURL.lastPathComponent

            // Skip fonts whose family has been replaced by a custom import
            if let (_, configName) = extractFontInfo(from: fileURL),
               replacedBundledFamilies.contains(configName) {
                logger.debug("Skipping replaced bundled font: \(filename)")
                continue
            }

            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(fileURL as CFURL, .process, &error) {
                registeredCount += 1
                logger.debug("Registered font: \(filename)")
            } else if let cfError = error?.takeRetainedValue() {
                // Font might already be registered - not necessarily an error
                logger.debug("Font registration note for \(filename): \(cfError)")
            }
        }

        logger.info("Registered \(registeredCount) bundled fonts")
    }

    /// Find the fonts directory in the app bundle
    private func findFontsDirectory() -> URL? {
        let fileManager = FileManager.default

        // Try multiple possible locations (similar to ThemeManager)
        let possiblePaths: [URL?] = [
            Bundle.main.bundleURL.appendingPathComponent("fonts"),
            Bundle.main.resourceURL?.appendingPathComponent("fonts"),
            Bundle.main.resourceURL?
                .appendingPathComponent("Resources")
                .appendingPathComponent("ghostty")
                .appendingPathComponent("fonts"),
            Bundle.main.bundleURL
                .appendingPathComponent("Resources")
                .appendingPathComponent("ghostty")
                .appendingPathComponent("fonts")
        ]

        for path in possiblePaths.compactMap({ $0 }) {
            if fileManager.fileExists(atPath: path.path) {
                logger.info("Found fonts directory at: \(path.path)")
                return path
            }
        }

        return nil
    }

    // MARK: - Custom Font Storage

    /// Directory for user-imported font files
    private var customFontsDirectory: URL {
        let documentsURL = ForkUITestConfiguration.isEnabled
            ? ForkUITestConfiguration.documentsDirectoryURL
            : FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fontsDir = documentsURL
            .appendingPathComponent(".ghostty", isDirectory: true)
            .appendingPathComponent("fonts", isDirectory: true)

        if !FileManager.default.fileExists(atPath: fontsDir.path) {
            try? FileManager.default.createDirectory(at: fontsDir, withIntermediateDirectories: true)
        }

        return fontsDir
    }

    /// Full path for a custom font file
    private func documentsPathForCustomFont(_ filename: String) -> URL {
        customFontsDirectory.appendingPathComponent(filename)
    }

    /// Register all previously-imported custom fonts with CoreText.
    /// Returns the set of family configNames that successfully registered at least one file.
    @discardableResult
    private func registerCustomFonts() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: Self.customFontFamiliesKey),
              let families = try? JSONDecoder().decode([CustomFontFamily].self, from: data) else {
            return []
        }

        customFontFamilies = families
        var registeredCount = 0
        var successfulFamilies: Set<String> = []

        for family in families {
            for file in family.fontFiles {
                let fileURL = documentsPathForCustomFont(file.filename)
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    let name = file.originalName
                    logger.warning("Custom font file missing: \(name)")
                    continue
                }

                var error: Unmanaged<CFError>?
                if CTFontManagerRegisterFontsForURL(fileURL as CFURL, .process, &error) {
                    registeredCount += 1
                    successfulFamilies.insert(family.configName)
                } else if isAlreadyRegisteredError(error) {
                    // Font is already registered (e.g., also installed via system/Font Case).
                    // The font is usable — count the family as valid.
                    successfulFamilies.insert(family.configName)
                    let name = file.originalName
                    logger.debug("Custom font already registered: \(name)")
                } else if let cfError = error?.takeRetainedValue() {
                    let name = file.originalName
                    logger.debug("Custom font registration note for \(name): \(cfError)")
                }
            }
        }

        let count = registeredCount
        logger.info("Registered \(count) custom font files")
        return successfulFamilies
    }

    // MARK: - Custom Font Import

    /// Import font files, grouping by family name. Returns newly created or updated families.
    @discardableResult
    func importFonts(from urls: [URL]) throws -> [CustomFontFamily] {
        struct ImportedFile {
            let familyName: String
            let styleName: String?
            let filename: String
            let originalName: String
        }

        var importedFiles: [ImportedFile] = []
        // Track bundled families unregistered during this import for rollback on failure
        var unregisteredBundledFamilies: Set<String> = []

        // Rollback helper: undo imported custom files first, then restore bundled families.
        // Order matters: bundled re-registration can fail if custom fonts with the same
        // family name are still registered.
        func rollbackOnFailure() {
            for file in importedFiles {
                let fileURL = documentsPathForCustomFont(file.filename)
                var error: Unmanaged<CFError>?
                CTFontManagerUnregisterFontsForURL(fileURL as CFURL, .process, &error)
                try? FileManager.default.removeItem(at: fileURL)
            }
            for family in unregisteredBundledFamilies {
                reregisterBundledFontsForFamily(family)
            }
        }

        for url in urls {
            // Start security-scoped access
            guard url.startAccessingSecurityScopedResource() else {
                rollbackOnFailure()
                throw FontImportError.accessDenied
            }
            defer { url.stopAccessingSecurityScopedResource() }

            // Validate file extension
            let ext = url.pathExtension.lowercased()
            guard ext == "ttf" || ext == "otf" else {
                let name = url.lastPathComponent
                rollbackOnFailure()
                throw FontImportError.invalidFormat(name)
            }

            // Validate font data
            guard let data = try? Data(contentsOf: url),
                  let provider = CGDataProvider(data: data as CFData),
                  let cgFont = CGFont(provider) else {
                let name = url.lastPathComponent
                rollbackOnFailure()
                throw FontImportError.invalidFont(name)
            }

            // Extract metadata
            let ctFont = CTFontCreateWithGraphicsFont(cgFont, 12, nil, nil)
            let familyName = CTFontCopyFamilyName(ctFont) as String
            let styleName = CTFontCopyName(ctFont, kCTFontStyleNameKey) as String?

            // UI-only utility families would collide with the bundled copy and
            // surface in the terminal font list via customFontFamilies
            if Self.hiddenUtilityFontFamilies.contains(familyName) {
                rollbackOnFailure()
                throw FontImportError.reservedFamily(familyName)
            }

            // Copy to Documents with UUID prefix
            let originalName = url.lastPathComponent
            let uniqueFilename = "\(UUID().uuidString)_\(originalName)"
            let destinationURL = documentsPathForCustomFont(uniqueFilename)

            do {
                try data.write(to: destinationURL)
            } catch {
                rollbackOnFailure()
                throw error
            }

            // Register with CoreText immediately
            var regError: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(destinationURL as CFURL, .process, &regError) {
                if isBundledFontFamily(familyName) {
                    // Conflict with bundled font — unregister bundled version and retry
                    unregisterBundledFontsForFamily(familyName)
                    unregisteredBundledFamilies.insert(familyName)
                    var retryError: Unmanaged<CFError>?
                    if !CTFontManagerRegisterFontsForURL(destinationURL as CFURL, .process, &retryError) {
                        try? FileManager.default.removeItem(at: destinationURL)
                        rollbackOnFailure()
                        throw FontImportError.registrationFailed(originalName)
                    }
                } else if isAlreadyRegisteredError(regError) && UIFont.familyNames.contains(familyName) {
                    // Font is already registered on the system (e.g., via Font Case).
                    // Keep the file; Ghostty resolves by family name so it will work.
                    logger.info("Font \(originalName) already available via system, storing metadata only")
                } else {
                    // Genuine registration failure — not a duplicate conflict
                    try? FileManager.default.removeItem(at: destinationURL)
                    rollbackOnFailure()
                    throw FontImportError.registrationFailed(originalName)
                }
            }

            importedFiles.append(ImportedFile(
                familyName: familyName,
                styleName: styleName,
                filename: uniqueFilename,
                originalName: originalName
            ))
        }

        if importedFiles.isEmpty {
            throw FontImportError.noFontsFound
        }

        // Group by family name and merge into existing families
        var updatedFamilyIDs: Set<UUID> = []
        let groupedByFamily = Dictionary(grouping: importedFiles, by: \.familyName)

        for (familyName, files) in groupedByFamily {
            let newFontFiles = files.map { file in
                CustomFontFamily.FontFile(
                    filename: file.filename,
                    originalName: file.originalName,
                    styleName: file.styleName
                )
            }

            if let existingIndex = customFontFamilies.firstIndex(where: { $0.configName == familyName }) {
                // Merge new styles, skip duplicates by style name
                let existingStyles = Set(customFontFamilies[existingIndex].fontFiles.compactMap(\.styleName))
                for newFile in newFontFiles {
                    if let style = newFile.styleName, existingStyles.contains(style) {
                        continue
                    }
                    customFontFamilies[existingIndex].fontFiles.append(newFile)
                }
                updatedFamilyIDs.insert(customFontFamilies[existingIndex].id)
            } else {
                let family = CustomFontFamily(
                    id: UUID(),
                    displayName: familyName,
                    configName: familyName,
                    fontFiles: newFontFiles,
                    importDate: Date()
                )
                customFontFamilies.append(family)
                updatedFamilyIDs.insert(family.id)
            }
        }

        // Sort custom families alphabetically
        customFontFamilies.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }

        saveCustomFontFamilies()

        // Now that the import transaction has fully succeeded, persist replacement state
        if !unregisteredBundledFamilies.isEmpty {
            saveReplacedBundledFamilies()
            loadAvailableFamilies()
        }

        // Refresh system fonts so newly-imported families don't appear in both sections
        loadSystemFonts()

        return customFontFamilies.filter { updatedFamilyIDs.contains($0.id) }
    }

    /// Delete a custom font family, unregistering from CoreText and removing files
    func deleteCustomFontFamily(id: UUID) {
        guard let index = customFontFamilies.firstIndex(where: { $0.id == id }) else { return }

        let family = customFontFamilies[index]
        let configName = family.configName
        let wasReplacingBundled = replacedBundledFamilies.contains(configName)

        // Unregister each font file from CoreText and delete from disk
        for file in family.fontFiles {
            let fileURL = documentsPathForCustomFont(file.filename)

            var error: Unmanaged<CFError>?
            CTFontManagerUnregisterFontsForURL(fileURL as CFURL, .process, &error)

            try? FileManager.default.removeItem(at: fileURL)
        }

        // If the deleted font was selected, reset to Ghostty Default
        if currentFontFamily == configName {
            currentFontFamily = nil
        }

        customFontFamilies.remove(at: index)
        saveCustomFontFamilies()

        // If this custom font was replacing a bundled font, restore the bundled version
        if wasReplacingBundled {
            reregisterBundledFontsForFamily(configName)
            saveReplacedBundledFamilies()
            loadAvailableFamilies()
        }

        // Refresh system fonts so deleted family can reappear in System section if applicable
        loadSystemFonts()
    }

    /// Re-reads custom font families from UserDefaults, registers any new fonts with CoreText,
    /// and refreshes the available families list. Call after restoring fonts from a backup.
    func reloadCustomFonts() {
        registerCustomFonts()
        loadAvailableFamilies()
        loadSystemFonts()
    }

    /// Create a preview font for a custom font family (Regular style preferred)
    func sampleFontForCustomFamily(_ family: CustomFontFamily) -> UIFont? {
        // Prefer Regular variant, fall back to first available
        let regularFile = family.fontFiles.first { $0.styleName?.contains("Regular") == true }
        let file = regularFile ?? family.fontFiles.first

        guard let file else { return nil }

        let fileURL = documentsPathForCustomFont(file.filename)
        return createFont(from: fileURL, size: 16)
    }

    // MARK: - Load Available Families

    /// Scan the fonts directory and build list of available font families
    private func loadAvailableFamilies() {
        guard let fontsURL = findFontsDirectory() else { return }

        let fileManager = FileManager.default
        var familyMap: [String: (displayName: String, configName: String, fontURL: URL)] = [:]

        guard let enumerator = fileManager.enumerator(
            at: fontsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard ext == "ttf" || ext == "otf" else { continue }

            let filename = fileURL.lastPathComponent

            // Extract font family name from the font file
            if let (familyName, configName) = extractFontInfo(from: fileURL) {
                // Skip UI-only utility fonts and families replaced by custom imports
                guard !Self.hiddenUtilityFontFamilies.contains(familyName) else { continue }
                guard !replacedBundledFamilies.contains(configName) else { continue }

                // Prefer Regular weight for preview
                let isRegular = filename.contains("Regular")
                if familyMap[familyName] == nil || isRegular {
                    familyMap[familyName] = (familyName, configName, fileURL)
                }
            }
        }

        // Build FontFamilyInfo array
        var families: [FontFamilyInfo] = []
        for (id, info) in familyMap {
            let sampleFont = createFont(from: info.fontURL, size: 16)

            families.append(FontFamilyInfo(
                id: id,
                displayName: info.displayName,
                configName: info.configName,
                sampleFont: sampleFont
            ))
        }

        // Sort alphabetically
        families.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        self.availableFamilies = families
        logger.info("Loaded \(families.count) font families")
    }

    // MARK: - System Font Discovery

    /// Discover monospace fonts installed on the device (e.g., via Font Case)
    private func loadSystemFonts() {
        let bundledConfigNames = Set(availableFamilies.map(\.configName))
        let customConfigNames = Set(customFontFamilies.map(\.configName))

        var systemFonts: [FontFamilyInfo] = []
        var seenFamilies = Set<String>()

        // Use UIFontDescriptor matching to discover all monospace fonts system-wide.
        // This finds fonts from UIFont.familyNames AND user-installed fonts (Font Case etc.)
        // when the com.apple.developer.user-fonts entitlement is present.
        let monoDescriptor = UIFontDescriptor(fontAttributes: [
            .traits: [UIFontDescriptor.TraitKey.symbolic: UIFontDescriptor.SymbolicTraits.traitMonoSpace.rawValue]
        ])
        let matchedDescriptors = monoDescriptor.matchingFontDescriptors(withMandatoryKeys: nil)
        let matchCount = matchedDescriptors.count
        logger.info("[SystemFonts] UIFontDescriptor monospace matches: \(matchCount)")

        for descriptor in matchedDescriptors {
            let font = UIFont(descriptor: descriptor, size: 16)
            let familyName = font.familyName

            guard !seenFamilies.contains(familyName),
                  !bundledConfigNames.contains(familyName),
                  !customConfigNames.contains(familyName),
                  !Self.hiddenUtilityFontFamilies.contains(familyName) else { continue }

            systemFonts.append(FontFamilyInfo(
                id: familyName,
                displayName: familyName,
                configName: familyName,
                sampleFont: font
            ))
            seenFamilies.insert(familyName)
        }

        let traitCount = systemFonts.count
        logger.info("[SystemFonts] From trait matching: \(traitCount) monospace families")

        // Also check UIFont.familyNames with glyph-advance fallback for fonts that
        // don't set the monospace trait but are actually monospace (e.g., Berkeley Mono)
        for familyName in UIFont.familyNames {
            guard !seenFamilies.contains(familyName),
                  !bundledConfigNames.contains(familyName),
                  !customConfigNames.contains(familyName),
                  !Self.hiddenUtilityFontFamilies.contains(familyName) else { continue }

            guard let font = UIFont(name: familyName, size: 16) else { continue }
            guard self.isMonospaceByGlyphAdvance(font) else { continue }

            logger.info("[SystemFonts] Glyph-advance detected mono: '\(familyName)'")
            systemFonts.append(FontFamilyInfo(
                id: familyName,
                displayName: familyName,
                configName: familyName,
                sampleFont: font
            ))
            seenFamilies.insert(familyName)
        }

        // Check CoreText registered font descriptors for user-installed fonts
        // that may not appear in UIFont.familyNames or descriptor matching
        let descriptors = CTFontManagerCopyRegisteredFontDescriptors(.user, true) as? [CTFontDescriptor] ?? []
        let ctCount = descriptors.count
        logger.info("[SystemFonts] CTFontManager .user scope: \(ctCount) descriptors")

        for descriptor in descriptors {
            guard let familyName = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String else {
                continue
            }
            guard !seenFamilies.contains(familyName),
                  !bundledConfigNames.contains(familyName),
                  !customConfigNames.contains(familyName),
                  !Self.hiddenUtilityFontFamilies.contains(familyName) else { continue }

            let ctFont = CTFontCreateWithFontDescriptor(descriptor, 16, nil)
            let uiFont = ctFont as UIFont
            let traits = uiFont.fontDescriptor.symbolicTraits
            let isMono = traits.contains(.traitMonoSpace) || self.isMonospaceByGlyphAdvance(uiFont)

            logger.info("[SystemFonts] CT user font: '\(familyName)' mono=\(isMono)")
            guard isMono else { continue }

            systemFonts.append(FontFamilyInfo(
                id: familyName,
                displayName: familyName,
                configName: familyName,
                sampleFont: uiFont
            ))
            seenFamilies.insert(familyName)
        }

        systemFonts.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }

        self.systemFontFamilies = systemFonts
        let totalCount = systemFonts.count
        logger.info("[SystemFonts] Total: \(totalCount) system monospace font families")
        for sf in systemFonts {
            let name = sf.displayName
            logger.info("[SystemFonts]   -> \(name)")
        }
    }

    /// Check if a font is monospace by comparing glyph advance widths.
    /// Some fonts (e.g., Berkeley Mono) don't set the OS/2 isFixedPitch flag,
    /// so UIFontDescriptor.symbolicTraits won't include .traitMonoSpace.
    /// This fallback compares advances of characters with typically extreme width differences.
    private func isMonospaceByGlyphAdvance(_ font: UIFont) -> Bool {
        let ctFont = font as CTFont
        var characters: [UniChar] = [0x004D, 0x0069, 0x0057, 0x002E] // M, i, W, .
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(ctFont, &characters, &glyphs, characters.count) else { return false }
        guard glyphs.allSatisfy({ $0 != 0 }) else { return false }
        var advances = [CGSize](repeating: .zero, count: characters.count)
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, glyphs, &advances, characters.count)
        let ref = advances[0].width
        guard ref > 0 else { return false }
        return advances.allSatisfy { abs($0.width - ref) < 0.01 }
    }

    private func setupFontRegistrationObserver() {
        fontRegistrationObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(kCTFontManagerRegisteredFontsChangedNotification as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.loadSystemFonts()
            }
        }
    }

    /// Extract font family name and config name from a font file
    private func extractFontInfo(from url: URL) -> (displayName: String, configName: String)? {
        guard let provider = CGDataProvider(url: url as CFURL),
              let cgFont = CGFont(provider) else {
            return nil
        }

        // Create a CTFont to get the family name
        let ctFont = CTFontCreateWithGraphicsFont(cgFont, 12, nil, nil)
        let familyName = CTFontCopyFamilyName(ctFont) as String

        // The config name is the font family name as-is
        return (familyName, familyName)
    }

    /// Create a UIFont from a TTF file URL
    private func createFont(from url: URL, size: CGFloat) -> UIFont? {
        guard let provider = CGDataProvider(url: url as CFURL),
              let cgFont = CGFont(provider) else {
            return nil
        }

        let ctFont = CTFontCreateWithGraphicsFont(cgFont, size, nil, nil)
        return ctFont as UIFont
    }

    /// Check if a CTFontManager registration error indicates a duplicate/already-registered font
    private func isAlreadyRegisteredError(_ error: Unmanaged<CFError>?) -> Bool {
        guard let cfError = error?.takeUnretainedValue() else { return false }
        let domain = CFErrorGetDomain(cfError) as String
        let code = CFErrorGetCode(cfError)
        // CTFontManagerError codes: .alreadyRegistered = 105, .duplicatedName = 106
        guard domain == kCTFontManagerErrorDomain as String else { return false }
        return code == 105 || code == 106
    }

    // MARK: - Bundled Font Replacement Helpers

    /// Check if a font family name matches one of our bundled font families
    private func isBundledFontFamily(_ familyName: String) -> Bool {
        // Utility fonts can never be replaced by imports; the profile icon UI depends on them
        guard !Self.hiddenUtilityFontFamilies.contains(familyName) else { return false }
        guard let fontsURL = findFontsDirectory() else { return false }
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: fontsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard ext == "ttf" || ext == "otf" else { continue }

            if let (_, configName) = extractFontInfo(from: fileURL), configName == familyName {
                return true
            }
        }
        return false
    }

    /// Unregister all bundled font files for a given family from CoreText.
    /// Updates in-memory state only; call `saveReplacedBundledFamilies()` to persist after the transaction succeeds.
    private func unregisterBundledFontsForFamily(_ familyName: String) {
        guard let fontsURL = findFontsDirectory() else { return }
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: fontsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard ext == "ttf" || ext == "otf" else { continue }

            if let (_, configName) = extractFontInfo(from: fileURL), configName == familyName {
                var error: Unmanaged<CFError>?
                CTFontManagerUnregisterFontsForURL(fileURL as CFURL, .process, &error)
                let filename = fileURL.lastPathComponent
                logger.debug("Unregistered bundled font: \(filename)")
            }
        }

        replacedBundledFamilies.insert(familyName)
    }

    /// Re-register bundled font files for a family that was previously replaced
    private func reregisterBundledFontsForFamily(_ familyName: String) {
        guard let fontsURL = findFontsDirectory() else { return }
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: fontsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard ext == "ttf" || ext == "otf" else { continue }

            if let (_, configName) = extractFontInfo(from: fileURL), configName == familyName {
                var error: Unmanaged<CFError>?
                if CTFontManagerRegisterFontsForURL(fileURL as CFURL, .process, &error) {
                    let filename = fileURL.lastPathComponent
                    logger.debug("Re-registered bundled font: \(filename)")
                }
            }
        }

        replacedBundledFamilies.remove(familyName)
    }

    private func saveReplacedBundledFamilies() {
        UserDefaults.standard.set(Array(replacedBundledFamilies), forKey: Self.replacedBundledFamiliesKey)
    }

    // MARK: - Persistence

    private func saveFontSize() {
        UserDefaults.standard.set(currentFontSize, forKey: Self.fontSizeKey)
    }

    private func saveFontFamily() {
        if let family = currentFontFamily {
            UserDefaults.standard.set(family, forKey: Self.fontFamilyKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.fontFamilyKey)
        }
    }

    private func saveLigaturesEnabled() {
        UserDefaults.standard.set(ligaturesEnabled, forKey: Self.ligaturesEnabledKey)
    }

    private func saveCustomFontFamilies() {
        if let data = try? JSONEncoder().encode(customFontFamilies) {
            UserDefaults.standard.set(data, forKey: Self.customFontFamiliesKey)
        }
    }

    private func saveFontFeaturePrefs() {
        let serializable = enabledFontFeatures.mapValues { Array($0) }
        if let data = try? JSONEncoder().encode(serializable) {
            UserDefaults.standard.set(data, forKey: Self.fontFeaturePrefsKey)
        }
    }

    private func saveCellAdjustments() {
        // Drop zeroed entries so the dict stays clean across launches.
        let pruned = cellAdjustments.filter { !$0.value.isZero }
        if let data = try? JSONEncoder().encode(pruned) {
            UserDefaults.standard.set(data, forKey: Self.cellAdjustmentsKey)
        }
    }

    // MARK: - Config Application

    /// Apply the current font size to a Ghostty configuration
    func applyFontSize(to config: Ghostty.Config) -> Bool {
        return config.setFontSize(Int(currentFontSize))
    }

    /// Apply the current font family to a Ghostty configuration
    func applyFontFamily(to config: Ghostty.Config) -> Bool {
        guard let family = currentFontFamily else {
            // nil = use Ghostty default, nothing to apply
            return true
        }
        return config.setFontFamily(family)
    }

    // MARK: - Helper Properties

    /// Display name for the current font family
    var currentFontFamilyDisplayName: String {
        if let family = currentFontFamily {
            if let bundled = availableFamilies.first(where: { $0.configName == family }) {
                return bundled.displayName
            }
            if let custom = customFontFamilies.first(where: { $0.configName == family }) {
                return custom.displayName
            }
            if let system = systemFontFamilies.first(where: { $0.configName == family }) {
                return system.displayName
            }
            return family
        }
        return "Ghostty Default"
    }

    // MARK: - Font Feature Discovery & Management

    /// AAT type/selector mappings for OpenType stylistic set features.
    /// Type 35 = kStylisticAlternativesType, Type 14 = kTypographicExtrasType.
    private static let aatToOpenType: [(aatTypeID: Int, aatSelectorOn: Int, aatSelectorOff: Int, tag: String)] = [
        (35, 2, 3, "ss01"),
        (35, 4, 5, "ss02"),
        (35, 6, 7, "ss03"),
        (35, 8, 9, "ss04"),
        (35, 10, 11, "ss05"),
        (35, 12, 13, "ss06"),
        (35, 14, 15, "ss07"),
        (35, 16, 17, "ss08"),
        (35, 18, 19, "ss09"),
        (35, 20, 21, "ss10"),
        (35, 22, 23, "ss11"),
        (35, 24, 25, "ss12"),
        (35, 26, 27, "ss13"),
        (35, 28, 29, "ss14"),
        (35, 30, 31, "ss15"),
        (35, 32, 33, "ss16"),
        (35, 34, 35, "ss17"),
        (35, 36, 37, "ss18"),
        (35, 38, 39, "ss19"),
        (35, 40, 41, "ss20"),
        (14, 4, 5, "zero"),
    ]

    /// Discover available OpenType font features for the given font family.
    /// Uses CoreText AAT feature tables and maps to OpenType tags.
    func discoverFeatures(for fontFamily: String?) -> [FontFeature] {
        guard let familyName = fontFamily else { return [] }

        // Create a CTFont from the family name
        let ctFont = CTFontCreateWithName(familyName as CFString, 16, nil)

        // Verify we got the right font (CoreText may substitute)
        let resolvedFamily = CTFontCopyFamilyName(ctFont) as String
        guard resolvedFamily == familyName else {
            logger.debug("Font family mismatch: requested '\(familyName)', got '\(resolvedFamily)'")
            return []
        }

        // Get AAT feature tables
        guard let features = CTFontCopyFeatures(ctFont) as? [[String: Any]] else {
            return []
        }

        // Build lookup of available AAT type+selector pairs and their names
        var availableSelectors: [String: String] = [:]  // "typeID:selectorID" -> name
        for feature in features {
            guard let typeID = feature[kCTFontFeatureTypeIdentifierKey as String] as? Int,
                  let selectors = feature[kCTFontFeatureTypeSelectorsKey as String] as? [[String: Any]] else {
                continue
            }

            for selector in selectors {
                guard let selectorID = selector[kCTFontFeatureSelectorIdentifierKey as String] as? Int else {
                    continue
                }
                let name = selector[kCTFontFeatureSelectorNameKey as String] as? String ?? ""
                let key = "\(typeID):\(selectorID)"
                availableSelectors[key] = name
            }
        }

        // Cross-reference with our mapping table
        var result: [FontFeature] = []
        for mapping in Self.aatToOpenType {
            let onKey = "\(mapping.aatTypeID):\(mapping.aatSelectorOn)"
            guard let name = availableSelectors[onKey] else { continue }

            let displayName = name.isEmpty ? mapping.tag.uppercased() : name
            result.append(FontFeature(
                tag: mapping.tag,
                name: displayName,
                aatTypeID: mapping.aatTypeID,
                aatSelectorOn: mapping.aatSelectorOn,
                aatSelectorOff: mapping.aatSelectorOff
            ))
        }

        return result
    }

    /// Get the set of enabled feature tags for a font family
    func enabledFeatureTags(for fontFamily: String?) -> Set<String> {
        guard let family = fontFamily else { return [] }
        return enabledFontFeatures[family] ?? []
    }

    /// Toggle a font feature on or off for a font family
    func setFeatureEnabled(_ tag: String, enabled: Bool, for fontFamily: String?) {
        guard let family = fontFamily else { return }

        var tags = enabledFontFeatures[family] ?? []
        if enabled {
            tags.insert(tag)
        } else {
            tags.remove(tag)
        }
        enabledFontFeatures[family] = tags

        saveFontFeaturePrefs()
        fontFeaturesDidChange.send()
    }

    /// Return a copy of the font with the user's enabled features applied via AAT attributes.
    func applyEnabledFeatures(to font: UIFont, for fontFamily: String?) -> UIFont {
        guard let family = fontFamily else { return font }
        let enabledTags = enabledFontFeatures[family] ?? []
        guard !enabledTags.isEmpty else { return font }

        var featureSettings: [[UIFontDescriptor.FeatureKey: Int]] = []
        for mapping in Self.aatToOpenType where enabledTags.contains(mapping.tag) {
            featureSettings.append([
                .type: mapping.aatTypeID,
                .selector: mapping.aatSelectorOn
            ])
        }
        guard !featureSettings.isEmpty else { return font }

        let descriptor = font.fontDescriptor.addingAttributes([
            .featureSettings: featureSettings
        ])
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    /// Generate Ghostty config lines for the current font's enabled features
    func fontFeatureConfigLines() -> [String] {
        let tags = enabledFeatureTags(for: currentFontFamily)
        return tags.sorted().map { "font-feature = \($0)" }
    }

    // MARK: - Cell Adjustments

    /// Storage key for a given font family (`defaultFontKey` when nil).
    private func cellAdjustmentKey(for fontFamily: String?) -> String {
        fontFamily ?? Self.defaultFontKey
    }

    /// Returns the saved cell adjustments for a font family, or `.zero` if none.
    func cellAdjustments(for fontFamily: String?) -> CellAdjustments {
        cellAdjustments[cellAdjustmentKey(for: fontFamily)] ?? .zero
    }

    /// Replace the cell adjustments for a font family. Persists and notifies.
    func setCellAdjustments(_ adjustments: CellAdjustments, for fontFamily: String?) {
        let key = cellAdjustmentKey(for: fontFamily)
        if adjustments.isZero {
            cellAdjustments.removeValue(forKey: key)
        } else {
            cellAdjustments[key] = adjustments
        }
        saveCellAdjustments()
        cellAdjustmentsDidChange.send()
    }

    /// Update only the width percentage for a font family.
    func setCellWidth(_ percent: Int, for fontFamily: String?) {
        var adj = cellAdjustments(for: fontFamily)
        adj.widthPercent = percent
        setCellAdjustments(adj, for: fontFamily)
    }

    /// Update only the height percentage for a font family.
    func setCellHeight(_ percent: Int, for fontFamily: String?) {
        var adj = cellAdjustments(for: fontFamily)
        adj.heightPercent = percent
        setCellAdjustments(adj, for: fontFamily)
    }

    /// Generate Ghostty config lines for the current font's cell adjustments.
    /// Zero-valued axes are omitted so the config stays minimal.
    func cellAdjustmentConfigLines() -> [String] {
        let adj = cellAdjustments(for: currentFontFamily)
        var lines: [String] = []
        if adj.widthPercent != 0 {
            lines.append("adjust-cell-width = \(adj.widthPercent)%")
        }
        if adj.heightPercent != 0 {
            lines.append("adjust-cell-height = \(adj.heightPercent)%")
        }
        return lines
    }
}
