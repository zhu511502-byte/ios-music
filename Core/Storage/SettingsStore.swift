import Foundation
import Combine
import SwiftUI
import UIKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}


@MainActor
final class SettingsStore: ObservableObject {
    @Published var serverURL: String {
        didSet { defaults.set(serverURL, forKey: Keys.serverURL) }
    }
    @Published var preferredQuality: Quality {
        didSet { defaults.set(preferredQuality.rawValue, forKey: Keys.preferredQuality) }
    }
    @Published var selectedSourceID: String? {
        didSet { defaults.set(selectedSourceID, forKey: Keys.selectedSourceID) }
    }
    @Published var allowCellular: Bool {
        didSet { defaults.set(allowCellular, forKey: Keys.allowCellular) }
    }
    @Published var showExplicitContent: Bool {
        didSet { defaults.set(showExplicitContent, forKey: Keys.showExplicitContent) }
    }

    /// Custom background chosen from the photo library.
    @Published private(set) var backgroundImage: UIImage? = nil

    /// Custom background appearance.
    @Published var backgroundBlur: Double {
        didSet { defaults.set(backgroundBlur, forKey: Keys.backgroundBlur) }
    }
    @Published var backgroundDim: Double {
        didSet { defaults.set(backgroundDim, forKey: Keys.backgroundDim) }
    }
    @Published var backgroundOpacity: Double {
        didSet { defaults.set(backgroundOpacity, forKey: Keys.backgroundOpacity) }
    }

    /// Light palette for the browsing screens (player/lyrics stay dark).
    @Published var lightBackground: Bool {
        didSet {
            defaults.set(lightBackground, forKey: Keys.lightBackground)
            ThemeStore.shared.applyBackgroundStyle(light: lightBackground)
        }
    }

    /// App-wide appearance: system, light, or dark.
    @Published var appearanceMode: AppAppearance {
        didSet {
            defaults.set(appearanceMode.rawValue, forKey: Keys.appearanceMode)
            ThemeStore.shared.applyAppearance(appearanceMode)
        }
    }

    /// Character-by-character highlight on the active lyric line.
    @Published var karaokeLyrics: Bool {
        didSet { defaults.set(karaokeLyrics, forKey: Keys.karaokeLyrics) }
    }

    /// Lyric page appearance (edited from the ellipsis menu on that page).
    @Published var lyricsFontSize: Double {
        didSet { defaults.set(lyricsFontSize, forKey: Keys.lyricsFontSize) }
    }
    @Published var lyricsLineSpacing: Double {
        didSet { defaults.set(lyricsLineSpacing, forKey: Keys.lyricsLineSpacing) }
    }
    @Published var lyricsLetterSpacing: Double {
        didSet { defaults.set(lyricsLetterSpacing, forKey: Keys.lyricsLetterSpacing) }
    }
    @Published var lyricsHighlightHeight: Double {
        didSet { defaults.set(lyricsHighlightHeight, forKey: Keys.lyricsHighlightHeight) }
    }
    /// LX sync merge strategy used as the default for every connection.
    @Published var syncMode: SyncMode {
        didSet { defaults.set(syncMode.rawValue, forKey: Keys.syncMode) }
    }

    /// Connect to the LX sync server automatically on launch.
    @Published var autoSync: Bool {
        didSet {
            defaults.set(autoSync, forKey: Keys.autoSync)
            defaults.synchronize()
        }
    }
    /// Accent colour (hex string) used across the app.
    @Published var themeColorHex: String {
        didSet {
            defaults.set(themeColorHex, forKey: Keys.themeColorHex)
            ThemeStore.shared.apply(hex: themeColorHex)
        }
    }
    var accentColor: Color { ThemeStore.shared.accent }

    @Published var authCode: String = "" {
        didSet {
            if authCode.isEmpty {
                KeychainStore.delete(account: "settings.authCode")
            } else if let data = authCode.data(using: .utf8) {
                KeychainStore.set(data, account: "settings.authCode")
            }
        }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let serverURL = "settings.serverURL"
        static let preferredQuality = "settings.preferredQuality"
        static let selectedSourceID = "settings.selectedSourceID"
        static let allowCellular = "settings.allowCellular"
        static let showExplicitContent = "settings.showExplicitContent"
        static let backgroundBlur = "settings.backgroundBlur"
        static let backgroundDim = "settings.backgroundDim"
        static let backgroundOpacity = "settings.backgroundOpacity"
        static let lightBackground = "settings.lightBackground"
        static let appearanceMode = "settings.appearanceMode"
        static let karaokeLyrics = "settings.karaokeLyrics"
        static let lyricsFontSize = "settings.lyricsFontSize"
        static let lyricsLineSpacing = "settings.lyricsLineSpacing"
        static let lyricsLetterSpacing = "settings.lyricsLetterSpacing"
        static let lyricsHighlightHeight = "settings.lyricsHighlightHeight"
        static let autoSync = "settings.autoSync"
        static let syncMode = "settings.syncMode"
        static let themeColorHex = "settings.themeColorHex"
    }

