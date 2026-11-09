import SwiftUI
import UIKit

/// The lyric scroller used before the kunyin experiment: a plain
/// `ScrollView` with a spring-driven `scrollTo` and a small scale/opacity
/// emphasis on the active row. Keeping the native scroll view makes it much
/// smoother than the hand-positioned renderer, while the spring restores the
/// old "line glides into the middle" feel.
struct LyricsViewportView: View {
    @EnvironmentObject private var settings: SettingsStore

    let lyrics: Lyrics
    let clock: PlaybackClock
    let lyricsClock: LyricsClock
    let activeSize: CGFloat
    let inactiveSize: CGFloat
    let karaoke: Bool
    let isPlaying: Bool
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
            KaraokeTextLayerView(line: line, clock: lyricsClock, fontSize: activeSize, isPlaying: isPlaying, letterSpacing: CGFloat(settings.lyricsLetterSpacing))
                    .frame(height: activeSize * 1.2)
                .padding(.vertical, isActive ? 13 * CGFloat(settings.lyricsHighlightHeight) : 13)
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
                .lineSpacing(CGFloat(settings.lyricsLineSpacing))
                .tracking(CGFloat(settings.lyricsLetterSpacing))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, isActive ? 13 * CGFloat(settings.lyricsHighlightHeight) : 13)
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
