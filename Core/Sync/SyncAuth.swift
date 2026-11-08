import Foundation

enum SyncAuth {
    static func authenticate(baseURL: URL, authCode: String?, deviceName: String) async throws -> SyncKeyInfo {
        let hello = try await requestText(baseURL.appendingPathComponent("hello"))
        guard hello == SyncCrypto.helloMessage else {
            if hello.hasPrefix("Hello~::^-^::") {
                throw SyncError.badHello(hello)
            }
            throw SyncError.badHello(hello)
        }

        let idText = try await requestText(baseURL.appendingPathComponent("id"))
        let prefix = "OjppZDo6"
        guard idText.hasPrefix(prefix) else {
            throw SyncError.badResponse("服务端 ID 格式不正确")
        }
        let serverID = String(idText.dropFirst(prefix.count))

        let trimmedCode = authCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedCode.isEmpty {
            let keyInfo = try await codeAuth(baseURL: baseURL, authCode: trimmedCode, deviceName: deviceName)
            let stored = SyncKeyInfo(
                clientId: keyInfo.clientId,
                key: keyInfo.key,
                deviceName: deviceName,
                isMobile: true,
                serverName: keyInfo.serverName
            )
            save(stored, serverID: serverID)
            return stored
        }

        guard let stored = load(serverID: serverID) else {
            throw SyncError.missingAuthCode
        }
        do {
            try await keyAuth(baseURL: baseURL, keyInfo: stored, deviceName: deviceName)
            return stored
        } catch SyncError.http(let code, _) where code == 401 {
            // 服务端重置数据目录、更换连接码或删除设备后，旧 key 会永久失效。
            // 清掉本地缓存，避免用户每次都被同一个 401 卡住。
            KeychainStore.delete(account: "sync.\(serverID)")
            throw SyncError.authExpired
        }
    }

    static func load(serverID: String) -> SyncKeyInfo? {
        guard let data = KeychainStore.get(account: "sync.\(serverID)") else { return nil }
        return try? JSONDecoder().decode(SyncKeyInfo.self, from: data)
    }

    static func save(_ info: SyncKeyInfo, serverID: String) {
        guard let data = try? JSONEncoder().encode(info) else { return }
        KeychainStore.set(data, account: "sync.\(serverID)")
    }

    private static func codeAuth(baseURL: URL, authCode: String, deviceName: String) async throws -> SyncKeyInfo {
        let key = SyncCrypto.authKey(from: authCode)
        let rsa = try SyncCrypto.RSAKeyPair.generate()
        let message = "\(SyncCrypto.authMessage)\n\(rsa.publicKeySPKIBase64)\n\(deviceName)\nlx_music_mobile"
        let encrypted = try SyncCrypto.aes128ECBEncrypt(Data(message.utf8), key: key)
        let response = try await request(
            baseURL.appendingPathComponent("ah"),
            method: "POST",
            headers: ["m": encrypted.base64EncodedString()]
        )
        guard let responseData = Data(base64Encoded: response.body) else {
            throw SyncError.badResponse("鉴权响应不是 Base64")
        }
        let plain = try SyncCrypto.rsaDecryptOAEP(responseData, privateKey: rsa.privateKey)
        return try JSONDecoder().decode(SyncKeyInfo.self, from: plain)
    }

    private static func keyAuth(baseURL: URL, keyInfo: SyncKeyInfo, deviceName: String) async throws {
        guard let key = Data(base64Encoded: keyInfo.key) else {
            throw SyncError.authFailed
        }
        let message = SyncCrypto.authMessage + deviceName
        let encrypted = try SyncCrypto.aes128ECBEncrypt(Data(message.utf8), key: key)
        let response = try await request(
            baseURL.appendingPathComponent("ah"),
            method: "POST",
            headers: [
                "i": keyInfo.clientId,
                "m": encrypted.base64EncodedString()
            ]
        )
        guard let data = Data(base64Encoded: response.body),
              let decrypted = try? SyncCrypto.aes128ECBDecrypt(data, key: key),
              String(data: decrypted, encoding: .utf8) == SyncCrypto.helloMessage else {
            throw SyncError.authFailed
        }
    }

    private struct HTTPResult { let status: Int; let body: String }

    private static func requestText(_ url: URL) async throws -> String {
        let result = try await request(url, method: "GET", headers: [:])
        return result.body
    }

    private static func request(_ url: URL, method: String, headers: [String: String]) async throws -> HTTPResult {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let body = String(data: data, encoding: .utf8) ?? ""
        guard let code = http?.statusCode, (200..<300).contains(code) else {
            throw SyncError.http(http?.statusCode ?? 0, body)
        }
        return HTTPResult(status: code, body: body)
    }
}
