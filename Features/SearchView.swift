import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var music: NativeMusicAPI
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlaybackCoordinator
    @EnvironmentObject private var sourceStore: SourceStore
    @EnvironmentObject private var theme: ThemeStore

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
    @State private var hotSongs: [MusicInfo] = []
    @State private var hotKeywords: [String] = []
    @State private var isLoadingHot = false
    @AppStorage("search.history") private var historyRaw = ""

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
            .background { AppBackgroundView() }
            .navigationTitle("搜索")
            .task(id: source) { await loadHotSongs() }
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
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                discoverContent
            } else {
                EmptyStateView(icon: "music.note", title: "没有结果", message: "换个关键词，或切换其他平台试试。")
            }
        } else {
            List {
                ForEach(results) { track in
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
                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private var discoverContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                if !historyItems.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("历史搜索")
                                .font(.headline)
                                .foregroundStyle(AppTheme.primaryText)
                            Spacer()
                            Button("清空") { historyRaw = "" }
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(historyItems, id: \.self) { item in
                                    Button {
                                        query = item
                                        search()
                                    } label: {
                                        Text(item)
                                            .font(.footnote)
                                            .foregroundStyle(AppTheme.primaryText.opacity(0.85))
                                            .padding(.horizontal, 12)
                                            .frame(height: 30)
                                            .background(AppTheme.card, in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("热门搜索")
                            .font(.headline)
                            .foregroundStyle(AppTheme.primaryText)
                        Spacer()
                        if isLoadingHot {
                            ProgressView().tint(AppTheme.accent).scaleEffect(0.8)
                        }
                    }

                    if source == "tx", !hotKeywords.isEmpty {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                            spacing: 8
                        ) {
                            ForEach(Array(hotKeywords.prefix(9)), id: \.self) { keyword in
                                Button {
                                    query = keyword
                                    search()
                                } label: {
                                    Text(keyword)
                                        .font(.footnote.weight(.medium))
                                        .foregroundStyle(AppTheme.primaryText.opacity(0.88))
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity)
                                        .padding(.horizontal, 8)
                                        .frame(height: 32)
                                        .background(AppTheme.card, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else if hotSongs.isEmpty {
                        Text(isLoadingHot ? "正在加载热门歌曲…" : "暂无热门歌曲")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(hotSongs) { track in
                            OnlineTrackRow(
                                track: track,
                                isCurrent: player.currentTrack?.id == track.id,
                                isPlaying: player.isPlaying,
                                onPlay: { player.play(track: track, queue: hotSongs) },
                                onAdd: { trackToAdd = track }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 20)
        }
    }

    private var historyItems: [String] {
        historyRaw
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func recordHistory(_ value: String) {
        var items = historyItems
        items.removeAll { $0 == value }
        items.insert(value, at: 0)
        historyRaw = items.prefix(10).joined(separator: "\n")
    }

    private func loadHotSongs() async {
        if source == "tx" {
            await MainActor.run { isLoadingHot = true }
            let keywords = (try? await music.hotSearchKeywords(source: "tx")) ?? []
            await MainActor.run {
                hotKeywords = keywords
                hotSongs = []
                isLoadingHot = false
            }
            return
        }
        await MainActor.run { hotKeywords = [] }
        let board: String
        switch source {
        case "tx": board = "26"
        case "wy": board = "3778678"
        case "kg": board = "8888"
        case "kw": board = "16"
        case "mg": board = "27186466"
        default: board = "26"
        }
        await MainActor.run { isLoadingHot = true }
        do {
            let page = try await music.rankList(source: source, boardID: board)
            await MainActor.run {
                hotSongs = Array(page.items.prefix(12))
                isLoadingHot = false
            }
        } catch {
            await MainActor.run {
                hotSongs = []
                isLoadingHot = false
            }
        }
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        recordHistory(text)
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
