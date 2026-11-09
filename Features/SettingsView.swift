import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var sources: SourceStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var sync: SyncClient
    @EnvironmentObject private var netease: NetEaseAccount

    @State private var showSourceImporter = false
    @State private var showSourceURLImporter = false
    @State private var sourceURLText = ""
    @State private var isWorking = false
    @State private var message: String?
    @State private var showMessage = false

    private let jsType = UTType(filenameExtension: "js") ?? .plainText

    var body: some View {
        NavigationStack {
            Form {
                builtinSection
                sourceSection
                neteaseSection
                syncSection
                appearanceSection
                playbackSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .navigationTitle("设置")
            .fileImporter(isPresented: $showSourceImporter, allowedContentTypes: [jsType], allowsMultipleSelection: false) { result in
                handleSourceImport(result)
            }
            .sheet(isPresented: $showSourceURLImporter) {
                SourceURLImportSheet(url: $sourceURLText) { value in
                    importSourceFromURL(value)
                }
            }
            .alert("提示", isPresented: $showMessage) {
                Button("好", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
            .sheet(item: $sync.modePrompt) { prompt in
                SyncModeSheet(prompt: prompt) { mode in
                    sync.resolveMode(mode)
                }
                .interactiveDismissDisabled()
            }
        }
    }

    private var builtinSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("内置平台接口").foregroundStyle(.white)
                    Text("QQ / 网易 / 酷狗 / 酷我 / 咪咕 · Swift 原生")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
        } header: {
            SectionHeader(title: "搜索与发现")
        } footer: {
            Text("搜索、歌单和排行榜直接移植自洛雪安卓端 musicSdk，不需要 Ceru 插件。自定义音源只在播放时由系统 JavaScriptCore 执行官方 preload。")
        }
        .listRowBackground(AppTheme.card)
    }

    private var sourceSection: some View {
        Section {
            ForEach(sources.profiles) { profile in
                Button {
                    sources.selectedID = profile.id
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: sources.selectedID == profile.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(sources.selectedID == profile.id ? AppTheme.accent : AppTheme.secondaryText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name).foregroundStyle(.white)
                            Text(sourceSubtitle(profile)).font(.caption).foregroundStyle(AppTheme.secondaryText)
                        }
                    }
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button(role: .destructive) {
                        sources.remove(profile)
                    } label: { Label("删除", systemImage: "trash") }
                }
            }
            Button {
                showSourceImporter = true
            } label: {
                Label("从文件导入音源 .js", systemImage: "doc.badge.plus")
            }
            .disabled(isWorking)
            Button {
                showSourceURLImporter = true
            } label: {
                Label("从链接导入音源 .js", systemImage: "link.badge.plus")
            }
            .disabled(isWorking)
            if sources.selectedProfile != nil {
                Button {
                    checkSelectedSource()
                } label: {
                    Label("检测音源脚本", systemImage: "waveform.path.ecg")
                }
                .disabled(isWorking)
            }
        } header: {
            SectionHeader(title: "洛雪音源")
        } footer: {
            Text("音源只负责解析播放地址。脚本必须支持当前平台和音质。")
        }
        .listRowBackground(AppTheme.card)
    }

    private var neteaseSection: some View {
        Section {
            NavigationLink {
                NetEaseAccountView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "cloud.fill")
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("网易云音乐")
                            .foregroundStyle(.white)
                        Text(netease.isLoggedIn ? (netease.profileName ?? "已登录") : "未登录，点此扫码登录")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
        } header: {
            SectionHeader(title: "账号")
        } footer: {
            Text("登录后可把网易云账号下的歌单同步到本机音乐库。")
        }
        .listRowBackground(AppTheme.card)
    }

    private var syncSection: some View {
        Section {
            TextField("http://192.168.1.2:23332", text: $settings.serverURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            SecureField("连接码", text: $settings.authCode)
            Toggle("打开 App 自动同步", isOn: $settings.autoSync)
            Button {
                connectSync()
            } label: {
                HStack {
                    Label("连接并同步", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    Text(sync.status.label)
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
            .disabled(settings.serverURL.isEmpty || sync.status == .connecting || sync.status == .syncing)

            if sync.isConnected {
                Button(role: .destructive) {
                    sync.disconnect()
                } label: {
                    Label("断开同步", systemImage: "xmark.circle")
                }
            }
        } header: {
            SectionHeader(title: "洛雪数据同步")
        } footer: {
            Text("支持桌面版「服务端模式」和独立 lx-music-sync-server；连接码是服务端 users[].password，不是用户名。开启自动同步后，每次启动会用保存的地址和连接码直连并推送本机歌单；首次选择的合并方式会被记住，之后不再弹窗。公网请使用 HTTPS/WSS。")
        }
        .listRowBackground(AppTheme.card)
    }

    private var appearanceSection: some View {
        Section {
            Picker("背景", selection: $settings.backgroundStyle) {
                ForEach(BackgroundStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            if settings.backgroundStyle == .artwork {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("模糊强度")
                        Spacer()
                        Text("\(Int(settings.backgroundBlur))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    Slider(value: $settings.backgroundBlur, in: 0...80, step: 1)
                        .tint(AppTheme.accent)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("压暗程度")
                        Spacer()
                        Text(String(format: "%.0f%%", settings.backgroundDim * 100))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    Slider(value: $settings.backgroundDim, in: 0...0.9, step: 0.05)
                        .tint(AppTheme.accent)
                }
                Toggle("歌词逐字高亮", isOn: $settings.karaokeLyrics)
            }
        } header: {
            SectionHeader(title: "外观")
        } footer: {
            Text("「动态封面」用当前播放歌曲的专辑封面做全 App 模糊背景，随切歌平滑过渡。网易云歌曲自动使用官方逐字歌词（yrc）；关闭逐字高亮后，其他来源的歌词按整句显示。")
        }
        .listRowBackground(AppTheme.card)
    }

    private var playbackSection: some View {
        Section {
            Picker("默认音质", selection: $settings.preferredQuality) {
                ForEach(Quality.allCases) { quality in
                    Text(quality.displayName).tag(quality)
                }
            }
            Toggle("允许蜂窝网络", isOn: $settings.allowCellular)
        } header: {
            SectionHeader(title: "播放")
        }
        .listRowBackground(AppTheme.card)
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Text("版本")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
                    .foregroundStyle(AppTheme.secondaryText)
            }
            Text("个人自签构建。第三方音源、平台接口与版权风险由使用者自行承担。")
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
        } header: {
            SectionHeader(title: "关于")
        }
        .listRowBackground(AppTheme.card)
    }

    private func checkSelectedSource() {
        isWorking = true
        Task {
            do {
                let capabilities = try await model.preloadSelectedSource()
                await MainActor.run {
                    isWorking = false
                    message = "音源可用平台：\(capabilities.keys.sorted().joined(separator: " / "))"
                    showMessage = true
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    message = error.localizedDescription
                    showMessage = true
                }
            }
        }
    }

    private func connectSync() {
        guard let url = URL(string: settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            message = "同步服务地址无效"
            showMessage = true
            return
        }
        Task {
            await sync.connect(
                baseURL: url,
                authCode: settings.authCode,
                deviceName: settings.deviceName,
                library: library
            )
        }
    }

    private func sourceSubtitle(_ profile: SourceProfile) -> String {
        if profile.sources.isEmpty { return "尚未初始化" }
        let platforms = profile.sources.keys.sorted().joined(separator: " / ")
        return "\(platforms) · \(profile.sources.values.flatMap { $0.qualitys }.count) 个音质"
    }

    private func handleSourceImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let profile = try sources.importScript(from: url)
                sources.selectedID = profile.id
                message = "音源已导入：\(profile.name)"
            } catch {
                message = error.localizedDescription
            }
            showMessage = true
        case .failure(let error):
            message = error.localizedDescription
            showMessage = true
        }
    }

    private func importSourceFromURL(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            message = "请输入 http:// 或 https:// 开头的脚本直链"
            showMessage = true
            return
        }

        isWorking = true
        Task {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 30
                request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) LxPlayer", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    throw SourceError.httpStatus(http.statusCode)
                }
                let profile = try sources.importScript(data: data, originURL: url)
                sources.selectedID = profile.id
                message = "音源已导入：\(profile.name)"
            } catch {
                message = error.localizedDescription
            }
            isWorking = false
            showMessage = true
        }
    }
}

