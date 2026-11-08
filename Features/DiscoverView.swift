import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var music: NativeMusicAPI

    private struct SourceOption: Identifiable {
        let id: String
        let name: String
    }

    private enum Mode: String, CaseIterable, Identifiable, Equatable, Hashable {
        case playlists = "歌单"
        case charts = "排行榜"
        var id: String { rawValue }
    }

    private let sources: [SourceOption] = [
        SourceOption(id: "tx", name: "QQ"),
        SourceOption(id: "wy", name: "网易"),
        SourceOption(id: "kg", name: "酷狗"),
        SourceOption(id: "kw", name: "酷我"),
        SourceOption(id: "mg", name: "咪咕")
    ]

    @State private var mode: Mode = .playlists
    @State private var source = "tx"
    @State private var playlists: [OnlinePlaylist] = []
    @State private var boards: [OnlineBoard] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("内容", selection: $mode) {
                    ForEach(Mode.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .onChange(of: mode) { _ in load() }

                sourcePicker
                content
            }
            .background(Color.clear)
            .navigationTitle("发现")
            .task { load() }
        }
    }

    private var sourcePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sources) { item in
                    Button {
                        source = item.id
                        load()
                    } label: {
                        Text(item.name)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(source == item.id ? .white : AppTheme.secondaryText)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(source == item.id ? AppTheme.accent : AppTheme.card, in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("加载中…").frame(maxWidth: .infinity, maxHeight: .infinity).tint(AppTheme.accent)
        } else if let errorMessage {
            EmptyStateView(icon: "wifi.exclamationmark", title: "加载失败", message: errorMessage)
        } else {
            List {
                if mode == .playlists {
                    if playlists.isEmpty {
                        EmptyStateView(icon: "music.note.list", title: "暂无歌单", message: "换一个平台或稍后再试。")
                            .frame(height: 240)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(playlists) { item in
                            NavigationLink {
                                OnlinePlaylistDetailView(source: source, item: item)
                            } label: {
                                OnlinePlaylistRow(item: item)
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(.white.opacity(0.08))
                        }
                    }
                } else {
                    ForEach(boards) { board in
                        NavigationLink {
                            OnlineRankDetailView(source: source, board: board)
                        } label: {
                            HStack(spacing: 12) {
                                ArtworkView(url: board.artworkURL, size: 52, cornerRadius: 10)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(board.name).foregroundStyle(.white)
                                    if let frequency = board.updateFrequency {
                                        Text(frequency).font(.caption).foregroundStyle(AppTheme.secondaryText)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(.white.opacity(0.08))
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func load() {
        isLoading = true
        errorMessage = nil
        let selectedMode = mode
        let selectedSource = source
        Task {
            do {
                if selectedMode == .playlists {
                    let values = try await music.playlistList(source: selectedSource)
                    await MainActor.run {
                        playlists = values
                        boards = []
                        isLoading = false
                    }
                } else {
                    let values = music.rankBoards(source: selectedSource)
                    await MainActor.run {
                        boards = values
                        playlists = []
                        isLoading = false
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

struct OnlinePlaylistDetailView: View {
    let source: String
    let item: OnlinePlaylist
    @EnvironmentObject private var music: NativeMusicAPI

    var body: some View {
        OnlineTrackListPage(
            title: item.name,
            subtitle: item.author,
            artworkURL: item.artworkURL
        ) {
            try await music.playlistDetail(source: source, id: item.id)
        }
    }
}

struct OnlineRankDetailView: View {
    let source: String
    let board: OnlineBoard
    @EnvironmentObject private var music: NativeMusicAPI

    var body: some View {
        OnlineTrackListPage(
            title: board.name,
            subtitle: board.updateFrequency,
            artworkURL: board.artworkURL
        ) {
            try await music.rankList(source: source, boardID: board.bangID)
        }
    }
}

private struct OnlineTrackListPage: View {
    let title: String
    let subtitle: String?
    let artworkURL: URL?
    let loader: () async throws -> OnlinePage

    @EnvironmentObject private var player: PlaybackCoordinator
    @EnvironmentObject private var library: LibraryStore
    @State private var tracks: [MusicInfo] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var trackToAdd: MusicInfo?

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    ArtworkView(url: artworkURL, size: 84, cornerRadius: 14)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title).font(.headline).foregroundStyle(.white).lineLimit(2)
                        if let subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(AppTheme.secondaryText)
                        }
                        Text("\(tracks.count) 首").font(.caption2).foregroundStyle(AppTheme.secondaryText)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
            }
            .listRowBackground(Color.clear)

            if isLoading && tracks.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowBackground(Color.clear)
            } else if let errorMessage, tracks.isEmpty {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .listRowBackground(Color.clear)
            } else if tracks.isEmpty {
                EmptyStateView(icon: "music.note", title: "暂无歌曲", message: "换一个平台或稍后再试。")
                    .listRowBackground(Color.clear)
                    .frame(height: 260)
            } else {
                ForEach(tracks) { track in
                    OnlineTrackRow(
                        track: track,
                        isCurrent: player.currentTrack?.id == track.id,
                        isPlaying: player.isPlaying,
                        onPlay: { play(track) },
                        onAdd: { trackToAdd = track }
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(.white.opacity(0.08))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    guard let first = tracks.first else { return }
                    play(first)
                } label: {
                    Image(systemName: "play.fill")
                }
                .disabled(tracks.isEmpty)
            }
        }
        .task { await load() }
        .sheet(item: $trackToAdd) { track in
            PlaylistPickerSheet(track: track)
                .environmentObject(library)
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let page = try await loader()
            await MainActor.run {
                tracks = page.items
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func play(_ track: MusicInfo) {
        player.play(track: track, queue: tracks)
    }
}
