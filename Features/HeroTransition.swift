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

struct HeroRGBA {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    var color: Color {
        Color(red: Double(red), green: Double(green), blue: Double(blue), opacity: Double(alpha))
    }

    static func lerp(_ a: HeroRGBA, _ b: HeroRGBA, _ t: CGFloat) -> HeroRGBA {
        HeroRGBA(
            red: a.red + (b.red - a.red) * t,
            green: a.green + (b.green - a.green) * t,
            blue: a.blue + (b.blue - a.blue) * t,
            alpha: a.alpha + (b.alpha - a.alpha) * t
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
    var titleColor: HeroRGBA
    var artistColor: HeroRGBA
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

    /// The mini player's artwork is hidden while the hero owns it. The rest
    /// of the capsule chrome can fade independently when the player closes.
    @Published private(set) var hideMiniCover = false
    @Published private(set) var hideMiniText = false
    @Published private(set) var miniChromeOpacity = 1.0
    /// The real capsule stays in the hierarchy for its anchors, but is not
    /// painted while its animated replacement is travelling to the player.
    @Published private(set) var hideMiniSurface = false
    /// The player page's own cover/title/artist are hidden while the hero is
    /// flying to/from them; the rest of the page stays visible.
    @Published private(set) var hidePlayerHero = false
    /// Same for the lyrics header.
    @Published private(set) var hideLyricsHero = false

    /// Page-level opacity is kept at one while the player exists. The reveal
    /// is done by masking the real player background, so there is no second
    /// surface that has to be cross-faded away at the end.
    @Published private(set) var playerPageOpacity = 0.0
    /// Player controls fade/slide in while the background is still unfolding.
    /// They are also clipped by the same reveal shape, so nothing spills over
    /// the browsing page before the panel reaches it.
    @Published private(set) var playerContentOpacity = 1.0
    /// A small travel on the chrome makes it belong to the unfolding page
    /// rather than appearing as a stationary fade on top of the mini player.
    @Published private(set) var playerContentOffset: CGFloat = 0
    @Published private(set) var lyricsPageOpacity = 0.0
    /// The lyrics background cross-fades over the player background while the
    /// cover flies to the header.
    @Published private(set) var lyricsBackgroundOpacity = 1.0
    /// Lyrics text/controls join the flight instead of popping in afterwards.
    @Published private(set) var lyricsContentOpacity = 1.0

    /// The player background is revealed through one animatable rounded-rect
    /// mask. The blurred artwork itself stays full-screen the whole time, so
    /// it never rescales or dips to black while the capsule grows.
    @Published private(set) var revealActive = false
    @Published private(set) var playerBackdropOpacity = 1.0
    /// One continuous surface moves from the mini capsule to full screen.
    /// Unlike a mask on the browsing page, this is visibly the capsule itself
    /// lifting away from the tab bar and unfolding in both directions.
    @Published private(set) var panelVisible = false
    @Published private(set) var panelFrom: CGRect = .zero
    @Published private(set) var panelTo: CGRect = .zero
    @Published private(set) var panelCornerFrom: CGFloat = 24
    @Published private(set) var panelCornerTo: CGFloat = 0

    @Published private(set) var heroVisible = false
    @Published private(set) var heroTrack: MusicInfo?
    @Published private(set) var progress: CGFloat = 0
    @Published private(set) var spec = HeroSpec(
        from: HeroSnapshot(
            cover: .zero, title: .zero, artist: .zero,
            coverCornerRadius: 10, titleFontSize: 15, artistFontSize: 11,
            shadowOpacity: 0.3, shadowRadius: 8, shadowY: 4,
            titleColor: HeroRGBA(red: 1, green: 1, blue: 1, alpha: 1),
            artistColor: HeroRGBA(red: 1, green: 1, blue: 1, alpha: 0.62)
        ),
        to: HeroSnapshot(
            cover: .zero, title: .zero, artist: .zero,
            coverCornerRadius: 10, titleFontSize: 15, artistFontSize: 11,
            shadowOpacity: 0.3, shadowRadius: 8, shadowY: 4,
            titleColor: HeroRGBA(red: 1, green: 1, blue: 1, alpha: 1),
            artistColor: HeroRGBA(red: 1, green: 1, blue: 1, alpha: 0.62)
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
        revealActive = true
        playerBackdropOpacity = 0
        panelVisible = true

        anchors.removeValue(forKey: .playerCover)
        anchors.removeValue(forKey: .playerTitle)
        anchors.removeValue(forKey: .playerArtist)

        playerPresented = true
        lyricsPresented = false
        playerPageOpacity = 1
        playerContentOpacity = 0
        playerContentOffset = 54
        lyricsPageOpacity = 0
        lyricsContentOpacity = 1
        hidePlayerHero = true
        hideLyricsHero = false
        hideMiniCover = true
        hideMiniText = true
        hideMiniSurface = true
        miniChromeOpacity = 0
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

        // One layout pass at progress 0 before the animation starts. This also
        // guarantees we never try to animate from the previous transition's
        // final progress value.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self, self.pending == .openPlayer else { return }
            withAnimation(.timingCurve(0.22, 0.78, 0.22, 1.0, duration: 0.52)) {
                self.progress = 1
            }
            // The capsule's own glass is visible at progress zero. The moving
            // panel becomes the player background while the page chrome joins
            // the same flight.
            withAnimation(.easeOut(duration: 0.22)) {
                self.playerBackdropOpacity = 1
            }
            // Page chrome joins the transition instead of appearing after it.
            withAnimation(.easeOut(duration: 0.30).delay(0.14)) {
                self.playerContentOpacity = 1
                self.playerContentOffset = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.56) { [weak self] in
            self?.finishOpenPlayer()
        }
    }

    private func finishOpenPlayer() {
        guard pending == .openPlayer else { return }
        pending = nil
        targetAnimationStarted = false
        fallbackWorkItem?.cancel()
        watchdogWorkItem?.cancel()

        // Everything has already reached its final value, so this is a pure
        // state swap without another fade. That removes the end-of-animation
        // pause that used to happen while the panel faded out.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            progress = 1
            revealActive = false
            playerBackdropOpacity = 1
            playerPageOpacity = 1
            playerContentOpacity = 1
            playerContentOffset = 0
            panelVisible = false
            hideMiniCover = false
            hideMiniText = false
            miniChromeOpacity = 1
            hidePlayerHero = false
            heroVisible = false
            isAnimating = false
        }
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
        revealActive = true
        playerBackdropOpacity = 1
        panelVisible = true

        hidePlayerHero = true
        hideMiniCover = true
        hideMiniText = true
        hideMiniSurface = true
        miniChromeOpacity = 0
        playerPageOpacity = 1
        playerContentOpacity = 1
        playerContentOffset = 0
        heroVisible = true

        armWatchdog()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self, self.pending == .closePlayer else { return }
            withAnimation(.timingCurve(0.30, 0.72, 0.24, 1.0, duration: 0.46)) {
                self.progress = 1
            }
            // Controls leave with the shrinking page instead of vanishing on
            // the first frame of the close.
            withAnimation(.easeOut(duration: 0.24)) {
                self.playerContentOpacity = 0
                self.playerContentOffset = 32
            }

            // The capsule chrome arrives while the hero cover is still
            // landing, so the mini player does not pop in at the last frame.
            withAnimation(.easeOut(duration: 0.14).delay(0.28)) {
                self.miniChromeOpacity = 1
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.50) { [weak self] in
            self?.finishClosePlayer()
        }
    }

    private func finishClosePlayer() {
        guard pending == .closePlayer else { return }
        pending = nil
        targetAnimationStarted = false
        watchdogWorkItem?.cancel()

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            playerPresented = false
            revealActive = false
            playerBackdropOpacity = 1
            playerPageOpacity = 0
            playerContentOpacity = 1
            playerContentOffset = 0
            hidePlayerHero = false
            hideMiniSurface = false
            panelVisible = false
            hideMiniCover = false
            hideMiniText = false
            miniChromeOpacity = 1
            heroVisible = false
            isAnimating = false
        }
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
            withAnimation(.timingCurve(0.16, 0.82, 0.24, 1.0, duration: 0.42)) {
                self.progress = 1
            }
            // The player chrome leaves while the lyric backdrop and text
            // arrive, so the page never goes through a flat black frame.
            withAnimation(.easeOut(duration: 0.18)) {
                self.playerContentOpacity = 0
            }
            withAnimation(.easeInOut(duration: 0.34)) {
                self.lyricsBackgroundOpacity = 1
            }
            // Text waits until the cover is close to the header, then joins
            // the last part of the flight instead of popping after it.
            withAnimation(.easeOut(duration: 0.20).delay(0.22)) {
                self.lyricsContentOpacity = 1
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.46) { [weak self] in
            self?.finishOpenLyrics()
        }
    }

    private func finishOpenLyrics() {
        guard pending == .openLyrics else { return }
        pending = nil
        targetAnimationStarted = false
        fallbackWorkItem?.cancel()
        watchdogWorkItem?.cancel()

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            progress = 1
            lyricsPageOpacity = 1
            lyricsBackgroundOpacity = 1
            lyricsContentOpacity = 1
            playerContentOpacity = 0
            hideLyricsHero = false
            heroVisible = false
            isAnimating = false
        }
    }

