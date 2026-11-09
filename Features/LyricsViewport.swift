import SwiftUI
import UIKit
import Foundation

/// Kunyin-style lyric viewport.
///
/// Instead of putting every line in a `ScrollView` and animating one shared
/// scroll offset, each line is absolutely positioned and receives its own
/// transition (duration + delay). When the active line changes the rows move
/// with a soft stagger, while scale / blur / opacity follow the distance from
/// the active row. That is what removes the rigid "whole page jumps" feeling
/// of the old implementation.
struct LyricsViewportView: View {
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
    @State private var heights: [CGFloat] = []
    @State private var tops: [CGFloat] = []
    @State private var contentHeight: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var isDragging = false
    @State private var dragBase: CGFloat = 0
    @State private var scrollDirection = 0
    @State private var resumeFollowAt = Date.distantPast
    @State private var resumeToken = UUID()

    private let anchorFraction: CGFloat = 0.44

    private var currentIndex: Int? {
        lyrics.lines.lastIndex { ($0.time ?? -1) <= clock.time + 0.05 }
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                Color.clear

                ForEach(visibleIndices, id: \.self) { index in
                    lineView(lyrics.lines[index], index: index)
                        .frame(width: max(1, size.width - horizontalPadding * 2),
                               height: height(at: index),
                               alignment: .leading)
                        .offset(x: horizontalPadding, y: top(at: index) + offset)
                        .animation(isDragging ? nil : scrollAnimation(for: index), value: offset)
                        .animation(.easeInOut(duration: 0.42), value: activeIndex)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
            .mask(edgeMask)
            .contentShape(Rectangle())
            .simultaneousGesture(dragGesture)
            .onAppear {
                rebuild(width: size.width, height: size.height, animated: false)
            }
            .onChange(of: geometry.size) { newSize in
                rebuild(width: newSize.width, height: newSize.height, animated: false)
            }
            .onChange(of: lyrics) { _ in
                activeIndex = currentIndex ?? 0
                scrollDirection = 0
                rebuild(width: geometry.size.width, height: geometry.size.height, animated: false)
            }
            .onChange(of: currentIndex) { newValue in
                guard let newValue else { return }
                let previous = activeIndex
                activeIndex = newValue
                if let previous, previous != newValue {
                    scrollDirection = newValue > previous ? 1 : -1
                }
                guard !isDragging, Date() >= resumeFollowAt else { return }
                recenter(animated: true)
            }
            .onChange(of: isImmersive) { _ in
                // Header/footer are overlays, so the viewport itself never
                // changes size. This only corrects a pending layout change.
                recenter(animated: true)
            }
        }
    }

    // MARK: - Lines

    @ViewBuilder
    private func lineView(_ line: LyricLine, index: Int) -> some View {
        let distance = index - (activeIndex ?? index)
        let gaussian = exp(-Double(distance * distance) / 18.0)
        let isActive = index == activeIndex
        let isPlayed = (activeIndex ?? 0) > index
        let scale: CGFloat = isActive ? 1 : 0.94 + 0.05 * CGFloat(gaussian)
        let blur: CGFloat = isActive ? 0 : 0.9 * CGFloat(1 - gaussian)
        let opacity = isActive ? 1.0 : (isPlayed ? 0.44 : 0.56) * (0.86 + 0.14 * gaussian)

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
                } else {
                    Text(line.text)
                        .font(.system(size: isActive ? activeSize : inactiveSize, weight: .bold))
                        .foregroundStyle(.white)
                        .lineSpacing(5)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .opacity(opacity)
            .scaleEffect(scale, anchor: .leading)
            .blur(radius: blur)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(LyricPressButtonStyle())
        .disabled(line.time == nil && !isImmersive)
    }

