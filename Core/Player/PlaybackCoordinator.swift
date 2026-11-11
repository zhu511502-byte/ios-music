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
    private var itemStatusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    private var interruptionBeganObserver: NSObjectProtocol?
    private var interruptionEndedObserver: NSObjectProtocol?
    private var sessionResetObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var currentIndex: Int?
    private var pendingSeek: Double?
    private var artworkTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var stallRecoveryTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var activeItemToken = UUID()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var preparedNext: PreparedNext?
    private var isRecovering = false
    private var recoveryAttempts = 0
    private var recoveryPosition: Double = 0
    private var wasPlayingBeforeInterruption = false
    private var isAppActive = true
    private var lastNowPlayingUpdate = Date.distantPast
    private var lastProgressDate = Date()
    private var lastObservedTime: Double = 0
    private var bufferStartedAt: Date?
    private var lastPrefetchCheck = Date.distantPast

    private struct PreparedNext {
        let trackID: String
        let index: Int
        let quality: Quality
        let item: AVPlayerItem
        let url: URL
    }

    var resolver: ((MusicInfo, Quality) async throws -> URL)?
    var qualityProvider: () -> Quality = { .k320 }

    init() {
        let defaults = UserDefaults.standard
        playMode = PlayMode(rawValue: defaults.string(forKey: "player.playMode") ?? "") ?? .sequential
        if defaults.object(forKey: "player.volume") != nil {
            volume = min(max(Float(defaults.double(forKey: "player.volume")), 0), 1)
        }
        player.volume = volume
        // Audio is the app's background mode. Keeping this on lets AVPlayer
        // wait for a network hiccup instead of immediately failing an item.
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .pause

        AudioSessionController.shared.configure()
        installRemoteCommands()
        installObservers()
        startHealthMonitor()
    }

    func play(track: MusicInfo, queue: [MusicInfo]? = nil, quality: Quality? = nil) {
        if let queue, !queue.isEmpty {
            self.queue = queue
            currentIndex = queue.firstIndex(where: { $0.id == track.id }) ?? 0
        } else if self.queue.isEmpty {
            self.queue = [track]
            currentIndex = 0
        } else if let index = self.queue.firstIndex(where: { $0.id == track.id }) {
            currentIndex = index
        }

        startTrack(
            track,
            index: currentIndex,
            quality: quality ?? qualityProvider(),
            startAt: 0,
            resetRecovery: true
        )
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
            resume()
        }
    }

    /// Used by the lock-screen play button and by the UI when the user resumes.
    func resume() {
        guard let track = currentTrack else { return }

        if player.currentItem == nil ||
            player.currentItem?.status == .failed ||
            player.currentItem?.error != nil {
            startTrack(
                track,
                index: currentIndex,
                quality: qualityProvider(),
                startAt: max(currentTime, 0),
                resetRecovery: true
            )
            return
        }

        if duration > 1, currentTime >= duration - 1 {
            pendingSeek = 0
        }

        AudioSessionController.shared.activate()
        player.play()
        isPlaying = true
        isBuffering = player.currentItem?.status != .readyToPlay
        lastProgressDate = Date()
        updateNowPlaying(force: true)
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlaying(force: true)
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
            startTrack(queue[index], index: index, quality: qualityProvider(), startAt: 0, resetRecovery: true)
        default:
            guard currentIndex > 0 else {
                seek(to: 0)
                return
            }
            let index = currentIndex - 1
            startTrack(queue[index], index: index, quality: qualityProvider(), startAt: 0, resetRecovery: true)
        }
    }

    func cyclePlayMode() {
        let modes = PlayMode.allCases
        let index = modes.firstIndex(of: playMode) ?? 0
        playMode = modes[(index + 1) % modes.count]
        UserDefaults.standard.set(playMode.rawValue, forKey: "player.playMode")
        preparedNext = nil
        prefetchTask?.cancel()
    }

    func setVolume(_ value: Double) {
        let clamped = min(max(Float(value), 0), 1)
        volume = clamped
        player.volume = clamped
        UserDefaults.standard.set(Double(clamped), forKey: "player.volume")
    }

    /// Re-resolve the current track at a new quality, preserving playback
    /// position so the quality switch feels seamless.
    func reloadCurrentTrack(quality: Quality) {
        guard let track = currentTrack else { return }
        startTrack(
            track,
            index: currentIndex,
            quality: quality,
            startAt: max(currentTime, 0),
            resetRecovery: true
        )
    }

    func seek(to seconds: Double) {
        let target = max(0, seconds)
        currentTime = target
        clock.time = target
        lyricsClock.time = target
        lastProgressDate = Date()
        guard player.currentItem != nil else { return }
        let time = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: time) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.lastProgressDate = Date()
                self.updateNowPlaying(force: true)
            }
        }
    }

    func stop() {
        loadGeneration += 1
        loadTask?.cancel()
        prefetchTask?.cancel()
        stallRecoveryTask?.cancel()
        artworkTask?.cancel()
        preparedNext = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        isBuffering = false
        currentTrack = nil
        currentTime = 0
        clock.time = 0
        lyricsClock.time = 0
        pendingSeek = nil
        duration = 0
        errorMessage = nil
        endTransitionBackgroundTask()
        NowPlayingCenter.shared.clear()
    }

    // MARK: - Track loading

    private func startTrack(
        _ track: MusicInfo,
        index: Int?,
        quality: Quality,
        preparedItem: AVPlayerItem? = nil,
        startAt: Double,
        resetRecovery: Bool
    ) {
        loadGeneration += 1
        let generation = loadGeneration
        loadTask?.cancel()
        prefetchTask?.cancel()
        prefetchTask = nil
        stallRecoveryTask?.cancel()
        preparedNext = nil
        if let index { currentIndex = index }
        if resetRecovery {
            isRecovering = false
            recoveryAttempts = 0
        }

        activeItemToken = UUID()
        itemStatusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentTrack = track
        currentTime = max(startAt, 0)
        clock.time = currentTime
        lyricsClock.time = currentTime
        pendingSeek = startAt > 1 ? startAt : nil
        duration = 0
        isPlaying = false
        isBuffering = true
        bufferStartedAt = Date()
        lastProgressDate = Date()
        lastObservedTime = currentTime
        errorMessage = nil

        loadArtwork(for: track)
        updateNowPlaying(force: true)

        if let preparedItem {
            let token = UUID()
            activeItemToken = token
            beginTransitionBackgroundTask()
            installItemObservers(for: preparedItem, token: token)
            player.replaceCurrentItem(with: preparedItem)
            if preparedItem.status == .readyToPlay {
                handleItemReady(preparedItem, token: token)
            }
            return
        }

        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.resolveAndPlay(
                track: track,
                quality: quality,
                startAt: startAt,
                generation: generation,
                recovering: !resetRecovery
            )
        }
    }

    private func resolveAndPlay(
        track: MusicInfo,
        quality: Quality,
        startAt: Double,
        generation: Int,
        recovering: Bool
    ) async {
        guard let resolver else {
            isBuffering = false
            isPlaying = false
            errorMessage = "播放器尚未初始化"
            return
        }

        isBuffering = true
        bufferStartedAt = Date()
        if !recovering {
            errorMessage = nil
        }
        beginTransitionBackgroundTask()

        do {
            let url = try await resolver(track, quality)
            guard !Task.isCancelled, generation == loadGeneration else { return }

            let item = makePlayerItem(url: url)
            let token = UUID()
            activeItemToken = token
            installItemObservers(for: item, token: token)
            player.replaceCurrentItem(with: item)
            currentTrack = track
            currentTime = max(startAt, 0)
            clock.time = currentTime
            lyricsClock.time = currentTime
            pendingSeek = startAt > 1 ? startAt : nil
            duration = 0
            updateNowPlaying(force: true)

            if item.status == .readyToPlay {
                handleItemReady(item, token: token)
            }
        } catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            isBuffering = false
            isPlaying = false
            player.pause()
            player.replaceCurrentItem(with: nil)
            endTransitionBackgroundTask()

            if recovering, recoveryAttempts < 4 {
                // A transient network/source error while the phone is locked
                // must not end the listening session. Keep retrying with a
                // short backoff until the lock screen is woken again.
                scheduleRecovery(after: error.localizedDescription)
            } else {
                isRecovering = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func makePlayerItem(url: URL) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 30
        return item
    }

    private func installItemObservers(for item: AVPlayerItem, token: UUID) {
        itemStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            Task { @MainActor in
                self?.handleItemStatus(item, token: token)
            }
        }
    }

    private func handleItemStatus(_ item: AVPlayerItem, token: UUID) {
        guard token == activeItemToken, player.currentItem === item else { return }

        switch item.status {
        case .readyToPlay:
            handleItemReady(item, token: token)
        case .failed:
            guard isPlaying || isBuffering else { return }
            isBuffering = false
            isPlaying = false
            if isRecovering {
                scheduleRecovery(after: item.error?.localizedDescription ?? "播放失败")
            } else {
                recoverCurrentTrack(reason: item.error?.localizedDescription ?? "播放失败")
            }
        default:
            break
        }
    }

    private func handleItemReady(_ item: AVPlayerItem, token: UUID) {
        guard token == activeItemToken, player.currentItem === item else { return }

        let durationValue = CMTimeGetSeconds(item.duration)
        duration = durationValue.isFinite ? max(durationValue, 0) : 0
        isBuffering = false
        bufferStartedAt = nil
        isRecovering = false
        recoveryAttempts = 0
        lastProgressDate = Date()
        lastObservedTime = currentTime

        AudioSessionController.shared.activate()
        player.play()
        isPlaying = true

        if let pendingSeek {
            self.pendingSeek = nil
            seek(to: pendingSeek)
        }
        updateNowPlaying(force: true)
        endTransitionBackgroundTask()
    }

    // MARK: - Automatic advance / prefetch

    private func advance(automatic: Bool) {
        guard let currentIndex, !queue.isEmpty else { return }

        switch playMode {
        case .repeatOne where automatic:
            seek(to: 0)
            player.play()
            isPlaying = true
            updateNowPlaying(force: true)
        case .shuffle:
            if let prepared = takePreparedNext() {
                self.currentIndex = prepared.index
                startTrack(
                    queue[prepared.index],
                    index: prepared.index,
                    quality: prepared.quality,
                    preparedItem: prepared.item,
                    startAt: 0,
                    resetRecovery: true
                )
            } else {
                playRandom(excluding: currentIndex)
            }
        case .repeatAll:
            if let prepared = takePreparedNext() {
                self.currentIndex = prepared.index
                startTrack(
                    queue[prepared.index],
                    index: prepared.index,
                    quality: prepared.quality,
                    preparedItem: prepared.item,
                    startAt: 0,
                    resetRecovery: true
                )
                return
            }
            let index = currentIndex + 1 < queue.count ? currentIndex + 1 : 0
            startTrack(queue[index], index: index, quality: qualityProvider(), startAt: 0, resetRecovery: true)
        default:
            guard currentIndex + 1 < queue.count else {
                if automatic {
                    player.pause()
                    isPlaying = false
                    seek(to: 0)
                    updateNowPlaying(force: true)
                }
                return
            }
            if let prepared = takePreparedNext(), prepared.index == currentIndex + 1 {
                self.currentIndex = prepared.index
                startTrack(
                    queue[prepared.index],
                    index: prepared.index,
                    quality: prepared.quality,
                    preparedItem: prepared.item,
                    startAt: 0,
                    resetRecovery: true
                )
            } else {
                let index = currentIndex + 1
                startTrack(queue[index], index: index, quality: qualityProvider(), startAt: 0, resetRecovery: true)
            }
        }
    }

    private func playRandom(excluding index: Int) {
        guard queue.count > 1 else {
            seek(to: 0)
            player.play()
            isPlaying = true
            updateNowPlaying(force: true)
            return
        }
        let candidates = queue.indices.filter { $0 != index }
        guard let next = candidates.randomElement() else { return }
        currentIndex = next
        startTrack(queue[next], index: next, quality: qualityProvider(), startAt: 0, resetRecovery: true)
    }

    private func takePreparedNext() -> PreparedNext? {
        guard let prepared = preparedNext else { return nil }
        preparedNext = nil
        guard queue.indices.contains(prepared.index),
              queue[prepared.index].id == prepared.trackID,
              prepared.quality == qualityProvider() else {
            return nil
        }
        return prepared
    }

    private func checkPrefetch() {
        guard isPlaying, !isBuffering, !isRecovering,
              let currentIndex, queue.indices.contains(currentIndex),
              currentTrack != nil, duration > 1,
              preparedNext == nil, prefetchTask == nil else { return }

        let now = Date()
        guard now.timeIntervalSince(lastPrefetchCheck) >= 2 else { return }
        lastPrefetchCheck = now

        let remaining = duration - currentTime
        guard remaining > 0, remaining <= 18 else { return }
        guard playMode != .repeatOne else { return }
        guard let target = nextTarget(excluding: currentIndex) else { return }
        guard target.index != currentIndex else { return }
        guard let resolver else { return }

        let quality = qualityProvider()
        let targetTrack = queue[target.index]
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await resolver(targetTrack, quality)
                guard !Task.isCancelled, self.currentIndex == currentIndex else { return }
                let item = self.makePlayerItem(url: url)
                self.preparedNext = PreparedNext(
                    trackID: targetTrack.id,
                    index: target.index,
                    quality: quality,
                    item: item,
                    url: url
                )
            } catch {
                // Prefetch is best-effort. Normal advancement will try again.
            }
            self.prefetchTask = nil
        }
    }

    private func nextTarget(excluding currentIndex: Int) -> (index: Int, track: MusicInfo)? {
        guard queue.indices.contains(currentIndex) else { return nil }
        switch playMode {
        case .repeatOne:
            return nil
        case .shuffle:
            guard queue.count > 1 else { return nil }
            let candidates = queue.indices.filter { $0 != currentIndex }
            guard let index = candidates.randomElement() else { return nil }
            return (index, queue[index])
        case .repeatAll:
            let index = currentIndex + 1 < queue.count ? currentIndex + 1 : 0
            return (index, queue[index])
        case .sequential:
            guard currentIndex + 1 < queue.count else { return nil }
            let index = currentIndex + 1
            return (index, queue[index])
        }
    }

    // MARK: - Recovery

    private func recoverCurrentTrack(reason: String) {
        guard let track = currentTrack, !isRecovering else { return }
        guard recoveryAttempts < 5 else {
            isBuffering = false
            isPlaying = false
            isRecovering = false
            errorMessage = "播放已停止：\(reason)"
            endTransitionBackgroundTask()
            return
        }

        recoveryAttempts += 1
        isRecovering = true
        recoveryPosition = max(currentTime, 0)
        isBuffering = true
        bufferStartedAt = Date()
        isPlaying = false
        activeItemToken = UUID()
        itemStatusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)

        let generation = loadGeneration
        let quality = qualityProvider()
        let delay = min(Double(recoveryAttempts) * 1.5, 6)

        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, generation == self.loadGeneration else { return }
            await self.resolveAndPlay(
                track: track,
                quality: quality,
                startAt: self.recoveryPosition,
                generation: generation,
                recovering: true
            )
        }
    }

    private func scheduleRecovery(after message: String) {
        guard currentTrack != nil else { return }
        isRecovering = false
        if recoveryAttempts < 5 {
            isBuffering = true
            errorMessage = nil
            recoverCurrentTrack(reason: message)
        } else {
            isBuffering = false
            isPlaying = false
            errorMessage = "播放已停止：\(message)"
            endTransitionBackgroundTask()
        }
    }

    // MARK: - Observers

    private func installObservers() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let seconds = CMTimeGetSeconds(time)
                self.currentTime = seconds.isFinite ? seconds : 0

                if self.duration == 0, let item = self.player.currentItem {
                    let value = CMTimeGetSeconds(item.duration)
                    if value.isFinite, value > 0 { self.duration = value }
                }

                if self.isAppActive {
                    self.clock.time = self.currentTime
                }
                // Prefetch must keep running while the screen is locked;
                // otherwise the next track cannot be resolved after the
                // current audio has stopped and iOS may suspend the app.
                self.checkPrefetch()

                if self.isPlaying, self.currentTime != self.lastObservedTime {
                    self.lastObservedTime = self.currentTime
                    self.lastProgressDate = Date()
                }
                self.updateNowPlaying()
            }
        }

        lyricTimeObserver = player.addPeriodicTimeObserver(
            // 30 Hz gives line changes a worst-case latency of ~33 ms
            // instead of 250 ms. The karaoke layer still renders at 60 fps.
            forInterval: CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self, self.isAppActive else { return }
                let seconds = CMTimeGetSeconds(time)
                self.lyricsClock.time = seconds.isFinite ? seconds : 0
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                self.advance(automatic: true)
            }
        }

        failureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                self.recoverCurrentTrack(reason: item.error?.localizedDescription ?? "播放中断")
            }
        }

        stallObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                self.handlePlaybackStall()
            }
        }

        interruptionBeganObserver = NotificationCenter.default.addObserver(
            forName: .lxAudioInterruptionBegan,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleInterruptionBegan() }
        }

        interruptionEndedObserver = NotificationCenter.default.addObserver(
            forName: .lxAudioInterruptionEnded,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let shouldResume = notification.userInfo?["shouldResume"] as? Bool ?? false
            Task { @MainActor in self?.handleInterruptionEnded(shouldResume: shouldResume) }
        }

        sessionResetObserver = NotificationCenter.default.addObserver(
            forName: .lxAudioSessionReset,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleAudioSessionReset() }
        }

        routeObserver = NotificationCenter.default.addObserver(
            forName: .lxAudioRouteChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.pause()
            }
        }

        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.isAppActive = false }
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isAppActive = true
                self.clock.time = self.currentTime
                self.lyricsClock.time = self.currentTime
                self.updateNowPlaying(force: true)
            }
        }
    }

    private func handleInterruptionBegan() {
        wasPlayingBeforeInterruption = isPlaying
        if isPlaying {
            player.pause()
            isPlaying = false
            updateNowPlaying(force: true)
        }
    }

    private func handleInterruptionEnded(shouldResume: Bool) {
        AudioSessionController.shared.activate()
        let shouldPlay = wasPlayingBeforeInterruption
        wasPlayingBeforeInterruption = false
        guard shouldPlay, shouldResume else {
            updateNowPlaying(force: true)
            return
        }
        resume()
    }

    private func handleAudioSessionReset() {
        let shouldPlay = isPlaying || wasPlayingBeforeInterruption
        wasPlayingBeforeInterruption = false
        guard currentTrack != nil, shouldPlay else { return }
        recoverCurrentTrack(reason: "系统音频服务重置")
    }

    private func handlePlaybackStall() {
        guard isPlaying, !isRecovering else { return }
        isBuffering = true
        bufferStartedAt = Date()
        player.play()

        stallRecoveryTask?.cancel()
        stallRecoveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled, self.isPlaying, self.isBuffering else { return }
            self.recoverCurrentTrack(reason: "播放缓冲超时")
        }
    }

    private func startHealthMonitor() {
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                self?.checkPlaybackHealth()
            }
        }
    }

    private func checkPlaybackHealth() {
        guard currentTrack != nil, isPlaying, !isRecovering else { return }

        if let bufferStartedAt {
            if Date().timeIntervalSince(bufferStartedAt) > 35 {
                recoverCurrentTrack(reason: "加载超时")
            }
            return
        }

        guard let item = player.currentItem else {
            recoverCurrentTrack(reason: "播放器项目丢失")
            return
        }
        if item.status == .failed {
            recoverCurrentTrack(reason: item.error?.localizedDescription ?? "播放失败")
            return
        }
        if item.status != .readyToPlay {
            return
        }
        if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            if item.isPlaybackBufferEmpty {
                isBuffering = true
                bufferStartedAt = Date()
            }
            return
        }
        guard player.rate > 0 else {
            if Date().timeIntervalSince(lastProgressDate) > 12 {
                recoverCurrentTrack(reason: "播放器已停止")
            }
            return
        }
        if Date().timeIntervalSince(lastProgressDate) > 12 {
            recoverCurrentTrack(reason: "播放进度停滞")
        }
    }

    // MARK: - Background transition task

    private func beginTransitionBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "LxPlayer.TrackTransition") { [weak self] in
            Task { @MainActor in self?.endTransitionBackgroundTask() }
        }
    }

    private func endTransitionBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Remote commands

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
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

    private func updateNowPlaying(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastNowPlayingUpdate) >= 1 else { return }
        lastNowPlayingUpdate = now
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
