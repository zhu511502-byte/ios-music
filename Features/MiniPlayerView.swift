import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var player: PlaybackCoordinator
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var hero: HeroTransitionCoordinator
    let onTap: () -> Void

    @State private var lyrics: Lyrics?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                ArtworkView(url: player.currentTrack?.picURL, size: 46, cornerRadius: 10)
                    .shadow(color: .black.opacity(0.3), radius: 7, y: 4)
                    .heroAnchor(.miniCover)
                    .opacity(hero.hideMiniCover ? 0 : 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.currentTrack?.name ?? "")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryText)
                        .lineLimit(1)
                        .heroAnchor(.miniTitle)
                    Text(player.currentTrack?.singer ?? "")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                        .heroAnchor(.miniArtist)
                    MiniLyricLine(clock: player.clock, lyrics: lyrics)
                }
                .opacity(hero.hideMiniText ? 0 : 1)

                Spacer(minLength: 6)

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppTheme.primaryText)
                        .frame(width: 36, height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hero.miniChromeOpacity)

                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppTheme.primaryText.opacity(0.9))
                        .frame(width: 32, height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hero.miniChromeOpacity)
            }
            .padding(.horizontal, 11)
            .padding(.top, 8)
            .padding(.bottom, 7)

        }
        .background(glassBackground)
        .opacity(hero.hideMiniSurface ? 0 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .heroAnchor(.miniCapsule)
        .onTapGesture(perform: onTap)
        .task(id: player.currentTrack?.id) {
            lyrics = nil
            guard let track = player.currentTrack else { return }
            let value = try? await LyricsService.shared.lyrics(for: track)
            guard !Task.isCancelled else { return }
            lyrics = value
        }
    }

    /// A frosted, floating "liquid glass" capsule: translucent material,
    /// a diagonal specular sheen, a bright rim and a soft drop shadow.
    private var glassBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return ZStack {
            shape.fill(.ultraThinMaterial)

            shape.fill(
                LinearGradient(
                    colors: [
                        .white.opacity(0.16),
                        .white.opacity(0.045),
                        .clear,
                        .white.opacity(0.035)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

            shape.strokeBorder(
                LinearGradient(
                    colors: [
                        .white.opacity(0.6),
                        .white.opacity(0.1),
                        .white.opacity(0.28)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.8
            )
        }
        .clipShape(shape)
        .shadow(color: .black.opacity(0.45), radius: 18, y: 9)
    }
}

/// Keeps the once-per-second lyric/clock redraw inside this tiny text view.
private struct MiniLyricLine: View {
    @ObservedObject var clock: PlaybackClock
    let lyrics: Lyrics?

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(AppTheme.secondaryText)
            .lineLimit(1)
            .frame(height: 13, alignment: .leading)
    }

    private var text: String {
        guard let lyrics = lyrics, !lyrics.isEmpty else { return " " }
        if lyrics.isSynced {
            guard let index = lyrics.lines.lastIndex(where: { ($0.time ?? -1) <= clock.time + 0.05 }) else {
                return " "
            }
            return lyrics.lines[index].text
        }
        return lyrics.lines.first?.text ?? " "
    }
}
