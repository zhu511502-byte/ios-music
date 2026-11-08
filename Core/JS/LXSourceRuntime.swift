import Foundation
import JavaScriptCore
import Security

/// Runs one LX custom source script in JavaScriptCore.
///
/// This is deliberately *not* a plugin host: it loads the official
/// `user-api-preload.js` from lx-music-mobile (Apache-2.0) and exposes only
/// the five native hooks that script expects. The Android app uses QuickJS for
/// the same job; iOS ships JavaScriptCore, so no third-party JS runtime or
/// Ceru plugin is needed.
final class LXSourceRuntime: @unchecked Sendable {
    struct ScriptInfo: Sendable {
        var id: String
        var name: String
        var description: String
        var version: String
        var author: String
        var homepage: String
        var rawScript: String
    }

    private let queue = DispatchQueue(label: "app.lxplayer.lx-source", qos: .userInitiated)
    private let context: JSContext
    private let key = UUID().uuidString
    private let session: URLSession
    private let lock = NSLock()
    private let info: ScriptInfo

    private var capabilities: [String: SourceCapability] = [:]
    private var readyContinuation: CheckedContinuation<[String: SourceCapability], Error>?
    private var pendingResponses: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var pendingTasks: [String: URLSessionDataTask] = [:]
    private var timers: [Int: DispatchWorkItem] = [:]

    private init(info: ScriptInfo) throws {
        guard let context = JSContext() else { throw JSRuntimeError.contextUnavailable }
        self.context = context
        self.info = info
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
        context.exceptionHandler = { _, exception in
            if let exception { print("[LXSource] JS exception: \(exception)") }
        }
        installNativeHooks()
    }

    static func start(profile: SourceProfile, script: String) async throws -> LXSourceRuntime {
        let info = ScriptInfo(
            id: profile.id,
            name: profile.name,
            description: "",
            version: profile.version ?? "",
            author: profile.author ?? "",
            homepage: profile.homepage ?? "",
            rawScript: script
        )
        let runtime = try LXSourceRuntime(info: info)
        _ = try await runtime.load()
        return runtime
    }

    var supportedCapabilities: [String: SourceCapability] { capabilities }

