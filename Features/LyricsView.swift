import Foundation
import SwiftUI
import UIKit

struct LyricsView: View {
    var isActive: Bool = true
    var onClose: (() -> Void)? = nil

    @EnvironmentObject private var player: PlaybackCoordinator
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss

    @State private var lyrics: Lyrics?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var loadedTrackID: String?
    @State private var isImmersive = false
    @State private var showAddToPlaylist = false
    @StateObject private var interaction = LyricsInteractionState()
    @State private var isLandscape = false

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height

            ZStack {
                background

                if landscape {
                    landscapeLayout(size: geometry.size)
                } else {
                    portraitLayout(size: geometry.size)
                }
            }
            .onAppear { isLandscape = landscape }
            .onChange(of: geometry.size) { size in
                isLandscape = size.width > size.height
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isImmersive)
        .simultaneousGesture(
            TapGesture().onEnded {
                interaction.last = Date()
                if isImmersive {
                    withAnimation(.easeInOut(duration: 0.28)) { isImmersive = false }
                }
            }
        )
        .onChange(of: isActive) { active in
            if !active { isImmersive = false }
            interaction.last = Date()
        }
        .task(id: player.currentTrack?.id) {
            await load()
        }
        .task {
            await autoImmersiveLoop()
        }
        .onChange(of: isImmersive) { value in
            if !value { interaction.last = Date() }
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let track = player.currentTrack {
                PlaylistPickerSheet(track: track)
                    .environmentObject(library)
            }
        }
    }

    // MARK: - Layouts

    private func portraitLayout(size: CGSize) -> some View {
        // Header/footer are overlays, not layout siblings. Hiding them for
        // immersive mode therefore does not resize the lyrics scroll view —
        // that was what made the highlighted line jump.
        ZStack(alignment: .bottom) {
            lyricsContent(isLandscape: false)
                .id("lyrics-content-portrait")

            if !isImmersive {
                VStack(spacing: 0) {
                    portraitHeader
                    Spacer(minLength: 0)
                    portraitFooter
                }
                .transition(.opacity)
            }
        }
    }

    private func landscapeLayout(size: CGSize) -> some View {
        let panelWidth = min(max(300, size.width * 0.4), 470)
        return HStack(spacing: 0) {
            if !isImmersive {
                landscapePanel(size: size)
                    .frame(width: panelWidth)
                    .transition(.opacity)
            } else {
                // Keep the lyrics column the same width in immersive mode so
                // entering/leaving full screen cannot reflow the text.
                Color.clear.frame(width: panelWidth)
            }

            lyricsContent(isLandscape: true)
                .id("lyrics-content-landscape")
        }
    }

    // MARK: - Header / panels

    private var portraitHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Button { closeLyrics() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.12), in: Circle())
            }

            ArtworkView(url: player.currentTrack?.picURL, size: 46, cornerRadius: 9)
                .shadow(color: .black.opacity(0.28), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentTrack?.name ?? "歌词")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(player.currentTrack?.singer ?? "")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            loveButton
            moreMenu
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    private func landscapePanel(size: CGSize) -> some View {
        let panelWidth = min(max(300, size.width * 0.4), 470)
        let artwork = min(panelWidth - 52, size.height * 0.42)

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { closeLyrics() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.12), in: Circle())
                }
                Spacer()
            }

            HStack {
                Spacer()
                ArtworkView(url: player.currentTrack?.picURL, size: artwork, cornerRadius: 10)
                    .shadow(color: .black.opacity(0.4), radius: 22, y: 12)
                Spacer()
            }
            .padding(.top, 4)

            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(player.currentTrack?.name ?? "歌词")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(player.currentTrack?.singer ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                loveButton
                moreMenu
            }
            .padding(.top, 14)

            Spacer(minLength: 10)

            QualityMenuView()

            transportRow
                .padding(.top, 10)

            volumeRow
                .padding(.top, 8)

            bottomControls
                .padding(.top, 8)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var portraitFooter: some View {
        VStack(spacing: 7) {
            QualityMenuView()

            transportRow

            volumeRow

            bottomControls
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 2)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.42), .black.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    private var transportRow: some View {
        HStack(spacing: 56) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 34, weight: .medium))
                    .frame(width: 58, height: 58)
                    .background(.white.opacity(0.09), in: Circle())
            }
            Button { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 44, height: 44)
            }
        }
        .foregroundStyle(.white)
    }

    private var volumeRow: some View {
        HStack(spacing: 8) {
            Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                .font(.system(size: 10))
            Slider(
                value: Binding(
                    get: { Double(player.volume) },
                    set: { player.setVolume($0) }
                ),
                in: 0...1
            )
            .tint(.white.opacity(0.5))
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 10))
        }
        .foregroundStyle(.white.opacity(0.38))
    }

    private var bottomControls: some View {
        HStack {
            Button { player.cyclePlayMode() } label: {
                Image(systemName: player.playMode.icon)
            }
            .accessibilityLabel("播放模式")

            Spacer()

            Button { showAddToPlaylist = true } label: {
                Image(systemName: "text.badge.plus")
            }
            .accessibilityLabel("添加到歌单")

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.25)) { isImmersive = true }
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .accessibilityLabel("全屏显示")

            Spacer()

            Menu {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { isImmersive = true }
                } label: {
                    Label("全屏显示", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                Button {
                    settings.karaokeLyrics.toggle()
                } label: {
                    Label(settings.karaokeLyrics ? "关闭逐字高亮" : "开启逐字高亮",
                          systemImage: settings.karaokeLyrics ? "character.cursor.ibeam" : "textformat")
                }
                Button {
                    Task { await load(force: true) }
                } label: {
                    Label("重新加载歌词", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("更多")
        }
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(.white.opacity(0.62))
        .padding(.horizontal, 18)
    }

    private var loveButton: some View {
        Button {
            if let track = player.currentTrack { library.toggleLove(track) }
        } label: {
            Image(systemName: isLoved ? "heart.fill" : "heart")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isLoved ? AppTheme.accent : .white.opacity(0.75))
                .frame(width: 34, height: 34)
        }
        .disabled(player.currentTrack == nil)
    }

    private var moreMenu: some View {
        Menu {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { isImmersive = true }
            } label: {
                Label("全屏显示", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            Button {
                showAddToPlaylist = true
            } label: {
                Label("添加到歌单", systemImage: "text.badge.plus")
            }
            Button {
                settings.karaokeLyrics.toggle()
            } label: {
                Label(settings.karaokeLyrics ? "关闭逐字高亮" : "开启逐字高亮",
                      systemImage: settings.karaokeLyrics ? "character.cursor.ibeam" : "textformat")
            }
            Button {
                Task { await load(force: true) }
            } label: {
                Label("重新加载歌词", systemImage: "arrow.clockwise")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 34, height: 34)
        }
    }

    private var isLoved: Bool {
        guard let id = player.currentTrack?.id else { return false }
        return library.isLoved(id)
    }

    // MARK: - Immersive

    // MARK: - Lyrics content

    @ViewBuilder
    private func lyricsContent(isLandscape: Bool) -> some View {
        Group {
            if isLoading {
                VStack(spacing: 14) {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.1)
                    Text("正在加载歌词…")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.5))
                }
            } else if let errorMessage = errorMessage {
                VStack(spacing: 14) {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 38, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.32))
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)
                    Button("重试") {
                        Task { await load(force: true) }
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
                .padding(32)
            } else if let lyrics = lyrics, !lyrics.isEmpty {
                if lyrics.isSynced {
                    LyricsViewportView(
                        lyrics: lyrics,
                        clock: player.clock,
                        lyricsClock: player.lyricsClock,
                        activeSize: isLandscape ? 31 : 30,
                        inactiveSize: isLandscape ? 24 : 23,
                        karaoke: settings.karaokeLyrics || lyrics.isWordTimed,
                        isImmersive: isImmersive,
                        horizontalPadding: isLandscape ? (isImmersive ? 70 : 38) : 24,
                        onSeek: { time in player.seek(to: time) },
                        onExitImmersive: {
                            withAnimation(.easeInOut(duration: 0.25)) { isImmersive = false }
                        },
                        onInteraction: { interaction.last = Date() },
                        isPageActive: isActive
                    )
                } else {
                    PlainLyricsView(lyrics: lyrics, horizontalPadding: isLandscape ? 48 : 26)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 36, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.3))
                    Text("暂无歌词")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                    Button("重新加载") {
                        Task { await load(force: true) }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .tint(.white.opacity(0.7))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            Color.black

            if let custom = settings.backgroundImage {
                GeometryReader { geometry in
                    Image(uiImage: custom)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .blur(radius: max(settings.backgroundBlur, 0.5))
                        .scaleEffect(1.08)
                        .opacity(settings.backgroundOpacity)
                }
                .ignoresSafeArea()
            } else if let url = player.currentTrack?.picURL {
                GeometryReader { geometry in
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable()
                                .scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .clipped()
                                .blur(radius: 65)
                                .scaleEffect(1.12)
                                .opacity(0.55)
                        }
                    }
                }
                .ignoresSafeArea()
            }

            FlowingGlowView(intensity: 0.5)

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.12), location: 0),
                    .init(color: .black.opacity(0.35), location: 0.45),
                    .init(color: .black.opacity(0.78), location: 0.8),
                    .init(color: .black.opacity(0.92), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
    }

    private func closeLyrics() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    // MARK: - Auto immersive

    private func autoImmersiveLoop() async {
        interaction.last = Date()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            guard isActive, !isImmersive, !isLandscape, player.isPlaying else { continue }
            if Date().timeIntervalSince(interaction.last) >= 10 {
                withAnimation(.easeInOut(duration: 0.35)) { isImmersive = true }
            }
        }
    }

    // MARK: - Load

    private func load(force: Bool = false) async {
        guard let track = player.currentTrack else {
            lyrics = nil
            isLoading = false
            return
        }
        if !force, loadedTrackID == track.id, lyrics != nil { return }

        loadedTrackID = track.id
        lyrics = nil
        errorMessage = nil
        isLoading = true

        do {
            let value = try await LyricsService.shared.lyrics(for: track)
            guard !Task.isCancelled else { return }
            lyrics = value
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            lyrics = nil
            if let lyricsError = error as? LyricsError {
                switch lyricsError {
                case .notFound:
                    errorMessage = nil
                default:
                    errorMessage = lyricsError.localizedDescription
                }
            } else {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

// MARK: - Plain lyrics

private struct PlainLyricsView: View {
    let lyrics: Lyrics
    let horizontalPadding: CGFloat

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(lyrics.lines) { line in
                    Text(line.text)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(0.76))
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 74)
            .padding(.bottom, 190)
        }
    }
}


/// Reference box for the last touch time. Deliberately has no `@Published`
/// storage: updating it from a 60 Hz drag must not rebuild the lyric screen.
private final class LyricsInteractionState: ObservableObject {
    var last = Date()
}
