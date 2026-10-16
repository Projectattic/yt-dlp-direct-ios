import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var appState = appState

        TabView(selection: $appState.selectedTab) {
            DownloadView()
                .tabItem { Label("Download", systemImage: "arrow.down.circle") }
                .badge(downloads.activeJobs.count)
                .tag(AppState.Tab.download)
            LibraryView()
                .tabItem { Label("Library", systemImage: "square.stack.fill") }
                .tag(AppState.Tab.library)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppState.Tab.settings)
        }
        .onOpenURL(perform: handleURL)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { library.refresh() }
        }
        .overlay(alignment: .top) {
            if let banner = appState.banner {
                BannerView(banner: banner)
                    .onTapGesture { appState.banner = nil }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: appState.banner)
    }

    /// ytdl-direct://download?url=<link>  – e.g. from a share-sheet Shortcut.
    /// Add &start=1 to start downloading straight away.
    private func handleURL(_ url: URL) {
        guard url.host?.lowercased() == "download" else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let link = query.first(where: { $0.name == "url" })?.value, !link.isEmpty else { return }
        appState.selectedTab = .download
        if query.contains(where: { $0.name == "start" && $0.value == "1" }) {
            downloads.enqueue(links: [link])
        } else {
            appState.linkText = link
        }
    }
}

private struct BannerView: View {
    let banner: Banner

    var body: some View {
        Label(banner.message, systemImage: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(banner.isError ? Color.white : Color.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(banner.isError ? Color.red : Color(.secondarySystemBackground)))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            .padding(.horizontal, 16)
            .padding(.top, 4)
    }
}
