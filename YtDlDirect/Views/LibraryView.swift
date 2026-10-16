import SwiftUI

struct LibraryView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", video = "Video", audio = "Audio"
        var id: String { rawValue }
    }

    @Environment(LibraryStore.self) private var library
    @Environment(AppState.self) private var appState
    @Environment(SettingsStore.self) private var settingsStore
    @State private var detailItem: MediaItem?
    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var showFolderPicker = false
    @State private var pendingDelete: MediaItem?

    private var visibleItems: [MediaItem] {
        library.items.filter { item in
            switch filter {
            case .all: true
            case .video: item.kind == .video
            case .audio: item.kind == .audio
            }
        }
        .filter { item in
            let q = search.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { return true }
            return item.title.localizedCaseInsensitiveContains(q)
                || (item.channel?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            list
            .navigationTitle("Library")
            .navigationDestination(for: MediaItem.self) { MediaDetailView(item: $0) }
            .navigationDestination(item: $detailItem) { MediaDetailView(item: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { library.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        Button { showFolderPicker = true } label: { Label("Choose download folder…", systemImage: "folder") }
                        if library.customFolderURL != nil {
                            Button { library.useAppFolder() } label: { Label("Use this app's folder", systemImage: "iphone") }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { library.setCustomFolder(url) }
            }
            .confirmationDialog(
                "Delete “\(pendingDelete?.title ?? "")”?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let item = pendingDelete { library.delete(item) }
                    pendingDelete = nil
                }
            } message: {
                Text("The file is removed from \(library.folderDescription).")
            }
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(visibleItems) { item in
                    Group {
                        if opensInVLC(item) {
                            Button {
                                Task {
                                    let ok = await VLCOpener.play(item.url, directlyReadable: !library.isInOwnContainer(item.url))
                                    if !ok { appState.show("No app can open this file. Is VLC installed?", isError: true) }
                                }
                            } label: {
                                HStack {
                                    MediaRow(item: item)
                                    Spacer(minLength: 0)
                                    Image(systemName: "play.circle")
                                        .font(.title3)
                                        .foregroundStyle(.tint)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        } else {
                            NavigationLink(value: item) {
                                MediaRow(item: item)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { pendingDelete = item } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        if opensInVLC(item) {
                            Button { detailItem = item } label: { Label("Details & player", systemImage: "info.circle") }
                        } else {
                            Button {
                                Task { await VLCOpener.play(item.url, directlyReadable: !library.isInOwnContainer(item.url)) }
                            } label: { Label("Open in VLC", systemImage: "play.circle") }
                        }
                        ShareLink(item: item.url)
                        if let web = item.webpageURL {
                            Link(destination: web) { Label("Open on YouTube", systemImage: "play.rectangle") }
                        }
                        Button(role: .destructive) { pendingDelete = item } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } preview: {
                        ThumbnailView(url: item.thumbnailURL, kind: item.kind, maxPixelSize: 900)
                            .frame(width: 360, height: 202)
                    }
                }
            } header: {
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .textCase(nil)
                .padding(.bottom, 4)
            } footer: {
                if let error = library.lastError {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $search, prompt: "Title or channel")
        .refreshable { await library.reload() }
        .overlay {
            if visibleItems.isEmpty && !library.isLoading {
                if library.items.isEmpty {
                    ContentUnavailableView(
                        "No downloads yet",
                        systemImage: "tray",
                        description: Text("Finished downloads appear here.")
                    )
                } else if !search.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    ContentUnavailableView("Nothing here", systemImage: filter == .audio ? "music.note" : "film")
                }
            }
        }
    }

    private func opensInVLC(_ item: MediaItem) -> Bool {
        settingsStore.settings.openInVLC
    }
}

struct MediaRow: View {
    let item: MediaItem

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(url: item.thumbnailURL, kind: item.kind, maxPixelSize: 360)
                .frame(width: 128, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if let duration = item.durationText {
                        Text(duration)
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
                            .padding(4)
                    }
                }
                .overlay(alignment: .topLeading) {
                    KindBadge(kind: item.kind).padding(4)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let channel = item.channel {
                    Text(channel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text([item.fileExtension.uppercased(), item.sizeText].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct KindBadge: View {
    let kind: MediaKind

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(kind == .audio ? Color.pink : Color.blue, in: Circle())
            .accessibilityLabel(kind.label)
    }
}

struct ThumbnailView: View {
    let url: URL?
    let kind: MediaKind
    var maxPixelSize: Int = 400
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        LinearGradient(
                            colors: kind == .audio ? [.pink, .purple] : [.blue, .indigo],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        Image(systemName: kind.symbol)
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            .clipped()
            .task(id: url) {
                guard let url else { image = nil; return }
                image = await ThumbnailLoader.shared.image(for: url, maxPixelSize: maxPixelSize)
            }
    }
}
