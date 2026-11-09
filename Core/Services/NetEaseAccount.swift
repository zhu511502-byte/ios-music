import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

struct NetEasePlaylist: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let trackCount: Int
    let coverURL: URL?
    let creator: String?
}

enum NetEaseAccountError: LocalizedError {
    case notLoggedIn
    case loginFailed(String)
    case response(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "请先登录网易云账号"
        case .loginFailed(let message): return "网易云登录失败：\(message)"
        case .response(let message): return "网易云接口返回异常：\(message)"
        case .cancelled: return "已取消"
        }
    }
}

/// NetEase account login + playlist import.
///
/// Uses the same public `music.163.com` endpoints as the desktop client:
/// QR login (`/api/login/qrcode/*`) and the user playlist endpoint. The
/// `MUSIC_U` cookie is stored in Keychain and injected only for
/// `music.163.com` requests.
@MainActor
final class NetEaseAccount: ObservableObject {
    @Published private(set) var isLoggedIn = false
    @Published private(set) var profileName: String?
    @Published private(set) var uid: String?
    @Published private(set) var playlists: [NetEasePlaylist] = []
    @Published private(set) var isWorking = false
    @Published private(set) var isSyncing = false
    @Published private(set) var qrContent: String?
    @Published private(set) var qrStatus = ""
    @Published private(set) var syncStatus = ""
    @Published var errorMessage: String?

    private var cookieHeader: String?
    private var pollTask: Task<Void, Never>?
    private let client = NativeMusicAPI.shared

    init() {
        if let data = KeychainStore.get(account: "netease.cookie"),
           let value = String(data: data, encoding: .utf8), !value.isEmpty {
            cookieHeader = value
            client.setNeteaseCookie(value)
            isLoggedIn = true
        }
    }

    func restoreSession() {
        guard isLoggedIn else { return }
        Task { await refreshProfile(silent: true) }
    }

    // MARK: - QR login

    func startQRLogin() {
        if isWorking { return }
        pollTask?.cancel()
        errorMessage = nil
        qrContent = nil
        qrStatus = "正在生成登录二维码…"
        isWorking = true

        pollTask = Task { [weak self] in
            guard let self else { return }
            do {
                let start = try await NetEaseEAPI.perform(
                    path: "/api/login/qrcode/unikey",
                    data: ["type": 3]
                )
                guard MusicParse.int(start.json["code"]) == 200,
                      let key = MusicParse.string(start.json["unikey"]).nilIfEmpty else {
                    throw NetEaseAccountError.loginFailed(
                        MusicParse.string(start.json["message"]).isEmpty
                            ? "二维码接口没有返回 unikey"
                            : MusicParse.string(start.json["message"])
                    )
                }

                self.qrContent = "https://music.163.com/login?codekey=\(key)"
                self.qrStatus = "打开网易云音乐 App，扫描二维码"

                for _ in 0..<90 {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { return }

                    let poll = try await NetEaseEAPI.perform(
                        path: "/api/login/qrcode/client/login",
                        data: ["key": key, "type": 3],
                        musicU: self.currentMusicU
                    )
                    switch MusicParse.int(poll.json["code"]) {
                    case 800:
                        self.qrStatus = "二维码已过期，请重新生成"
                        self.isWorking = false
                        return
                    case 801:
                        self.qrStatus = "等待扫码…"
                    case 802:
                        self.qrStatus = "已扫码，请在网易云音乐里确认登录"
                    case 803:
                        if let cookie = poll.cookie {
                            self.saveCookie(cookie)
                        } else if self.currentMusicU == nil {
                            self.qrStatus = "登录成功但未拿到 MUSIC_U"
                            self.errorMessage = "登录接口没有返回 MUSIC_U，请重试"
                            self.isWorking = false
                            return
                        }
                        self.qrStatus = "登录成功"
                        self.qrContent = nil
                        await self.refreshProfile()
                        self.isWorking = false
                        return
                    default:
                        self.qrStatus = MusicParse.string(poll.json["message"]).isEmpty
                            ? "等待扫码…"
                            : MusicParse.string(poll.json["message"])
                    }
                }

                self.qrStatus = "二维码等待超时，请重新生成"
                self.isWorking = false
            } catch is CancellationError {
                self.isWorking = false
            } catch {
                self.qrStatus = "登录失败"
                self.errorMessage = error.localizedDescription
                self.isWorking = false
            }
        }
    }

