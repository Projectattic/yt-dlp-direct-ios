import SwiftUI
import AVKit
import Photos

struct MediaDetailView: View {
    let item: MediaItem

    @Environment(LibraryStore.self) private var library
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var artwork: UIImage?
    @State private var confirmDelete = false
    @State private var isSaving = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VideoPlayer(player: player) {
                    if item.kind == .audio {
                        // Audio has no picture, so show the thumbnail under the controls.
                        ZStack {
                            Color.black
                            if let artwork {
                                Image(uiImage: artwork).resizable().scaledToFit()
                            } else {
                                Image(systemName: "music.note")
                                    .font(.system(size: 48))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                        }
                        .allowsHitTesting(false)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        KindBadge(kind: item.kind)
                        Text(item.fileExtension.uppercased())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(item.title)
                        .font(.title3.weight(.bold))
                        .textSelection(.enabled)
                    if let channel = item.channel {
                        Text(channel)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }

                details

                actions

                if let summary = item.info?.summary, !summary.isEmpty {
                    DisclosureGroup("Description") {
                        Text(summary)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(item.kind.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: item.url)
            }
        }
        .onAppear {
            if player == nil { player = AVPlayer(url: item.url) }
        }
        .onDisappear { player?.pause() }
        .task {
            if item.kind == .audio, let thumb = item.thumbnailURL {
                artwork = await ThumbnailLoader.shared.image(for: thumb, maxPixelSize: 1280)
            }
        }
        .confirmationDialog("Delete this file?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                player?.pause()
                library.delete(item)
                dismiss()
            }
        }
    }

    private var details: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            if let date = item.info?.uploadDate {
                row("Uploaded", date.formatted(date: .long, time: .omitted))
            }
            if let duration = item.durationText {
                row("Length", duration)
            }
            if let views = item.info?.viewCount {
                row("Views", views.formatted())
            }
            if let size = item.sizeText {
                row("Size", size)
            }
            row("Downloaded", item.dateAdded.formatted(date: .abbreviated, time: .shortened))
            row("File", item.url.lastPathComponent)
        }
        .font(.callout)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ShareLink(item: item.url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                if item.canSaveToPhotos {
                    Button {
                        Task { await saveToPhotos() }
                    } label: {
                        Label(isSaving ? "Saving…" : "Save to Photos", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(isSaving)
                }
            }
            Button {
                player?.pause()
                Task {
                    let ok = await VLCOpener.play(item.url, directlyReadable: !library.isInOwnContainer(item.url))
                    if !ok { appState.show("No app can open this file. Is VLC installed?", isError: true) }
                }
            } label: {
                Label("Open in VLC", systemImage: "play.circle")
                    .frame(maxWidth: .infinity)
            }
            HStack(spacing: 10) {
                if let web = item.webpageURL {
                    Link(destination: web) {
                        Label("YouTube", systemImage: "play.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                }
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Delete", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private func saveToPhotos() async {
        isSaving = true
        defer { isSaving = false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            appState.show("Allow Photos access in Settings to save videos.", isError: true)
            return
        }
        let fileURL = item.url
        do {
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
            }
            appState.show("Saved to Photos.")
        } catch {
            appState.show("Couldn't save to Photos: \(error.localizedDescription)", isError: true)
        }
    }
}
