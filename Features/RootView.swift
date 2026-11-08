import SwiftUI

struct RootView: View {
    @EnvironmentObject private var player: PlaybackCoordinator
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @State private var showPlayer = false
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            tab(SearchView())
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                .tag(0)

            tab(DiscoverView())
                .tabItem { Label("发现", systemImage: "square.grid.2x2") }
                .tag(1)

            tab(LibraryView())
                .tabItem { Label("音乐库", systemImage: "music.note.list") }
                .tag(2)

            tab(SettingsView())
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(3)
        }
        .tint(AppTheme.accent)
        .background {
            AppBackgroundView()
        }
        .task {
            await model.start()
        }
        .fullScreenCover(isPresented: $showPlayer) {
            PlayerView()
        }
        .alert("播放失败", isPresented: playbackErrorPresented) {
            Button("去设置") { selectedTab = 3 }
            Button("好", role: .cancel) {}
        } message: {
            Text(player.errorMessage ?? "未知错误")
        }
    }

    /// Keep the mini player inside each tab's safe area so it sits above the
    /// native tab bar instead of covering it.
    private func tab<Content: View>(_ content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if player.currentTrack != nil {
                MiniPlayerView { showPlayer = true }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }
        }
    }

    private var playbackErrorPresented: Binding<Bool> {
        Binding(
            get: { player.errorMessage != nil },
            set: { presented in
                if !presented { player.errorMessage = nil }
            }
        )
    }
}
