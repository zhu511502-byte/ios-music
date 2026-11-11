import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var music: NativeMusicAPI
    @EnvironmentObject private var theme: ThemeStore

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
                .onChange(of: mode) { newMode in
                    if newMode == .charts, source == "tx" {
                        source = "wy"
                    }
                    if newMode == .playlists, source == "kg" {
                        source = "tx"
                    }
                    load()
                }

                sourcePicker
                content
            }
            .background { AppBackgroundView() }
            .navigationTitle("发现")
            .task { load() }
        }
    }

    private var availableSources: [SourceOption] {
        switch mode {
        case .charts:
            // QQ has no usable leaderboard endpoint (kunyin does not
            // implement one either), so hide it from the chart source picker.
            return sources.filter { $0.id != "tx" }
        case .playlists:
            // Kugou's public playlist endpoints are not usable here. Keep
            // Kugou in charts, but do not offer a playlist source that can
            // only fail when tapped.
            return sources.filter { $0.id != "kg" }
        }
    }

    private var sourcePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availableSources) { item in
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
        } else if mode == .playlists {
            ScrollView(showsIndicators: false) {
                if playlists.isEmpty {
                    EmptyStateView(icon: "music.note.list", title: "暂无歌单", message: "换一个平台或稍后再试。")
                        .frame(height: 240)
                } else {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 14),
                            GridItem(.flexible(), spacing: 14)
                        ],
                        spacing: 18
                    ) {
                        ForEach(playlists) { item in
                            NavigationLink {
                                OnlinePlaylistDetailView(source: source, item: item)
                            } label: {
                                OnlinePlaylistGridCard(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 18)
                }
            }
            .scrollContentBackground(.hidden)
        } else {
            List {
                ForEach(boards) { board in
                    NavigationLink {
                        OnlineRankDetailView(source: source, board: board)
                    } label: {
                        HStack(spacing: 12) {
                            ArtworkView(url: board.artworkURL, size: 52, cornerRadius: 10)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(board.name).foregroundStyle(AppTheme.primaryText)
                                if let frequency = board.updateFrequency {
                                    Text(frequency).font(.caption).foregroundStyle(AppTheme.secondaryText)
                                }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(AppTheme.separator)
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
        let available = availableSources
        let selectedSource = available.contains(where: { $0.id == source })
            ? source
            : (available.first?.id ?? "tx")
        if selectedSource != source {
            source = selectedSource
        }
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

private struct PlaylistCoverView: View {
    let url: URL?

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder
                    default:
                        placeholder.overlay(ProgressView().tint(.white.opacity(0.7)))
                    }
                }
            } else {
                placeholder
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [AppTheme.accent.opacity(0.7), Color.purple.opacity(0.45)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            Image(systemName: "music.note")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        )
    }
}

struct OnlinePlaylistGridCard: View {
    let item: OnlinePlaylist

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PlaylistCoverView(url: item.artworkURL)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 6)

            Text(item.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Text(item.author ?? "")
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
                .lineLimit(1)

            if let count = item.trackCount {
                Text("\(count) 首")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .contentShape(Rectangle())
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
                        Text(title).font(.headline).foregroundStyle(AppTheme.primaryText).lineLimit(2)
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
                    .listRowSeparatorTint(AppTheme.separator)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background { AppBackgroundView() }
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
