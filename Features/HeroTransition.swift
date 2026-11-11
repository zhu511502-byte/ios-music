import SwiftUI
import UIKit

/// Global anchors reported by the real pages. The transition never applies
/// matchedGeometryEffect to those pages; it reads their frames and moves one
/// independent hero layer instead.
enum HeroAnchor: Hashable {
    case miniCapsule
    case miniCover
    case miniTitle
    case miniArtist
    case playerCover
    case playerTitle
    case playerArtist
    case lyricsCover
    case lyricsTitle
    case lyricsArtist
}

struct HeroAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: [HeroAnchor: CGRect] = [:]

    static func reduce(value: inout [HeroAnchor: CGRect], nextValue: () -> [HeroAnchor: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func heroAnchor(_ anchor: HeroAnchor) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: HeroAnchorPreferenceKey.self,
                    value: [anchor: proxy.frame(in: .global)]
                )
            }
        )
    }
}

/// A complete description of one end of the transition. Using real measured
/// anchors (rather than hand-built guesses) keeps the flying title/artist
/// exactly on top of the real labels when the pages swap.
struct HeroSnapshot {
    var cover: CGRect
    var title: CGRect
    var artist: CGRect
    var coverCornerRadius: CGFloat
    var titleFontSize: CGFloat
    var artistFontSize: CGFloat
    var shadowOpacity: CGFloat
    var shadowRadius: CGFloat
    var shadowY: CGFloat
}

struct HeroSpec {
    var from: HeroSnapshot
    var to: HeroSnapshot
}

/// Coordinates compact -> player -> lyrics.
///
/// Important behaviour:
/// * There is exactly one moving cover/title/artist layer.
/// * The destination page is inserted immediately. Its own copy of the
///   cover/title/artist is hidden until the hero lands, so the two copies can
///   never be visible at the same time (the old cross-fade produced obvious
///   double images and ghost text).
/// * There is no full-screen material "backdrop" card. That card was what
///   looked like a giant grey panel growing out of the mini player.
@MainActor
final class HeroTransitionCoordinator: ObservableObject {
    enum Pending: Equatable {
        case openPlayer
        case closePlayer
        case openLyrics
        case closeLyrics
    }

    @Published private(set) var playerPresented = false
    @Published private(set) var lyricsPresented = false

    /// The mini player is hidden as soon as the hero takes over its artwork.
    @Published private(set) var hideMiniContent = false
    /// The player page's own cover/title/artist are hidden while the hero is
    /// flying to/from them; the rest of the page stays visible.
    @Published private(set) var hidePlayerHero = false
    /// Same for the lyrics header.
    @Published private(set) var hideLyricsHero = false

    /// A very light fade-in for the destination page. It deliberately starts
    /// mostly opaque so the light browsing list can never show through white
    /// player text.
    @Published private(set) var playerPageOpacity = 0.0
    /// Player controls/title fade independently from the background, so a
    /// lyrics-background cross-fade never shows two sets of controls at once.
    @Published private(set) var playerContentOpacity = 1.0
    @Published private(set) var lyricsPageOpacity = 0.0
    /// The lyrics background cross-fades over the player background while the
    /// cover flies to the header.
    @Published private(set) var lyricsBackgroundOpacity = 1.0
    /// The lyrics background stays visible during the cover flight, while the
    /// text/controls wait until the hero has landed. This avoids a giant album
    /// cover sweeping across the lyric lines.
    @Published private(set) var lyricsContentOpacity = 1.0

    /// A mini-player-shaped glass panel that unfolds into the player page.
    @Published private(set) var panelVisible = false
    @Published private(set) var panelFrom: CGRect = .zero
    @Published private(set) var panelTo: CGRect = .zero
    @Published private(set) var panelCornerFrom: CGFloat = 24
    @Published private(set) var panelCornerTo: CGFloat = 0
    @Published private(set) var panelBackdropFrom: Double = 0.06
    @Published private(set) var panelBackdropTo: Double = 1.0
    @Published private(set) var panelOpacity = 1.0

