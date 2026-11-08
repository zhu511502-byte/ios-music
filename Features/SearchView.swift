import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var music: NativeMusicAPI
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlaybackCoordinator
    @EnvironmentObject private var sourceStore: SourceStore

    private struct SearchSource: Identifiable {
        let id: String
        let name: String
    }

    private let sources: [SearchSource] = [
        SearchSource(id: "tx", name: "QQ"),
        SearchSource(id: "wy", name: "网易"),
        SearchSource(id: "kg", name: "酷狗"),
        SearchSource(id: "kw", name: "酷我"),
        SearchSource(id: "mg", name: "咪咕")
    ]

    @State private var query = ""
    @State private var source = "tx"
    @State private var results: [MusicInfo] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var trackToAdd: MusicInfo?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                sourcePicker
                if sourceStore.profiles.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                        Text("搜索只负责找到歌曲；播放前请先到设置导入洛雪音源脚本")
                            .font(.caption)
                        Spacer()
                    }
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
                content
            }
            .background(Color.clear)
            .navigationTitle("搜索")
            .sheet(item: $trackToAdd) { track in
                PlaylistPickerSheet(track: track)
                    .environmentObject(library)
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(AppTheme.secondaryText)
                TextField("歌曲、歌手、专辑", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { search() }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(AppTheme.secondaryText)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button("搜索") { search() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 42)
                .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(isLoading)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var sourcePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sources, id: \.id) { item in
                    Button {
                        source = item.id
                    } label: {
                        Text(item.name)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(source == item.id ? .white : AppTheme.secondaryText)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(
                                source == item.id ? AppTheme.accent : AppTheme.card,
                                in: Capsule()
                            )
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && results.isEmpty {
            ProgressView("搜索中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tint(AppTheme.accent)
        } else if let errorMessage, results.isEmpty {
            EmptyStateView(icon: "wifi.exclamationmark", title: "搜索失败", message: errorMessage)
        } else if results.isEmpty {
            EmptyStateView(icon: "music.note", title: "找点什么", message: "输入关键词，从五个平台里搜索。")
        } else {
            List {
                ForEach(results) { track in
                    OnlineTrackRow(track: track) {
                        play(track)
                    } onAdd: {
                        trackToAdd = track
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(.white.opacity(0.08))
                }
                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        results = []
        let selectedSource = source
        Task {
            do {
                let page = try await music.search(source: selectedSource, query: text)
                await MainActor.run {
                    results = page.items
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func play(_ track: MusicInfo) {
        player.play(track: track, queue: results)
    }
}
