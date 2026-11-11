import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    let library: LibraryStore
    let settings: SettingsStore
    let sources: SourceStore
    let music: NativeMusicAPI
    let player: PlaybackCoordinator
    let sync: SyncClient
    let netease: NetEaseAccount

    private let resolver: PlaybackResolver

    init() {
        let library = LibraryStore()
        let settings = SettingsStore()
        let sources = SourceStore()
        let music = NativeMusicAPI.shared
        let resolver = PlaybackResolver(sources: sources)
        let player = PlaybackCoordinator()
        let sync = SyncClient()
        let netease = NetEaseAccount()

        self.library = library
        self.settings = settings
        self.sources = sources
        self.music = music
        self.resolver = resolver
        self.player = player
        self.sync = sync
        self.netease = netease
        netease.restoreSession()

        player.resolver = { [resolver] track, quality in
            try await resolver.url(for: track, quality: quality)
        }
        player.qualityProvider = { [weak settings] in
            settings?.preferredQuality ?? .k320
        }
        sources.selectedID = sources.selectedID ?? sources.profiles.first?.id
        library.onChange = { [weak sync] in
            guard let sync else { return }
            sync.uploadLocalList()
        }
    }

    /// Called once after the root view appears. Connects the LX sync client
    /// automatically when the user enabled auto-sync and filled the settings.
    func start() async {
        guard settings.autoSync,
              !settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        guard sync.status == .disconnected else { return }
        await sync.connect(
            baseURL: url,
            authCode: settings.authCode,
            deviceName: settings.deviceName,
            library: library,
            mode: settings.syncMode
        )
    }

    func preloadSelectedSource() async throws -> [String: SourceCapability] {
        guard let profile = sources.selectedProfile else {
            throw JSRuntimeError.native("请先导入洛雪音源脚本")
        }
        return try await resolver.preload(profile: profile)
    }
}
