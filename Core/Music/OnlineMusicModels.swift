import Foundation

/// A page of tracks returned by the built-in platform clients.
struct OnlinePage: Sendable {
    var items: [MusicInfo]
    var page: Int
    var total: Int
    var hasMore: Bool

    static let empty = OnlinePage(items: [], page: 1, total: 0, hasMore: false)
}

/// A playlist card in the Discover tab.
struct OnlinePlaylist: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var author: String?
    var artworkURL: URL?
    var trackCount: Int?
    var source: String
}

/// A leaderboard card in the Discover tab.
struct OnlineBoard: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var bangID: String
    var artworkURL: URL?
    var updateFrequency: String?
    var source: String
}

enum MusicAPIError: LocalizedError {
    case badURL
    case http(Int)
    case invalidResponse(String)
    case unsupported(String)
    case noData

    var errorDescription: String? {
        switch self {
        case .badURL: return "接口地址无效"
        case .http(let code): return "平台接口返回 HTTP \(code)"
        case .invalidResponse(let message): return "平台响应解析失败：\(message)"
        case .unsupported(let source): return "该平台暂不支持此操作（\(source)）"
        case .noData: return "平台没有返回数据"
        }
    }
}
