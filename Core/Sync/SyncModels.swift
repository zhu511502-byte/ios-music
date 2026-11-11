import Foundation

/// Merge strategy negotiated with an LX sync server when both sides already
/// contain lists. The value strings are the protocol's `list_sync_get_sync_mode`
/// return values.
enum SyncMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case mergeLocalRemote = "merge_local_remote"
    case mergeRemoteLocal = "merge_remote_local"
    case overwriteLocalRemote = "overwrite_local_remote"
    case overwriteRemoteLocal = "overwrite_remote_local"
    case overwriteLocalRemoteFull = "overwrite_local_remote_full"
    case overwriteRemoteLocalFull = "overwrite_remote_local_full"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mergeLocalRemote: return "以本机为主合并"
        case .mergeRemoteLocal: return "以远端为主合并"
        case .overwriteLocalRemote: return "用本机覆盖远端"
        case .overwriteRemoteLocal: return "用远端覆盖本机"
        case .overwriteLocalRemoteFull: return "本机完整覆盖远端"
        case .overwriteRemoteLocalFull: return "远端完整覆盖本机"
        }
    }

    var detail: String {
        switch self {
        case .mergeLocalRemote: return "保留双方歌曲，重复歌曲以本机为准。"
        case .mergeRemoteLocal: return "保留双方歌曲，重复歌曲以远端为准。"
        case .overwriteLocalRemote: return "本机列表覆盖远端，保留远端独有的用户歌单。"
        case .overwriteRemoteLocal: return "远端列表覆盖本机，保留本机独有的用户歌单。"
        case .overwriteLocalRemoteFull: return "删除远端独有的用户歌单，慎用。"
        case .overwriteRemoteLocalFull: return "删除本机独有的用户歌单，慎用。"
        }
    }
}


struct SyncKeyInfo: Codable, Sendable {
    var clientId: String
    var key: String
    var deviceName: String?
    var isMobile: Bool?
    var serverName: String?
}

enum SyncStatus: Equatable, Sendable {
    case disconnected
    case connecting
    case syncing
    case connected
    case failed(String)

    var label: String {
        switch self {
        case .disconnected: return "未连接"
        case .connecting: return "连接中…"
        case .syncing: return "同步中…"
        case .connected: return "已连接"
        case .failed(let message): return message
        }
    }
}

enum SyncError: LocalizedError {
    case invalidURL
    case badHello(String)
    case http(Int, String)
    case missingAuthCode
    case authFailed
    case authExpired
    case badResponse(String)
    case crypto(String)
    case webSocket(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "同步服务地址无效"
        case .badHello(let value): return "不是兼容的洛雪同步服务：\(value)"
        case .http(let code, let message):
            if code == 401 {
                return "同步服务拒绝鉴权（HTTP 401）。请重新输入服务端连接码；如果刚改过连接码或重置过服务端数据，这是正常现象。"
            }
            if code == 403 {
                return "同步服务拒绝访问（HTTP 403）：\(message)"
            }
            return "同步服务返回 HTTP \(code)：\(message)"
        case .missingAuthCode: return "请输入连接码"
        case .authFailed: return "连接码错误，或服务端已重置设备密钥；请重新输入连接码"
        case .authExpired: return "设备密钥已失效（服务端可能重置过数据或更换了连接码）；请重新输入连接码"
        case .badResponse(let message): return "同步响应异常：\(message)"
        case .crypto(let message): return "加密失败：\(message)"
        case .webSocket(let message): return "WebSocket 错误：\(message)"
        case .cancelled: return "同步已取消"
        }
    }
}
