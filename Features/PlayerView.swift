import SwiftUI
import UIKit

struct PlayerView: View {
    @EnvironmentObject private var player: PlaybackCoordinator
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var showLyrics = false
    @State private var showAddToPlaylist = false

    private var artworkSize: CGFloat {
        min(360, max(220, UIScreen.main.bounds.width - 48))
    }

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
            background
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 24)
                    .padding(.top, 6)
                    .padding(.bottom, 2)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        ArtworkView(url: player.currentTrack?.picURL, size: artworkSize, cornerRadius: 12)
                            .shadow(color: .black.opacity(0.5), radius: 28, y: 20)
                            .padding(.top, 22)

                        titleBlock
                            .padding(.top, 24)

                        PlayerProgressView(clock: player.clock, duration: player.duration) { value in
                            player.seek(to: value)
                        }
                        .padding(.top, 18)

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
        }
        .fullScreenCover(isPresented: $showLyrics) {
            LyricsView()
                .environmentObject(player)
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let track = player.currentTrack {
                PlaylistPickerSheet(track: track)
                    .environmentObject(library)
            }
        }
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            Color.black
            if let url = player.currentTrack?.picURL {
                GeometryReader { geometry in
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable()
                                .scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .clipped()
                                .blur(radius: 65)
                                .opacity(0.45)
                        }
                    }
                }
                .ignoresSafeArea()
            }
            LinearGradient(
                colors: [.black.opacity(0.12), .black.opacity(0.42), .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
    }

    // MARK: - Header

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
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
                    showLyrics = true
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
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(player.currentTrack?.singer ?? "")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
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
            Button { showLyrics = true } label: {
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
