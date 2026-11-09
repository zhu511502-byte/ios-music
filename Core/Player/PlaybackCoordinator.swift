import Foundation
import AVFoundation
import MediaPlayer
import UIKit
import Combine

enum PlayMode: String, CaseIterable, Identifiable, Equatable, Sendable {
    case sequential
    case repeatAll
    case repeatOne
    case shuffle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sequential: return "顺序播放"
        case .repeatAll: return "列表循环"
        case .repeatOne: return "单曲循环"
        case .shuffle: return "随机播放"
        }
    }

    var shortTitle: String {
        switch self {
        case .sequential: return "顺序"
        case .repeatAll: return "循环"
        case .repeatOne: return "单曲"
        case .shuffle: return "随机"
        }
    }

    var icon: String {
        switch self {
        case .sequential: return "arrow.right"
        case .repeatAll: return "repeat"
        case .repeatOne: return "repeat.1"
        case .shuffle: return "shuffle"
        }
    }
}

/// Playback progress is published separately from the main coordinator.
/// Views that only show track metadata must not redraw twice a second — that
/// used to make open `Menu` popovers flicker while a song was playing.
final class PlaybackClock: ObservableObject {
    @Published var time: Double = 0
}

/// High-frequency clock used only by karaoke lyrics. Keeping it separate from
/// `PlaybackClock` means progress bars and lists still update at 2 Hz.
final class LyricsClock: ObservableObject {
    @Published var time: Double = 0
}

@MainActor
final class PlaybackCoordinator: ObservableObject {
    @Published private(set) var currentTrack: MusicInfo?
    @Published private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    let clock = PlaybackClock()
    let lyricsClock = LyricsClock()
    @Published private(set) var duration: Double = 0
    @Published private(set) var isBuffering = false
    @Published private(set) var queue: [MusicInfo] = []
    @Published private(set) var playMode: PlayMode = .sequential
    @Published private(set) var volume: Float = 1
    @Published var errorMessage: String?

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var lyricTimeObserver: Any?
    private var pendingSeek: Double?
    private var itemStatusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var currentIndex: Int?
    private var artworkTask: Task<Void, Never>?

    var resolver: ((MusicInfo, Quality) async throws -> URL)?
    var qualityProvider: () -> Quality = { .k320 }

    init() {
        let defaults = UserDefaults.standard
        playMode = PlayMode(rawValue: defaults.string(forKey: "player.playMode") ?? "") ?? .sequential
        if defaults.object(forKey: "player.volume") != nil {
            volume = min(max(Float(defaults.double(forKey: "player.volume")), 0), 1)
        }
        player.volume = volume

        AudioSessionController.shared.configure()
        installRemoteCommands()
        installObservers()
    }

    func play(track: MusicInfo, queue: [MusicInfo]? = nil, quality: Quality? = nil) {
        if let queue, !queue.isEmpty {
            self.queue = queue
            currentIndex = queue.firstIndex(where: { $0.id == track.id })
        } else if self.queue.isEmpty {
            self.queue = [track]
            currentIndex = 0
        }
        // Show the mini player / player UI immediately. Resolution can take a
        // few seconds, and if no custom source is configured the error must
        // still be visible instead of making the row look unresponsive.
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentTrack = track
        currentTime = 0
        clock.time = 0
        lyricsClock.time = 0
        pendingSeek = nil
        duration = 0
        errorMessage = nil
        isBuffering = true
        loadArtwork(for: track)
        Task { await resolveAndPlay(track: track, quality: quality ?? qualityProvider()) }
    }

