import Foundation
import SwiftUI

struct LyricsView: View {
    @EnvironmentObject private var player: PlaybackCoordinator
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var lyrics: Lyrics?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var loadedTrackID: String?
    @State private var isImmersive = false

    var body: some View {
        ZStack(alignment: .bottom) {
            background

            VStack(spacing: 0) {
                if !isImmersive {
                    header
                        .transition(.opacity)
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if !isImmersive {
                footer
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isImmersive)
        .task(id: player.currentTrack?.id) {
            await load()
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
                                .blur(radius: 70)
                                .scaleEffect(1.12)
                                .opacity(0.42)
                        }
                    }
                }
                .ignoresSafeArea()
            }

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.32), location: 0),
                    .init(color: .black.opacity(0.5), location: 0.42),
                    .init(color: .black.opacity(0.88), location: 0.78),
                    .init(color: .black, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.12), in: Circle())
            }

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

            Spacer(minLength: 8)

            Button {
                withAnimation(.easeInOut(duration: 0.25)) { isImmersive = true }
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .accessibilityLabel("全屏显示")

            ArtworkView(url: player.currentTrack?.picURL, size: 46, cornerRadius: 10)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 14) {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.1)
                Text("正在加载歌词…")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
        } else if let lyrics = lyrics, !lyrics.isEmpty {
            if lyrics.isSynced {
                SyncedLyricsView(
                    lyrics: lyrics,
                    clock: player.clock,
                    // Word-timed sources (NetEase yrc) always render karaoke;
                    // the toggle only controls synthesized per-char timing.
                    karaoke: settings.karaokeLyrics || lyrics.isWordTimed,
                    isImmersive: isImmersive,
                    exitImmersive: {
                        withAnimation(.easeInOut(duration: 0.25)) { isImmersive = false }
                    }
                ) { time in
                    player.seek(to: time)
                }
            } else {
                PlainLyricsView(lyrics: lyrics)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 12) {
            LyricsProgressBar(clock: player.clock, duration: player.duration) { value in
                player.seek(to: value)
            }

            HStack(spacing: 58) {
                Button { player.previous() } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 21, weight: .medium))
                        .frame(width: 44, height: 44)
                }
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 31, weight: .medium))
                        .frame(width: 56, height: 56)
                        .background(.white.opacity(0.1), in: Circle())
                }
                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 21, weight: .medium))
                        .frame(width: 44, height: 44)
                }
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 30)
        .padding(.top, 42)
        .padding(.bottom, 6)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.62), .black.opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
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
    let karaoke: Bool
    let isImmersive: Bool
    let exitImmersive: () -> Void
    let onSeek: (Double) -> Void

    @State private var activeIndex: Int?

    private var currentIndex: Int? {
        lyrics.lines.lastIndex { ($0.time ?? -1) <= clock.time + 0.05 }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Spacer sized so the active line lands at the visual
                        // golden-ratio point instead of hugging the bottom.
                        Color.clear
                            .frame(height: max(72, geometry.size.height * 0.3))

                        ForEach(lyrics.lines) { line in
                            lyricLine(line, isActive: line.id == activeIndex)
                                .id(line.id)
                        }

                        Color.clear
                            .frame(height: max(120, geometry.size.height * (isImmersive ? 0.62 : 0.38)))
                    }
                    .padding(.horizontal, 26)
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
                .onTapGesture {
                    // In immersive mode a single tap brings the controls back.
                    if isImmersive { exitImmersive() }
                }
                .onAppear {
                    let index = currentIndex
                    activeIndex = index
                    guard let index else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
                .onChange(of: currentIndex) { index in
                    guard index != activeIndex else { return }
                    activeIndex = index
                    guard let index else { return }
                    withAnimation(.spring(response: 0.55, dampingFraction: 0.88)) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func lyricLine(_ line: LyricLine, isActive: Bool) -> some View {
        if isActive, karaoke, line.hasWordTiming {
            KaraokeLineView(line: line, clock: clock)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
                .onTapGesture {
                    if let time = line.time { onSeek(time) }
                }
        } else {
            Text(line.text)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.34))
                .lineSpacing(5)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .scaleEffect(isActive ? 1 : 0.9, anchor: .leading)
                .opacity(isActive ? 1 : 0.9)
                .animation(.easeInOut(duration: 0.25), value: isActive)
                .contentShape(Rectangle())
                .onTapGesture {
                    if let time = line.time { onSeek(time) }
                }
        }
    }
}

// MARK: - Karaoke (character-by-character) line

private struct KaraokeLineView: View {
    let line: LyricLine
    @ObservedObject var clock: PlaybackClock

    /// Index of the character currently being sung; -1 before the line starts.
    private var sungCount: Int {
        guard let start = line.time, clock.time >= start - 0.05 else { return -1 }
        let times = line.wordTimes
        guard !times.isEmpty else { return -1 }
        var count = 0
        for (index, offset) in times.enumerated() where clock.time + 0.05 >= offset {
            count = index + 1
        }
        return count
    }

    var body: some View {
        flowingText
            .font(.system(size: 26, weight: .bold))
            .lineSpacing(5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.linear(duration: 0.18), value: sungCount)
    }

    /// Two overlaid copies of the text; the top one is clipped to the sung
    /// characters so the highlight follows the singing position exactly.
    private var flowingText: some View {
        let count = sungCount
        return ZStack(alignment: .leading) {
            Text(line.text)
                .foregroundStyle(.white.opacity(0.3))

            Text(line.text)
                .foregroundStyle(.white)
                .mask(alignmentMask(count: count))
        }
    }

    private func alignmentMask(count: Int) -> some View {
        GeometryReader { geometry in
            if count >= line.text.count {
                Rectangle().fill(.white)
            } else if count >= 0 {
                // Hidden copy of the sung prefix measures its real width via
                // SwiftUI's own layout (background alignment trick), so the
                // highlight boundary lands exactly between characters.
                Color.clear
                    .background(
                        Text(String(line.text.prefix(count)))
                            .font(.system(size: 26, weight: .bold))
                            .lineSpacing(5)
                            .fixedSize(horizontal: true, vertical: false)
                            .hidden()
                    )
                    .overlay(
                        GeometryReader { prefixGeometry in
                            Rectangle()
                                .fill(.white)
                                .frame(width: max(0, prefixGeometry.size.width))
                        }
                        .allowsHitTesting(false)
                    )
            } else {
                Color.clear
            }
        }
    }
}

// MARK: - Plain lyrics

private struct PlainLyricsView: View {
    let lyrics: Lyrics

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
            .padding(.horizontal, 28)
            .padding(.top, 30)
            .padding(.bottom, 170)
        }
    }
}

// MARK: - Footer progress

private struct LyricsProgressBar: View {
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
        VStack(spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.18))
                        .frame(height: 3)
                    Capsule()
                        .fill(.white.opacity(0.9))
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
            .frame(height: 14)

            HStack {
                Text(timeText(displayedTime))
                Spacer()
                Text("-" + timeText(max(0, duration - displayedTime)))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.45))
        }
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