    func closeLyrics() {
        guard lyricsPresented, !isAnimating else { return }
        isAnimating = true
        pending = .closeLyrics
        targetAnimationStarted = true

        let from = lyricsSnapshot()
        let to = playerSnapshot()

        // Keep the lyrics page while its content and backdrop cross-fade
        // away. The player controls underneath fade back in during the same
        // flight instead of appearing after it.
        lyricsPresented = true
        lyricsPageOpacity = 1
        lyricsBackgroundOpacity = 1
        lyricsContentOpacity = 1
        playerContentOpacity = 0
        hideLyricsHero = true
        hidePlayerHero = true
        heroVisible = true

        spec = HeroSpec(from: from, to: to)
        progress = 0

        armWatchdog()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self, self.pending == .closeLyrics else { return }
            withAnimation(.timingCurve(0.16, 0.82, 0.24, 1.0, duration: 0.42)) {
                self.progress = 1
            }
            withAnimation(.easeOut(duration: 0.16)) {
                self.lyricsContentOpacity = 0
            }
            withAnimation(.easeInOut(duration: 0.30)) {
                self.lyricsBackgroundOpacity = 0
            }
            withAnimation(.easeOut(duration: 0.20).delay(0.16)) {
                self.playerContentOpacity = 1
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.46) { [weak self] in
            self?.finishCloseLyrics()
        }
    }

