import SwiftUI
import AVFoundation

@main
struct YtDlDirectApp: App {
    @State private var appState = AppState()
    @State private var settings: SettingsStore
    @State private var library: LibraryStore
    @State private var downloads: DownloadManager

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        let settings = SettingsStore()
        let library = LibraryStore()
        _settings = State(initialValue: settings)
        _library = State(initialValue: library)
        _downloads = State(initialValue: DownloadManager(library: library, settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(settings)
                .environment(library)
                .environment(downloads)
                .task { await downloads.bootstrap() }
        }
    }
}
