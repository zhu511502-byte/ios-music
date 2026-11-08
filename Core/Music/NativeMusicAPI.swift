import Foundation
import Combine

/// Native ports of the platform clients from lx-music-mobile
/// (`src/utils/musicSdk`). Search, playlists and leaderboards no longer need
/// the Ceru plugin or a JavaScript host.
final class NativeMusicAPI: ObservableObject, @unchecked Sendable {
    static let shared = NativeMusicAPI()

    let objectWillChange = ObservableObjectPublisher()
    private let session: URLSession
    private let defaultUserAgent = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36"
    private let cookieLock = NSLock()
    private var neteaseCookie: String?

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = .shared
        configuration.httpShouldSetCookies = true
        session = URLSession(configuration: configuration)
    }

    /// Set by NetEaseAccount after login. It is only attached to
    /// music.163.com requests, never to other platform hosts.
    func setNeteaseCookie(_ value: String?) {
        cookieLock.lock()
        neteaseCookie = value
        cookieLock.unlock()
    }

    /// Current stored NetEase cookie header (MUSIC_U/__csrf), if any.
    func neteaseCookie() -> String? {
        cookieLock.lock()
        defer { cookieLock.unlock() }
        return neteaseCookie
    }



    // MARK: - Public API

    func search(source: String, query: String, page: Int = 1, limit: Int = 25) async throws -> OnlinePage {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        switch source {
        case "tx": return try await searchTX(trimmed, page: page, limit: limit)
        case "wy": return try await searchWY(trimmed, page: page, limit: limit)
        case "kg": return try await searchKG(trimmed, page: page, limit: limit)
        case "kw": return try await searchKW(trimmed, page: page, limit: limit)
        case "mg": return try await searchMG(trimmed, page: page, limit: limit)
        default: throw MusicAPIError.unsupported(source)
        }
    }

    func rankBoards(source: String) -> [OnlineBoard] {
        switch source {
        case "tx":
            return [
                ("流行指数榜", "4"), ("热歌榜", "26"), ("新歌榜", "27"), ("飙升榜", "62"),
                ("说唱榜", "58"), ("电音榜", "57"), ("网络歌曲榜", "28"), ("内地榜", "5"),
                ("欧美榜", "3"), ("香港地区榜", "59"), ("韩国榜", "16"), ("日本榜", "17"),
                ("影视金曲榜", "29"), ("国风热歌榜", "65"), ("动漫音乐榜", "72")
            ].map { OnlineBoard(id: "tx_\($0.1)", name: $0.0, bangID: $0.1, artworkURL: nil, updateFrequency: nil, source: "tx") }
        case "wy":
            return [
                ("飙升榜", "19723756"), ("新歌榜", "3779629"), ("原创榜", "2884035"), ("热歌榜", "3778678"),
                ("说唱榜", "991319590"), ("古典榜", "71384707"), ("电音榜", "1978921795"), ("ACG榜", "71385702"),
                ("韩语榜", "745956260"), ("国风榜", "5059642708"), ("民谣榜", "5059661515"), ("欧美热歌榜", "2809513713")
            ].map { OnlineBoard(id: "wy_\($0.1)", name: $0.0, bangID: $0.1, artworkURL: nil, updateFrequency: nil, source: "wy") }
        case "kg":
            return [
                ("TOP500", "8888"), ("飙升榜", "6666"), ("蜂鸟流行音乐榜", "59703"), ("抖音热歌榜", "52144"),
                ("快手热歌榜", "52767"), ("DJ热歌榜", "24971"), ("网络红歌榜", "23784"), ("说唱先锋榜", "44412"),
                ("内地榜", "31308"), ("电音榜", "33160"), ("香港地区榜", "31313"), ("欧美榜", "31310"),
                ("ACG新歌榜", "33162"), ("韩国榜", "31311"), ("日本榜", "31312"), ("粤语金曲榜", "33165")
            ].map { OnlineBoard(id: "kg_\($0.1)", name: $0.0, bangID: $0.1, artworkURL: nil, updateFrequency: nil, source: "kg") }
        case "kw":
            return [
                ("飙升榜", "93"), ("新歌榜", "17"), ("热歌榜", "16"), ("抖音热歌榜", "158"),
                ("热评榜", "284"), ("ACG新歌榜", "290"), ("华语榜", "104"), ("粤语榜", "182"),
                ("欧美榜", "22"), ("韩语榜", "184"), ("日语榜", "183"), ("古风音乐榜", "278"),
                ("电音榜", "242"), ("经典怀旧榜", "26")
            ].map { OnlineBoard(id: "kw_\($0.1)", name: $0.0, bangID: $0.1, artworkURL: nil, updateFrequency: nil, source: "kw") }
        case "mg":
            return [
                ("新歌榜", "27553319"), ("热歌榜", "27186466"), ("原创榜", "27553408"),
                ("音乐风向榜", "75959118"), ("港台榜", "23189800"), ("内地榜", "23189399"),
                ("欧美榜", "19190036"), ("国风金曲榜", "83176390")
            ].map { OnlineBoard(id: "mg_\($0.1)", name: $0.0, bangID: $0.1, artworkURL: nil, updateFrequency: nil, source: "mg") }
        default:
            return []
        }
    }

    func rankList(source: String, boardID: String, page: Int = 1) async throws -> OnlinePage {
        switch source {
        case "tx": return try await rankTX(boardID, page: page)
        case "wy": return try await rankWY(boardID, page: page)
        case "kg": return try await rankKG(boardID, page: page)
        case "kw": return try await rankKW(boardID, page: page)
        case "mg": return try await rankMG(boardID, page: page)
        default: throw MusicAPIError.unsupported(source)
        }
    }

    func playlistList(source: String, page: Int = 1) async throws -> [OnlinePlaylist] {
        switch source {
        case "tx": return try await playlistsTX(page: page)
        case "wy": return try await playlistsWY(page: page)
        case "kw": return try await playlistsKW(page: page)
        case "mg": return try await playlistsMG(page: page)
        case "kg": return try await playlistsKG(page: page)
        default: throw MusicAPIError.unsupported(source)
        }
    }

    func playlistDetail(source: String, id: String, page: Int = 1) async throws -> OnlinePage {
        switch source {
        case "tx": return try await playlistDetailTX(id, page: page)
        case "wy": return try await playlistDetailWY(id, page: page)
        case "kw": return try await playlistDetailKW(id, page: page)
        case "mg": return try await playlistDetailMG(id, page: page)
        case "kg": return try await playlistDetailKG(id, page: page)
        default: throw MusicAPIError.unsupported(source)
        }
    }

    // MARK: - HTTP

    struct HTTPResult {
        var data: Data
        var response: HTTPURLResponse
    }

    func perform(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 15) async throws -> HTTPResult {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if url.host?.contains("music.163.com") == true,
           let cookie = neteaseCookie(),
           request.value(forHTTPHeaderField: "Cookie") == nil {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let body {
            request.httpBody = body
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MusicAPIError.invalidResponse("不是 HTTP 响应")
        }
        return HTTPResult(data: data, response: http)
    }

    func getJSON(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval = 15) async throws -> [String: Any] {
        let result = try await perform(url, headers: headers, timeout: timeout)
        guard (200..<300).contains(result.response.statusCode) else {
            throw MusicAPIError.http(result.response.statusCode)
        }
        return try MusicParse.decode(result.data)
    }

    func postJSON(_ url: URL, body: Any, headers: [String: String] = [:], timeout: TimeInterval = 15) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: body)
        var merged = headers
        if merged["Content-Type"] == nil { merged["Content-Type"] = "application/json" }
        let result = try await perform(url, method: "POST", headers: merged, body: data, timeout: timeout)
        guard (200..<300).contains(result.response.statusCode) else {
            throw MusicAPIError.http(result.response.statusCode)
        }
        return try MusicParse.decode(result.data)
    }

    func postForm(_ url: URL, fields: [String: String], headers: [String: String] = [:], timeout: TimeInterval = 15) async throws -> [String: Any] {
        var components = URLComponents()
        var items: [URLQueryItem] = []
        for (key, value) in fields { items.append(URLQueryItem(name: key, value: value)) }
        components.queryItems = items
        let body = Data((components.percentEncodedQuery ?? "").utf8)
        var merged = headers
        merged["Content-Type"] = "application/x-www-form-urlencoded"
        let result = try await perform(url, method: "POST", headers: merged, body: body, timeout: timeout)
        guard (200..<300).contains(result.response.statusCode) else {
            throw MusicAPIError.http(result.response.statusCode)
        }
        return try MusicParse.decode(result.data)
    }

    // MARK: - Shared helpers

    func makeURL(_ base: String, _ query: [(String, String?)] = []) throws -> URL {
        guard var components = URLComponents(string: base) else { throw MusicAPIError.badURL }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        guard let url = components.url else { throw MusicAPIError.badURL }
        return url
    }

    func makeTrack(
        source: String,
        songID: String,
        name: String,
        singer: String,
        albumName: String = "",
        albumID: String = "",
        interval: String? = nil,
        picURL: String = "",
        qualities: [ParsedQuality] = [],
        extra: [String: JSONValue] = [:],
        identity: String? = nil
    ) -> MusicInfo {
        var meta: [String: JSONValue] = [
            "songId": .string(songID),
            "albumName": .string(albumName),
            "picUrl": .string(picURL)
        ]
        if !albumID.isEmpty { meta["albumId"] = .string(albumID) }
        meta["qualitys"] = .array(qualities.map { quality in
            var object: [String: JSONValue] = ["type": .string(quality.type)]
            if let size = quality.size { object["size"] = .string(size) }
            for (key, value) in quality.extra { object[key] = .string(value) }
            return .object(object)
        })
        var qualityMap: [String: JSONValue] = [:]
        for quality in qualities {
            var object: [String: JSONValue] = [:]
            if let size = quality.size { object["size"] = .string(size) }
            for (key, value) in quality.extra { object[key] = .string(value) }
            qualityMap[quality.type] = .object(object)
        }
        meta["_qualitys"] = .object(qualityMap)
        for (key, value) in extra { meta[key] = value }
        return MusicInfo(
            id: identity ?? "\(source)_\(songID)",
            name: name,
            singer: singer,
            source: source,
            interval: interval,
            meta: .object(meta)
        )
    }
}

