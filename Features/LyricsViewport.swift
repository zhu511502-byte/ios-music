import SwiftUI
import UIKit

/// The lyric scroller used before the kunyin experiment: a plain
/// `ScrollView` with a spring-driven `scrollTo` and a small scale/opacity
/// emphasis on the active row. Keeping the native scroll view makes it much
/// smoother than the hand-positioned renderer, while the spring restores the
/// old "line glides into the middle" feel.
struct LyricsViewportView: View {
    let lyrics: Lyrics
    let clock: PlaybackClock
    let lyricsClock: LyricsClock
    let activeSize: CGFloat
    let inactiveSize: CGFloat
    let karaoke: Bool
    let isImmersive: Bool
    let horizontalPadding: CGFloat
    let onSeek: (Double) -> Void
    let onExitImmersive: () -> Void
    let onInteraction: () -> Void
    var isPageActive: Bool = true

    @State private var activeIndex: Int?

    private func index(at time: Double) -> Int? {
        lyrics.lines.lastIndex { ($0.time ?? -1) <= time + 0.05 }
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
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { _ in onInteraction() }
                )
                .onAppear {
                    let initial = index(at: clock.time)
                    activeIndex = initial
                    guard let initial else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        proxy.scrollTo(initial, anchor: UnitPoint(x: 0.5, y: 0.42))
                    }
                }
                .onReceive(clock.$time) { time in
                    guard isPageActive else { return }
                    updateActiveIndex(time, proxy: proxy)
                }
                .onChange(of: isPageActive) { active in
                    guard active else { return }
                    let current = index(at: clock.time)
                    activeIndex = current
                    guard let current else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        proxy.scrollTo(current, anchor: UnitPoint(x: 0.5, y: 0.42))
                    }
                }
                .onChange(of: isImmersive) { _ in
                    guard let index = activeIndex ?? index(at: clock.time) else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: 0.42))
                        }
                    }
                }
            }
        }
    }

    private func updateActiveIndex(_ time: Double, proxy: ScrollViewProxy) {
        let next = index(at: time)
        guard next != activeIndex else { return }
        activeIndex = next
        guard let next else { return }
        withAnimation(.spring(response: 0.65, dampingFraction: 0.9)) {
            proxy.scrollTo(next, anchor: UnitPoint(x: 0.5, y: 0.42))
        }
    }

    @ViewBuilder
    private func lyricLine(_ line: LyricLine, isActive: Bool) -> some View {
        if isActive, karaoke, line.time != nil {
            KaraokeLineView(line: line, clock: lyricsClock, fontSize: activeSize)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
                .onTapGesture {
                    onInteraction()
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
                    onInteraction()
                    if isImmersive {
                        onExitImmersive()
                    } else if let time = line.time {
                        onSeek(time)
                    }
                }
        }
    }
}

// MARK: - Karaoke line

private struct KaraokeLineView: View {
    let line: LyricLine
    @ObservedObject var clock: LyricsClock
    let fontSize: CGFloat

    /// Real enhanced timings when they line up with the rendered text;
    /// otherwise distribute the line duration across its characters so a
    /// missing/HTML-decoded timing still produces a per-character wipe.
    private var effectiveTimes: [Double] {
        if line.wordTimes.count == line.text.count { return line.wordTimes }
        guard let start = line.time else { return [] }
        let characters = Array(line.text)
        guard !characters.isEmpty else { return [] }
        let end = line.endTime ?? (start + min(max(Double(characters.count) * 0.32, 2.0), 4.0))
        let duration = max(end - start, 0.4)
        return characters.indices.map { index in
            start + duration * Double(index) / Double(characters.count)
        }
    }

    private var fillProgress: Double {
        guard let start = line.time, clock.time >= start else { return 0 }
        let times = effectiveTimes
        guard !times.isEmpty else { return 1 }

        var filled = 0.0
        for index in times.indices {
            let startTime = times[index]
            let endTime = index + 1 < times.count
                ? times[index + 1]
                : (line.endTime ?? startTime + 0.35)
            if clock.time >= endTime {
                filled += 1
            } else if clock.time > startTime {
                let span = max(endTime - startTime, 0.06)
                filled += min(max((clock.time - startTime) / span, 0), 1)
                break
            } else {
                break
            }
        }
        return min(filled / Double(max(line.text.count, 1)), 1)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Text(line.text)
                .foregroundStyle(.white.opacity(0.30))

            Text(line.text)
                .foregroundStyle(.white)
                .mask(alignment: .leading) {
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(.white)
                            .frame(width: max(0, geometry.size.width * fillProgress))
                            .animation(.linear(duration: 0.12), value: fillProgress)
                    }
                }
        }
        .font(.system(size: fontSize, weight: .bold))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(line.text)
    }
}
