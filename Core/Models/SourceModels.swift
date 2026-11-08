import Foundation

struct SourceCapability: Codable, Hashable, Sendable {
    var name: String
    var type: String
    var actions: [String]
    var qualitys: [String]
}

struct SourceProfile: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var version: String?
    var author: String?
    var homepage: String?
    var fileName: String
    var sha256: String
    var enabled: Bool
    var sources: [String: SourceCapability]
    /// 在线导入时的原始直链；文件导入为 nil。
    var originURL: String?

    var scriptURL: URL {
        AppPaths.sourcesDirectory.appendingPathComponent(fileName)
    }
}

struct SourceHeader {
    var name: String
    var description: String?
    var version: String?
    var author: String?
    var homepage: String?

    static func parse(_ script: String) -> SourceHeader? {
        // Header comments are ordinary block comments at the beginning of the file.
        let head = String(script.prefix(4096))
        func value(_ key: String) -> String? {
            let pattern = "@\(key)\\s+([^\\n\\r*]+)"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let range = NSRange(head.startIndex..<head.endIndex, in: head)
            guard let match = regex.firstMatch(in: head, range: range),
                  let valueRange = Range(match.range(at: 1), in: head) else { return nil }
            return String(head[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let name = value("name"), !name.isEmpty else { return nil }
        return SourceHeader(name: name, description: value("description"),
                            version: value("version"), author: value("author"),
                            homepage: value("homepage"))
    }
}
