import AVFoundation
import UIKit

/// Does ffmpeg's job with AVFoundation: joins the separate video and audio streams,
/// rewrites YouTube's DASH files into normal MP4/M4A files, and embeds the title,
/// artist (channel) and cover art. Everything is copied ("passthrough"), never
/// re-encoded, so it's quick and lossless.
enum MediaFinisher {
    enum FinishError: LocalizedError {
        case noTrack(String)
        case exportUnavailable
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noTrack(let kind): "The downloaded file has no \(kind) track."
            case .exportUnavailable: "iOS can't process this file's format."
            case .exportFailed(let message): "Couldn't finish the file: \(message)"
            }
        }
    }

    struct Tags {
        var title: String
        var artist: String?
        var album: String?
        var date: String?
        var description: String?
        var artwork: Data?
    }

    /// Builds the final file. `inputs` are the downloaded parts (video first).
    static func export(inputs: [URL], mode: DownloadMode, tags: Tags, to output: URL) async throws {
        let assets = inputs.map { AVURLAsset(url: $0) }
        let composition = AVMutableComposition()
        var videoDuration: CMTime?

        if mode == .video {
            guard let track = try await firstTrack(.video, in: assets) else { throw FinishError.noTrack("video") }
            let range = try await track.load(.timeRange)
            guard let target = composition.addMutableTrack(withMediaType: .video,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw FinishError.exportUnavailable
            }
            try target.insertTimeRange(range, of: track, at: .zero)
            target.preferredTransform = try await track.load(.preferredTransform)
            videoDuration = range.duration
        }

        if let track = try await firstTrack(.audio, in: assets) {
            var range = try await track.load(.timeRange)
            if let videoDuration, range.duration > videoDuration {
                range = CMTimeRange(start: range.start, duration: videoDuration)
            }
            guard let target = composition.addMutableTrack(withMediaType: .audio,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw FinishError.exportUnavailable
            }
            try target.insertTimeRange(range, of: track, at: .zero)
        } else if mode == .audio {
            throw FinishError.noTrack("audio")
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw FinishError.exportUnavailable
        }
        try? FileManager.default.removeItem(at: output)
        session.outputURL = output
        session.outputFileType = mode == .audio ? .m4a : .mp4
        session.shouldOptimizeForNetworkUse = true
        session.metadata = metadataItems(tags)

        await session.export()
        withExtendedLifetime(assets) {}

        guard session.status == .completed else {
            throw FinishError.exportFailed(session.error?.localizedDescription ?? "unknown error")
        }
    }

    private static func firstTrack(_ type: AVMediaType, in assets: [AVURLAsset]) async throws -> AVAssetTrack? {
        for asset in assets {
            if let track = try await asset.loadTracks(withMediaType: type).first {
                return track
            }
        }
        return nil
    }

    /// iTunes-style tags, which Music, VLC, Files and most players read from MP4/M4A.
    private static func metadataItems(_ tags: Tags) -> [AVMetadataItem] {
        func item(_ identifier: AVMetadataIdentifier, _ value: (NSCopying & NSObjectProtocol)?,
                  dataType: String? = nil) -> AVMetadataItem? {
            guard let value else { return nil }
            let m = AVMutableMetadataItem()
            m.identifier = identifier
            m.value = value
            m.extendedLanguageTag = "und"
            if let dataType { m.dataType = dataType }
            return m
        }
        return [
            item(.iTunesMetadataSongName, tags.title as NSString),
            item(.iTunesMetadataArtist, tags.artist as NSString?),
            item(.iTunesMetadataAlbumArtist, tags.artist as NSString?),
            item(.iTunesMetadataAlbum, tags.album as NSString?),
            item(.iTunesMetadataReleaseDate, tags.date as NSString?),
            item(.iTunesMetadataDescription, tags.description.map { String($0.prefix(2000)) } as NSString?),
            item(.iTunesMetadataCoverArt, tags.artwork as NSData?, dataType: kCMMetadataBaseDataType_JPEG as String),
        ].compactMap { $0 }
    }

    // MARK: Thumbnails

    /// Downloads the YouTube thumbnail and returns it as JPEG, optionally cropped square
    /// (nicer as album art).
    static func thumbnailJPEG(from url: URL?, square: Bool) async -> Data? {
        guard let url, let response = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: response.0), let cg = image.cgImage else { return nil }
        var output = cg
        if square {
            let side = min(cg.width, cg.height)
            let rect = CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side)
            output = cg.cropping(to: rect) ?? cg
        }
        return UIImage(cgImage: output).jpegData(compressionQuality: 0.9)
    }
}
