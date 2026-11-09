import Foundation
import Combine

struct SyncModePrompt: Identifiable, Equatable {
    let id = UUID()
    let serverName: String
}

@MainActor
final class SyncClient: ObservableObject {
    @Published private(set) var status: SyncStatus = .disconnected
    @Published private(set) var serverName: String = ""
    @Published private(set) var message: String = ""
    @Published private(set) var isConnected = false
    @Published var modePrompt: SyncModePrompt?

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var message2call: Message2Call?
    private var library: LibraryStore?
    private var keyInfo: SyncKeyInfo?
    private var baseURL: URL?
    private var pendingUpload = false

    private var modeContinuation: CheckedContinuation<String, Never>?

    func connect(baseURL: URL, authCode: String?, deviceName: String, library: LibraryStore) async {
        disconnect()
        status = .connecting
        message = "正在连接 \(baseURL.host ?? "")…"
        self.library = library
        self.baseURL = baseURL

        do {
            let info = try await SyncAuth.authenticate(baseURL: baseURL, authCode: authCode, deviceName: deviceName)
            keyInfo = info
            serverName = info.serverName ?? baseURL.host ?? "同步服务"
            let wsURL = try makeWebSocketURL(baseURL: baseURL, info: info)

            var request = URLRequest(url: wsURL)
            request.timeoutInterval = 30
            let socket = URLSession.shared.webSocketTask(with: request)
            self.socket = socket

            let m2c = Message2Call { [weak self] text in
                guard let self else { return }
                self.send(text)
            }
            m2c.onRequest = { [weak self] path, arguments in
                guard let self else { throw SyncError.cancelled }
                return try await self.handleRequest(path: path, arguments: arguments)
            }
            message2call = m2c
            socket.resume()
            status = .syncing
            message = "正在同步…"
            receiveTask = Task { [weak self] in
                await self?.receiveLoop(socket: socket)
            }
        } catch {
            status = .failed(error.localizedDescription)
            message = error.localizedDescription
            isConnected = false
        }
    }

    func resolveMode(_ mode: String) {
        modePrompt = nil
        if mode != "cancel" {
            // Remember the user's choice so automatic sync never asks again.
            UserDefaults.standard.set(mode, forKey: syncModeKey)
        }
        guard let continuation = modeContinuation else { return }
        modeContinuation = nil
        continuation.resume(returning: mode)
    }

    private var syncModeKey: String {
        "sync.mode.\(baseURL?.absoluteString ?? "default")"
    }

    private func requestMode() async -> String {
        // A saved choice is reused on every later launch (including auto-sync).
        if let saved = UserDefaults.standard.string(forKey: syncModeKey), !saved.isEmpty {
            return saved
        }
        return await withCheckedContinuation { continuation in
            modeContinuation = continuation
            modePrompt = SyncModePrompt(serverName: serverName.isEmpty ? "同步服务" : serverName)
        }
    }

    /// Push the current library to the server. This is intentionally a full
    /// overwrite action: it is simple, idempotent, and sufficient for a
    /// personal library. Later we can send the 12 fine-grained actions.
    func uploadLocalList() {
        guard isConnected else {
            pendingUpload = true
            return
        }
        guard let message2call, let library,
              let payload = try? jsonObject(library.snapshot()) else { return }
        Task {
            _ = try? await message2call.request(
                path: ["onListSyncAction"],
                arguments: [["action": "list_data_overwrite", "data": payload]]
            )
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        message2call?.cancelAll()
        message2call = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        isConnected = false
        pendingUpload = false
        if let modeContinuation {
            modeContinuation.resume(returning: "cancel")
            self.modeContinuation = nil
        }
        modePrompt = nil
        status = .disconnected
        message = ""
    }

    private func makeWebSocketURL(baseURL: URL, info: SyncKeyInfo) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let key = Data(base64Encoded: info.key) else {
            throw SyncError.invalidURL
        }
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/socket"
        let token = try SyncCrypto.aes128ECBEncrypt(Data(SyncCrypto.connectMessage.utf8), key: key)
        // 不要用 URLQueryItem 拼 query：Foundation 可能保留 base64 里的 "+"，
        // 而服务端用 querystring.parse 会把未转义的 "+" 当成空格，导致 WS 握手 401。
        func encode(_ value: String) -> String {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        }
        components.percentEncodedQuery = "i=\(encode(info.clientId))&t=\(encode(token.base64EncodedString()))"
        guard let url = components.url else { throw SyncError.invalidURL }
        return url
    }

