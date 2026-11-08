import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

struct NetEaseAccountView: View {
    @EnvironmentObject private var account: NetEaseAccount
    @EnvironmentObject private var library: LibraryStore
    @State private var message: String?
    @State private var showMessage = false
    @State private var phone = ""
    @State private var password = ""

    var body: some View {
        Form {
            if account.isLoggedIn {
                accountSection
                playlistSection
            } else {
                loginSection
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .navigationTitle("网易云账号")
        .navigationBarTitleDisplayMode(.inline)
        .alert("提示", isPresented: $showMessage) {
            Button("好", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private var accountSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(AppTheme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.profileName ?? "网易云用户")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("UID \(account.uid ?? "-")")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                    Text("已登录，可同步账号歌单")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
            .padding(.vertical, 4)

            Button {
                Task {
                    await account.loadPlaylists()
                    message = "已刷新 \(account.playlists.count) 个歌单"
                    showMessage = true
                }
            } label: {
                Label("刷新账号歌单", systemImage: "arrow.clockwise")
            }

            Button(role: .destructive) {
                account.logout()
            } label: {
                Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } header: {
            SectionHeader(title: "账号")
        } footer: {
            Text("登录信息只保存在本机 Keychain，不会上传到其他服务器。")
        }
        .listRowBackground(AppTheme.card)
    }

    private var playlistSection: some View {
        Section {
            if account.playlists.isEmpty {
                Text("账号下暂无歌单")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)
            } else {
                ForEach(account.playlists) { playlist in
                    HStack(spacing: 12) {
                        ArtworkView(url: playlist.coverURL, size: 44, cornerRadius: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(playlist.name)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text("\(playlist.trackCount) 首")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            }

            Button {
                syncPlaylists()
            } label: {
                HStack {
                    Label("同步我的歌单到音乐库", systemImage: "arrow.down.circle")
                    Spacer()
                    if account.isSyncing {
                        ProgressView().tint(.white)
                    }
                }
            }
            .disabled(account.isSyncing || account.playlists.isEmpty)

            if !account.syncStatus.isEmpty {
                Text(account.syncStatus)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
        } header: {
            SectionHeader(title: "我的网易云歌单")
        } footer: {
            Text("同步会按网易云歌单 ID 更新本机对应歌单；已存在的同名歌单会更新歌曲列表。")
        }
        .listRowBackground(AppTheme.card)
    }

    @ViewBuilder
    private var loginSection: some View {
        Section {
            TextField("手机号", text: $phone)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
            SecureField("网易云密码", text: $password)
                .textContentType(.password)
            Button {
                Task { await account.login(phone: phone, password: password) }
            } label: {
                HStack {
                    Label("手机号登录", systemImage: "person.badge.key")
                    Spacer()
                    if account.isWorking {
                        ProgressView().tint(.white)
                    }
                }
            }
            .disabled(account.isWorking || phone.isEmpty || password.isEmpty)
        } header: {
            SectionHeader(title: "手机号登录")
        } footer: {
            Text("如果账号开启了二次验证，建议使用下面的扫码登录。")
        }
        .listRowBackground(AppTheme.card)

        Section {
            if let content = account.qrContent {
                HStack {
                    Spacer()
                    QRCodeView(content: content)
                        .frame(width: 220, height: 220)
                    Spacer()
                }
                .padding(.vertical, 10)

                Text(account.qrStatus)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .center)

                Button {
                    account.startQRLogin()
                } label: {
                    Label("刷新二维码", systemImage: "arrow.clockwise")
                }
                .disabled(account.isWorking)
            } else if account.isWorking {
                HStack {
                    Spacer()
                    VStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text(account.qrStatus.isEmpty ? "正在准备登录…" : account.qrStatus)
                            .font(.footnote)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    Spacer()
                }
                .padding(.vertical, 28)
            } else {
                Button {
                    account.startQRLogin()
                } label: {
                    Label("生成登录二维码", systemImage: "qrcode")
                }
            }

            if let error = account.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.9))
            }
        } header: {
            SectionHeader(title: "扫码登录")
        } footer: {
            Text("用网易云音乐 App 扫码并在手机上确认登录。二维码有效期约 3 分钟。")
        }
        .listRowBackground(AppTheme.card)
    }

    private func syncPlaylists() {
        Task {
            do {
                let count = try await account.syncPlaylists(to: library)
                message = "已同步 \(count) 个网易云歌单到音乐库"
            } catch {
                message = error.localizedDescription
            }
            showMessage = true
        }
    }
}

private struct QRCodeView: View {
    let content: String

    var body: some View {
        Group {
            if let image = makeImage() {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white)
                    .overlay(ProgressView())
            }
        }
    }

    private func makeImage() -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
