import SwiftUI
import UIKit

enum AppTheme {
    static let background = Color(red: 0.055, green: 0.055, blue: 0.075)
    static let card = Color(red: 0.10, green: 0.10, blue: 0.13)
    static var accent: Color { ThemeStore.shared.accent }
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

/// Slow-moving specular highlights layered over the app background. The
/// motion is intentionally subtle — it should feel like light moving behind
/// frosted glass, not a screensaver.
struct FlowingGlowView: View {
    var intensity: Double = 0.55

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.12)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geometry in
                let w = geometry.size.width
                let h = geometry.size.height
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.white.opacity(0.19), .clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: w * 0.46
                            )
                        )
                        .frame(width: w * 0.92)
                        .offset(x: CGFloat(sin(t * 0.21)) * w * 0.22,
                                y: CGFloat(cos(t * 0.17)) * h * 0.14)

                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [AppTheme.accent.opacity(0.18), .clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: w * 0.38
                            )
                        )
                        .frame(width: w * 0.74)
                        .offset(x: CGFloat(cos(t * 0.13)) * w * 0.30,
                                y: CGFloat(sin(t * 0.19)) * h * 0.22)

                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color(red: 0.45, green: 0.55, blue: 1.0).opacity(0.10), .clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: w * 0.34
                            )
                        )
                        .frame(width: w * 0.66)
                        .offset(x: CGFloat(sin(t * 0.11 + 1.7)) * w * 0.26,
                                y: CGFloat(cos(t * 0.15 + 0.8)) * h * 0.20)
                }
                .blendMode(.screen)
                .opacity(intensity)
            }
        }
        .allowsHitTesting(false)
    }
}

/// App-wide backdrop: the user's custom photo when set, otherwise a solid
/// dark color, with slow specular highlights on top.
struct AppBackgroundView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        ZStack {
            Color(red: 0.03, green: 0.03, blue: 0.05)

            if let image = settings.backgroundImage {
                GeometryReader { geometry in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .blur(radius: max(settings.backgroundBlur, 0.5))
                        .opacity(settings.backgroundOpacity)
                }
                .ignoresSafeArea()
            }

            Color.black.opacity(settings.backgroundDim)
            FlowingGlowView(intensity: 0.5)
        }
        .ignoresSafeArea()
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

/// Cover-derived animated mesh gradient, modelled on kunyin's
/// `AlbumMeshBackground`. Four dominant cover colours drift behind a heavily
/// blurred copy of the artwork, which gives the player the slow "liquid glass"
/// light show Apple Music uses instead of a static blur.
struct CoverMeshBackground: View {
    let url: URL?
    var intensity: Double = 0.9
    var artworkOpacity: Double = 0.5

    @State private var palette: [Color] = CoverMeshBackground.fallbackPalette

    static let fallbackPalette: [Color] = [
        Color(red: 0.24, green: 0.30, blue: 0.52),
        Color(red: 0.46, green: 0.26, blue: 0.48),
        Color(red: 0.18, green: 0.42, blue: 0.46),
        Color(red: 0.52, green: 0.28, blue: 0.30)
    ]

    var body: some View {
        ZStack {
            Color.black

            if let url {
                GeometryReader { geometry in
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable()
                                .scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .clipped()
                                .blur(radius: 78)
                                .scaleEffect(1.22)
                                .opacity(artworkOpacity)
                        }
                    }
                }
            }

            TimelineView(.periodic(from: .now, by: 0.2)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                GeometryReader { geometry in
                    let w = max(geometry.size.width, 1)
                    let h = max(geometry.size.height, 1)
                    ZStack {
                        ForEach(0..<4, id: \.self) { index in
                            Ellipse()
                                .fill(
                                    RadialGradient(
                                        colors: [
                                            palette[index % palette.count].opacity(0.72),
                                            palette[index % palette.count].opacity(0.24),
                                            .clear
                                        ],
                                        center: .center,
                                        startRadius: 0,
                                        endRadius: max(w, h) * 0.52
                                    )
                                )
                                .frame(width: w * (0.92 + CGFloat(index) * 0.14),
                                       height: h * (0.72 + CGFloat(index) * 0.10))
                                .offset(
                                    x: CGFloat(sin(t * (0.11 + Double(index) * 0.017) + Double(index) * 1.7)) * w * 0.26,
                                    y: CGFloat(cos(t * (0.09 + Double(index) * 0.013) + Double(index) * 0.9)) * h * 0.20
                                )
                        }
                    }
                    .blendMode(.screen)
                }
            }
            .opacity(intensity)
            .allowsHitTesting(false)
        }
        .task(id: url?.absoluteString) {
            palette = await CoverPaletteStore.shared.palette(for: url)
        }
    }
}

/// Extracts four representative colours (one per cover quadrant) and boosts
/// their saturation so they read as light rather than mud once blurred.
@MainActor
final class CoverPaletteStore {
    static let shared = CoverPaletteStore()

    private var cache: [String: [Color]] = [:]
    private var running: [String: Task<[Color], Never>] = [:]

    func palette(for url: URL?) async -> [Color] {
        guard let url else { return CoverMeshBackground.fallbackPalette }
        let key = url.absoluteString
        if let cached = cache[key] { return cached }
        if let task = running[key] { return await task.value }

        let task = Task<[Color], Never> {
            guard let result = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: result.0) else {
                return CoverMeshBackground.fallbackPalette
            }
            return CoverPaletteStore.extract(from: image)
        }
        running[key] = task
        let colors = await task.value
        running[key] = nil
        cache[key] = colors
        return colors
    }

    private static func extract(from image: UIImage) -> [Color] {
        let side = 40
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let cgImage = image.cgImage,
              let context = CGContext(
                data: &pixels,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return CoverMeshBackground.fallbackPalette
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var colors: [Color] = []
        let half = side / 2
        for quadrant in 0..<4 {
            let originX = (quadrant % 2) * half
            let originY = (quadrant / 2) * half
            var red = 0, green = 0, blue = 0, count = 0
            for y in originY..<(originY + half) {
                for x in originX..<(originX + half) {
                    let index = (y * side + x) * 4
                    red += Int(pixels[index])
                    green += Int(pixels[index + 1])
                    blue += Int(pixels[index + 2])
                    count += 1
                }
            }
            guard count > 0 else { continue }
            colors.append(boosted(
                CGFloat(red) / CGFloat(count) / 255,
                CGFloat(green) / CGFloat(count) / 255,
                CGFloat(blue) / CGFloat(count) / 255
            ))
        }
        return colors.isEmpty ? CoverMeshBackground.fallbackPalette : colors
    }

    private static func boosted(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> Color {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 1
        UIColor(red: red, green: green, blue: blue, alpha: 1)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        saturation = min(1, saturation * 1.45 + 0.16)
        brightness = min(0.86, max(0.34, brightness * 1.05))
        return Color(hue: Double(hue), saturation: Double(saturation), brightness: Double(brightness))
    }
}
