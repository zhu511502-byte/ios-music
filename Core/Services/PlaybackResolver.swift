import Foundation

@MainActor
final class PlaybackResolver {
    private let sources: SourceStore
    private var runtimes: [String: LXSourceRuntime] = [:]
    private var loading: [String: Task<LXSourceRuntime, Error>] = [:]

    init(sources: SourceStore) {
        self.sources = sources
    }

    func url(for track: MusicInfo, quality: Quality) async throws -> URL {
        if track.source == "local" {
            guard let path = track.localFilePath else {
                throw JSRuntimeError.native("本地歌曲缺少文件路径")
            }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                throw JSRuntimeError.native("本地文件不存在：\(url.lastPathComponent)")
            }
            return url
        }

        guard let profile = sources.profiles.first(where: { $0.sources[track.source] != nil })
                ?? sources.selectedProfile
                ?? sources.profiles.first else {
            throw JSRuntimeError.native("请先在设置中导入洛雪音源脚本")
        }
        let runtime = try await runtime(for: profile)
        return try await runtime.musicURL(for: track, quality: quality)
    }

    func unload(profileID: String) {
        runtimes.removeValue(forKey: profileID)
        loading.removeValue(forKey: profileID)
    }

    private func runtime(for profile: SourceProfile) async throws -> LXSourceRuntime {
        if let runtime = runtimes[profile.id] { return runtime }
        if let task = loading[profile.id] { return try await task.value }
        let task = Task<LXSourceRuntime, Error> {
            let script = try String(contentsOf: profile.scriptURL, encoding: .utf8)
            return try await LXSourceRuntime.start(profile: profile, script: script)
        }
        loading[profile.id] = task
        do {
            let runtime = try await task.value
            runtimes[profile.id] = runtime
            loading.removeValue(forKey: profile.id)
            sources.setCapabilities(runtime.supportedCapabilities, for: profile.id)
            return runtime
        } catch {
            loading.removeValue(forKey: profile.id)
            throw error
        }
    }

    /// Load a source ahead of playback so Settings can show its platforms.
    func preload(profile: SourceProfile) async throws -> [String: SourceCapability] {
        let runtime = try await runtime(for: profile)
        return runtime.supportedCapabilities
    }
}
