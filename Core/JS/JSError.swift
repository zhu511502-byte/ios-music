import Foundation

enum JSRuntimeError: LocalizedError {
    case contextUnavailable
    case bootstrapMissing
    case exception(String)
    case callback(String)
    case native(String)

    var errorDescription: String? {
        switch self {
        case .contextUnavailable: return "无法创建 JavaScript 运行时"
        case .bootstrapMissing: return "缺少 user-api-preload.js 资源"
        case .exception(let message): return "JavaScript 异常：\(message)"
        case .callback(let message): return "音源脚本失败：\(message)"
        case .native(let message): return "原生调用失败：\(message)"
        }
    }
}
