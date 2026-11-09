import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlaybackCoordinator
    @EnvironmentObject private var theme: ThemeStore
    @State private var showCreate = false
    @State private var newListName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(library.playlists) { playlist in
                        NavigationLink(value: playlist.id) {
                            HStack(spacing: 12) {
                                Image(systemName: playlist.id == "love" ? "heart.fill" : playlist.id == "default" ? "clock.fill" : "music.note.list")
                                    .foregroundStyle(AppTheme.accent)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name).foregroundStyle(.white)
                                    Text("\(playlist.count) 首").font(.caption).foregroundStyle(AppTheme.secondaryText)
                                }
                            }
                        }
                        .listRowBackground(AppTheme.card)
                        .swipeActions {
                            if playlist.kind == .user {
                                Button(role: .destructive) {
                                    library.deleteUserList(id: playlist.id)
                                } label: {
                                    Label("删除歌单", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    SectionHeader(title: "我的歌单")
                }

                Section {
                    Button {
                        newListName = ""
                        showCreate = true
                    } label: {
                        Label("新建歌单", systemImage: "plus")
                            .foregroundStyle(AppTheme.accent)
                    }
                    .listRowBackground(AppTheme.card)
                }
            }
            .scrollContentBackground(.hidden)
            .background { AppBackgroundView() }
            .navigationTitle("音乐库")
            .navigationDestination(for: String.self) { playlistID in
                PlaylistDetailView(playlistID: playlistID)
            }
            .alert("新建歌单", isPresented: $showCreate) {
                TextField("歌单名称", text: $newListName)
                Button("取消", role: .cancel) {}
                Button("创建") {
                    let name = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { _ = library.createUserList(name: name) }
                }
            }
        }
    }
}

struct PlaylistDetailView: View {
    let playlistID: String
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlaybackCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var trackToAdd: MusicInfo?

    private var isUserList: Bool {
        library.playlists.first(where: { $0.id == playlistID })?.kind == .user
    }

    private var tracks: [MusicInfo] { library.tracks(for: playlistID) }
    private var title: String {
        library.playlists.first(where: { $0.id == playlistID })?.name ?? "歌单"
    }

    var body: some View {
        List {
            ForEach(tracks) { track in
                OnlineTrackRow(
                    track: track,
                    isCurrent: player.currentTrack?.id == track.id,
                    isPlaying: player.isPlaying,
                    onPlay: { player.play(track: track, queue: tracks) },
                    onAdd: { trackToAdd = track }
                )
                .listRowBackground(AppTheme.card)
                .swipeActions {
                    Button(role: .destructive) {
                        library.remove(track.id, from: playlistID)
                    } label: { Label("删除", systemImage: "trash") }
                }
                .contextMenu {
                    Button {
                        trackToAdd = track
                    } label: {
                        Label("添加到其他歌单", systemImage: "text.badge.plus")
                    }
                    Button {
                        player.play(track: track, queue: tracks)
                    } label: {
                        Label("播放", systemImage: "play.fill")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background { AppBackgroundView() }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        guard let first = tracks.first else { return }
                        player.play(track: first, queue: tracks)
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                    }
                    .disabled(tracks.isEmpty)

                    if isUserList {
                        Divider()
                        Button(role: .destructive) {
                            library.deleteUserList(id: playlistID)
                            dismiss()
                        } label: {
                            Label("删除歌单", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .overlay {
            if tracks.isEmpty {
                EmptyStateView(icon: "music.note.list", title: "歌单是空的", message: "从搜索页添加歌曲，或同步洛雪歌单。")
            }
        }
        .sheet(item: $trackToAdd) { track in
            PlaylistPickerSheet(track: track)
                .environmentObject(library)
        }
    }
}