    /// Only the rows around the viewport are materialised. A full lyric file
    /// can hold 100+ lines and every row carries a blur/scale layer, so
    /// rendering all of them would make the 4 Hz clock update expensive.
    private var visibleIndices: [Int] {
        guard tops.count == lyrics.lines.count, heights.count == lyrics.lines.count else {
            return Array(lyrics.lines.indices)
        }
        let topEdge = -offset - 600
        let bottomEdge = -offset + viewportHeight + 600
        var result: [Int] = []
        for index in lyrics.lines.indices {
            let lineTop = tops[index]
            let lineBottom = lineTop + heights[index]
            if lineBottom >= topEdge && lineTop <= bottomEdge {
                result.append(index)
            }
        }
        return result
    }

    private func height(at index: Int) -> CGFloat {
        heights.indices.contains(index) ? heights[index] : activeSize * 1.4 + 26
    }

    private func top(at index: Int) -> CGFloat {
        tops.indices.contains(index) ? tops[index] : 0
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

    // MARK: - Motion

    private func scrollAnimation(for index: Int) -> Animation? {
        let base = Animation.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.58)
        guard let activeIndex, scrollDirection != 0 else { return base }
        let range = 4
        let clamped = max(-range, min(range, index - activeIndex))
        let delay = Double(range + scrollDirection * clamped) * 0.045
        return base.delay(max(0, delay))
    }

    private func recenter(animated: Bool) {
        guard let index = activeIndex,
              tops.indices.contains(index),
              heights.indices.contains(index),
              viewportHeight > 0 else { return }
        let target = viewportHeight * anchorFraction - (tops[index] + heights[index] / 2)
        setOffset(target, animated: animated)
    }

    private func setOffset(_ target: CGFloat, animated: Bool) {
        if animated {
            withAnimation(.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.5)) {
                offset = target
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                offset = target
            }
        }
    }

    // MARK: - Layout

    private func rebuild(width: CGFloat, height: CGFloat, animated: Bool) {
        guard width > 1, height > 1, !lyrics.lines.isEmpty else { return }
        let textWidth = max(1, width - horizontalPadding * 2)
        var newHeights: [CGFloat] = []
        newHeights.reserveCapacity(lyrics.lines.count)
        for line in lyrics.lines {
            newHeights.append(Self.lineHeight(for: line, width: textWidth, fontSize: activeSize))
        }
        var newTops: [CGFloat] = []
        newTops.reserveCapacity(newHeights.count)
        var running: CGFloat = 0
        for value in newHeights {
            newTops.append(running)
            running += value
        }

        heights = newHeights
        tops = newTops
        contentHeight = running
        viewportWidth = width
        viewportHeight = height
        if activeIndex == nil {
            activeIndex = currentIndex ?? 0
        }
        guard let index = activeIndex, newTops.indices.contains(index) else { return }
        let target = height * anchorFraction - (newTops[index] + newHeights[index] / 2)
        setOffset(target, animated: animated)
    }

    private static func lineHeight(for line: LyricLine, width: CGFloat, fontSize: CGFloat) -> CGFloat {
        let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph
        ]
        let rect = (line.text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        return max(fontSize * 1.3, ceil(rect.height)) + 26
    }

    // MARK: - Manual scroll

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    dragBase = offset
                }
                offset = clamp(dragBase + value.translation.height)
                resumeFollowAt = Date().addingTimeInterval(3.5)
            }
            .onEnded { _ in
                isDragging = false
                resumeFollowAt = Date().addingTimeInterval(3.5)
                let token = UUID()
                resumeToken = token
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    guard !Task.isCancelled, resumeToken == token, !isDragging else { return }
                    recenter(animated: true)
                }
            }
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        let lower = min(0, viewportHeight - contentHeight - viewportHeight * 0.35)
        let upper = max(0, viewportHeight * 0.65)
        return min(upper, max(lower, value))
    }
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

/// Character-by-character fill measured in real glyph widths. The old version
/// divided the line width by `text.count`, which drifted badly on lines that
/// mix CJK and Latin characters. The mask also carries a short feathered edge
/// so the wipe reads as light rather than a hard rectangle.
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
                        GeometryReader { proxy in
                            let total = proxy.size.width
                            let filled = total * CGFloat(fill)
                            let feather = min(14, filled)
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
                            .frame(width: filled, alignment: .leading)
                        }
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
