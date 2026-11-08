import Foundation
import Combine
import CryptoKit

@MainActor
final class SourceStore: ObservableObject {
    @Published private(set) var profiles: [SourceProfile] = []
    @Published var selectedID: String? {
        didSet { UserDefaults.standard.set(selectedID, forKey: "sources.selectedID") }
    }

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL = AppPaths.sourcesFile) {
        self.fileURL = fileURL
        encoder.outputFormatting = [.sortedKeys]
        selectedID = UserDefaults.standard.string(forKey: "sources.selectedID")
        load()
    }

    var selectedProfile: SourceProfile? {
        if let id = selectedID, let profile = profiles.first(where: { $0.id == id }) { return profile }
        return profiles.first(where: { $0.enabled })
    }

    func profile(id: String) -> SourceProfile? {
        profiles.first { $0.id == id }
    }

    @discardableResult
    func importScript(from url: URL) throws -> SourceProfile {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        return try importScript(data: data, originURL: nil)
    }

    /// 文件导入和在线导入共用同一套校验 / 落盘逻辑。
    /// `originURL` 只作为来源记录，方便以后做「检查更新」。
    @discardableResult
    func importScript(data: Data, originURL: URL?) throws -> SourceProfile {
        guard data.count <= 2 * 1024 * 1024 else { throw SourceError.tooLarge }
        guard let script = String(data: data, encoding: .utf8) else { throw SourceError.notUTF8 }
        guard let header = SourceHeader.parse(script) else { throw SourceError.missingHeader }

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let existing = profiles.first(where: { $0.sha256 == digest }) {
            if selectedID == nil { selectedID = existing.id }
            return existing
        }

        let fileName = UUID().uuidString + ".js"
        let destination = AppPaths.sourcesDirectory.appendingPathComponent(fileName)
        try data.write(to: destination, options: .atomic)

        let profile = SourceProfile(
            id: UUID().uuidString,
            name: header.name,
            version: header.version,
            author: header.author,
            homepage: header.homepage,
            fileName: fileName,
            sha256: digest,
            enabled: true,
            sources: [:],
            originURL: originURL?.absoluteString
        )
        profiles.append(profile)
        if selectedID == nil { selectedID = profile.id }
        save()
        return profile
    }

    func remove(_ profile: SourceProfile) {
        try? FileManager.default.removeItem(at: profile.scriptURL)
        profiles.removeAll { $0.id == profile.id }
        if selectedID == profile.id { selectedID = profiles.first?.id }
        save()
    }

    func setCapabilities(_ sources: [String: SourceCapability], for profileID: String) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[index].sources = sources
        save()
    }

    func script(for profile: SourceProfile) throws -> String {
        try String(contentsOf: profile.scriptURL, encoding: .utf8)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let value = try? decoder.decode([SourceProfile].self, from: data) else { return }
        profiles = value
    }

    private func save() {
        guard let data = try? encoder.encode(profiles) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

enum SourceError: LocalizedError {
    case tooLarge, notUTF8, missingHeader, invalidScript
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .tooLarge: return "脚本文件超过 2MB"
        case .notUTF8: return "脚本不是 UTF-8 编码"
        case .missingHeader: return "缺少 @name 头部信息"
        case .invalidScript: return "音源脚本初始化失败"
        case .httpStatus(let code): return "下载音源失败：HTTP \(code)。请确认是脚本文件的直链（raw 链接）"
        }
    }
}