/// Parsed quality plus platform-specific fields (for example Kugou's hash).
struct ParsedQuality: Sendable {
    var type: String
    var size: String?
    var extra: [String: String] = [:]
}

enum MusicParse {
    static func decode(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let dictionary = object as? [String: Any] else {
            throw MusicAPIError.invalidResponse("顶层不是对象")
        }
        return dictionary
    }

    static func dictionary(_ value: Any?) -> [String: Any] {
        if let dictionary = value as? [String: Any] { return dictionary }
        return [:]
    }

    static func array(_ value: Any?) -> [Any] {
        value as? [Any] ?? []
    }

    static func objects(_ value: Any?) -> [[String: Any]] {
        (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    static func string(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    static func int(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }

    static func int64(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) ?? 0 }
        return 0
    }

    static func double(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) ?? 0 }
        return 0
    }

    static func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    static func htmlDecode(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var text = input
        let named: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&apos;": "'", "&nbsp;": " ", "&#39;": "'", "&#x27;": "'"
        ]
        for (key, value) in named { text = text.replacingOccurrences(of: key, with: value) }
        guard let regex = try? NSRegularExpression(pattern: "&#(x?[0-9A-Fa-f]+);") else { return text }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        for match in matches.reversed() {
            guard let full = Range(match.range, in: text),
                  let valueRange = Range(match.range(at: 1), in: text) else { continue }
            let raw = String(text[valueRange])
            let scalarValue: UInt32?
            if raw.lowercased().hasPrefix("x") {
                scalarValue = UInt32(String(raw.dropFirst()), radix: 16)
            } else {
                scalarValue = UInt32(raw)
            }
            if let scalarValue, let scalar = UnicodeScalar(scalarValue) {
                text.replaceSubrange(full, with: String(Character(scalar)))
            }
        }
        return text
    }

    static func formatPlayTime(_ seconds: Int) -> String {
        if seconds <= 0 { return "--/--" }
        let minutes = seconds / 60
        let rest = seconds % 60
        return String(format: "%02d:%02d", minutes, rest)
    }

    static func size(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        let index = min(Int(log(Double(bytes)) / log(1024)), units.count - 1)
        let value = Double(bytes) / pow(1024, Double(index))
        return String(format: "%.2f", value) + " " + units[index]
    }

    static func singer(names: [String]) -> String {
        names.filter { !$0.isEmpty }.joined(separator: "、")
    }
}