    @Published private(set) var heroVisible = false
    @Published private(set) var heroTrack: MusicInfo?
    @Published private(set) var progress: CGFloat = 0
    @Published private(set) var spec = HeroSpec(
        from: HeroSnapshot(
            cover: .zero, title: .zero, artist: .zero,
            coverCornerRadius: 10, titleFontSize: 15, artistFontSize: 11,
            shadowOpacity: 0.3, shadowRadius: 8, shadowY: 4
        ),
        to: HeroSnapshot(
            cover: .zero, title: .zero, artist: .zero,
            coverCornerRadius: 10, titleFontSize: 15, artistFontSize: 11,
            shadowOpacity: 0.3, shadowRadius: 8, shadowY: 4
        )
    )

    private var anchors: [HeroAnchor: CGRect] = [:]
    private var pending: Pending?
    private var targetAnimationStarted = false
    @Published private(set) var isAnimating = false
    private var watchdogWorkItem: DispatchWorkItem?
    private var fallbackWorkItem: DispatchWorkItem?

    private var screenBounds: CGRect { UIScreen.main.bounds }

    // MARK: - Anchor updates

    func updateAnchors(_ values: [HeroAnchor: CGRect]) {
        anchors.merge(values, uniquingKeysWith: { _, new in new })

        if pending == .openPlayer, (anchors[.playerCover]?.width ?? 0) > 1 {
            beginOpenPlayer()
        } else if pending == .openLyrics, (anchors[.lyricsCover]?.width ?? 0) > 1 {
            beginOpenLyrics()
        }
    }

    // MARK: - Player

    func openPlayer(track: MusicInfo?) {
        guard !playerPresented, !isAnimating else { return }
        isAnimating = true
        pending = .openPlayer
        targetAnimationStarted = false
        heroTrack = track

        let mini = miniSnapshot()
        spec = HeroSpec(from: mini, to: mini)
        progress = 0

        panelFrom = frame(.miniCapsule, fallback: fallbackMiniCapsule)
        panelTo = screenBounds
        panelCornerFrom = 24
        panelCornerTo = 0
        panelBackdropFrom = 0.06
        panelBackdropTo = 1.0
        panelOpacity = 1
        panelVisible = true

        anchors.removeValue(forKey: .playerCover)
        anchors.removeValue(forKey: .playerTitle)
        anchors.removeValue(forKey: .playerArtist)

        playerPresented = true
        lyricsPresented = false
        playerPageOpacity = 0
        playerContentOpacity = 1
        lyricsPageOpacity = 0
        lyricsContentOpacity = 1
        hidePlayerHero = true
        hideLyricsHero = false
        hideMiniContent = true
        heroVisible = true

        armWatchdog()
        scheduleFallback(after: 0.42) { [weak self] in self?.beginOpenPlayer() }
    }