    func playQueue(_ tracks: [MusicInfo], startAt index: Int = 0) {
        guard tracks.indices.contains(index) else { return }
        queue = tracks
        currentIndex = index
        play(track: tracks[index], queue: tracks)
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            if player.currentItem == nil, let currentTrack {
                play(track: currentTrack)
            } else {
                AudioSessionController.shared.activate()
                player.play()
                isPlaying = true
            }
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func next() {
        advance(automatic: false)
    }

    func previous() {
        guard let currentIndex, !queue.isEmpty else { return }
        if currentTime > 4 {
            seek(to: 0)
            return
        }

        switch playMode {
        case .shuffle:
            playRandom(excluding: currentIndex)
        case .repeatAll:
            let index = currentIndex > 0 ? currentIndex - 1 : queue.count - 1
            play(track: queue[index], quality: qualityProvider())
            self.currentIndex = index
        default:
            guard currentIndex > 0 else {
                seek(to: 0)
                return
            }
            let index = currentIndex - 1
            self.currentIndex = index
            play(track: queue[index], quality: qualityProvider())
        }
    }

    func cyclePlayMode() {
        let modes = PlayMode.allCases
        let index = modes.firstIndex(of: playMode) ?? 0
        playMode = modes[(index + 1) % modes.count]
        UserDefaults.standard.set(playMode.rawValue, forKey: "player.playMode")
    }

    func setVolume(_ value: Double) {
        let clamped = min(max(Float(value), 0), 1)
        volume = clamped
        player.volume = clamped
        UserDefaults.standard.set(Double(clamped), forKey: "player.volume")
    }

    private func advance(automatic: Bool) {
        guard let currentIndex, !queue.isEmpty else { return }

        switch playMode {
        case .repeatOne where automatic:
            seek(to: 0)
            player.play()
            isPlaying = true
            updateNowPlaying()
        case .shuffle:
            playRandom(excluding: currentIndex)
        case .repeatAll:
            let index = currentIndex + 1 < queue.count ? currentIndex + 1 : 0
            self.currentIndex = index
            play(track: queue[index], quality: qualityProvider())
        default:
            guard currentIndex + 1 < queue.count else {
                if automatic {
                    player.pause()
                    isPlaying = false
                    seek(to: 0)
                    updateNowPlaying()
                }
                return
            }
            let index = currentIndex + 1
            self.currentIndex = index
            play(track: queue[index], quality: qualityProvider())
        }
    }

    private func playRandom(excluding index: Int) {
        guard queue.count > 1 else {
            seek(to: 0)
            player.play()
            isPlaying = true
            updateNowPlaying()
            return
        }
        let candidates = queue.indices.filter { $0 != index }
        guard let next = candidates.randomElement() else { return }
        self.currentIndex = next
        play(track: queue[next], quality: qualityProvider())
    }

    /// Re-resolve the current track at a new quality, preserving playback
    /// position so the quality switch feels seamless.
    func reloadCurrentTrack(quality: Quality) {
        guard let track = currentTrack else { return }
        let resume = currentTime
        play(track: track, queue: queue, quality: quality)
        if resume > 1 { pendingSeek = resume }
    }

    func seek(to seconds: Double) {
        let target = max(0, seconds)
        currentTime = target
        clock.time = target
        lyricsClock.time = target
        let time = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: time) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlaying() }
        }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentTrack = nil
        currentTime = 0
        clock.time = 0
        lyricsClock.time = 0
        pendingSeek = nil
        duration = 0
        NowPlayingCenter.shared.clear()
    }

    private func resolveAndPlay(track: MusicInfo, quality: Quality) async {
        guard let resolver else {
            errorMessage = "播放器尚未初始化"
            return
        }
        isBuffering = true
        errorMessage = nil
        do {
            let url = try await resolver(track, quality)
            let item = AVPlayerItem(url: url)
            itemStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self else { return }
                    switch item.status {
                    case .readyToPlay:
                        self.isBuffering = false
                        self.duration = CMTimeGetSeconds(item.duration).isFinite ? CMTimeGetSeconds(item.duration) : 0
                        AudioSessionController.shared.activate()
                        self.player.play()
                        self.isPlaying = true
                        if let pendingSeek = self.pendingSeek {
                            self.pendingSeek = nil
                            self.seek(to: pendingSeek)
                        }
                        self.updateNowPlaying()
                    case .failed:
                        self.isBuffering = false
                        self.isPlaying = false
                        self.errorMessage = item.error?.localizedDescription ?? "播放失败"
                    default:
                        break
                    }
                }
            }
            player.replaceCurrentItem(with: item)
            currentTrack = track
            currentTime = 0
            clock.time = 0
            lyricsClock.time = 0
            duration = 0
            NowPlayingCenter.shared.update(track: track, elapsed: 0, duration: 0, rate: 1)
        } catch {
            isBuffering = false
            isPlaying = false
            player.pause()
            player.replaceCurrentItem(with: nil)
            errorMessage = error.localizedDescription
        }
    }

    private func installObservers() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let seconds = CMTimeGetSeconds(time)
                self.currentTime = seconds.isFinite ? seconds : 0
                self.clock.time = self.currentTime
                if self.duration == 0, let item = self.player.currentItem {
                    let value = CMTimeGetSeconds(item.duration)
                    if value.isFinite { self.duration = value }
                }
                self.updateNowPlaying()
            }
        }

        lyricTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let seconds = CMTimeGetSeconds(time)
                self.lyricsClock.time = seconds.isFinite ? seconds : 0
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.advance(automatic: true) }
        }

        NotificationCenter.default.addObserver(
            forName: .lxAudioInterruptionBegan,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pause() }
        }

        NotificationCenter.default.addObserver(
            forName: .lxAudioInterruptionEnded,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.currentTrack != nil else { return }
                AudioSessionController.shared.activate()
                self.player.play()
                self.isPlaying = true
            }
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            Task { @MainActor in self?.pause() }
        }
    }

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
        UIApplication.shared.beginReceivingRemoteControlEvents()
    }

    private func updateNowPlaying() {
        NowPlayingCenter.shared.update(
            track: currentTrack,
            elapsed: currentTime,
            duration: duration,
            rate: isPlaying ? 1 : 0
        )
    }

    private func loadArtwork(for track: MusicInfo) {
        artworkTask?.cancel()
        guard let url = track.picURL else { return }
        artworkTask = Task { [weak self] in
            guard let self else { return }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
                if track.source == "tx" {
                    request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
                } else if track.source == "wy" {
                    request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
                }
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return }
                guard !Task.isCancelled, let image = UIImage(data: data) else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                NowPlayingCenter.shared.update(
                    track: track,
                    elapsed: self.currentTime,
                    duration: self.duration,
                    rate: self.isPlaying ? 1 : 0,
                    artwork: artwork
                )
            } catch {
                // Artwork is optional.
            }
        }
    }
}
