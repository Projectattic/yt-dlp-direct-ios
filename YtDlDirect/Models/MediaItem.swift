import Foundation

enum MediaKind: String, Codable, Hashable {
    case video, audio
    var symbol: String { self == .video ? "film" : "music.note" }
    var label: String { self == .video ? "Video" : "Audio" }
}

/// Details the app saved about a file it downloaded. Kept in the app's own storage,
/// so the download folder (e.g. VLC's) contains nothing but media files.
struct StoredInfo: Codable, Hashable {
    var videoID: String?
    var title: String
    var channel: String?
    var duration: Double?
    var uploadDate: Date?
    var webpageURL: String?
    var summary: String?
    var viewCount: Int?
    var thumbnailFile: String?
    var downloadedAt: Date
}

/// A media file in the download folder, plus anything we know about it.
struct MediaItem: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let kind: MediaKind
    let info: StoredInfo?
    let thumbnailURL: URL?
    let fileSize: Int64?
    let dateAdded: Date

    var title: String { info?.title ?? url.deletingPathExtension().lastPathComponent }
    var channel: String? { info?.channel }
    var fileName: String { url.lastPathComponent }
    var fileExtension: String { url.pathExtension.lowercased() }
    var webpageURL: URL? { info?.webpageURL.flatMap(URL.init(string:)) }
    var canSaveToPhotos: Bool { ["mp4", "m4v", "mov"].contains(fileExtension) }

    var durationText: String? {
        guard let duration = info?.duration, duration > 0 else { return nil }
        return Self.formatDuration(duration)
    }

    var sizeText: String? {
        fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