    private func finishCloseLyrics() {
        guard pending == .closeLyrics else { return }
        pending = nil
        targetAnimationStarted = false
        watchdogWorkItem?.cancel()

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
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
    }

    // MARK: - Snapshots

    private func miniSnapshot() -> HeroSnapshot {
        let cover = frame(.miniCover, fallback: fallbackMiniCover)
        let title = labelFrame(.miniTitle, fallback: miniTitleFrame(from: cover),
                               minWidth: max(screenBounds.width - cover.maxX - 110, 80))
        let artist = labelFrame(.miniArtist, fallback: miniArtistFrame(from: cover),
                                minWidth: max(screenBounds.width - cover.maxX - 110, 80))
        return HeroSnapshot(
            cover: cover,
            title: title,
            artist: artist,
            coverCornerRadius: 10,
            titleFontSize: 15,
            artistFontSize: 11,
            shadowOpacity: 0.3,
            shadowRadius: 7,
            shadowY: 4,
            titleColor: rgba(AppTheme.primaryText),
            artistColor: rgba(AppTheme.secondaryText)
        )
    }

    private func playerSnapshot() -> HeroSnapshot {
        let cover = frame(.playerCover, fallback: fallbackPlayerCover)
        let title = labelFrame(.playerTitle, fallback: playerTitleFrame(from: cover),
                               minWidth: max(screenBounds.width - 48, 160))
        let artist = labelFrame(.playerArtist, fallback: playerArtistFrame(from: cover),
                                minWidth: max(screenBounds.width - 48, 160))
        return HeroSnapshot(
            cover: cover,
            title: title,
            artist: artist,
            coverCornerRadius: 14,
            titleFontSize: 20,
            artistFontSize: 20,
            shadowOpacity: 0.55,
            shadowRadius: 34,
            shadowY: 22,
            titleColor: HeroRGBA(red: 1, green: 1, blue: 1, alpha: 1),
            artistColor: HeroRGBA(red: 1, green: 1, blue: 1, alpha: 0.62)
        )
    }

