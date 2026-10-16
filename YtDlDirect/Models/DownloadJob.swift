import Foundation
import Observation

/// One link in the download queue, updated live while it runs.
@MainActor
@Observable
final class DownloadJob: Identifiable {
    enum State: Equatable {
        case queued
        case running
        case finished
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let link: String
    let mode: DownloadMode
    let quality: VideoQuality

    var state: State = .queued
    var phase = "Waiting…"
    var title: String?
    var channel: String?
    var thumbnailURL: URL?
    /// 0…1 across all parts of the download, nil when unknown.
    var fraction: Double?
    /// e.g. "12.3 MB of 45.6 MB · 3.2 MB/s · 0:12 left"
    var detail: String?
    var resultFile: URL?
    var log: [String] = []

    init(link: String, mode: DownloadMode, quality: VideoQuality) {
        self.link = link
        self.mode = mode
        self.quality = quality
    }

    var isActive: Bool { state == .queued || state == .running }
    var displayTitle: String { title ?? link }

    /// Applies a progress snapshot written by `ytdl_bridge`.
    func apply(progress p: [String: Any]) {
        if let t = p["title"] as? String { title = t }
        if let c = p["channel"] as? String { channel = c }
        if let thumb = p["thumbnail"] as? String { thumbnailURL = URL(string: thumb) }

        switch p["phase"] as? String {
        case "info":
            phase = "Getting video info…"
        case "downloading":
            let part = p["part"] as? Int ?? 1
            let count = p["part_count"] as? Int ?? 1
            let kind = (p["part_kind"] as? String) == "audio" ? "audio" : "video"
            var label = "Downloading \(kind)"
            if kind == "video", let h = p["height"] as? Int { label += " (\(h)p)" }
            if count > 1 { label += " · part \(part) of \(count)" }
            phase = label
            fraction = (p["overall"] as? Double)
            detail = Self.detailText(
                downloaded: (p["downloaded"] as? NSNumber)?.int64Value,
                total: (p["total"] as? NSNumber)?.int64Value,
                speed: (p["speed"] as? NSNumber)?.doubleValue,
                eta: (p["eta"] as? NSNumber)?.intValue
            )
        case "finishing":
            phase = "Adding title, artist and cover art…"
            fraction = 1
            detail = nil
        default:
            break
        }
        if let lines = p["log"] as? [String] { log = lines }
    }

    private static func detailText(downloaded: Int64?, total: Int64?, speed: Double?, eta: Int?) -> String? {
        var parts: [String] = []
        let f = ByteCountFormatter()
        f.countStyle = .file
        if let downloaded, let total, total > 0 {
            parts.append("\(f.string(fromByteCount: downloaded)) of \(f.string(fromByteCount: total))")
        } else if let downloaded {
            parts.append(f.string(fromByteCount: downloaded))
        }
        if let speed, speed > 0 {
            parts.append("\(f.string(fromByteCount: Int64(speed)))/s")
        }
        if let eta, eta >= 0 {
            parts.append(String(format: "%d:%02d left", eta / 60, eta % 60))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
