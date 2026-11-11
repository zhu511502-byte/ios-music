import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

// MARK: - Sources

struct SourceSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var sources: SourceStore

    @State private var showSourceImporter = false
    @State private var showSourceURLImporter = false
    @State private var sourceURLText = ""
    @State private var isWorking = false
    @State private var message: String?
    @State private var showMessage = false

    private let jsType = UTType(filenameExtension: "js") ?? .plainText

    var body: some View {
        Form {
            Section {
                if sources.profiles.isEmpty {
                    Text("还没有导入音源")
                        .foregroundStyle(AppTheme.secondaryText)
                } else {
                    ForEach(sources.profiles) { profile in
                        Button {
                            sources.selectedID = profile.id
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: sources.selectedID == profile.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(sources.selectedID == profile.id ? AppTheme.accent : AppTheme.secondaryText)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.name).foregroundStyle(AppTheme.primaryText)
                                    Text(sourceSubtitle(profile))
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.secondaryText)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) {
                                sources.remove(profile)
                            } label: { Label("删除", systemImage: "trash") }
                        }
                    }
                }
            } header: {
                SectionHeader(title: "已安装")
            }
            .listRowBackground(AppTheme.card)

            Section {
                Button {
                    showSourceImporter = true
                } label: {
                    Label("从文件导入 .js", systemImage: "doc.badge.plus")
                }
                .disabled(isWorking)

                Button {
                    showSourceURLImporter = true
                } label: {
                    Label("从链接导入 .js", systemImage: "link.badge.plus")
                }
                .disabled(isWorking)

                if sources.selectedProfile != nil {
                    Button {
                        checkSelectedSource()
                    } label: {
                        Label("检测当前音源", systemImage: "waveform.path.ecg")
                    }
                    .disabled(isWorking)
                }
            } header: {
                SectionHeader(title: "导入")
            }
            .listRowBackground(AppTheme.card)
        }
        .scrollContentBackground(.hidden)
        .background { AppBackgroundView() }
        .navigationTitle("洛雪音源")
        .navigationBarTitleDisplayMode(.inline)
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
    }

    private func checkSelectedSource() {
        isWorking = true
        Task {
            do {
                let capabilities = try await model.preloadSelectedSource()
                await MainActor.run {
                    isWorking = false
                    message = "可用平台：\(capabilities.keys.sorted().joined(separator: " / "))"
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

struct SourceURLImportSheet: View {
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
                    Text("GitHub 请使用 raw.githubusercontent.com 链接。")
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

// MARK: - Sync

struct SyncSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var sync: SyncClient
    @EnvironmentObject private var library: LibraryStore

    @State private var message: String?
    @State private var showMessage = false

    var body: some View {
        Form {
            Section {
                TextField("http://192.168.1.2:23332", text: $settings.serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("连接码", text: $settings.authCode)
                Toggle("启动时自动同步", isOn: $settings.autoSync)
                    .tint(AppTheme.accent)
            } header: {
                SectionHeader(title: "服务器")
            } footer: {
                Text("连接码是服务端 users[].password。")
            }
            .listRowBackground(AppTheme.card)

            Section {
                Picker("同步模式", selection: $settings.syncMode) {
                    ForEach(SyncMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            } header: {
                SectionHeader(title: "同步方式")
            } footer: {
                Text(settings.syncMode.detail)
            }
            .listRowBackground(AppTheme.card)

            Section {
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
            }
            .listRowBackground(AppTheme.card)
        }
        .scrollContentBackground(.hidden)
        .background { AppBackgroundView() }
        .navigationTitle("洛雪同步")
        .navigationBarTitleDisplayMode(.inline)
        .alert("提示", isPresented: $showMessage) {
            Button("好", role: .cancel) {}
        } message: {
            Text(message ?? "")
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
                library: library,
                mode: settings.syncMode
            )
        }
    }
}

// MARK: - Appearance

struct AppearanceSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var message: String?
    @State private var showMessage = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("主题色")
                    Spacer()
                    ColorPicker(
                        "",
                        selection: Binding(
                            get: { settings.accentColor },
                            set: { settings.setThemeColor($0) }
                        ),
                        supportsOpacity: false
                    )
                    .labelsHidden()
                }

                HStack(spacing: 13) {
                    ForEach(ThemeSwatch.presets) { swatch in
                        Button {
                            settings.setThemeColor(swatch.color)
                        } label: {
                            Circle()
                                .fill(swatch.color)
                                .frame(width: 27, height: 27)
                                .overlay(
                                    Circle()
                                        .stroke(Color.white.opacity(settings.themeColorHex == swatch.hex ? 0.95 : 0), lineWidth: 2)
                                )
                                .overlay(
                                    Circle()
                                        .stroke(Color.white.opacity(0.16), lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(swatch.name)
                    }
                }
            } header: {
                SectionHeader(title: "主题色")
            }
            .listRowBackground(AppTheme.card)

            Section {
                Toggle("浅色背景", isOn: $settings.lightBackground)
                    .tint(AppTheme.accent)
            } header: {
                SectionHeader(title: "背景风格")
            } footer: {
                Text("浅色只影响搜索、发现、音乐库和设置页；播放页与歌词页保持深色。")
            }
            .listRowBackground(AppTheme.card)

            Section {
                if let image = settings.backgroundImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }

                PhotosPicker(selection: $selectedPhoto, matching: .images, photoLibrary: .shared()) {
                    Label(settings.hasCustomBackground ? "更换背景图" : "选择背景图", systemImage: "photo.on.rectangle.angled")
                        .foregroundStyle(AppTheme.accent)
                }

                if settings.hasCustomBackground {
                    Button(role: .destructive) {
                        settings.removeBackgroundImage()
                    } label: {
                        Label("移除背景图", systemImage: "trash")
                    }

                    sliderRow(
                        title: "模糊",
                        value: "\(Int(settings.backgroundBlur))",
                        binding: $settings.backgroundBlur,
                        range: 0...60,
                        step: 1
                    )
                    sliderRow(
                        title: "压暗",
                        value: String(format: "%.0f%%", settings.backgroundDim * 100),
                        binding: $settings.backgroundDim,
                        range: 0...0.9,
                        step: 0.05
                    )
                    sliderRow(
                        title: "亮度",
                        value: String(format: "%.0f%%", settings.backgroundOpacity * 100),
                        binding: $settings.backgroundOpacity,
                        range: 0.2...1,
                        step: 0.05
                    )
                }
            } header: {
                SectionHeader(title: "背景图")
            } footer: {
                Text("只用于搜索、发现、音乐库和设置页；播放页与歌词页使用专辑封面。")
            }
            .listRowBackground(AppTheme.card)
        }
        .scrollContentBackground(.hidden)
        .background { AppBackgroundView() }
        .navigationTitle("主题与背景")
        .navigationBarTitleDisplayMode(.inline)
        .alert("提示", isPresented: $showMessage) {
            Button("好", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
        .onChange(of: selectedPhoto) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    await MainActor.run {
                        settings.setBackgroundImage(image)
                    }
                } else {
                    await MainActor.run {
                        message = "读取照片失败，请换一张试试"
                        showMessage = true
                    }
                }
                await MainActor.run { selectedPhoto = nil }
            }
        }
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
                    .foregroundStyle(AppTheme.secondaryText)
            }
            Slider(value: binding, in: range, step: step)
                .tint(AppTheme.accent)
        }
    }
}

