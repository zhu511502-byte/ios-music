import Foundation
import SwiftUI

struct LyricsView: View {
    @EnvironmentObject private var player: PlaybackCoordinator
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var lyrics: Lyrics?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var loadedTrackID: String?
    @State private var isImmersive = false
    @State private var showAddToPlaylist = false

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

                if isImmersive {
                    immersiveExitButton
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isImmersive)
        .task(id: player.currentTrack?.id) {
            await load()
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
        VStack(spacing: 0) {
            if !isImmersive {
                portraitHeader
                    .transition(.opacity)
            }

            lyricsContent(isLandscape: false)

            if !isImmersive {
                portraitFooter
                    .transition(.opacity)
            }
        }
    }

    private func landscapeLayout(size: CGSize) -> some View {
        HStack(spacing: 0) {
            if !isImmersive {
                landscapePanel(size: size)
                    .frame(width: min(max(300, size.width * 0.4), 470))
                    .transition(.opacity)
            }

            lyricsContent(isLandscape: true)
        }
    }

    // MARK: - Header / panels

    private var portraitHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Button { dismiss() } label: {
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
                Button { dismiss() } label: {
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

            LyricsProgressRow(clock: player.clock, duration: player.duration) { value in
                player.seek(to: value)
            }

            QualityMenuView()
                .padding(.top, -1)

            transportRow
                .padding(.top, 8)

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
            LyricsProgressRow(clock: player.clock, duration: player.duration) { value in
                player.seek(to: value)
            }

            QualityMenuView()
                .padding(.top, -1)

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

    private var immersiveExitButton: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { isImmersive = false }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.down")
                        Text("退出全屏")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.8)
                    )
                }
            }
            Spacer()
        }
        .padding(.top, 8)
        .padding(.trailing, 18)
    }

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
                    SyncedLyricsView(
                        lyrics: lyrics,
                        clock: player.clock,
                        lyricsClock: player.lyricsClock,
                        activeSize: isLandscape ? 27 : 26,
                        inactiveSize: isLandscape ? 23 : 22,
                        karaoke: settings.karaokeLyrics || lyrics.isWordTimed,
                        isImmersive: isImmersive,
                        horizontalPadding: isLandscape ? (isImmersive ? 70 : 38) : 24,
                        onSeek: { time in player.seek(to: time) },
                        onExitImmersive: {
                            withAnimation(.easeInOut(duration: 0.25)) { isImmersive = false }
                        }
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

            if let url = player.currentTrack?.picURL {
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

// MARK: - Synced lyrics

private struct SyncedLyricsView: View {
    let lyrics: Lyrics
    @ObservedObject var clock: PlaybackClock
    let lyricsClock: LyricsClock
    let activeSize: CGFloat
    let inactiveSize: CGFloat
    let karaoke: Bool
    let isImmersive: Bool
    let horizontalPadding: CGFloat
    let onSeek: (Double) -> Void
    let onExitImmersive: () -> Void

    @State private var activeIndex: Int?

    private var currentIndex: Int? {
        lyrics.lines.lastIndex { ($0.time ?? -1) <= clock.time + 0.05 }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear
                            .frame(height: max(80, geometry.size.height * 0.45))

                        ForEach(lyrics.lines) { line in
                            lyricLine(line, isActive: line.id == activeIndex)
                                .id(line.id)
                        }

                        Color.clear
                            .frame(height: max(140, geometry.size.height * 0.55))
                    }
                    .padding(.horizontal, horizontalPadding)
                }
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white, location: 0.08),
                            .init(color: .white, location: 0.86),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    if isImmersive { onExitImmersive() }
                }
                .onAppear {
                    let index = currentIndex
                    activeIndex = index
                    guard let index else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: 0.42))
                    }
                }
                .onChange(of: currentIndex) { index in
                    guard index != activeIndex else { return }
                    activeIndex = index
                    guard let index else { return }
                    withAnimation(.spring(response: 0.65, dampingFraction: 0.9)) {
                        proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: 0.42))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func lyricLine(_ line: LyricLine, isActive: Bool) -> some View {
        if isActive, karaoke, line.hasWordTiming {
            KaraokeLineView(line: line, clock: lyricsClock, fontSize: activeSize)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
                .onTapGesture {
                    if isImmersive {
                        onExitImmersive()
                    } else if let time = line.time {
                        onSeek(time)
                    }
                }
        } else {
            Text(line.text)
                .font(.system(size: isActive ? activeSize : inactiveSize, weight: .bold))
                .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.34))
                .lineSpacing(5)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 13)
                .scaleEffect(isActive ? 1 : 0.97, anchor: .leading)
                .opacity(isActive ? 1 : 0.92)
                .animation(.easeInOut(duration: 0.22), value: isActive)
                .contentShape(Rectangle())
                .onTapGesture {
                    if isImmersive {
                        onExitImmersive()
                    } else if let time = line.time {
                        onSeek(time)
                    }
                }
        }
    }
}

// MARK: - Karaoke (character-by-character) line

private struct KaraokeLineView: View {
    let line: LyricLine
    @ObservedObject var clock: LyricsClock
    let fontSize: CGFloat

    private var sungCount: Int {
        guard let start = line.time, clock.time >= start - 0.05 else { return 0 }
        var count = 0
        for offset in line.wordTimes where clock.time + 0.03 >= offset {
            count += 1
        }
        return min(count, line.text.count)
    }

    var body: some View {
        Text(styledText)
            .font(.system(size: fontSize, weight: .bold))
            .lineSpacing(5)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.1), value: sungCount)
    }

    private var styledText: AttributedString {
        let characters = Array(line.text)
        var result = AttributedString()
        for (index, character) in characters.enumerated() {
            var piece = AttributedString(String(character))
            if index < sungCount {
                piece.foregroundColor = .white
            } else if index == sungCount {
                piece.foregroundColor = Color.white.opacity(0.72)
            } else {
                piece.foregroundColor = Color.white.opacity(0.32)
            }
            result.append(piece)
        }
        return result
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
            .padding(.top, 30)
            .padding(.bottom, 40)
        }
    }
}

// MARK: - Progress + quality row

private struct LyricsProgressRow: View {
    @ObservedObject var clock: PlaybackClock
    let duration: Double
    let onSeek: (Double) -> Void

    @State private var dragValue: Double = 0
    @State private var isDragging = false

    private var displayedTime: Double {
        min(max(isDragging ? dragValue : clock.time, 0), max(duration, 0))
    }

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(displayedTime / duration, 0), 1)
    }

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.2))
                        .frame(height: 3)
                    Capsule()
                        .fill(.white.opacity(0.88))
                        .frame(width: max(0, CGFloat(progress) * geometry.size.width), height: 3)
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0 else { return }
                            isDragging = true
                            let fraction = min(max(value.location.x / max(geometry.size.width, 1), 0), 1)
                            dragValue = Double(fraction) * duration
                        }
                        .onEnded { _ in
                            isDragging = false
                            onSeek(dragValue)
                        }
                )
            }
            .frame(height: 13)

            HStack {
                Text(timeText(displayedTime))
                Spacer()
                Text("-" + timeText(max(0, duration - displayedTime)))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.48))
        }
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
