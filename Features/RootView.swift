import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var player: PlaybackCoordinator
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var hero = HeroTransitionCoordinator()
    @State private var selectedTab = 0

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        appearance.backgroundColor = UIColor.black.withAlphaComponent(0.12)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                tab(SearchView(), tag: 0)
                    .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                    .tag(0)

                tab(DiscoverView(), tag: 1)
                    .tabItem { Label("发现", systemImage: "square.grid.2x2") }
                    .tag(1)

                tab(LibraryView(), tag: 2)
                    .tabItem { Label("音乐库", systemImage: "music.note.list") }
                    .tag(2)

                tab(SettingsView(), tag: 3)
                    .tabItem { Label("设置", systemImage: "gearshape") }
                    .tag(3)
            }
            .tint(AppTheme.accent)

            if hero.playerPresented {
                PlayerView(onClose: closePlayer)
                    .zIndex(1)
                    .opacity(hero.playerPageOpacity)
            }

            if hero.panelVisible {
                HeroPanelView(hero: hero)
                    .zIndex(50)
            }

            // The moving cover/title lives above every page. The pages only
            // report anchor frames, so their own crossfades can never fade or
            // drag the hero element around.
            HeroOverlayView(hero: hero)
                .zIndex(100)
        }
        .background(Color.black.ignoresSafeArea())
        .environmentObject(hero)
        .onPreferenceChange(HeroAnchorPreferenceKey.self) { values in
            hero.updateAnchors(values)
        }
        .task {
            await model.start()
        }
        .alert("播放失败", isPresented: playbackErrorPresented) {
            Button("去设置") { selectedTab = 3 }
            Button("好", role: .cancel) {}
        } message: {
            Text(player.errorMessage ?? "未知错误")
        }
    }

    private func openPlayer() {
        hero.openPlayer(track: player.currentTrack)
    }

    private func closePlayer() {
        hero.closePlayer()
    }

    /// Each screen paints `AppBackgroundView` inside its own NavigationStack.
    /// A `.background` on the TabView sits behind UITabBarController's opaque
    /// view, and a background outside NavigationStack can be hidden by its
    /// hosting controller — both were why the custom photo never appeared.
    private func tab<Content: View>(_ content: Content, tag: Int) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            // Only the visible tab owns the mini player. Four hidden copies
            // with the same matched-geometry id would confuse the hero
            // transition into the player.
            if player.currentTrack != nil, selectedTab == tag {
                MiniPlayerView(onTap: openPlayer)
                    .opacity(hero.hideMiniContent ? 0 : 1)
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