    private func send(_ text: String) {
        guard let socket else { return }
        var payload = text
        if text.utf8.count > 1024 {
            if let compressed = try? Gzip.compress(Data(text.utf8)) {
                payload = "cg_" + compressed.base64EncodedString()
            }
        }
        Task {
            do { try await socket.send(.string(payload)) }
            catch { await MainActor.run { self.message = "发送失败：\(error.localizedDescription)" } }
        }
    }

    private func receiveLoop(socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                switch message {
                case .string(let text):
                    if text == "ping" { continue }
                    if let decoded = decodeIncoming(text) {
                        message2call?.receive(decoded)
                    }
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8), let decoded = decodeIncoming(text) {
                        message2call?.receive(decoded)
                    }
                default:
                    break
                }
            } catch {
                if !Task.isCancelled {
                    let nsError = error as NSError
                    let text: String
                    if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorBadServerResponse {
                        text = "同步服务拒绝了 WebSocket 连接（HTTP 401/403）。请检查连接码，或确认反向代理已转发 /socket 的 WebSocket 升级。"
                    } else {
                        text = error.localizedDescription
                    }
                    status = .failed(text)
                    self.message = text
                    isConnected = false
                }
                return
            }
        }
    }

    private func decodeIncoming(_ text: String) -> String? {
        guard text.hasPrefix("cg_") else { return text }
        guard let data = Data(base64Encoded: String(text.dropFirst(3))),
              let decompressed = try? Gzip.decompress(data),
              let json = String(data: decompressed, encoding: .utf8) else {
            return nil
        }
        return json
    }

    private func handleRequest(path: [String], arguments: [Any]) async throws -> Any {
        guard let method = path.first, let library else {
            throw SyncError.badResponse("同步请求缺少方法或本地库")
        }
        switch method {
        case "getEnabledFeatures":
            // 只启用列表同步。dislike 规则本机还没有实现，
            // 不能让服务端误以为支持，否则会用空数据覆盖远端 dislike 列表。
            return ["list": ["skipSnapshot": false]]

        case "list_sync_get_md5":
            let data = try JSONEncoder().encode(library.snapshot())
            let text = String(data: data, encoding: .utf8) ?? "{}"
            return SyncCrypto.md5Hex(text)

        case "list_sync_get_sync_mode":
            return await requestMode()

        case "list_sync_get_list_data":
            return try jsonObject(library.snapshot())

        case "list_sync_set_list_data":
            guard let first = arguments.first else { throw SyncError.badResponse("缺少 ListData") }
            let data: ListData = try decode(ListData.self, from: first)
            library.apply(data)
            return NSNull()

        case "list_sync_finished":
            status = .connected
            isConnected = true
            message = "已连接"
            return NSNull()

        case "onListSyncAction":
            guard let first = arguments.first else { throw SyncError.badResponse("缺少增量动作") }
            try applyAction(first, library: library)
            return NSNull()

        case "finished":
            status = .connected
            isConnected = true
            message = "同步完成"
            if pendingUpload {
                pendingUpload = false
                uploadLocalList()
            }
            return NSNull()

        case "dislike_sync_get_list_data":
            return ""
        case "dislike_sync_get_md5":
            return SyncCrypto.md5Hex("")
        case "dislike_sync_get_sync_mode":
            return "merge_remote_local"
        case "dislike_sync_set_list_data", "dislike_sync_finished", "onDislikeSyncAction":
            return NSNull()

        default:
            throw SyncError.badResponse("不支持的同步方法：\(method)")
        }
    }

    private struct UserListMeta: Codable {
        var id: String
        var name: String
        var source: String?
        var sourceListId: String?
        var locationUpdateTime: Int64?
    }

    private struct ListCreatePayload: Codable {
        var position: Int
        var listInfos: [UserListMeta]
    }

    private struct PositionPayload: Codable {
        var position: Int
        var ids: [String]
    }

    private struct MusicAddPayload: Codable {
        var id: String
        var musicInfos: [MusicInfo]
        var addMusicLocationType: String?
    }

    private struct MusicRemovePayload: Codable {
        var listId: String
        var ids: [String]
    }

    private struct MusicMovePayload: Codable {
        var fromId: String
        var toId: String
        var musicInfos: [MusicInfo]
        var addMusicLocationType: String?
    }

    private struct MusicOverwritePayload: Codable {
        var listId: String
        var musicInfos: [MusicInfo]
    }

    private struct MusicPositionPayload: Codable {
        var listId: String
        var position: Int
        var ids: [String]
    }

    private struct MusicUpdateItem: Codable {
        struct Value: Codable {
            var id: String
            var name: String?
            var singer: String?
            var source: String?
            var interval: String?
            var meta: JSONValue?
        }
        var id: String
        var musicInfo: Value
    }

    private func applyAction(_ raw: Any, library: LibraryStore) throws {
        guard let object = raw as? [String: Any],
              let action = object["action"] as? String else {
            throw SyncError.badResponse("增量动作格式错误")
        }
        guard let payload = object["data"] else {
            throw SyncError.badResponse("增量动作缺少 data")
        }
        var snapshot = library.snapshot()

        switch action {
        case "list_data_overwrite":
            snapshot = try decode(ListData.self, from: payload)

        case "list_create":
            let value: ListCreatePayload = try decode(ListCreatePayload.self, from: payload)
            let newLists = value.listInfos.map {
                UserListInfo(id: $0.id, name: $0.name, source: $0.source,
                             sourceListId: $0.sourceListId,
                             locationUpdateTime: $0.locationUpdateTime, list: [])
            }
            let index = min(max(0, value.position), snapshot.userList.count)
            snapshot.userList.insert(contentsOf: newLists, at: index)

        case "list_remove":
            let ids: [String] = try decode([String].self, from: payload)
            snapshot.userList.removeAll { ids.contains($0.id) }

        case "list_update":
            let values: [UserListMeta] = try decode([UserListMeta].self, from: payload)
            for value in values {
                guard let index = snapshot.userList.firstIndex(where: { $0.id == value.id }) else { continue }
                snapshot.userList[index].name = value.name
                snapshot.userList[index].source = value.source
                snapshot.userList[index].sourceListId = value.sourceListId
                snapshot.userList[index].locationUpdateTime = value.locationUpdateTime
            }

        case "list_update_position":
            let value: PositionPayload = try decode(PositionPayload.self, from: payload)
            reorderUserLists(&snapshot, ids: value.ids, position: value.position)

        case "list_music_add":
            let value: MusicAddPayload = try decode(MusicAddPayload.self, from: payload)
            addMusic(value.musicInfos, to: value.id, atTop: value.addMusicLocationType == "top", snapshot: &snapshot)

        case "list_music_move":
            let value: MusicMovePayload = try decode(MusicMovePayload.self, from: payload)
            removeMusic(ids: value.musicInfos.map(\.id), from: value.fromId, snapshot: &snapshot)
            addMusic(value.musicInfos, to: value.toId, atTop: value.addMusicLocationType == "top", snapshot: &snapshot)

        case "list_music_remove":
            let value: MusicRemovePayload = try decode(MusicRemovePayload.self, from: payload)
            removeMusic(ids: value.ids, from: value.listId, snapshot: &snapshot)

        case "list_music_overwrite":
            let value: MusicOverwritePayload = try decode(MusicOverwritePayload.self, from: payload)
            overwriteMusic(value.musicInfos, in: value.listId, snapshot: &snapshot)

        case "list_music_clear":
            let ids: [String] = try decode([String].self, from: payload)
            for id in ids { overwriteMusic([], in: id, snapshot: &snapshot) }

        case "list_music_update":
            let values: [MusicUpdateItem] = try decode([MusicUpdateItem].self, from: payload)
            for item in values {
                let listID = item.id
                let musicID = item.musicInfo.id
                func updated(_ track: MusicInfo) -> MusicInfo {
                    var track = track
                    if let value = item.musicInfo.name { track.name = value }
                    if let value = item.musicInfo.singer { track.singer = value }
                    if let value = item.musicInfo.source { track.source = value }
                    if let value = item.musicInfo.interval { track.interval = value }
                    if let value = item.musicInfo.meta { track.meta = value }
                    return track
                }
                switch listID {
                case "default":
                    if let index = snapshot.defaultList.firstIndex(where: { $0.id == musicID }) {
                        snapshot.defaultList[index] = updated(snapshot.defaultList[index])
                    }
                case "love":
                    if let index = snapshot.loveList.firstIndex(where: { $0.id == musicID }) {
                        snapshot.loveList[index] = updated(snapshot.loveList[index])
                    }
                default:
                    guard let listIndex = snapshot.userList.firstIndex(where: { $0.id == listID }),
                          let trackIndex = snapshot.userList[listIndex].list.firstIndex(where: { $0.id == musicID }) else { continue }
                    snapshot.userList[listIndex].list[trackIndex] = updated(snapshot.userList[listIndex].list[trackIndex])
                }
            }

        case "list_music_update_position":
            let value: MusicPositionPayload = try decode(MusicPositionPayload.self, from: payload)
            reorderMusic(&snapshot, listID: value.listId, ids: value.ids, position: value.position)

        default:
            throw SyncError.badResponse("不支持的增量动作：\(action)")
        }

        library.apply(snapshot)
    }

    private func addMusic(_ music: [MusicInfo], to listID: String, atTop: Bool, snapshot: inout ListData) {
        switch listID {
        case "default":
            let ids = Set(snapshot.defaultList.map(\.id))
            let values = music.filter { !ids.contains($0.id) }
            if atTop { snapshot.defaultList.insert(contentsOf: values, at: 0) } else { snapshot.defaultList.append(contentsOf: values) }
        case "love":
            let ids = Set(snapshot.loveList.map(\.id))
            let values = music.filter { !ids.contains($0.id) }
            if atTop { snapshot.loveList.insert(contentsOf: values, at: 0) } else { snapshot.loveList.append(contentsOf: values) }
        default:
            guard let index = snapshot.userList.firstIndex(where: { $0.id == listID }) else { return }
            let ids = Set(snapshot.userList[index].list.map(\.id))
            let values = music.filter { !ids.contains($0.id) }
            if atTop { snapshot.userList[index].list.insert(contentsOf: values, at: 0) } else { snapshot.userList[index].list.append(contentsOf: values) }
        }
    }

    private func removeMusic(ids: [String], from listID: String, snapshot: inout ListData) {
        switch listID {
        case "default": snapshot.defaultList.removeAll { ids.contains($0.id) }
        case "love": snapshot.loveList.removeAll { ids.contains($0.id) }
        default:
            guard let index = snapshot.userList.firstIndex(where: { $0.id == listID }) else { return }
            snapshot.userList[index].list.removeAll { ids.contains($0.id) }
        }
    }

    private func overwriteMusic(_ music: [MusicInfo], in listID: String, snapshot: inout ListData) {
        switch listID {
        case "default": snapshot.defaultList = music
        case "love": snapshot.loveList = music
        default:
            guard let index = snapshot.userList.firstIndex(where: { $0.id == listID }) else { return }
            snapshot.userList[index].list = music
        }
    }

    private func reorderUserLists(_ snapshot: inout ListData, ids: [String], position: Int) {
        let map = Dictionary(uniqueKeysWithValues: snapshot.userList.map { ($0.id, $0) })
        let moved = ids.compactMap { map[$0] }
        let remaining = snapshot.userList.filter { !ids.contains($0.id) }
        let index = min(max(0, position), remaining.count)
        snapshot.userList = Array(remaining.prefix(index)) + moved + Array(remaining.dropFirst(index))
    }

    private func reorderMusic(_ snapshot: inout ListData, listID: String, ids: [String], position: Int) {
        func reorder(_ list: inout [MusicInfo]) {
            let map = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            let moved = ids.compactMap { map[$0] }
            let remaining = list.filter { !ids.contains($0.id) }
            let index = min(max(0, position), remaining.count)
            list = Array(remaining.prefix(index)) + moved + Array(remaining.dropFirst(index))
        }
        switch listID {
        case "default": reorder(&snapshot.defaultList)
        case "love": reorder(&snapshot.loveList)
        default:
            guard let index = snapshot.userList.firstIndex(where: { $0.id == listID }) else { return }
            reorder(&snapshot.userList[index].list)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from any: Any) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: any)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }
}
