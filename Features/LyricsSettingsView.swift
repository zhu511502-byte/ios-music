import SwiftUI

/// Sheet wrapper used by the ellipsis menu on the lyric page.
struct LyricsSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LyricsSettingsContent()
                .navigationTitle("歌词样式")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
        }
        .preferredColorScheme(.dark)
    }
}

/// Shared editor, also pushed from Settings without a nested NavigationStack.
struct LyricsSettingsContent: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            Section {
                sliderRow(
                    title: "字号",
                    value: "\(Int(settings.lyricsFontSize)) pt",
                    binding: $settings.lyricsFontSize,
                    range: 22...40,
                    step: 1
                )
                sliderRow(
                    title: "行间距",
                    value: "\(Int(settings.lyricsLineSpacing)) pt",
                    binding: $settings.lyricsLineSpacing,
                    range: 0...30,
                    step: 1
                )
                sliderRow(
                    title: "字间距",
                    value: String(format: "%.1f", settings.lyricsLetterSpacing),
                    binding: $settings.lyricsLetterSpacing,
                    range: -1...4,
                    step: 0.5
                )
                sliderRow(
                    title: "高亮行高度",
                    value: String(format: "%.0f%%", settings.lyricsHighlightHeight * 100),
                    binding: $settings.lyricsHighlightHeight,
                    range: 0.8...1.6,
                    step: 0.05
                )
                Toggle("逐字高亮", isOn: $settings.karaokeLyrics)
                    .tint(AppTheme.accent)
            } header: {
                Text("歌词外观")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(secondaryText)
            }
            .listRowBackground(cardColor)

            Section {
                Button(role: .destructive) {
                    settings.resetLyricsAppearance()
                } label: {
                    Label("恢复默认", systemImage: "arrow.counterclockwise")
                }
            }
            .listRowBackground(cardColor)
        }
        .scrollContentBackground(.hidden)
        .background {
            if colorScheme == .dark {
                Color(red: 0.03, green: 0.03, blue: 0.05)
            } else {
                AppBackgroundView()
            }
        }
    }

    private var cardColor: Color {
        colorScheme == .dark
            ? Color(red: 0.10, green: 0.10, blue: 0.13)
            : Color.white.opacity(0.78)
    }

    private var secondaryText: Color {
        colorScheme == .dark ? Color.white.opacity(0.58) : Color.black.opacity(0.55)
    }

    private func sliderRow(
        title: String,
        value: String,
        binding: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(value)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(secondaryText)
            }
            Slider(value: binding, in: range, step: step)
                .tint(AppTheme.accent)
        }
    }
}
