import Foundation
import Combine
import SwiftUI

struct LibraryPlaylist: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable, Equatable { case system, user }
    var id: String
    var name: String
    var kind: Kind
    var count: Int
    var artwork: URL?
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var defaultList: [MusicInfo] = []
    @Published private(set) var loveList: [MusicInfo] = []
    @Published private(set) var userLists: [UserListInfo] = []

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    var onChange: (() -> Void)?
    private var suppressChangeNotification = false

    init(fileURL: URL = AppPaths.libraryFile) {
        self.fileURL = fileURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        load()
    }

    var playlists: [LibraryPlaylist] {
        [
            LibraryPlaylist(id: "default", name: "试听列表", kind: .system,
                            count: defaultList.count, artwork: defaultList.first?.picURL),
            LibraryPlaylist(id: "love", name: "我的收藏", kind: .system,
                            count: loveList.count, artwork: loveList.first?.picURL)
        ] + userLists.map {
            LibraryPlaylist(id: $0.id, name: $0.name, kind: .user,
                            count: $0.list.count, artwork: $0.list.first?.picURL)
        }
    }

    func tracks(for playlistID: String) -> [MusicInfo] {
        switch playlistID {
        case "default": return defaultList
        case "love": return loveList
        default: return userLists.first(where: { $0.id == playlistID })?.list ?? []
        }
    }

    func track(id: String) -> MusicInfo? {
        if let value = defaultList.first(where: { $0.id == id }) { return value }
        if let value = loveList.first(where: { $0.id == id }) { return value }
        for list in userLists {
            if let value = list.list.first(where: { $0.id == id }) { return value }
        }
        return nil
    }

    func snapshot() -> ListData {
        ListData(defaultList: defaultList, loveList: loveList, userList: userLists)
    }

    func apply(_ data: ListData) {
        suppressChangeNotification = true
        defaultList = data.defaultList
        loveList = data.loveList
        userLists = data.userList
        save()
        suppressChangeNotification = false
    }

    func add(_ music: MusicInfo, to playlistID: String = "default", atTop: Bool = false) {
        guard !tracks(for: playlistID).contains(where: { $0.id == music.id }) else { return }
        switch playlistID {
        case "default":
            if atTop { defaultList.insert(music, at: 0) } else { defaultList.append(music) }
        case "love":
            if atTop { loveList.insert(music, at: 0) } else { loveList.append(music) }
        default:
            guard let index = userLists.firstIndex(where: { $0.id == playlistID }) else { return }
            if atTop { userLists[index].list.insert(music, at: 0) } else { userLists[index].list.append(music) }
        }
        didChange()
    }

    func remove(_ musicID: String, from playlistID: String) {
        switch playlistID {
        case "default": defaultList.removeAll { $0.id == musicID }
        case "love": loveList.removeAll { $0.id == musicID }
        default:
            guard let index = userLists.firstIndex(where: { $0.id == playlistID }) else { return }
            userLists[index].list.removeAll { $0.id == musicID }
        }
        didChange()
    }

    func isLoved(_ musicID: String) -> Bool {
        loveList.contains { $0.id == musicID }
    }

    func toggleLove(_ music: MusicInfo) {
        if isLoved(music.id) {
            loveList.removeAll { $0.id == music.id }
        } else {
            loveList.insert(music, at: 0)
        }
        didChange()
    }

    @discardableResult
    func upsertUserList(name: String, source: String?, sourceListId: String?, tracks: [MusicInfo]) -> UserListInfo {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if let index = userLists.firstIndex(where: { $0.source == source && $0.sourceListId == sourceListId }) {
            userLists[index].name = name
            userLists[index].list = tracks
            userLists[index].locationUpdateTime = now
            didChange()
            return userLists[index]
        }

        let list = UserListInfo(
            id: UUID().uuidString,
            name: name,
            source: source,
            sourceListId: sourceListId,
            locationUpdateTime: now,
            list: tracks
        )
        userLists.append(list)
        didChange()
        return list
    }

    @discardableResult
    func createUserList(name: String) -> UserListInfo {
        let list = UserListInfo(id: UUID().uuidString, name: name, locationUpdateTime: Int64(Date().timeIntervalSince1970 * 1000))
        userLists.append(list)
        didChange()
        return list
    }

    func deleteUserList(id: String) {
        userLists.removeAll { $0.id == id }
        didChange()
    }

    func moveTracks(in playlistID: String, from source: IndexSet, to destination: Int) {
        switch playlistID {
        case "default":
            defaultList.move(fromOffsets: source, toOffset: destination)
        case "love":
            loveList.move(fromOffsets: source, toOffset: destination)
        default:
            guard let index = userLists.firstIndex(where: { $0.id == playlistID }) else { return }
            userLists[index].list.move(fromOffsets: source, toOffset: destination)
        }
        didChange()
    }

    private func didChange() {
        save()
        if !suppressChangeNotification { onChange?() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let value = try? decoder.decode(ListData.self, from: data) else { return }
        defaultList = value.defaultList
        loveList = value.loveList
        userLists = value.userList
    }

    private func save() {
        guard let data = try? encoder.encode(snapshot()) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
