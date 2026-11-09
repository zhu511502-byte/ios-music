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

/// Character-by-character fill measured in real glyph widths, with a short
/// feathered edge. This is the accurate version: CJK and Latin characters
/// advance by their actual width instead of pretending every character has
/// the same width.
private struct KaraokeLineView: View {
    let line: LyricLine
    @ObservedObject var clock: LyricsClock
    let fontSize: CGFloat

    @State private var charWidths: [CGFloat] = []
    @State private var totalWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let fit = totalWidth > 0 ? min(1, width / totalWidth) : 1
            let fitted = max(fontSize * 0.72, fontSize * fit)
            let displayWidth = totalWidth * (fitted / fontSize)
            let filled = displayWidth * CGFloat(fillProgress)
            let feather = min(14, filled)

            ZStack(alignment: .leading) {
                Text(line.text)
                    .font(.system(size: fitted, weight: .bold))
                    .foregroundStyle(.white.opacity(0.30))
                    .lineLimit(1)

                Text(line.text)
                    .font(.system(size: fitted, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .mask(alignment: .leading) {
                        HStack(spacing: 0) {
                            Rectangle()
                                .fill(Color.white)
                                .frame(width: max(0, filled - feather))
                            LinearGradient(
                                colors: [.white, .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: feather)
                        }
                        .frame(maxHeight: .infinity)
                    }
                    .animation(.linear(duration: 0.08), value: fillProgress)
            }
            .frame(width: width, height: geometry.size.height, alignment: .leading)
        }
        .frame(height: fontSize * 1.2)
        .task(id: "\(line.id)-\(fontSize)") {
            let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
            var widths: [CGFloat] = []
            var prefix = ""
            var previous: CGFloat = 0
            for character in line.text {
                prefix.append(character)
                let current = (prefix as NSString).size(withAttributes: [.font: font]).width
                widths.append(max(0, current - previous))
                previous = current
            }
            charWidths = widths
            totalWidth = previous
        }
    }

    /// Real enhanced timings when aligned; otherwise distribute the line
    /// duration across its characters so HTML-decoded text still wipes.
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
        guard !times.isEmpty, times.count == charWidths.count, totalWidth > 0 else { return 0 }

        var filled: CGFloat = 0
        for index in times.indices {
            let startTime = times[index]
            let endTime: Double
            if index + 1 < times.count {
                endTime = times[index + 1]
            } else {
                endTime = min(line.endTime ?? (startTime + 0.4), startTime + 0.6)
            }
            if clock.time >= endTime {
                filled += charWidths[index]
            } else if clock.time > startTime {
                let span = max(endTime - startTime, 0.06)
                let progress = min(max((clock.time - startTime) / span, 0), 1)
                filled += charWidths[index] * CGFloat(progress)
                break
            } else {
                break
            }
        }
        return Double(min(filled / totalWidth, 1))
    }
}
