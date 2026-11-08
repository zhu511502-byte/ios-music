import Foundation

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
