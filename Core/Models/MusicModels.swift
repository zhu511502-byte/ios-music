import Foundation

enum Quality: String, Codable, CaseIterable, Sendable, Identifiable, Hashable {
    case k128 = "128k"
    case k320 = "320k"
    case flac
    case flac24bit
    case k192 = "192k"
    case ape
    case wav

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .k128: return "128K"
        case .k320: return "320K"
        case .flac: return "FLAC"
        case .flac24bit: return "FLAC 24bit"
        case .k192: return "192K"
        case .ape: return "APE"
        case .wav: return "WAV"
        }
    }

    var rank: Int {
        switch self {
        case .k128: return 10
        case .k320: return 20
        case .flac: return 30
        case .flac24bit: return 40
        case .k192: return 15
        case .ape: return 35
        case .wav: return 45
        }
    }

    /// Human-friendly quality class shown under the playback progress bar.
    var qualityTitle: String {
        switch self {
        case .flac, .flac24bit, .wav, .ape:
            return "无损音质"
        case .k320:
            return "高品质"
        case .k192, .k128:
            return "标准音质"
        }
    }
}

struct QualityInfo: Codable, Hashable, Sendable {
    var type: String
    var size: String?
}

struct MusicInfo: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var singer: String
    var source: String
    var interval: String?
    var meta: JSONValue

    enum CodingKeys: String, CodingKey {
        case id, name, singer, source, interval, meta
    }

    init(id: String, name: String, singer: String, source: String, interval: String?, meta: JSONValue) {
        self.id = id
        self.name = name
        self.singer = singer
        self.source = source
        self.interval = interval
        self.meta = meta
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        singer = try container.decodeIfPresent(String.self, forKey: .singer) ?? ""
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        interval = try container.decodeIfPresent(String.self, forKey: .interval)
        meta = try container.decodeIfPresent(JSONValue.self, forKey: .meta) ?? .object([:])
    }

    var songID: String? {
        if let value = meta["songId"]?.stringValue { return value }
        if let value = meta["songId"]?.intValue { return String(value) }
        return nil
    }

    var albumName: String? { meta["albumName"]?.stringValue }
    var picURL: URL? {
        var value = meta["picUrl"]?.stringValue ?? ""
        if value.isEmpty, source == "tx",
           let albumMid = meta["albumMid"]?.stringValue,
           !albumMid.isEmpty, albumMid != "空" {
            value = "https://y.gtimg.cn/music/photo_new/T002R500x500M000\(albumMid).jpg"
        }
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("//") { value = "https:" + value }
        return URL(string: value)
    }

    var qualitys: [QualityInfo] {
        meta["qualitys"]?.arrayValue?.compactMap { value in
            guard let object = value.objectValue,
                  let type = object["type"]?.stringValue else { return nil }
            return QualityInfo(type: type, size: object["size"]?.stringValue)
        } ?? []
    }

    var availableQualities: [Quality] {
        let known = Set(qualitys.map(\.type))
        return Quality.allCases.filter { known.contains($0.rawValue) }.sorted { $0.rank < $1.rank }
    }

    var localFilePath: String? { meta["filePath"]?.stringValue }
}

struct UserListInfo: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var source: String?
    var sourceListId: String?
    var locationUpdateTime: Int64?
    var list: [MusicInfo]

    enum CodingKeys: String, CodingKey {
        case id, name, source, sourceListId, locationUpdateTime, list
    }

    init(id: String, name: String, source: String? = nil, sourceListId: String? = nil,
         locationUpdateTime: Int64? = nil, list: [MusicInfo] = []) {
        self.id = id
        self.name = name
        self.source = source
        self.sourceListId = sourceListId
        self.locationUpdateTime = locationUpdateTime
        self.list = list
    }
}

struct ListData: Codable, Sendable {
    var defaultList: [MusicInfo]
    var loveList: [MusicInfo]
    var userList: [UserListInfo]

    init(defaultList: [MusicInfo] = [], loveList: [MusicInfo] = [], userList: [UserListInfo] = []) {
        self.defaultList = defaultList
        self.loveList = loveList
        self.userList = userList
    }
}

extension MusicInfo {
    static func localFile(_ url: URL) -> MusicInfo {
        let path = url.path
        return MusicInfo(
            id: "local_\(path)",
            name: url.deletingPathExtension().lastPathComponent,
            singer: "",
            source: "local",
            interval: nil,
            meta: .object([
                "songId": .string(path),
                "albumName": .string(""),
                "filePath": .string(path),
                "ext": .string(url.pathExtension)
            ])
        )
    }
}
