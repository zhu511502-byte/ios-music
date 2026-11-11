import SwiftUI

struct PlaylistPickerSheet: View {
    let track: MusicInfo

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var newListName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(library.playlists) { playlist in
                        let contains = library.tracks(for: playlist.id).contains { $0.id == track.id }
                        Button {
                            guard !contains else { return }
                            library.add(track, to: playlist.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: icon(for: playlist))
                                    .foregroundStyle(AppTheme.accent)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name).foregroundStyle(primaryText)
                                    Text("\(playlist.count) 首")
                                        .font(.caption)
                                        .foregroundStyle(secondaryText)
                                }
                                Spacer()
                                Image(systemName: contains ? "checkmark.circle.fill" : "plus.circle")
                                    .foregroundStyle(contains ? AppTheme.accent : secondaryText)
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                        .disabled(contains)
                    }
                } header: {
                    Text("选择歌单")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(secondaryText)
                }

                Section {
                    HStack {
                        TextField("新歌单名称", text: $newListName)
                            .submitLabel(.done)
                            .onSubmit { createList() }
                        Button("创建") { createList() }
                            .disabled(trimmedName.isEmpty)
                    }
                } header: {
                    Text("新建歌单")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(secondaryText)
                } footer: {
                    Text("创建后会直接把《\(track.name)》加入这个歌单。")
                }
            }
            .scrollContentBackground(.hidden)
            .background(.ultraThinMaterial)
            .navigationTitle("添加到歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private var primaryText: Color {
        colorScheme == .dark ? .white : Color.black.opacity(0.88)
    }

    private var secondaryText: Color {
        colorScheme == .dark ? Color.white.opacity(0.58) : Color.black.opacity(0.55)
    }

    private var trimmedName: String {
        newListName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func createList() {
        guard !trimmedName.isEmpty else { return }
        let list = library.createUserList(name: trimmedName)
        library.add(track, to: list.id)
        dismiss()
    }

    private func icon(for playlist: LibraryPlaylist) -> String {
        if playlist.id == "love" { return "heart.fill" }
        if playlist.id == "default" { return "clock.fill" }
        return "music.note.list"
    }
}