    private func beginOpenPlayer() {
        guard pending == .openPlayer, !targetAnimationStarted else { return }
        targetAnimationStarted = true
        fallbackWorkItem?.cancel()

        let from = miniSnapshot()
        let to = playerSnapshot()
        spec = HeroSpec(from: from, to: to)
        progress = 0
        hidePlayerHero = true

        // One layout pass at progress 0 before the spring starts. This also
        // guarantees we never try to animate from the previous transition's
        // final progress value.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self, self.pending == .openPlayer else { return }
            withAnimation(.timingCurve(0.16, 0.82, 0.24, 1.0, duration: 0.38)) {
                self.progress = 1
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { [weak self] in
            self?.finishOpenPlayer()
        }
    }

    private func finishOpenPlayer() {
        guard pending == .openPlayer else { return }
        pending = nil
        targetAnimationStarted = false
        fallbackWorkItem?.cancel()
        watchdogWorkItem?.cancel()

        progress = 1
        playerPageOpacity = 1
        panelVisible = false
        hidePlayerHero = false
        hideMiniContent = false
        heroVisible = false
        isAnimating = false
    }

    func closePlayer() {
        guard playerPresented, !isAnimating else { return }
        isAnimating = true
        pending = .closePlayer
        targetAnimationStarted = true

        let from = playerSnapshot()
        let to = miniSnapshot()
        spec = HeroSpec(from: from, to: to)
        progress = 0

        panelFrom = screenBounds
        panelTo = frame(.miniCapsule, fallback: fallbackMiniCapsule)
        panelCornerFrom = 0
        panelCornerTo = 24
        panelBackdropFrom = 1.0
        panelBackdropTo = 0.06
        panelOpacity = 1
        panelVisible = true

        hidePlayerHero = true
        hideMiniContent = true
        playerPageOpacity = 0
        heroVisible = true

        armWatchdog()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self, self.pending == .closePlayer else { return }
            withAnimation(.timingCurve(0.16, 0.82, 0.24, 1.0, duration: 0.36)) {
                self.progress = 1
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) { [weak self] in
            self?.finishClosePlayer()
        }
    }

    private func finishClosePlayer() {
        guard pending == .closePlayer else { return }
        pending = nil
        targetAnimationStarted = false
        watchdogWorkItem?.cancel()

        playerPresented = false
        hidePlayerHero = false
        hideMiniContent = false
        heroVisible = false
        playerPageOpacity = 0
        panelVisible = false
        isAnimating = false
    }

    // MARK: - Lyrics

    func openLyrics() {
        guard playerPresented, !lyricsPresented, !isAnimating else { return }
        isAnimating = true
        pending = .openLyrics
        targetAnimationStarted = false

        let player = playerSnapshot()
        spec = HeroSpec(from: player, to: player)
        progress = 0

        anchors.removeValue(forKey: .lyricsCover)
        anchors.removeValue(forKey: .lyricsTitle)
        anchors.removeValue(forKey: .lyricsArtist)

        lyricsPresented = true
        lyricsPageOpacity = 1
        lyricsBackgroundOpacity = 0
        lyricsContentOpacity = 0
        playerContentOpacity = 0
        hidePlayerHero = true
        hideLyricsHero = true
        heroVisible = true

        armWatchdog()
        scheduleFallback(after: 0.42) { [weak self] in self?.beginOpenLyrics() }
    }

    private func beginOpenLyrics() {
        guard pending == .openLyrics, !targetAnimationStarted else { return }
        targetAnimationStarted = true
        fallbackWorkItem?.cancel()

        let from = playerSnapshot()
        let to = lyricsSnapshot()
        spec = HeroSpec(from: from, to: to)
        progress = 0
        hideLyricsHero = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self, self.pending == .openLyrics else { return }
            withAnimation(.timingCurve(0.16, 0.82, 0.24, 1.0, duration: 0.34)) {
                self.progress = 1
            }
            withAnimation(.easeOut(duration: 0.28)) {
                self.lyricsBackgroundOpacity = 1
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) { [weak self] in
            self?.finishOpenLyrics()
        }
    }

    private func finishOpenLyrics() {
        guard pending == .openLyrics else { return }
        pending = nil
        targetAnimationStarted = false
        fallbackWorkItem?.cancel()
        watchdogWorkItem?.cancel()

        progress = 1
        lyricsPageOpacity = 1
        lyricsBackgroundOpacity = 1
        lyricsContentOpacity = 1
        hideLyricsHero = false
        heroVisible = false
        isAnimating = false
    }

    func closeLyrics() {
        guard lyricsPresented, !isAnimating else { return }
        isAnimating = true
        pending = .closeLyrics
        targetAnimationStarted = true

        let from = lyricsSnapshot()
        let to = playerSnapshot()

        // Keep the lyrics page for its background cross-fade, but hide its
        // content and header immediately. The player page underneath becomes
        // visible as the lyric backdrop fades out.
        lyricsPresented = true
        lyricsPageOpacity = 1
        lyricsBackgroundOpacity = 1
        lyricsContentOpacity = 0
        hideLyricsHero = true
        hidePlayerHero = true
        heroVisible = true

        spec = HeroSpec(from: from, to: to)
        progress = 0

        armWatchdog()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self, self.pending == .closeLyrics else { return }
            withAnimation(.timingCurve(0.16, 0.82, 0.24, 1.0, duration: 0.34)) {
                self.progress = 1
            }
            withAnimation(.easeOut(duration: 0.30)) {
                self.lyricsBackgroundOpacity = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
            guard let self, self.pending == .closeLyrics else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                self.playerContentOpacity = 1
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) { [weak self] in
            self?.finishCloseLyrics()
        }
    }

    private func finishCloseLyrics() {
        guard pending == .closeLyrics else { return }
        pending = nil
        targetAnimationStarted = false
        watchdogWorkItem?.cancel()

        lyricsPresented = false
        playerContentOpacity = 1
        hidePlayerHero = false
        hideLyricsHero = false
        heroVisible = false
        lyricsPageOpacity = 0
        lyricsBackgroundOpacity = 0
        lyricsContentOpacity = 0
        isAnimating = false
    }

    // MARK: - Snapshots

    private func miniSnapshot() -> HeroSnapshot {
        let cover = frame(.miniCover, fallback: fallbackMiniCover)
        let title = labelFrame(.miniTitle, fallback: miniTitleFrame(from: cover),
                               minWidth: max(screenBounds.width - cover.maxX - 110, 80), minHeight: 22)
        let artist = labelFrame(.miniArtist, fallback: miniArtistFrame(from: cover),
                                minWidth: max(screenBounds.width - cover.maxX - 110, 80), minHeight: 16)
        return HeroSnapshot(
            cover: cover,
            title: title,
            artist: artist,
            coverCornerRadius: 10,
            titleFontSize: 15,
            artistFontSize: 11,
            shadowOpacity: 0.3,
            shadowRadius: 7,
            shadowY: 4
        )
    }

    private func playerSnapshot() -> HeroSnapshot {
        let cover = frame(.playerCover, fallback: fallbackPlayerCover)
        let title = labelFrame(.playerTitle, fallback: playerTitleFrame(from: cover),
                               minWidth: max(screenBounds.width - 48, 160), minHeight: 30)
        let artist = labelFrame(.playerArtist, fallback: playerArtistFrame(from: cover),
                                minWidth: max(screenBounds.width - 48, 160), minHeight: 24)
        return HeroSnapshot(
            cover: cover,
            title: title,
            artist: artist,
            coverCornerRadius: 14,
            titleFontSize: 20,
            artistFontSize: 20,
            shadowOpacity: 0.55,
            shadowRadius: 34,
            shadowY: 22
        )
    }

    private func lyricsSnapshot() -> HeroSnapshot {
        let cover = frame(.lyricsCover, fallback: fallbackLyricsCover)
        let title = labelFrame(.lyricsTitle, fallback: lyricsTitleFrame(from: cover),
                               minWidth: max(screenBounds.width - cover.maxX - 110, 140), minHeight: 22)
        let artist = labelFrame(.lyricsArtist, fallback: lyricsArtistFrame(from: cover),
                                minWidth: max(screenBounds.width - cover.maxX - 110, 140), minHeight: 16)
        return HeroSnapshot(
            cover: cover,
            title: title,
            artist: artist,
            coverCornerRadius: 9,
            titleFontSize: 17,
            artistFontSize: 12,
            shadowOpacity: 0.28,
            shadowRadius: 8,
            shadowY: 4
        )
    }

    private func miniTitleFrame(from cover: CGRect) -> CGRect {
        let x = cover.maxX + 11
        return CGRect(x: x, y: cover.minY + 6,
                      width: max(screenBounds.width - x - 100, 80), height: 22)
    }

    private func miniArtistFrame(from cover: CGRect) -> CGRect {
        CGRect(x: cover.maxX + 11, y: cover.minY + 28,
               width: max(screenBounds.width - cover.maxX - 111, 70), height: 16)
    }

    private func playerTitleFrame(from cover: CGRect) -> CGRect {
        let x = max(24, cover.minX)
        return CGRect(x: x, y: cover.maxY + 48,
                      width: max(screenBounds.width - x * 2, 120), height: 30)
    }

    private func playerArtistFrame(from cover: CGRect) -> CGRect {
        let title = playerTitleFrame(from: cover)
        return CGRect(x: title.minX, y: title.maxY + 3,
                      width: title.width, height: 24)
    }

    private func lyricsTitleFrame(from cover: CGRect) -> CGRect {
        let x = cover.maxX + 12
        return CGRect(x: x, y: cover.minY + 1,
                      width: max(screenBounds.width - x - 100, 80), height: 22)
    }

    private func lyricsArtistFrame(from cover: CGRect) -> CGRect {
        let title = lyricsTitleFrame(from: cover)
        return CGRect(x: title.minX, y: title.maxY + 2,
                      width: title.width, height: 16)
    }

    private func labelFrame(
        _ anchor: HeroAnchor,
        fallback: CGRect,
        minWidth: CGFloat,
        minHeight: CGFloat
    ) -> CGRect {
        var value = frame(anchor, fallback: fallback)
        value.size.width = max(value.width, minWidth)
        value.size.height = max(value.height, minHeight)
        return value
    }

    private func frame(_ anchor: HeroAnchor, fallback: CGRect) -> CGRect {
        guard let value = anchors[anchor], value.width > 1, value.height > 1 else {
            return fallback
        }
        return value
    }

    // MARK: - Safety net

    private func armWatchdog() {
        watchdogWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.forceComplete() }
        watchdogWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: item)
    }

    private func forceComplete() {
        guard isAnimating else { return }
        let current = pending
        pending = nil
        targetAnimationStarted = false
        fallbackWorkItem?.cancel()
        watchdogWorkItem?.cancel()

        switch current {
        case .openPlayer:
            playerPageOpacity = 1
            panelVisible = false
            hidePlayerHero = false
            hideMiniContent = false
            heroVisible = false
        case .closePlayer:
            playerPresented = false
            playerPageOpacity = 0
            panelVisible = false
            hidePlayerHero = false
            hideMiniContent = false
            heroVisible = false
        case .openLyrics:
            lyricsPageOpacity = 1
            lyricsBackgroundOpacity = 1
            lyricsContentOpacity = 1
            playerContentOpacity = 0
            hideLyricsHero = false
            hidePlayerHero = true
            heroVisible = false
        case .closeLyrics:
            lyricsPresented = false
            playerContentOpacity = 1
            lyricsPageOpacity = 0
            lyricsBackgroundOpacity = 0
            lyricsContentOpacity = 0
            hidePlayerHero = false
            hideLyricsHero = false
            heroVisible = false
        case .none:
            heroVisible = false
            hidePlayerHero = false
            hideLyricsHero = false
        }
        isAnimating = false
    }

    private func scheduleFallback(after seconds: TimeInterval, _ action: @escaping () -> Void) {
        fallbackWorkItem?.cancel()
        let item = DispatchWorkItem(block: action)
        fallbackWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    // MARK: - Fallbacks (used only when an anchor has not laid out yet)

    private var fallbackMiniCapsule: CGRect {
        CGRect(x: 10, y: screenBounds.maxY - 128, width: screenBounds.width - 20, height: 64)
    }
    private var fallbackMiniCover: CGRect {
        CGRect(x: 21, y: screenBounds.maxY - 118, width: 46, height: 46)
    }
    private var fallbackPlayerCover: CGRect {
        let side = min(360, max(220, screenBounds.width - 48))
        return CGRect(x: (screenBounds.width - side) / 2, y: 100, width: side, height: side)
    }
    private var fallbackPlayerTitle: CGRect {
        CGRect(x: 24, y: fallbackPlayerCover.maxY + 24, width: screenBounds.width - 48, height: 28)
    }
    private var fallbackPlayerArtist: CGRect {
        CGRect(x: 24, y: fallbackPlayerTitle.maxY + 5, width: screenBounds.width - 48, height: 24)
    }
    private var fallbackLyricsCover: CGRect {
        CGRect(x: 62, y: 52, width: 46, height: 46)
    }
    private var fallbackLyricsTitle: CGRect {
        CGRect(x: 120, y: 54, width: screenBounds.width - 220, height: 22)
    }
    private var fallbackLyricsArtist: CGRect {
        CGRect(x: 120, y: 76, width: screenBounds.width - 220, height: 16)
    }
}