// MARK: - Playback

struct PlaybackSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker("默认音质", selection: $settings.preferredQuality) {
                    ForEach(Quality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                Toggle("允许蜂窝网络", isOn: $settings.allowCellular)
                    .tint(AppTheme.accent)
            } header: {
                SectionHeader(title: "播放")
            }
            .listRowBackground(AppTheme.card)
        }
        .scrollContentBackground(.hidden)
        .background { AppBackgroundView() }
        .navigationTitle("播放")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - About

struct AboutSettingsView: View {
    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "music.note.house.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(AppTheme.accent.gradient)
                        )
                    VStack(alignment: .leading, spacing: 4) {
                        Text("LxPlayer")
                            .font(.title3.weight(.semibold))
                        Text("版本 \(AppInfo.version)")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }
                .padding(.vertical, 6)
            }
            .listRowBackground(AppTheme.card)

            Section {
                LabeledContent("内置平台", value: "QQ / 网易 / 酷狗 / 酷我 / 咪咕")
                LabeledContent("歌词格式", value: "LRC / KRC / YRC")
                LabeledContent("数据同步", value: "LX Sync v4")
            }
            .listRowBackground(AppTheme.card)

            Section {
                Text("个人自签构建，第三方音源与平台版权风险由使用者承担。")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .listRowBackground(AppTheme.card)
        }
        .scrollContentBackground(.hidden)
        .background { AppBackgroundView() }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Sync mode sheet

struct SyncModeSheet: View {
    let prompt: SyncModePrompt
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("首次同步「\(prompt.serverName)」，请选择合并方式。")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                ForEach(SyncMode.allCases) { mode in
                    Button {
                        onSelect(mode.rawValue)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(mode.title).foregroundStyle(AppTheme.primaryText)
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
