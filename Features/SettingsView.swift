import SwiftUI

/// Settings hub. Each row opens a focused second-level page instead of
/// stacking every control and paragraph of help text on one screen.
struct SettingsView: View {
    @EnvironmentObject private var sources: SourceStore
    @EnvironmentObject private var netease: NetEaseAccount
    @EnvironmentObject private var sync: SyncClient
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        NetEaseAccountView()
                    } label: {
                        SettingsRow(
                            icon: "cloud.fill",
                            color: .red,
                            title: "网易云音乐",
                            subtitle: netease.isLoggedIn ? (netease.profileName ?? "已登录") : "未登录"
                        )
                    }

                    NavigationLink {
                        SourceSettingsView()
                    } label: {
                        SettingsRow(
                            icon: "doc.badge.gearshape",
                            color: .orange,
                            title: "洛雪音源",
                            subtitle: sourceSummary
                        )
                    }

                    NavigationLink {
                        SyncSettingsView()
                    } label: {
                        SettingsRow(
                            icon: "arrow.triangle.2.circlepath",
                            color: .green,
                            title: "洛雪同步",
                            subtitle: sync.isConnected ? "已连接 · \(sync.serverName)" : sync.status.label
                        )
                    }
                } header: {
                    SectionHeader(title: "账号与连接")
                }
                .listRowBackground(AppTheme.card)

                Section {
                    NavigationLink {
                        AppearanceSettingsView()
                    } label: {
                        SettingsRow(
                            icon: "paintpalette.fill",
                            color: .pink,
                            title: "主题与背景",
                            subtitle: "\(settings.lightBackground ? "浅色" : "深色") · \(settings.hasCustomBackground ? "自定义背景" : "纯色")"
                        )
                    }

                    NavigationLink {
                        LyricsSettingsContent()
                            .navigationTitle("歌词样式")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        SettingsRow(
                            icon: "textformat.size",
                            color: .purple,
                            title: "歌词样式",
                            subtitle: "\(Int(settings.lyricsFontSize)) pt · 行距 \(Int(settings.lyricsLineSpacing))"
                        )
                    }
                } header: {
                    SectionHeader(title: "外观")
                }
                .listRowBackground(AppTheme.card)

                Section {
                    NavigationLink {
                        PlaybackSettingsView()
                    } label: {
                        SettingsRow(
                            icon: "play.circle.fill",
                            color: .blue,
                            title: "播放",
                            subtitle: "\(settings.preferredQuality.displayName) · \(settings.allowCellular ? "允许蜂窝网络" : "仅 Wi-Fi")"
                        )
                    }
                } header: {
                    SectionHeader(title: "播放")
                }
                .listRowBackground(AppTheme.card)

                Section {
                    NavigationLink {
                        AboutSettingsView()
                    } label: {
                        SettingsRow(
                            icon: "info.circle.fill",
                            color: .gray,
                            title: "关于",
                            subtitle: "版本 \(AppInfo.version)"
                        )
                    }
                } header: {
                    SectionHeader(title: "其他")
                }
                .listRowBackground(AppTheme.card)
            }
            .scrollContentBackground(.hidden)
            .background { AppBackgroundView() }
            .navigationTitle("设置")
            .sheet(item: $sync.modePrompt) { prompt in
                SyncModeSheet(prompt: prompt) { mode in
                    sync.resolveMode(mode)
                }
                .interactiveDismissDisabled()
            }
        }
    }

    private var sourceSummary: String {
        guard let profile = sources.selectedProfile else { return "未导入" }
        return "\(profile.name) · \(sources.profiles.count) 个"
    }
}

struct SettingsRow: View {
    let icon: String
    let color: Color
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(color.gradient)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(AppTheme.primaryText)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 2)
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }
}
