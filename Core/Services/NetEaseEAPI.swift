import Foundation
import UIKit

/// NetEase's EAPI request format, ported from kunyin's `NeteaseCrypto`.
///
/// The plain `/api/login/qrcode/*` endpoints no longer behave consistently;
/// the mobile client signs every request with AES-128-ECB over
/// `path-36cd479b6b5-json-36cd479b6b5-md5` and posts it to
/// `interface.music.163.com/eapi...`. The QR login in particular must use
/// `type=3` and read `MUSIC_U` from the poll response's `Set-Cookie`.
enum NetEaseEAPI {
    struct Result {
        let json: [String: Any]
        let cookie: String?
        let statusCode: Int
    }

    private static let key = Data("e82ckenh8dichen8".utf8)
    private static let appVersion = "3.1.17.204416"
    private static let versionCode = "140"
    private static let osVersion = "Microsoft-Windows-10-Professional-build-19045-64bit"
    private static let resolution = "1920x1080"
    private static let channel = "netease"
    private static let userAgent = "NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)"

    static func perform(
        path: String,
        data: [String: Any],
        musicU: String? = nil
    ) async throws -> Result {
        let request = try build(path: path, data: data, musicU: musicU)
        let response = try await NativeMusicAPI.shared.perform(
            request.url,
            method: "POST",
            headers: request.headers,
            body: request.body,
            timeout: 20
        )
        guard (200..<300).contains(response.response.statusCode) else {
            throw NetEaseAccountError.response("HTTP \(response.response.statusCode)")
        }
        let object = try JSONSerialization.jsonObject(with: response.data, options: [.fragmentsAllowed])
        guard let json = object as? [String: Any] else {
            throw NetEaseAccountError.response("响应不是 JSON 对象")
        }
        return Result(
            json: json,
            cookie: cookieHeader(from: response.response, url: request.url),
            statusCode: response.response.statusCode
        )
    }

    private struct Request {
        let url: URL
        let headers: [String: String]
        let body: Data
    }

    private static func build(path: String, data: [String: Any], musicU: String?) throws -> Request {
        var header: [String: String] = [
            "osver": osVersion,
            "deviceId": deviceID(),
            "os": "pc",
            "appver": appVersion,
            "versioncode": versionCode,
            "mobilename": "",
            "buildver": String(Int(Date().timeIntervalSince1970)),
            "resolution": resolution,
            "__csrf": "",
            "channel": channel,
            "requestId": requestID()
        ]
        if let musicU, !musicU.isEmpty {
            header["MUSIC_U"] = musicU
        }

        var payload = data
        payload["header"] = header
        let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard let json = String(data: jsonData, encoding: .utf8) else {
            throw NetEaseAccountError.response("无法序列化登录参数")
        }

        let digest = MusicCrypto.md5Hex("nobody\(path)use\(json)md5forencrypt")
        let plain = "\(path)-36cd479b6b5-\(json)-36cd479b6b5-\(digest)"
        let encrypted = try MusicCrypto.aes128ECBPKCS7(Data(plain.utf8), key: key)
        let params = encrypted.map { String(format: "%02X", $0) }.joined()

        let suffix = path.hasPrefix("/api") ? String(path.dropFirst(4)) : path
        guard let url = URL(string: "https://interface.music.163.com/eapi\(suffix)") else {
            throw NetEaseAccountError.response("无效的 EAPI 地址")
        }
        let cookie = header.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        return Request(
            url: url,
            headers: [
                "User-Agent": userAgent,
                "Accept": "application/json, text/plain, */*",
                "Content-Type": "application/x-www-form-urlencoded",
                "Cookie": cookie
            ],
            body: Data("params=\(params)".utf8)
        )
    }

    private static func cookieHeader(from response: HTTPURLResponse, url: URL) -> String? {
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            fields[String(describing: key)] = String(describing: value)
        }
        var cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        if cookies.isEmpty,
           let stored = HTTPCookieStorage.shared.cookies(for: URL(string: "https://music.163.com")!) {
            cookies = stored
        }
        let selected = cookies.filter { $0.name == "MUSIC_U" || $0.name == "__csrf" }
        if !selected.isEmpty {
            return selected.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }

        let raw = fields.first { $0.key.lowercased() == "set-cookie" }?.value ?? ""
        var pieces: [String] = []
        for name in ["MUSIC_U", "__csrf"] {
            if let range = raw.range(of: "\(name)=[^;\\s]+", options: .regularExpression) {
                pieces.append(String(raw[range]))
            }
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: "; ")
    }

    private static func requestID() -> String {
        "\(Int(Date().timeIntervalSince1970))_\(String(format: "%04d", Int.random(in: 0...9999)))"
    }

    private static func deviceID() -> String {
        let key = "netease.eapi.deviceID"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty {
            return saved
        }
        let hex = "0123456789ABCDEF"
        let value = String((0..<52).map { _ in hex.randomElement() ?? "0" })
        UserDefaults.standard.set(value, forKey: key)
        return value
    }
}
