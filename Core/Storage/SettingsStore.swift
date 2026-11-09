import Foundation
import Combine
import UIKit

/// App-wide backdrop style. "Dynamic cover" uses the current track's album
/// artwork as a blurred background across the whole app.
enum BackgroundStyle: String, CaseIterable, Identifiable {
    case solid
    case artwork

    var id: String { rawValue }

    var title: String {
        switch self {
        case .solid: return "纯色"
        case .artwork: return "动态封面"
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
    @Published var backgroundStyle: BackgroundStyle {
        didSet { defaults.set(backgroundStyle.rawValue, forKey: Keys.backgroundStyle) }
    }
    /// Blur radius for the dynamic artwork backdrop, 0...80.
    @Published var backgroundBlur: Double {
        didSet { defaults.set(backgroundBlur, forKey: Keys.backgroundBlur) }
    }
    /// Dark overlay strength for the dynamic backdrop, 0...0.9.
    @Published var backgroundDim: Double {
        didSet { defaults.set(backgroundDim, forKey: Keys.backgroundDim) }
    }
    /// Character-by-character highlight on the active lyric line.
    @Published var karaokeLyrics: Bool {
        didSet { defaults.set(karaokeLyrics, forKey: Keys.karaokeLyrics) }
    }
    /// Connect to the LX sync server automatically on launch.
    @Published var autoSync: Bool {
        didSet {
            defaults.set(autoSync, forKey: Keys.autoSync)
            // Settings must survive an immediate app termination after a toggle.
            defaults.synchronize()
        }
    }
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
        static let backgroundStyle = "settings.backgroundStyle"
        static let backgroundBlur = "settings.backgroundBlur"
        static let backgroundDim = "settings.backgroundDim"
        static let karaokeLyrics = "settings.karaokeLyrics"
        static let autoSync = "settings.autoSync"
    }

    init() {
        serverURL = defaults.string(forKey: Keys.serverURL) ?? "http://127.0.0.1:23332"
        preferredQuality = Quality(rawValue: defaults.string(forKey: Keys.preferredQuality) ?? "") ?? .k320
        selectedSourceID = defaults.string(forKey: Keys.selectedSourceID)
        if let value = defaults.object(forKey: Keys.allowCellular) as? Bool { allowCellular = value } else { allowCellular = true }
        if let value = defaults.object(forKey: Keys.showExplicitContent) as? Bool { showExplicitContent = value } else { showExplicitContent = false }
        backgroundStyle = BackgroundStyle(rawValue: defaults.string(forKey: Keys.backgroundStyle) ?? "") ?? .artwork
        let blur = defaults.double(forKey: Keys.backgroundBlur)
        backgroundBlur = (0...80).contains(blur) ? blur : 60
        let dim = defaults.double(forKey: Keys.backgroundDim)
        backgroundDim = (0...0.9).contains(dim) ? dim : 0.45
        if defaults.object(forKey: Keys.karaokeLyrics) != nil {
            karaokeLyrics = defaults.bool(forKey: Keys.karaokeLyrics)
        } else {
            karaokeLyrics = true
        }
        if defaults.object(forKey: Keys.autoSync) != nil {
            autoSync = defaults.bool(forKey: Keys.autoSync)
        } else {
            autoSync = true
        }
        if let data = KeychainStore.get(account: "settings.authCode"),
           let code = String(data: data, encoding: .utf8) {
            authCode = code
        }
    }

    var deviceName: String {
        let model = UIDevice.current.model
        return "iPhone/\(model)"
    }
}
