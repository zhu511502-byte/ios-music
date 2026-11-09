import SwiftUI

/// Lyrics-specific appearance editor, opened from the ellipsis menu on the
/// lyric page. Values are live because `SettingsStore` is observed by the
/// lyric viewport.
struct LyricsSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("字大小")
                            Spacer()
                            Text("\(Int(settings.lyricsFontSize)) pt")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                        Slider(value: $settings.lyricsFontSize, in: 22...40, step: 1)
                            .tint(AppTheme.accent)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("行间距")
                            Spacer()
                            Text(String(format: "%.0f", settings.lyricsLineSpacing))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                        Slider(value: $settings.lyricsLineSpacing, in: 0...18, step: 1)
                            .tint(AppTheme.accent)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("字间距")
                            Spacer()
                            Text(String(format: "%.1f", settings.lyricsLetterSpacing))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                        Slider(value: $settings.lyricsLetterSpacing, in: -1...4, step: 0.5)
                            .tint(AppTheme.accent)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("高亮行高度")
                            Spacer()
                            Text(String(format: "%.0f%%", settings.lyricsHighlightHeight * 100))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                        Slider(value: $settings.lyricsHighlightHeight, in: 0.8...1.6, step: 0.05)
                            .tint(AppTheme.accent)
                    }

                    Toggle("逐字高亮", isOn: $settings.karaokeLyrics)
                        .tint(AppTheme.accent)
                } header: {
                    SectionHeader(title: "歌词外观")
                } footer: {
                    Text("高亮行高度控制当前高亮句上下留白；字间距对逐字遮罩同样生效。")
                }
                .listRowBackground(AppTheme.card)

                Section {
                    Button(role: .destructive) {
                        settings.resetLyricsAppearance()
                    } label: {
                        Label("恢复默认歌词样式", systemImage: "arrow.counterclockwise")
                    }
                }
                .listRowBackground(AppTheme.card)
            }
            .scrollContentBackground(.hidden)
            .background { AppBackgroundView() }
            .navigationTitle("歌词自定义")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