    func cancelQRLogin() {
        pollTask?.cancel()
        pollTask = nil
        qrContent = nil
        qrStatus = ""
        isWorking = false
    }

    func login(phone: String, password: String) async {
        let phone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phone.isEmpty, !password.isEmpty else {
            errorMessage = "请输入手机号和密码"
            return
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let body = try await NetEaseEAPI.perform(
                path: "/api/login/cellphone",
                data: [
                    "phone": phone,
                    "password": MusicCrypto.md5Hex(password),
                    "rememberLogin": "true",
                    "countrycode": "86"
                ],
                musicU: currentMusicU
            )
            guard MusicParse.int(body.json["code"]) == 200 else {
                throw NetEaseAccountError.loginFailed(
                    MusicParse.string(body.json["message"]).isEmpty
                        ? "手机号或密码错误"
                        : MusicParse.string(body.json["message"])
                )
            }
            if let cookie = body.cookie {
                saveCookie(cookie)
            }
            await refreshProfile()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Session

    func refreshProfile(silent: Bool = false) async {
        do {
            var body = try await requestJSON(path: "/api/nuser/account/get")
            if MusicParse.dictionary(body["profile"]).nilIfEmpty == nil,
               let musicU = currentMusicU {
                let eapi = try await NetEaseEAPI.perform(
                    path: "/api/nuser/account/get",
                    data: [:],
                    musicU: musicU
                )
                body = eapi.json
            }
            guard let profile = MusicParse.dictionary(body["profile"]).nilIfEmpty,
                  let account = MusicParse.dictionary(body["account"]).nilIfEmpty else {
                throw NetEaseAccountError.notLoggedIn
            }
            uid = MusicParse.string(account["id"]).nilIfEmpty
            profileName = MusicParse.string(profile["nickname"]).nilIfEmpty ?? "网易云用户"
            isLoggedIn = true
            await loadPlaylists()
        } catch {
            if !silent {
                errorMessage = error.localizedDescription
            }
            if !isLoggedIn || silent {
                isLoggedIn = false
                uid = nil
                profileName = nil
                playlists = []
            }
        }
    }

    func loadPlaylists() async {
        guard let uid = uid else { return }
        do {
            var body = try await requestJSON(
                path: "/api/user/playlist",
                query: [("uid", uid), ("limit", "1000"), ("offset", "0")]
            )
            if MusicParse.objects(body["playlist"]).isEmpty, let musicU = currentMusicU {
                let eapi = try await NetEaseEAPI.perform(
                    path: "/api/user/playlist",
                    data: ["uid": uid, "limit": 1000, "offset": 0],
                    musicU: musicU
                )
                body = eapi.json
            }
            playlists = MusicParse.objects(body["playlist"]).compactMap { item in
                let id = MusicParse.string(item["id"])
                guard !id.isEmpty else { return nil }
                let cover = MusicParse.string(item["coverImgUrl"])
                return NetEasePlaylist(
                    id: id,
                    name: MusicParse.string(item["name"]),
                    trackCount: MusicParse.int(item["trackCount"]),
                    coverURL: cover.isEmpty ? nil : URL(string: cover),
                    creator: MusicParse.string(MusicParse.dictionary(item["creator"])["nickname"]).nilIfEmpty
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func logout() {
        pollTask?.cancel()
        pollTask = nil
        if let url = URL(string: "https://music.163.com"),
           let cookies = HTTPCookieStorage.shared.cookies(for: url) {
            cookies.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        }
        KeychainStore.delete(account: "netease.cookie")
        cookieHeader = nil
        client.setNeteaseCookie(nil)
        isLoggedIn = false
        uid = nil
        profileName = nil
        playlists = []
        qrContent = nil
        qrStatus = ""
        syncStatus = ""
    }

    // MARK: - Playlist sync

    func syncPlaylists(to library: LibraryStore) async throws -> Int {
        guard isLoggedIn else { throw NetEaseAccountError.notLoggedIn }
        guard !playlists.isEmpty else {
            throw NetEaseAccountError.response("账号下没有可同步的歌单")
        }
        isSyncing = true
        defer { isSyncing = false }

        var imported = 0
        for playlist in playlists {
            if Task.isCancelled { throw NetEaseAccountError.cancelled }
            syncStatus = "正在同步 \(imported + 1)/\(playlists.count)：\(playlist.name)"
            let page = try await client.playlistDetail(source: "wy", id: playlist.id)
            library.upsertUserList(
                name: "网易云 · \(playlist.name)",
                source: "wy",
                sourceListId: playlist.id,
                tracks: page.items
            )
            imported += 1
        }
        syncStatus = "已同步 \(imported) 个歌单"
        return imported
    }

    // MARK: - Cookie helpers

    private var currentMusicU: String? {
        guard let cookieHeader else { return nil }
        for part in cookieHeader.split(separator: ";") {
            let item = part.trimmingCharacters(in: .whitespaces)
            if item.hasPrefix("MUSIC_U=") {
                return String(item.dropFirst("MUSIC_U=".count))
            }
        }
        return nil
    }

    private func saveCookie(_ value: String) {
        var pieces: [String: String] = [:]
        if let cookieHeader {
            for part in cookieHeader.split(separator: ";") {
                let item = part.trimmingCharacters(in: .whitespaces)
                guard let equals = item.firstIndex(of: "=") else { continue }
                let name = String(item[..<equals])
                let val = String(item[item.index(after: equals)...])
                if !name.isEmpty { pieces[name] = val }
            }
        }
        for part in value.split(separator: ";") {
            let item = part.trimmingCharacters(in: .whitespaces)
            guard let equals = item.firstIndex(of: "=") else { continue }
            let name = String(item[..<equals])
            let val = String(item[item.index(after: equals)...])
            if !name.isEmpty { pieces[name] = val }
        }
        let merged = pieces.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        guard !merged.isEmpty else { return }
        cookieHeader = merged
        client.setNeteaseCookie(merged)
        KeychainStore.set(Data(merged.utf8), account: "netease.cookie")
    }

    // MARK: - HTTP / cookies

    private func requestJSON(
        path: String,
        method: String = "GET",
        query: [(String, String)] = [],
        form: [String: String] = [:]
    ) async throws -> [String: Any] {
        guard var components = URLComponents(string: "https://music.163.com" + path) else {
            throw NetEaseAccountError.response("无效的接口地址")
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        guard let url = components.url else { throw NetEaseAccountError.response("无效的接口地址") }

        var headers: [String: String] = [
            "Referer": "https://music.163.com/",
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"
        ]
        if let cookieHeader { headers["Cookie"] = cookieHeader }

        var body: Data?
        if method == "POST" {
            var formComponents = URLComponents()
            formComponents.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
            body = Data((formComponents.percentEncodedQuery ?? "").utf8)
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        }

        let result = try await client.perform(url, method: method, headers: headers, body: body)
        captureCookies(from: result.response, url: url)
        guard (200..<300).contains(result.response.statusCode) else {
            throw NetEaseAccountError.response("HTTP \(result.response.statusCode)")
        }
        let object = try JSONSerialization.jsonObject(with: result.data, options: [.fragmentsAllowed])
        guard let dictionary = object as? [String: Any] else {
            throw NetEaseAccountError.response("响应不是 JSON 对象")
        }
        return dictionary
    }

    private func captureCookies(from response: HTTPURLResponse, url: URL) {
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            fields[String(describing: key)] = String(describing: value)
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        if !cookies.isEmpty {
            HTTPCookieStorage.shared.setCookies(cookies, for: url, mainDocumentURL: nil)
        }
        let all = HTTPCookieStorage.shared.cookies(for: URL(string: "https://music.163.com")!) ?? []
        let relevant = all.filter { ["MUSIC_U", "__csrf"].contains($0.name) }
        if !relevant.isEmpty {
            let value = relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            cookieHeader = value
            client.setNeteaseCookie(value)
            KeychainStore.set(Data(value.utf8), account: "netease.cookie")
        }
    }
}

private extension Optional where Wrapped == String {
    var nilIfEmpty: String? {
        guard let value = self, !value.isEmpty else { return nil }
        return value
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension Dictionary where Key == String, Value == Any {
    var nilIfEmpty: [String: Any]? {
        isEmpty ? nil : self
    }
}
