import SwiftUI

@main
@MainActor
struct LxPlayerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var theme = ThemeStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.library)
                .environmentObject(model.settings)
                .environmentObject(model.sources)
                .environmentObject(model.music)
                .environmentObject(model.player)
                .environmentObject(model.sync)
                .environmentObject(model.netease)
                .environmentObject(ThemeStore.shared)
                .preferredColorScheme(theme.isLightBackground ? .light : .dark)
        }
    }
}
