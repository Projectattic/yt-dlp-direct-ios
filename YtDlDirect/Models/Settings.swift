import Foundation
import Observation

enum DownloadMode: String, Codable, CaseIterable, Identifiable {
    case video, audio
    var id: String { rawValue }
    var label: String { self == .video ? "Video" : "Audio" }
    var symbol: String { self == .video ? "film" : "music.note" }
}

/// Without ffmpeg the app keeps YouTube's H.264 video, which tops out at 1080p.
enum VideoQuality: String, Codable, CaseIterable, Identifiable {
    case best, p1080, p720, p480, p360
    var id: String { rawValue }

    var label: String {
        switch self {
        case .best: "Best (up to 1080p)"
        case .p1080: "1080p"
        case .p720: "720p"
        case .p480: "480p"
        case .p360: "360p"
        }
    }

    var maxHeight: Int? {
        switch self {
        case .best: nil
        case .p1080: 1080
        case .p720: 720
        case .p480: 480
        case .p360: 360
        }
    }
}

struct AppSettings: Codable, Equatable {
    var mode: DownloadMode = .video
    var videoQuality: VideoQuality = .best
    var squareAudioArtwork = true
    var channelAsAlbum = false
    var allowPlaylists = true
    var openInVLC = true
    var autoPasteLinks = true
    var keepScreenAwake = true
    var rateLimit = ""

    init() {}

    /// Lenient decoding so settings survive new options being added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        mode = v(.mode, d.mode)
        videoQuality = v(.videoQuality, d.videoQuality)
        squareAudioArtwork = v(.squareAudioArtwork, d.squareAudioArtwork)
        channelAsAlbum = v(.channelAsAlbum, d.channelAsAlbum)
        allowPlaylists = v(.allowPlaylists, d.allowPlaylists)
        openInVLC = v(.openInVLC, d.openInVLC)
        autoPasteLinks = v(.autoPasteLinks, d.autoPasteLinks)
        keepScreenAwake = v(.keepScreenAwake, d.keepScreenAwake)
        rateLimit = v(.rateLimit, d.rateLimit)
    }
}

@Observable
final class SettingsStore {
    private static let key = "appSettings.v1"

    var settings: AppSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) {
                UserDefaults.standard.set(data, forKey: Self.key)
            }
        }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = saved
        } else {
            settings = AppSettings()
        }
    }
}
