import SwiftUI
import UIKit

struct PlayerView: View {
    @EnvironmentObject private var player: PlaybackCoordinator
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var hero: HeroTransitionCoordinator

    var onClose: (() -> Void)? = nil

    @State private var showAddToPlaylist = false
    @State private var autoPresentedLandscape = false
    @State private var isLandscape = false

    private var albumName: String? {
        guard let value = player.currentTrack?.albumName, !value.isEmpty else { return nil }
        return value
    }

    private var isLoved: Bool {
        guard let id = player.currentTrack?.id else { return false }
        return library.isLoved(id)
    }

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                playerContent(size: geometry.size)
                    .onAppear { updateOrientation(geometry.size) }
                    .onChange(of: geometry.size) { updateOrientation($0) }
            }

            if hero.lyricsPresented {
                LyricsView(isActive: true, onClose: closeLyricsPage)
                    .zIndex(2)
                    .opacity(hero.lyricsPageOpacity)
            }
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let track = player.currentTrack {
                PlaylistPickerSheet(track: track)
                    .environmentObject(library)
            }
        }
        .onChange(of: hero.isAnimating) { animating in
            // In landscape the player normally goes straight to lyrics. Do
            // it only after the opening hero animation has fully settled,
            // otherwise the two transitions would overlap.
            guard !animating, isLandscape, hero.playerPresented,
                  !hero.lyricsPresented, !autoPresentedLandscape else { return }
            autoPresentedLandscape = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if !hero.lyricsPresented { openLyrics() }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func closePlayer() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private func closeLyricsPage() {
        hero.closeLyrics()
    }

    private func playerContent(size: CGSize) -> some View {
        ZStack {
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 24)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                    .opacity(hero.playerTopBarOpacity)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        ArtworkView(url: player.currentTrack?.picURL,
                                    size: min(360, max(220, size.width - 48)),
                                    cornerRadius: 14)
                            .shadow(color: .black.opacity(0.55), radius: 34, y: 22)
                            .heroAnchor(.playerCover)
                            .opacity(hero.hidePlayerHero ? 0 : 1)
                            .padding(.top, 22)

                        titleBlock
                            .padding(.top, 24)

                        PlayerProgressView(clock: player.clock, duration: player.duration) { value in
                            player.seek(to: value)
                        }
                        .padding(.top, 18)

                        QualityMenuView()
                            .padding(.top, 2)

                        transportControls
                            .padding(.top, 12)

                        utilityControls
                            .padding(.top, 26)

                        volumeBlock
                            .padding(.top, 20)

                        if player.isBuffering {
                            ProgressView("正在解析播放地址…")
                                .tint(.white)
                                .padding(.top, 14)
                        }

                        if let error = player.errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red.opacity(0.9))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                                .padding(.top, 12)
                        }

                        Spacer(minLength: 26)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
            .opacity(hero.playerContentOpacity)
        }
    }

    /// In landscape the player has no useful portrait layout, so mirror
    /// kunyin's adaptive player and slide straight into the lyric view.
    private func updateOrientation(_ size: CGSize) {
        let landscape = size.width > size.height
        isLandscape = landscape
        guard landscape else {
            autoPresentedLandscape = false
            return
        }
        guard !autoPresentedLandscape, !hero.lyricsPresented, !hero.isAnimating else { return }
        autoPresentedLandscape = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            openLyrics()
        }
    }

    private func openLyrics() {
        hero.openLyrics()
    }

    // MARK: - Header

    private var topBar: some View {
        HStack {
            Button { closePlayer() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.12), in: Circle())
            }

            Spacer()

            Text("正在播放")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))

            Spacer()

            Menu {
                Button {
                    openLyrics()
                } label: {
                    Label("歌词", systemImage: "quote.bubble")
                }
                Button {
                    showAddToPlaylist = true
                } label: {
                    Label("添加到歌单", systemImage: "text.badge.plus")
                }
                Button {
                    if let track = player.currentTrack { library.toggleLove(track) }
                } label: {
                    Label(isLoved ? "取消收藏" : "收藏", systemImage: isLoved ? "heart.fill" : "heart")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.12), in: Circle())
            }
        }
    }

    // MARK: - Song info

    private var titleBlock: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(player.currentTrack?.name ?? "未播放")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .heroAnchor(.playerTitle)
                    .opacity(hero.hidePlayerHero ? 0 : 1)
                Text(player.currentTrack?.singer ?? "")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .heroAnchor(.playerArtist)
                    .opacity(hero.hidePlayerHero ? 0 : 1)
                if let albumName = albumName {
                    Text(albumName)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button {
                if let track = player.currentTrack { library.toggleLove(track) }
            } label: {
                Image(systemName: isLoved ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundStyle(isLoved ? AppTheme.accent : .white.opacity(0.62))
                    .frame(width: 36, height: 36)
            }
            .disabled(player.currentTrack == nil)
        }
    }

    // MARK: - Transport

    private var transportControls: some View {
        HStack(spacing: 44) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 28, weight: .medium))
            }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 48, weight: .medium))
                    .frame(width: 62, height: 62)
            }
            Button { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 28, weight: .medium))
            }
        }
        .foregroundStyle(.white)
    }

    // MARK: - Utility row

    private var utilityControls: some View {
        HStack(spacing: 54) {
            Button {
                openLyrics()
            } label: {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 20, weight: .medium))
            }
            .accessibilityLabel("歌词")

            Button { showAddToPlaylist = true } label: {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 20, weight: .medium))
            }
            .accessibilityLabel("添加到歌单")
            .disabled(player.currentTrack == nil)

            Button { player.cyclePlayMode() } label: {
                Image(systemName: player.playMode.icon)
                    .font(.system(size: 20, weight: .medium))
                    .overlay(alignment: .topTrailing) {
                        if player.playMode == .repeatOne {
                            Circle()
                                .fill(AppTheme.accent)
                                .frame(width: 5, height: 5)
                                .offset(x: 3, y: -3)
                        }
                    }
            }
            .accessibilityLabel("播放模式：\(player.playMode.title)")
        }
        .foregroundStyle(.white.opacity(0.68))
    }

    // MARK: - Volume

    private var volumeBlock: some View {
        HStack(spacing: 9) {
            Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                .font(.system(size: 11, weight: .medium))
            Slider(
                value: Binding(
                    get: { Double(player.volume) },
                    set: { player.setVolume($0) }
                ),
                in: 0...1
            )
            .tint(.white.opacity(0.55))
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.42))
    }
}

/// Isolates the twice-a-second progress updates from the rest of the player.
/// Keeping them out of `PlayerView` stops open menus from being rebuilt and
/// flickering while a track is playing.
private struct PlayerProgressView: View {
    @ObservedObject var clock: PlaybackClock
    let duration: Double
    let onSeek: (Double) -> Void

    @State private var dragValue: Double = 0
    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 5) {
            Slider(
                value: Binding(
                    get: { isDragging ? dragValue : clock.time },
                    set: { dragValue = $0 }
                ),
                in: 0...max(duration, 1),
                onEditingChanged: { editing in
                    isDragging = editing
                    if !editing { onSeek(dragValue) }
                }
            )
            .tint(.white)

            HStack {
                Text(timeText(isDragging ? dragValue : clock.time))
                Spacer()
                Text("-" + timeText(max(0, duration - (isDragging ? dragValue : clock.time))))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.48))
        }
        .onAppear { dragValue = clock.time }
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
