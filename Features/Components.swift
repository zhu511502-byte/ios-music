import SwiftUI

enum AppTheme {
    static let background = Color(red: 0.055, green: 0.055, blue: 0.075)
    static let card = Color(red: 0.10, green: 0.10, blue: 0.13)
    static let accent = Color(red: 0.96, green: 0.30, blue: 0.45)
    static let secondaryText = Color.white.opacity(0.58)
}

struct ArtworkView: View {
    let url: URL?
    var size: CGFloat = 52
    var cornerRadius: CGFloat = 10

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder
                    default:
                        placeholder.overlay(ProgressView().tint(.white.opacity(0.7)))
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [AppTheme.accent.opacity(0.7), Color.purple.opacity(0.45)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            Image(systemName: "music.note")
                .font(.system(size: size * 0.35, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        )
    }
}

/// Inline quality picker used by the player and lyrics screens. Changing the
/// quality re-resolves the current track while keeping the playback position.
struct QualityMenuView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var player: PlaybackCoordinator

    private var qualities: [Quality] {
        let available = player.currentTrack?.availableQualities ?? []
        return available.isEmpty ? Quality.allCases : available
    }

    var body: some View {
        Menu {
            ForEach(qualities) { quality in
                Button {
                    guard quality != settings.preferredQuality else { return }
                    settings.preferredQuality = quality
                    player.reloadCurrentTrack(quality: quality)
                } label: {
                    HStack {
                        Text("\(quality.qualityTitle) · \(quality.displayName)")
                        if quality == settings.preferredQuality {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "waveform")
                Text("\(settings.preferredQuality.qualityTitle) \(settings.preferredQuality.displayName)")
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white.opacity(0.62))
        }
        .disabled(player.currentTrack == nil)
        .accessibilityLabel("音质选择")
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(AppTheme.secondaryText)
            Text(title).font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(AppTheme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// App-wide backdrop: solid dark color, or a blurred version of the current
/// album artwork when "动态封面" is selected. Reads blur/dim strength from
/// SettingsStore so the effect is configurable in the appearance settings.
struct AppBackgroundView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var player: PlaybackCoordinator

    var body: some View {
        ZStack {
            Color(red: 0.03, green: 0.03, blue: 0.05)

            if settings.backgroundStyle == .artwork,
               let url = player.currentTrack?.picURL {
                GeometryReader { geometry in
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable()
                                .scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .clipped()
                                .blur(radius: max(settings.backgroundBlur, 1))
                                .scaleEffect(1.1)
                                .opacity(0.5)
                        }
                    }
                }
                .ignoresSafeArea()
                .transition(.opacity)
                .id(player.currentTrack?.id ?? "")
            }

            Color.black.opacity(settings.backgroundStyle == .artwork ? settings.backgroundDim : 0)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.45), value: player.currentTrack?.id)
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppTheme.secondaryText)
            .padding(.horizontal, 4)
    }
}

struct OnlineTrackRow: View {
    let track: MusicInfo
    var isCurrent = false
    var isPlaying = false
    let onPlay: () -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPlay) {
                HStack(spacing: 12) {
                    ArtworkView(url: track.picURL)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(track.singer)
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(1)
                        if !track.qualitys.isEmpty {
                            Text(track.qualitys.prefix(4).map(\.type).joined(separator: " · "))
                                .font(.caption2)
                                .foregroundStyle(AppTheme.accent.opacity(0.9))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if isCurrent {
                        Image(systemName: isPlaying ? "waveform" : "pause.fill")
                            .foregroundStyle(AppTheme.accent)
                    } else {
                        Image(systemName: "play.circle")
                            .font(.title3)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onAdd) {
                Image(systemName: "plus.circle")
                    .font(.title3)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

struct OnlinePlaylistRow: View {
    let item: OnlinePlaylist

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: item.artworkURL, size: 56, cornerRadius: 12)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.body.weight(.medium)).foregroundStyle(.white).lineLimit(1)
                Text(item.author ?? "")
                    .font(.caption).foregroundStyle(AppTheme.secondaryText).lineLimit(1)
                if let count = item.trackCount {
                    Text("\(count) 首").font(.caption2).foregroundStyle(AppTheme.secondaryText)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.secondaryText)
        }
        .padding(.vertical, 4)
    }
}
