import SwiftUI

struct DownloadView: View {
    @Environment(AppState.self) private var appState
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(DownloadManager.self) private var downloads
    @Environment(LibraryStore.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @State private var lastPasteboardChange = -1
    @FocusState private var linkFocused: Bool

    private var links: [String] {
        appState.linkText.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
    }

    var body: some View {
        @Bindable var appState = appState
        @Bindable var settingsStore = settingsStore

        NavigationStack {
            Form {
                setupSection

                Section {
                    TextField("Paste a YouTube link", text: $appState.linkText, axis: .vertical)
                        .lineLimit(1...5)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($linkFocused)
                    HStack {
                        Button {
                            if let text = UIPasteboard.general.string {
                                appState.linkText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        Spacer()
                        if !appState.linkText.isEmpty {
                            Button("Clear", role: .destructive) { appState.linkText = "" }
                                .buttonStyle(.borderless)
                        }
                    }
                } header: {
                    Text("Link")
                }

                Section {
                    Picker("Download", selection: $settingsStore.settings.mode) {
                        ForEach(DownloadMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                    if settingsStore.settings.mode == .video {
                        Picker("Quality", selection: $settingsStore.settings.videoQuality) {
                            ForEach(VideoQuality.allCases) { Text($0.label).tag($0) }
                        }
                    } else {
                        LabeledContent("Format", value: "M4A (AAC), original quality")
                    }

                    Button {
                        linkFocused = false
                        downloads.enqueue(links: links)
                        appState.linkText = ""
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(links.isEmpty || downloads.setup != .ready)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                } footer: {
                    Text("Saving to \(library.folderDescription).")
                }

                if !downloads.activeJobs.isEmpty {
                    Section("Downloading") {
                        ForEach(downloads.activeJobs) { job in
                            JobRow(job: job)
                        }
                    }
                }

                if !downloads.finishedJobs.isEmpty {
                    Section {
                        ForEach(downloads.finishedJobs.reversed()) { job in
                            JobRow(job: job)
                                .swipeActions {
                                    Button("Remove", role: .destructive) { downloads.remove(job) }
                                }
                        }
                    } header: {
                        HStack {
                            Text("Recent")
                            Spacer()
                            Button("Clear") { downloads.clearFinished() }
                                .font(.caption)
                                .textCase(nil)
                        }
                    }
                }
            }
            .navigationTitle("Download")
            .onAppear(perform: autoFillFromClipboard)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { autoFillFromClipboard() }
            }
        }
    }

    @ViewBuilder
    private var setupSection: some View {
        switch downloads.setup {
        case .ready:
            EmptyView()
        case .checking:
            Section { Label("Starting yt-dlp…", systemImage: "hourglass") }
        case .installing(let message):
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading) {
                        Text(message).font(.headline)
                        Text("First launch only: fetching the latest yt-dlp.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        case .failed(let message):
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("yt-dlp isn't ready", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline).foregroundStyle(.orange)
                    Text(message).font(.callout)
                    Button("Try again") { Task { await downloads.bootstrap() } }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    /// Fills in a YouTube link copied elsewhere. Only reads the clipboard when it changed.
    private func autoFillFromClipboard() {
        guard settingsStore.settings.autoPasteLinks else { return }
        let pasteboard = UIPasteboard.general
        guard pasteboard.changeCount != lastPasteboardChange else { return }
        lastPasteboardChange = pasteboard.changeCount
        guard pasteboard.hasURLs || pasteboard.hasStrings,
              let text = pasteboard.string?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        let lower = text.lowercased()
        guard lower.contains("youtube.com/") || lower.contains("youtu.be/"),
              !text.contains("\n"), text != appState.linkText else { return }
        // Don't offer a link that's already queued or was just downloaded.
        guard !downloads.jobs.contains(where: { $0.link == text }) else { return }
        appState.linkText = text
    }
}

/// One queued, running or finished download.
struct JobRow: View {
    let job: DownloadJob
    @Environment(DownloadManager.self) private var downloads
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(LibraryStore.self) private var library
    @Environment(AppState.self) private var appState
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                artwork
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if let channel = job.channel {
                        Text(channel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(job.phase)
                        .font(.caption)
                        .foregroundStyle(phaseColor)
                }
                Spacer(minLength: 0)
                trailingButton
            }

            if job.state == .running {
                if let fraction = job.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                if let detail = job.detail {
                    Text(detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if case .failed(let message) = job.state {
                Text(message).font(.caption).foregroundStyle(.red)
                HStack {
                    Button("Retry") { downloads.retry(job) }.buttonStyle(.bordered)
                    if !job.log.isEmpty {
                        Button(showLog ? "Hide details" : "Details") { showLog.toggle() }
                            .buttonStyle(.borderless)
                    }
                }
                .font(.caption)
                if showLog {
                    Text(job.log.suffix(12).joined(separator: "\n"))
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var phaseColor: Color {
        switch job.state {
        case .finished: .green
        case .failed: .red
        default: .secondary
        }
    }

    private var artwork: some View {
        AsyncImage(url: job.thumbnailURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                LinearGradient(colors: job.mode == .audio ? [.pink, .purple] : [.blue, .indigo],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: job.mode.symbol).foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(width: 96, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    @ViewBuilder
    private var trailingButton: some View {
        switch job.state {
        case .queued, .running:
            Button {
                downloads.cancel(job)
            } label: {
                Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Cancel")
        case .finished:
            if let file = job.resultFile {
                Button {
                    play(file)
                } label: {
                    Image(systemName: "play.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Play")
            }
        default:
            EmptyView()
        }
    }

    private func play(_ file: URL) {
        if settingsStore.settings.openInVLC {
            Task {
                let ok = await VLCOpener.play(file, directlyReadable: !library.isInOwnContainer(file))
                if !ok { appState.show("No app can open this file. Is VLC installed?", isError: true) }
            }
        } else {
            appState.selectedTab = .library
        }
    }
}
