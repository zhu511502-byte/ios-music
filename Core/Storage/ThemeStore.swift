import SwiftUI
import UIKit

/// Holds the user-selected accent colour. `AppTheme.accent` reads from here so
/// every existing call site picks up the change without threading another
/// environment object through the whole app.
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    @Published private(set) var accent: Color = Color(hex: "#F54D73")

    private init() {}

    func apply(hex: String) {
        accent = Color(hex: hex)
    }
}

extension Color {
    init(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        var number: UInt64 = 0
        Scanner(string: value).scanHexInt64(&number)
        let red: Double
        let green: Double
        let blue: Double
        if value.count == 6 {
            red = Double((number >> 16) & 0xFF) / 255
            green = Double((number >> 8) & 0xFF) / 255
            blue = Double(number & 0xFF) / 255
        } else {
            red = 1
            green = 1
            blue = 1
        }
        self.init(red: red, green: green, blue: blue)
    }
}

extension UIColor {
    var hexString: String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "#%02X%02X%02X",
            Int(round(red * 255)),
            Int(round(green * 255)),
            Int(round(blue * 255))
        )
    }
}

struct ThemeSwatch: Identifiable {
    let id: String
    let name: String
    let hex: String

    var color: Color { Color(hex: hex) }

    static let presets: [ThemeSwatch] = [
        ThemeSwatch(id: "pink", name: "玫红", hex: "#F54D73"),
        ThemeSwatch(id: "blue", name: "海蓝", hex: "#3D8BFF"),
        ThemeSwatch(id: "purple", name: "紫罗兰", hex: "#9B6BFF"),
        ThemeSwatch(id: "green", name: "青绿", hex: "#2ECC9A"),
        ThemeSwatch(id: "orange", name: "落日橙", hex: "#FF8A3D"),
        ThemeSwatch(id: "red", name: "朱红", hex: "#F04B4B")
    ]
}
