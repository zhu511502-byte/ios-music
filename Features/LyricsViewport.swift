import SwiftUI
import UIKit
import Foundation

/// Native-scrolling lyric viewport.
///
/// The previous version positioned every row by hand and animated each row on
/// the main thread. That looked good in a demo but made an old iPhone drop
/// frames as soon as the finger touched the screen. This version lets
/// `ScrollView` do the scrolling (UIKit-backed, 120 Hz ProMotion aware) and
/// only asks SwiftUI to move when the active line actually changes. Karaoke
/// fill is still driven by the isolated 10 Hz clock, so a playing song does
/// not re-render the whole lyric page.
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

    @State private var activeIndex: Int?
    @StateObject private var scrollState = LyricScrollState()

    private let anchor = UnitPoint(x: 0.5, y: 0.44)

    private func index(at time: Double) -> Int? {
        lyrics.lines.lastIndex { ($0.time ?? -1) <= time + 0.05 }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear
                            .frame(height: max(80, geometry.size.height * 0.42))

                        ForEach(lyrics.lines) { line in
                            lyricLine(line, isActive: line.id == activeIndex)
                                .id(line.id)
                        }

                        Color.clear
                            .frame(height: max(140, geometry.size.height * 0.55))
                    }
                    .padding(.horizontal, horizontalPadding)
                }
                .mask(edgeMask)
                .contentShape(Rectangle())
                .onTapGesture {
                    if isImmersive { onExitImmersive() }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { _ in
                            scrollState.lastInteraction = Date()
                            if !scrollState.isUserScrolling { scrollState.isUserScrolling = true }
                        }
                        .onEnded { _ in
                            scrollState.lastInteraction = Date()
                            scrollState.isUserScrolling = false
                            scheduleResume(proxy: proxy)
                        }
                )
                .onAppear {
                    let initial = index(at: clock.time) ?? 0
                    activeIndex = initial
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        proxy.scrollTo(initial, anchor: anchor)
                    }
                }
                .onReceive(clock.$time) { time in
                    updateActiveIndex(time, proxy: proxy)
                }
                .onChange(of: geometry.size) { _ in
                    guard let index = activeIndex else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        proxy.scrollTo(index, anchor: anchor)
                    }
                }
                .onChange(of: lyrics) { _ in
                    let initial = index(at: clock.time) ?? 0
                    activeIndex = initial
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        proxy.scrollTo(initial, anchor: anchor)
                    }
                }
            }
        }
    }

    // MARK: - Lines

    @ViewBuilder
    private func lyricLine(_ line: LyricLine, isActive: Bool) -> some View {
        Button {
            if isImmersive {
                onExitImmersive()
            } else if let time = line.time {
                onSeek(time)
            }
        } label: {
            Group {
                if isActive, karaoke, line.hasWordTiming {
                    KaraokeLyricLine(line: line, clock: lyricsClock, fontSize: activeSize)
                        .frame(height: activeSize * 1.2)
                } else {
                    Text(line.text)
                        .font(.system(size: isActive ? activeSize : inactiveSize, weight: .bold))
                        .foregroundStyle(.white)
                        .lineSpacing(5)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .opacity(isActive ? 1 : 0.46)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(LyricPressButtonStyle())
        .frame(minHeight: activeSize * 1.2 + 26, alignment: .leading)
        .animation(.easeInOut(duration: 0.22), value: isActive)
        .disabled(line.time == nil && !isImmersive)
    }

    private var edgeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .white, location: 0.09),
                .init(color: .white, location: 0.86),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Follow

    private func updateActiveIndex(_ time: Double, proxy: ScrollViewProxy) {
        guard let next = index(at: time) else { return }
        let previous = activeIndex
        guard previous != next else { return }
        activeIndex = next

        guard !scrollState.isUserScrolling, Date() >= scrollState.resumeAt else { return }
        withAnimation(.easeInOut(duration: 0.45)) {
            proxy.scrollTo(next, anchor: anchor)
        }
    }

    private func scheduleResume(proxy: ScrollViewProxy) {
        let token = UUID()
        scrollState.token = token
        scrollState.resumeAt = Date().addingTimeInterval(3.0)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, scrollState.token == token, !scrollState.isUserScrolling else { return }
            guard let index = activeIndex else { return }
            withAnimation(.easeInOut(duration: 0.45)) {
                proxy.scrollTo(index, anchor: anchor)
            }
        }
    }
}

/// Touch/resume bookkeeping. No `@Published` properties: a 60 Hz drag must
/// never invalidate the lyric view.
private final class LyricScrollState: ObservableObject {
    var lastInteraction = Date.distantPast
    var resumeAt = Date.distantPast
    var token = UUID()
    var isUserScrolling = false
}

// MARK: - Press feedback

private struct LyricPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.13 : 0))
                    .padding(.horizontal, -12)
                    .padding(.vertical, -4)
            )
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

// MARK: - Karaoke line

/// Character-by-character fill measured in real glyph widths, with a short
/// feathered edge. Only the one active row runs this view at 10 Hz.
private struct KaraokeLyricLine: View {
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
            let fill = fillFraction
            let displayWidth = totalWidth * (fitted / fontSize)
            let filled = displayWidth * CGFloat(fill)
            let feather = min(14, filled)

            ZStack(alignment: .leading) {
                Text(line.text)
                    .font(.system(size: fitted, weight: .bold))
                    .foregroundStyle(.white.opacity(0.32))
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
                    .animation(.linear(duration: 0.08), value: fill)
            }
            .frame(width: width, height: geometry.size.height, alignment: .leading)
        }
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

    private var fillFraction: Double {
        guard let start = line.time, clock.time >= start else { return 0 }
        let times = line.wordTimes
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
