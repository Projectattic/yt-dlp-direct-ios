import UIKit

/// Gets a file playing in VLC.
///
/// Files in a folder VLC can read (e.g. On My iPhone › VLC) open directly through VLC's
/// x-callback URL. Files in this app's own folder can't be read by VLC that way, so the
/// system "Open in…" sheet is shown instead, which hands VLC a copy.
@MainActor
enum VLCOpener {
    private static var interaction: UIDocumentInteractionController?

    /// Returns false if nothing could be opened.
    @discardableResult
    static func play(_ fileURL: URL, directlyReadable: Bool) async -> Bool {
        if directlyReadable, await openDirect(fileURL) {
            return true
        }
        return presentOpenIn(fileURL)
    }

    private static func openDirect(_ fileURL: URL) async -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encoded = fileURL.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "vlc-x-callback://x-callback-url/stream?url=\(encoded)") else { return false }
        return await UIApplication.shared.open(url)
    }

    /// Shows the "Open in…" app picker (VLC appears there once installed).
    private static func presentOpenIn(_ fileURL: URL) -> Bool {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              var top = scene.keyWindow?.rootViewController else { return false }
        while let presented = top.presentedViewController { top = presented }

        let controller = UIDocumentInteractionController(url: fileURL)
        interaction = controller // must stay alive while the menu is shown
        let anchor = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 80, width: 1, height: 1)
        return controller.presentOpenInMenu(from: anchor, in: top.view, animated: true)
    }
}