    private func lyricsSnapshot() -> HeroSnapshot {
        let cover = frame(.lyricsCover, fallback: fallbackLyricsCover)
        let title = labelFrame(.lyricsTitle, fallback: lyricsTitleFrame(from: cover),
                               minWidth: max(screenBounds.width - cover.maxX - 110, 140))
        let artist = labelFrame(.lyricsArtist, fallback: lyricsArtistFrame(from: cover),
                                minWidth: max(screenBounds.width - cover.maxX - 110, 140))
        return HeroSnapshot(
            cover: cover,
            title: title,
            artist: artist,
            coverCornerRadius: 9,
            titleFontSize: 17,
            artistFontSize: 12,
            shadowOpacity: 0.28,
            shadowRadius: 8,
            shadowY: 4,
            titleColor: HeroRGBA(red: 1, green: 1, blue: 1, alpha: 1),
            artistColor: HeroRGBA(red: 1, green: 1, blue: 1, alpha: 0.5)
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

    private func rgba(_ color: Color) -> HeroRGBA {
        let ui = UIColor(color)
        var red: CGFloat = 1
        var green: CGFloat = 1
        var blue: CGFloat = 1
        var alpha: CGFloat = 1
        guard ui.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return HeroRGBA(red: 1, green: 1, blue: 1, alpha: 1)
        }
        return HeroRGBA(red: red, green: green, blue: blue, alpha: alpha)
    }

    private func labelFrame(
        _ anchor: HeroAnchor,
        fallback: CGRect,
        minWidth: CGFloat
    ) -> CGRect {
        var value = frame(anchor, fallback: fallback)
        value.size.width = max(value.width, minWidth)
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
            revealActive = false
            playerBackdropOpacity = 1
            playerContentOpacity = 1
            playerContentOffset = 0
            hidePlayerHero = false
            hideMiniSurface = false
            panelVisible = false
            hideMiniCover = false
            hideMiniText = false
            miniChromeOpacity = 1
            heroVisible = false
        case .closePlayer:
            playerPresented = false
            playerPageOpacity = 0
            revealActive = false
            playerBackdropOpacity = 1
            playerContentOpacity = 1
            playerContentOffset = 0
            hidePlayerHero = false
            hideMiniSurface = false
            panelVisible = false
            hideMiniCover = false
            hideMiniText = false
            miniChromeOpacity = 1
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

/// The actual moving capsule. Its blurred artwork is kept full-screen behind
/// the moving clip, so the image does not stretch into a dark rectangle while
/// the capsule opens. The same surface also travels back down on close.
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
                track: hero.heroTrack
            )
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
        let p = min(max(progress, 0), 1)
        // The capsule keeps its rounded silhouette while it lifts. Only the
        // final part opens into square screen edges; closing reverses this.
        let opening = cornerTo == 0
        let cornerPhase = opening ? min(max((p - 0.70) / 0.30, 0), 1) : min(p / 0.65, 1)
        let easedCorner = cornerPhase * cornerPhase * (3 - 2 * cornerPhase)
        let radius = opening
            ? cornerFrom * (1 - easedCorner)
            : cornerTo * easedCorner
        let artworkOpacity = opening
            ? min(1, 0.16 + p * 1.2)
            : max(0, 1 - p * 1.35)
        let glassOpacity = opening ? max(0, 1 - p * 1.35) : min(1, p * p * 1.1)
        let baseOpacity = opening ? max(0, 1 - p * 1.35) : p * p
        let shadowOpacity = 0.34 * (1 - min(1, p * 1.5))

        // The real capsule is already light glass. At the last frame the
        // travelling surface must be that same light glass, not a black panel
        // fading out over a white one.

        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            ZStack {
                // Full-screen content is clipped by the moving capsule. The
                // artwork therefore retains its scale instead of stretching
                // from a 60 pt capsule into a full-screen rectangle.
                PlayerBackdrop(url: track?.picURL)
                    .frame(width: to.width, height: to.height)
                    .position(x: to.midX, y: to.midY)
                    .opacity(artworkOpacity)

                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(glassOpacity)
            }
            .frame(width: max(frame.width, 1), height: max(frame.height, 1))
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color(red: 0.80, green: 0.81, blue: 0.84))
                    .opacity(baseOpacity)
            )
            .clipShape(RoundedRectangle(cornerRadius: max(radius, 0), style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: max(radius, 0), style: .continuous)
                    .strokeBorder(Color.white.opacity(0.24 * glassOpacity), lineWidth: 0.8)
            )
            .position(x: frame.midX, y: frame.midY)
            .shadow(color: .black.opacity(shadowOpacity), radius: 22, y: 10)
            .offset(x: -origin.x, y: -origin.y)
        }
    }
}

