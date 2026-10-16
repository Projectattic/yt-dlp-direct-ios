import SwiftUI

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @Environment(AppState.self) private var appState
    @State private var showFolderPicker = false

    var body: some View {
        @Bindable var settingsStore = settingsStore

        NavigationStack {
            Form {
                Section {
                    LabeledContent("Installed version", value: downloads.ytdlpVersion ?? "—")
                    Button {
                        Task {
                            let before = downloads.ytdlpVersion
                            await downloads.installYtDlp()
                            if let error = downloads.lastUpdateError {
                                appState.show("Update failed: \(error)", isError: true)
                            } else if before == downloads.ytdlpVersion {
                                appState.show("yt-dlp is up to date (\(downloads.ytdlpVersion ?? "")).")
                            } else {
                                appState.show("Updated yt-dlp to \(downloads.ytdlpVersion ?? "").")
                            }
                        }
                    } label: {
                        HStack {
                            Label("Update yt-dlp", systemImage: "arrow.triangle.2.circlepath")
                            if downloads.isUpdating {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(downloads.isUpdating || downloads.jobs.contains { $0.state == .running })
                } header: {
                    Text("yt-dlp")
                } footer: {
                    Text("If downloads start failing, update first. YouTube changes often and yt-dlp keeps up.")
                }

                Section {
                    LabeledContent("Save to", value: library.folderDescription)
                    Button("Choose folder…") { showFolderPicker = true }
                    if library.customFolderURL != nil {
                        Button("Use this app's folder") { library.useAppFolder() }
                    }
                    Toggle("Tap to play in VLC", isOn: $settingsStore.settings.openInVLC)
                } header: {
                    Text("Download folder")
                } footer: {
                    Text("Best: pick On My iPhone › VLC, so downloads land straight in VLC and tapping one plays it immediately. Files kept in this app's own folder open through the “Open in…” sheet instead, where VLC makes its own copy.")
                }

                Section {
                    Toggle("Square cover art for audio", isOn: $settingsStore.settings.squareAudioArtwork)
                    Toggle("Channel as album", isOn: $settingsStore.settings.channelAsAlbum)
                } header: {
                    Text("Tags & artwork")
                } footer: {
                    Text("Every file gets the video title as its title, the channel as artist and album artist, the upload date and the thumbnail as cover art.")
                }

                Section {
                    Toggle("Allow playlists", isOn: $settingsStore.settings.allowPlaylists)
                    Toggle("Auto-fill copied YouTube links", isOn: $settingsStore.settings.autoPasteLinks)
                    Toggle("Keep screen on while downloading", isOn: $settingsStore.settings.keepScreenAwake)
                    LabeledContent("Speed limit") {
                        TextField("none, e.g. 5M", text: $settingsStore.settings.rateLimit)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("iOS pauses apps shortly after you leave them, so keep the app open for long downloads. Playlist and channel links add each video to the queue.")
                }

                Section("About") {
                    LabeledContent("Formats", value: "MP4 (H.264/AAC), M4A")
                    Text("Without ffmpeg on iOS, the app keeps YouTube's iPhone-compatible streams and joins and tags them with Apple's own media tools, without re-encoding. That caps video at 1080p.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { library.setCustomFolder(url) }
            }
        }
    }
}