private struct SourceURLImportSheet: View {
    @Binding var url: String
    let onImport: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/source.js", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    SectionHeader(title: "脚本直链")
                } footer: {
                    Text("必须是返回 JavaScript 源码的直链。GitHub 页面请使用 raw.githubusercontent.com，而不是 blob 页面。")
                }
                .listRowBackground(AppTheme.card)
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .navigationTitle("从链接导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        let value = url.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !value.isEmpty else { return }
                        onImport(value)
                        dismiss()
                    }
                    .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}


private struct SyncModeSheet: View {
    let prompt: SyncModePrompt
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private struct SyncModeOption: Identifiable {
        let id: String
        let title: String
        let detail: String
    }

    private let modes: [SyncModeOption] = [
        SyncModeOption(id: "merge_local_remote", title: "以本机为主合并", detail: "保留双方歌曲；重复歌曲以本机为准。"),
        SyncModeOption(id: "merge_remote_local", title: "以远端为主合并", detail: "保留双方歌曲；重复歌曲以远端为准。"),
        SyncModeOption(id: "overwrite_local_remote", title: "用本机覆盖远端", detail: "本机列表覆盖远端，但保留远端独有的用户歌单。"),
        SyncModeOption(id: "overwrite_remote_local", title: "用远端覆盖本机", detail: "远端列表覆盖本机，但保留本机独有的用户歌单。"),
        SyncModeOption(id: "overwrite_local_remote_full", title: "本机完整覆盖远端", detail: "删除远端独有的用户歌单，慎用。"),
        SyncModeOption(id: "overwrite_remote_local_full", title: "远端完整覆盖本机", detail: "删除本机独有的用户歌单，慎用。")
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("首次同步「\(prompt.serverName)」时，两边都有列表，请选择合并方式。")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                ForEach(modes) { mode in
                    Button {
                        onSelect(mode.id)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(mode.title).foregroundStyle(.white)
                            Text(mode.detail).font(.caption).foregroundStyle(AppTheme.secondaryText)
                        }
                    }
                    .listRowBackground(AppTheme.card)
                }
                Section {
                    Button(role: .cancel) {
                        onSelect("cancel")
                        dismiss()
                    } label: {
                        Text("取消本次同步").foregroundStyle(.red)
                    }
                    .listRowBackground(AppTheme.card)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .navigationTitle("选择同步方式")
        }
    }
}