/// An animatable rounded rectangle used as a mask over the *real* player
/// background. The background stays full-screen; only this window grows or
/// shrinks. That keeps the blurred artwork at a constant scale and removes the
/// dark flash that happened when a small panel stretched its own backdrop.
struct HeroRevealShape: Shape {
    var progress: CGFloat
    let from: CGRect
    let to: CGRect
    let cornerFrom: CGFloat
    let cornerTo: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private func smoothstep(_ value: CGFloat) -> CGFloat {
        let t = min(max(value, 0), 1)
        return t * t * (3 - 2 * t)
    }

    func path(in rect: CGRect) -> Path {
        let p = min(max(progress, 0), 1)
        let frame = CGRect(
            x: from.minX + (to.minX - from.minX) * p,
            y: from.minY + (to.minY - from.minY) * p,
            width: from.width + (to.width - from.width) * p,
            height: from.height + (to.height - from.height) * p
        )
        // Opening: hold the capsule radius until the very end, then square
        // off. Closing: stay square while the page is still large, and only
        // round the corners once the shape is close to the capsule.
        let radius: CGFloat = cornerTo == 0
            ? cornerFrom * (1 - smoothstep((p - 0.86) / 0.14))
            : cornerTo * smoothstep((p - 0.62) / 0.30)
        return RoundedRectangle(cornerRadius: max(radius, 0), style: .continuous)
            .path(in: frame)
    }
}

/// Aligns the global anchor frames with whatever local coordinate space the
/// masked view happens to use (safe area or full screen).
struct HeroRevealMask: View {
    @ObservedObject var hero: HeroTransitionCoordinator

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            Group {
                if hero.revealActive {
                    HeroRevealShape(
                        progress: hero.progress,
                        from: hero.panelFrom.offsetBy(dx: -origin.x, dy: -origin.y),
                        to: hero.panelTo.offsetBy(dx: -origin.x, dy: -origin.y),
                        cornerFrom: hero.panelCornerFrom,
                        cornerTo: hero.panelCornerTo
                    )
                    .fill(Color.white)
                } else {
                    Rectangle().fill(Color.white)
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// The only moving hero layer. It draws above every page so page swaps can
/// never fade, duplicate or drag the cover around.
struct HeroOverlayView: View {
    @ObservedObject var hero: HeroTransitionCoordinator

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                if hero.heroVisible, let track = hero.heroTrack {
                    HeroVisual(progress: hero.progress, spec: hero.spec, track: track)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                        .offset(x: -origin.x, y: -origin.y)
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
        let titleColor = HeroRGBA.lerp(spec.from.titleColor, spec.to.titleColor, progress).color
        let artistColor = HeroRGBA.lerp(spec.from.artistColor, spec.to.artistColor, progress).color

        ZStack(alignment: .topLeading) {
            artwork
                .frame(width: max(cover.width, 1), height: max(cover.height, 1))
                .clipShape(RoundedRectangle(cornerRadius: max(corner, 0), style: .continuous))
                .position(x: cover.midX, y: cover.midY)
                .shadow(color: .black.opacity(Double(shadowOpacity)),
                        radius: shadowRadius,
                        y: shadowY)

            heroText(track.name, frame: title, size: titleSize, weight: .semibold, color: titleColor)
            heroText(track.singer, frame: artist, size: artistSize, weight: .regular, color: artistColor)
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
        color: Color
    ) -> some View {
        Text(text)
            .font(.system(size: max(size, 1), weight: weight))
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(width: max(frame.width, 1), height: max(frame.height, 1), alignment: .leading)
            .position(x: frame.midX, y: frame.midY)
    }
}