/// The mini-player capsule unfolding into the player page. It is a separate
/// surface above the (still hidden) player page; because both use
/// `PlayerBackdrop`, the hand-off when the panel reaches full screen is
/// colour-identical.
struct HeroPanelView: View {
    @ObservedObject var hero: HeroTransitionCoordinator

    var body: some View {
        GeometryReader { _ in
            HeroPanelVisual(
                progress: hero.progress,
                from: hero.panelFrom,
                to: hero.panelTo,
                cornerFrom: hero.panelCornerFrom,
                cornerTo: hero.panelCornerTo,
                backdropFrom: hero.panelBackdropFrom,
                backdropTo: hero.panelBackdropTo,
                track: hero.heroTrack
            )
            .opacity(hero.panelOpacity)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct HeroPanelVisual: View, Animatable {
    var progress: CGFloat
    let from: CGRect
    let to: CGRect
    let cornerFrom: CGFloat
    let cornerTo: CGFloat
    let backdropFrom: Double
    let backdropTo: Double
    let track: MusicInfo?

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        a + (b - a) * min(max(progress, 0), 1)
    }

    var body: some View {
        let frame = CGRect(
            x: lerp(from.minX, to.minX),
            y: lerp(from.minY, to.minY),
            width: lerp(from.width, to.width),
            height: lerp(from.height, to.height)
        )
        let radius = lerp(cornerFrom, cornerTo)
        let p = min(max(progress, 0), 1)
        let backdropOpacity = backdropFrom + (backdropTo - backdropFrom) * Double(p)

        ZStack {
            ZStack {
                RoundedRectangle(cornerRadius: max(radius, 0), style: .continuous)
                    .fill(.ultraThinMaterial)

                PlayerBackdrop(url: track?.picURL)
                    .opacity(backdropOpacity)
            }
            .frame(width: max(frame.width, 1), height: max(frame.height, 1))
            .clipShape(RoundedRectangle(cornerRadius: max(radius, 0), style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: max(radius, 0), style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
            )
            .position(x: frame.midX, y: frame.midY)
            .shadow(color: .black.opacity(0.42), radius: 24, y: 10)
        }
    }
}

/// The only moving hero layer. It draws above every page so page swaps can
/// never fade, duplicate or drag the cover around.
struct HeroOverlayView: View {
    @ObservedObject var hero: HeroTransitionCoordinator

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if hero.heroVisible, let track = hero.heroTrack {
                    HeroVisual(progress: hero.progress, spec: hero.spec, track: track)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Interpolates every geometric property from one `progress` value. Animating
/// width and height through separate SwiftUI frames used to let the artwork
/// become briefly wide/short; a single animatable value keeps it square.
private struct HeroVisual: View, Animatable {
    var progress: CGFloat
    let spec: HeroSpec
    let track: MusicInfo

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private func lerp(_ from: CGFloat, _ to: CGFloat) -> CGFloat {
        from + (to - from) * progress
    }

    private func lerp(_ from: CGRect, _ to: CGRect) -> CGRect {
        CGRect(
            x: lerp(from.minX, to.minX),
            y: lerp(from.minY, to.minY),
            width: lerp(from.width, to.width),
            height: lerp(from.height, to.height)
        )
    }

    var body: some View {
        let cover = lerp(spec.from.cover, spec.to.cover)
        let title = lerp(spec.from.title, spec.to.title)
        let artist = lerp(spec.from.artist, spec.to.artist)
        let corner = lerp(spec.from.coverCornerRadius, spec.to.coverCornerRadius)
        let titleSize = lerp(spec.from.titleFontSize, spec.to.titleFontSize)
        let artistSize = lerp(spec.from.artistFontSize, spec.to.artistFontSize)
        let shadowOpacity = lerp(spec.from.shadowOpacity, spec.to.shadowOpacity)
        let shadowRadius = lerp(spec.from.shadowRadius, spec.to.shadowRadius)
        let shadowY = lerp(spec.from.shadowY, spec.to.shadowY)

        ZStack(alignment: .topLeading) {
            artwork
                .frame(width: max(cover.width, 1), height: max(cover.height, 1))
                .clipShape(RoundedRectangle(cornerRadius: max(corner, 0), style: .continuous))
                .position(x: cover.midX, y: cover.midY)
                .shadow(color: .black.opacity(Double(shadowOpacity)),
                        radius: shadowRadius,
                        y: shadowY)

            heroText(track.name, frame: title, size: titleSize, weight: .semibold, opacity: 1)
            heroText(track.singer, frame: artist, size: artistSize, weight: .regular, opacity: 0.62)
        }
    }

    private var artwork: some View {
        CachedArtworkImage(url: track.picURL) {
            placeholder
        }
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [AppTheme.accent.opacity(0.8), Color.purple.opacity(0.55)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            Image(systemName: "music.note")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        )
    }

    private func heroText(
        _ text: String,
        frame: CGRect,
        size: CGFloat,
        weight: Font.Weight,
        opacity: Double
    ) -> some View {
        Text(text)
            .font(.system(size: max(size, 1), weight: weight))
            .foregroundStyle(.white.opacity(opacity))
            .lineLimit(1)
            .frame(width: max(frame.width, 1), height: max(frame.height, 1), alignment: .leading)
            .position(x: frame.midX, y: frame.midY)
    }
}
