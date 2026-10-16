import Foundation
import Observation

struct Banner: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let isError: Bool
}

@MainActor
@Observable
final class AppState {
    enum Tab: Hashable { case download, library, settings }

    var selectedTab: Tab = .download
    var linkText = ""
    var banner: Banner?

    func show(_ message: String, isError: Bool = false) {
        let banner = Banner(message: message, isError: isError)
        self.banner = banner
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(isError ? 6 : 4))
            if self.banner?.id == banner.id { self.banner = nil }
        }
    }
}