    @discardableResult
    private func load() async throws -> [String: SourceCapability] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            readyContinuation = continuation
            lock.unlock()
            queue.async { self.loadOnQueue() }
            queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                self?.failReady(message: "音源脚本初始化超时")
            }
        }
    }

    private func loadOnQueue() {
        do {
            guard let url = Bundle.main.url(forResource: "user-api-preload", withExtension: "js") else {
                throw JSRuntimeError.bootstrapMissing
            }
            let preload = try String(contentsOf: url, encoding: .utf8)
            try evaluate(preload)
            guard let setup = context.objectForKeyedSubscript("lx_setup"), !setup.isUndefined else {
                throw JSRuntimeError.exception("user-api-preload.js 没有导出 lx_setup")
            }
            setup.call(withArguments: [
                key, info.id, info.name, info.description, info.version, info.author, info.homepage, info.rawScript
            ])
            try evaluate(info.rawScript)
        } catch {
            failReady(message: error.localizedDescription)
        }
    }

    private func evaluate(_ script: String) throws {
        context.exception = nil
        context.evaluateScript(script)
        if let exception = context.exception {
            context.exception = nil
            throw JSRuntimeError.exception(exception.toString() ?? "unknown")
        }
    }

    // MARK: - Native hooks

    private func installNativeHooks() {
        let call: @convention(block) (String, String, String) -> Void = { [weak self] key, action, data in
            guard let self, key == self.key else { return }
            self.handleNative(action: action, data: data)
        }
        context.setObject(call, forKeyedSubscript: "__lx_native_call__" as NSString)

        let str2b64: @convention(block) (String) -> String = { value in
            Data(value.utf8).base64EncodedString()
        }
        context.setObject(str2b64, forKeyedSubscript: "__lx_native_call__utils_str2b64" as NSString)

        let b642buf: @convention(block) (String) -> String = { value in
            let data = Data(base64Encoded: value) ?? Data()
            let bytes = data.map { Int(Int8(bitPattern: $0)) }
            return (try? JSONSerialization.data(withJSONObject: bytes)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        context.setObject(b642buf, forKeyedSubscript: "__lx_native_call__utils_b642buf" as NSString)

        let str2md5: @convention(block) (String) -> String = { value in
            MusicCrypto.md5Hex(value.removingPercentEncoding ?? value)
        }
        context.setObject(str2md5, forKeyedSubscript: "__lx_native_call__utils_str2md5" as NSString)

        let aes: @convention(block) (String, String, String, String) -> String = { data, key, iv, mode in
            (try? Self.aesEncrypt(data: data, key: key, iv: iv, mode: mode)) ?? ""
        }
        context.setObject(aes, forKeyedSubscript: "__lx_native_call__utils_aes_encrypt" as NSString)

        let rsa: @convention(block) (String, String, String) -> String = { data, key, padding in
            (try? Self.rsaEncrypt(data: data, publicKey: key, padding: padding)) ?? ""
        }
        context.setObject(rsa, forKeyedSubscript: "__lx_native_call__utils_rsa_encrypt" as NSString)

        let timeout: @convention(block) (Double, Double) -> Void = { [weak self] id, milliseconds in
            self?.scheduleTimer(id: Int(id), milliseconds: milliseconds)
        }
        context.setObject(timeout, forKeyedSubscript: "__lx_native_call__set_timeout" as NSString)
    }

    private func handleNative(action: String, data: String?) {
        var object: [String: Any] = [:]
        if let data, let bytes = data.data(using: .utf8),
           let raw = try? JSONSerialization.jsonObject(with: bytes),
           let parsed = raw as? [String: Any] {
            object = parsed
        }
        switch action {
        case "init":
            handleInit(object)
        case "request":
            handleHTTPRequest(object)
        case "cancelRequest":
            if let requestKey = object["requestKey"] as? String { cancelHTTP(requestKey) }
        case "response":
            handleScriptResponse(object)
        case "showUpdateAlert":
            print("[LXSource] update alert: \(object["log"] ?? "")")
        case "log":
            print("[LXSource] \(data ?? "")")
        default:
            break
        }
    }

    private func handleInit(_ object: [String: Any]) {
        guard let infoObject = object["info"] as? [String: Any],
              let sources = infoObject["sources"] as? [String: Any] else {
            failReady(message: (object["errorMessage"] as? String) ?? "音源没有返回能力信息")
            return
        }
        var result: [String: SourceCapability] = [:]
        for (source, raw) in sources {
            guard let value = raw as? [String: Any],
                  let type = value["type"] as? String, type == "music" else { continue }
            let actions = (value["actions"] as? [Any])?.compactMap { $0 as? String } ?? []
            let qualities = (value["qualitys"] as? [Any])?.compactMap { $0 as? String } ?? []
            result[source] = SourceCapability(name: source, type: type, actions: actions, qualitys: qualities)
        }
        guard !result.isEmpty else {
            failReady(message: "音源没有声明任何平台")
            return
        }
        lock.lock()
        capabilities = result
        let continuation = readyContinuation
        readyContinuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }

    private func failReady(message: String) {
        lock.lock()
        let continuation = readyContinuation
        readyContinuation = nil
        lock.unlock()
        continuation?.resume(throwing: JSRuntimeError.callback(message))
    }

    // MARK: - Script -> native HTTP

    private func handleHTTPRequest(_ object: [String: Any]) {
        guard let requestKey = object["requestKey"] as? String,
              let urlString = object["url"] as? String,
              let url = URL(string: urlString) else {
            return
        }
        let options: [String: Any]
        if let rawOptions = object["options"] as? [String: Any] { options = rawOptions } else { options = [:] }
        var request = URLRequest(url: url)
        request.httpMethod = ((options["method"] as? String) ?? "GET").uppercased()
        request.timeoutInterval = min(max(((options["timeout"] as? Double) ?? 13_000) / 1000, 1), 60)
        if let headers = options["headers"] as? [String: Any] {
            for (name, value) in headers {
                request.setValue(String(describing: value), forHTTPHeaderField: name)
            }
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36", forHTTPHeaderField: "User-Agent")
        }

        if let body = options["body"] {
            if let text = body as? String {
                request.httpBody = Data(text.utf8)
            } else if JSONSerialization.isValidJSONObject(body) {
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
            }
        } else if let form = options["form"] as? [String: Any] {
            request.httpBody = Self.formEncoded(form)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        } else if let formData = options["formData"] as? [String: Any] {
            request.httpBody = Self.formEncoded(formData)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        } else if let formData = options["formData"] as? String {
            request.httpBody = Data(formData.utf8)
        }

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.lock.lock()
            self.pendingTasks.removeValue(forKey: requestKey)
            self.lock.unlock()
            if let error {
                self.sendHTTPResponse(requestKey: requestKey, error: error.localizedDescription, response: nil)
                return
            }
            let http = response as? HTTPURLResponse
            let headers = http?.allHeaderFields.reduce(into: [String: String]()) { result, item in
                if let key = item.key as? String { result[key] = String(describing: item.value) }
            } ?? [:]
            var body: Any = NSNull()
            if let data {
                if options["binary"] as? Bool == true {
                    body = data.map { Int($0) }
                } else if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                    body = json
                } else {
                    body = String(data: data, encoding: .utf8) ?? ""
                }
            }
            let responseObject: [String: Any] = [
                "statusCode": http?.statusCode ?? 0,
                "statusMessage": http.map { HTTPURLResponse.localizedString(forStatusCode: $0.statusCode) } ?? "",
                "headers": headers,
                "body": body
            ]
            self.sendHTTPResponse(requestKey: requestKey, error: nil, response: responseObject)
        }
        lock.lock()
        pendingTasks[requestKey] = task
        lock.unlock()
        task.resume()
    }

    private func cancelHTTP(_ requestKey: String) {
        lock.lock()
        let task = pendingTasks.removeValue(forKey: requestKey)
        lock.unlock()
        task?.cancel()
    }

    private func sendHTTPResponse(requestKey: String, error: String?, response: [String: Any]?) {
        var payload: [String: Any] = ["requestKey": requestKey]
        if let error {
            payload["error"] = error
            payload["response"] = NSNull()
        } else {
            payload["error"] = NSNull()
            if let response { payload["response"] = response } else { payload["response"] = NSNull() }
        }
        callJS(action: "response", object: payload)
    }

    private static func formEncoded(_ values: [String: Any]) -> Data {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=")
        let text = values.map { pair in
            let encodedKey = pair.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? pair.key
            let encodedValue = String(describing: pair.value).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return Data(text.utf8)
    }

    // MARK: - Native -> script request

    func musicURL(for musicInfo: MusicInfo, quality: Quality) async throws -> URL {
        guard let capability = capabilities[musicInfo.source] else {
            throw JSRuntimeError.callback("该音源不支持平台 \(musicInfo.source)")
        }
        guard capability.actions.contains("musicUrl") else {
            throw JSRuntimeError.callback("该音源没有声明 musicUrl 能力")
        }
        let requested = capability.qualitys.contains(quality.rawValue)
            ? quality
            : (capability.qualitys.compactMap(Quality.init(rawValue:)).max(by: { $0.rank < $1.rank }) ?? quality)
        let musicObject = try makeSourceScriptMusicInfo(musicInfo)
        let requestKey = "request-" + UUID().uuidString
        let payload: [String: Any] = [
            "requestKey": requestKey,
            "data": [
                "source": musicInfo.source,
                "action": "musicUrl",
                "info": ["type": requested.rawValue, "musicInfo": musicObject]
            ]
        ]
        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
            lock.lock()
            pendingResponses[requestKey] = continuation
            lock.unlock()
            callJS(action: "request", object: payload)
            queue.asyncAfter(deadline: .now() + 25) { [weak self] in
                self?.failPending(requestKey, message: "音源解析播放地址超时")
            }
        }
        let data = result["data"] as? [String: Any]
        let urlString = (data?["url"] as? String) ?? (result["url"] as? String) ?? ""
        guard urlString.count <= 2048, let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw JSRuntimeError.callback("音源没有返回有效的播放地址")
        }
        return url
    }

    private func handleScriptResponse(_ object: [String: Any]) {
        guard let requestKey = object["requestKey"] as? String else { return }
        lock.lock()
        let continuation = pendingResponses.removeValue(forKey: requestKey)
        lock.unlock()
        guard let continuation else { return }
        if let status = object["status"] as? Bool, status == false {
            continuation.resume(throwing: JSRuntimeError.callback((object["errorMessage"] as? String) ?? "音源解析失败"))
            return
        }
        if let result = object["result"] as? [String: Any] {
            continuation.resume(returning: result)
        } else {
            continuation.resume(throwing: JSRuntimeError.callback("音源响应格式不正确"))
        }
    }

    private func failPending(_ requestKey: String, message: String) {
        lock.lock()
        let continuation = pendingResponses.removeValue(forKey: requestKey)
        lock.unlock()
        continuation?.resume(throwing: JSRuntimeError.callback(message))
    }

    private func callJS(action: String, object: [String: Any]) {
        callJSRaw(action: action, value: object)
    }

    private func callJSRaw(action: String, value: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        queue.async {
            guard let function = self.context.objectForKeyedSubscript("__lx_native__"), !function.isUndefined else { return }
            function.call(withArguments: [self.key, action, data])
            if let exception = self.context.exception {
                self.context.exception = nil
                print("[LXSource] callJS \(action) error: \(exception)")
            }
        }
    }

    private func scheduleTimer(id: Int, milliseconds: Double) {
        let work = DispatchWorkItem { [weak self] in
            self?.callJSRaw(action: "__set_timeout__", value: id)
        }
        lock.lock()
        timers[id]?.cancel()
        timers[id] = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + max(0, milliseconds) / 1000, execute: work)
    }

    private func makeSourceScriptMusicInfo(_ musicInfo: MusicInfo) throws -> Any {
        let encoded = try JSONEncoder().encode(musicInfo)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw JSRuntimeError.callback("无法编码歌曲信息")
        }
        guard var meta = object["meta"] as? [String: Any] else { return object }
        if let songId = meta["songId"] {
            if meta["songmid"] == nil { meta["songmid"] = songId }
            if object["songmid"] == nil { object["songmid"] = songId }
        }
        if let value = meta["picUrl"], object["img"] == nil { object["img"] = value }
        if let value = meta["qualitys"], object["types"] == nil { object["types"] = value }
        if let value = meta["_qualitys"], object["_types"] == nil { object["_types"] = value }
        for key in ["hash", "copyrightId", "strMediaMid", "albumMid", "albumId", "songId", "id"] {
            if let value = meta[key], object[key] == nil { object[key] = value }
        }
        object["meta"] = meta
        return object
    }

    // MARK: - Crypto hooks

    private static func aesEncrypt(data dataBase64: String, key keyBase64: String, iv ivBase64: String, mode: String) throws -> String {
        guard let data = Data(base64Encoded: dataBase64), let key = Data(base64Encoded: keyBase64) else {
            return ""
        }
        var input = data
        let options: CCOptions
        let ivData = Data(base64Encoded: ivBase64) ?? Data()
        let blockSize = Int(kCCBlockSizeAES128)
        if mode.contains("CBC") {
            options = CCOptions(kCCOptionPKCS7Padding)
        } else {
            options = CCOptions(kCCOptionECBMode)
            if input.count % blockSize != 0 {
                input.append(contentsOf: [UInt8](repeating: 0, count: blockSize - input.count % blockSize))
            }
        }
        var output = Data(count: input.count + blockSize)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBuffer in
            input.withUnsafeBytes { dataBuffer in
                key.withUnsafeBytes { keyBuffer in
                    ivData.withUnsafeBytes { ivBuffer in
                        CCCrypt(
                            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), options,
                            keyBuffer.baseAddress, key.count,
                            mode.contains("CBC") ? ivBuffer.baseAddress : nil,
                            dataBuffer.baseAddress, input.count,
                            outputBuffer.baseAddress, outputBuffer.count, &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return "" }
        output.removeSubrange(moved..<output.count)
        return output.base64EncodedString()
    }

    private static func rsaEncrypt(data dataBase64: String, publicKey keyBase64: String, padding: String) throws -> String {
        guard let data = Data(base64Encoded: dataBase64),
              let spki = Data(base64Encoded: keyBase64),
              let pkcs1 = derExtractRSAPublicKey(spki) else { return "" }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) else { return "" }
        let blockSize = SecKeyGetBlockSize(key)
        var input = data
        if input.count < blockSize {
            var padded = Data(repeating: 0, count: blockSize - input.count)
            padded.append(input)
            input = padded
        }
        let algorithm: SecKeyAlgorithm = padding.contains("OAEP") ? .rsaEncryptionOAEPSHA1 : .rsaEncryptionRaw
        guard let encrypted = SecKeyCreateEncryptedData(key, algorithm, input as CFData, &error) else { return "" }
        return (encrypted as Data).base64EncodedString()
    }

    /// Extract the PKCS#1 RSAPublicKey from an X.509 SubjectPublicKeyInfo.
    private static func derExtractRSAPublicKey(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        var index = 0
        func readLength() -> Int? {
            guard index < bytes.count else { return nil }
            let first = bytes[index]
            index += 1
            if first & 0x80 == 0 { return Int(first) }
            let count = Int(first & 0x7f)
            guard count > 0, index + count <= bytes.count else { return nil }
            var value = 0
            for _ in 0..<count {
                value = (value << 8) | Int(bytes[index])
                index += 1
            }
            return value
        }
        guard index < bytes.count, bytes[index] == 0x30 else { return nil }
        index += 1
        guard let totalLength = readLength(), index + totalLength <= bytes.count else { return nil }
        let end = index + totalLength
        guard index < end, bytes[index] == 0x30 else { return nil }
        index += 1
        guard let algorithmLength = readLength(), index + algorithmLength <= end else { return nil }
        index += algorithmLength
        guard index < end, bytes[index] == 0x03 else { return nil }
        index += 1
        guard let bitStringLength = readLength(), index + bitStringLength <= end else { return nil }
        guard bitStringLength > 1 else { return nil }
        let unused = bytes[index]
        guard unused == 0 else { return nil }
        index += 1
        return Data(bytes[index..<(index + bitStringLength - 1)])
    }
}