    private static var backgroundImageFile: URL {
        AppPaths.root.appendingPathComponent("custom-background.jpg")
    }

    init() {
        serverURL = defaults.string(forKey: Keys.serverURL) ?? "http://127.0.0.1:23332"
        preferredQuality = Quality(rawValue: defaults.string(forKey: Keys.preferredQuality) ?? "") ?? .k320
        selectedSourceID = defaults.string(forKey: Keys.selectedSourceID)
        if let value = defaults.object(forKey: Keys.allowCellular) as? Bool { allowCellular = value } else { allowCellular = true }
        if let value = defaults.object(forKey: Keys.showExplicitContent) as? Bool { showExplicitContent = value } else { showExplicitContent = false }

        let blur = defaults.object(forKey: Keys.backgroundBlur) != nil ? defaults.double(forKey: Keys.backgroundBlur) : 26
        backgroundBlur = (0...60).contains(blur) ? blur : 26
        let dim = defaults.object(forKey: Keys.backgroundDim) != nil ? defaults.double(forKey: Keys.backgroundDim) : 0.35
        backgroundDim = (0...0.9).contains(dim) ? dim : 0.35
        let opacity = defaults.object(forKey: Keys.backgroundOpacity) != nil ? defaults.double(forKey: Keys.backgroundOpacity) : 0.9
        backgroundOpacity = (0.2...1).contains(opacity) ? opacity : 0.9
        let light = defaults.object(forKey: Keys.lightBackground) != nil
            ? defaults.bool(forKey: Keys.lightBackground)
            : false
        lightBackground = light
        let initialAppearance = AppAppearance(rawValue: defaults.string(forKey: Keys.appearanceMode) ?? "") ?? .system
        appearanceMode = initialAppearance
        ThemeStore.shared.applyAppearance(initialAppearance)
        ThemeStore.shared.applyBackgroundStyle(light: light)
        backgroundImage = UIImage(contentsOfFile: Self.backgroundImageFile.path)

        if defaults.object(forKey: Keys.karaokeLyrics) != nil {
            karaokeLyrics = defaults.bool(forKey: Keys.karaokeLyrics)
        } else {
            karaokeLyrics = true
        }
        let lyricFont = defaults.object(forKey: Keys.lyricsFontSize) != nil
            ? defaults.double(forKey: Keys.lyricsFontSize) : 30
        lyricsFontSize = (22...40).contains(lyricFont) ? lyricFont : 30
        let lyricLine = defaults.object(forKey: Keys.lyricsLineSpacing) != nil
            ? defaults.double(forKey: Keys.lyricsLineSpacing) : 8
        lyricsLineSpacing = (0...30).contains(lyricLine) ? lyricLine : 8
        let lyricLetter = defaults.object(forKey: Keys.lyricsLetterSpacing) != nil
            ? defaults.double(forKey: Keys.lyricsLetterSpacing) : 0
        lyricsLetterSpacing = (-1...4).contains(lyricLetter) ? lyricLetter : 0
        let lyricHighlight = defaults.object(forKey: Keys.lyricsHighlightHeight) != nil
            ? defaults.double(forKey: Keys.lyricsHighlightHeight) : 1
        lyricsHighlightHeight = (0.8...1.6).contains(lyricHighlight) ? lyricHighlight : 1
        syncMode = SyncMode(rawValue: defaults.string(forKey: Keys.syncMode) ?? "")
            ?? .mergeLocalRemote
        if defaults.object(forKey: Keys.autoSync) != nil {
            autoSync = defaults.bool(forKey: Keys.autoSync)
        } else {
            autoSync = true
        }
        if let data = KeychainStore.get(account: "settings.authCode"),
           let code = String(data: data, encoding: .utf8) {
            authCode = code
        }
        themeColorHex = defaults.string(forKey: Keys.themeColorHex) ?? "#F54D73"
        ThemeStore.shared.apply(hex: themeColorHex)
    }

    func setThemeColor(_ color: Color) {
        themeColorHex = UIColor(color).hexString
    }

    var hasCustomBackground: Bool { backgroundImage != nil }

    func setBackgroundImage(_ image: UIImage?) {
        guard let image else {
            backgroundImage = nil
            try? FileManager.default.removeItem(at: Self.backgroundImageFile)
            return
        }
        let resized = Self.resized(image, maxDimension: 2400)
        guard let data = resized.jpegData(compressionQuality: 0.88) else { return }
        do {
            try data.write(to: Self.backgroundImageFile, options: .atomic)
            backgroundImage = resized
        } catch {
            // Keep the old image if writing fails.
        }
    }

    func removeBackgroundImage() {
        setBackgroundImage(nil)
    }

    private static func resized(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: target).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    func resetLyricsAppearance() {
        lyricsFontSize = 30
        lyricsLineSpacing = 8
        lyricsLetterSpacing = 0
        lyricsHighlightHeight = 1
        karaokeLyrics = true
    }

    var deviceName: String {
        let model = UIDevice.current.model
        return "iPhone/\(model)"
    }
}
