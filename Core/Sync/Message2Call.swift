import Foundation

/// Implementation of the `message2call@0.1.3` wire protocol used by LX sync.
@MainActor
final class Message2Call {
    typealias RequestHandler = (_ path: [String], _ arguments: [Any]) async throws -> Any

    private var pending: [String: CheckedContinuation<Any, Error>] = [:]
    private let sendText: (String) -> Void
    var onRequest: RequestHandler?

    init(sendText: @escaping (String) -> Void) {
        self.sendText = sendText
    }

    func request(path: [String], arguments: [Any] = []) async throws -> Any {
        let name = path.joined(separator: ".") + "__" + String(Int.random(in: 1...999_999_999))
        return try await withCheckedThrowingContinuation { continuation in
            pending[name] = continuation
            let object: [String: Any] = [
                "name": name,
                "path": path,
                "data": arguments
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: object),
                  let text = String(data: data, encoding: .utf8) else {
                pending.removeValue(forKey: name)
                continuation.resume(throwing: SyncError.badResponse("无法编码同步请求"))
                return
            }
            sendText(text)
        }
    }

    func receive(_ text: String) {
        guard let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any] else {
            return
        }

        if let path = object["path"] as? [String], !path.isEmpty {
            let name = (object["name"] as? String) ?? ""
            let arguments = (object["data"] as? [Any]) ?? []
            Task { [weak self] in
                guard let self, let handler = self.onRequest else { return }
                do {
                    let result = try await handler(path, arguments)
                    self.sendResponse(name: name, data: result)
                } catch {
                    self.sendError(name: name, message: error.localizedDescription)
                }
            }
            return
        }

        guard let name = object["name"] as? String,
              let continuation = pending.removeValue(forKey: name) else { return }
        if let error = object["error"] as? String, !error.isEmpty {
            continuation.resume(throwing: SyncError.badResponse(error))
        } else {
            continuation.resume(returning: object["data"] ?? NSNull())
        }
    }

    func cancelAll() {
        let values = pending.values
        pending.removeAll()
        for continuation in values {
            continuation.resume(throwing: SyncError.cancelled)
        }
    }

    private func sendResponse(name: String, data: Any) {
        let object: [String: Any] = ["name": name, "error": NSNull(), "data": data]
        guard let encoded = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: encoded, encoding: .utf8) else { return }
        sendText(text)
    }

    private func sendError(name: String, message: String) {
        let object: [String: Any] = ["name": name, "error": message]
        guard let encoded = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: encoded, encoding: .utf8) else { return }
        sendText(text)
    }
}
