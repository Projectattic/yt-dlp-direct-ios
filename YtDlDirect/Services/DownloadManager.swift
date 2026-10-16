import Foundation
import Observation
import UIKit

/// Runs the download queue: yt-dlp (in the embedded Python) fetches the streams,
/// MediaFinisher builds the tagged file, LibraryStore files it away.
@MainActor
@Observable
final class DownloadManager {
    enum SetupState: Equatable {
        case checking
        case installing(String)
        case ready
        case failed(String)
    }

    private(set) var jobs: [DownloadJob] = []
    private(set) var setup: SetupState = .checking
    private(set) var ytdlpVersion: String?
    private(set) var isUpdating = false

    private let python = PythonRuntime.shared
    private let library: LibraryStore
    private let settingsStore: SettingsStore
    private var isProcessing = false
    private var cancelFiles: [UUID: URL] = [:]

    init(library: LibraryStore, settings: SettingsStore) {
        self.library = library
        self.settingsStore = settings
    }

    var activeJobs: [DownloadJob] { jobs.filter(\.isActive) }
    var finishedJobs: [DownloadJob] { jobs.filter { !$0.isActive } }

    // MARK: - yt-dlp setup

    /// Checks for yt-dlp and installs it on first launch.
    func bootstrap() async {
        setup = .checking
        do {
            let result = try await python.run(action: "version")
            if let version = result["version"] as? String {
                ytdlpVersion = version
                setup = .ready
                processQueue()
            } else {
                await installYtDlp()
            }
        } catch {
            setup = .failed(error.localizedDescription)
        }
    }

    /// Downloads the latest yt-dlp (and certifi) from PyPI and installs it.
    func installYtDlp() async {
        guard !isUpdating else { return }
        isUpdating = true
        lastUpdateError = nil
        defer { isUpdating = false }
        let wasReady = setup == .ready
        if !wasReady { setup = .installing("Downloading yt-dlp…") }
        do {
            let wheelsDir = FileManager.default.temporaryDirectory.appendingPathComponent("wheels", isDirectory: true)
            try? FileManager.default.removeItem(at: wheelsDir)
            try FileManager.default.createDirectory(at: wheelsDir, withIntermediateDirectories: true)

            var wheels: [String] = []
            for package in ["yt-dlp", "certifi"] {
                wheels.append(try await Self.downloadWheel(package, into: wheelsDir).path)
            }
            if !wasReady { setup = .installing("Installing yt-dlp…") }
            let result = try await python.run(action: "install", payload: [
                "target": python.packagesURL.path,
                "wheels": wheels,
            ])
            try? FileManager.default.removeItem(at: wheelsDir)
            guard let version = result["version"] as? String else {
                throw NSError(domain: "yt-dlp", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: result["error"] as? String ?? "yt-dlp didn't install correctly.",
                ])
            }
            ytdlpVersion = version
            setup = .ready
            processQueue()
        } catch {
            if wasReady {
                setup = .ready // keep using the version we already have
            } else {
                setup = .failed("Couldn't install yt-dlp: \(error.localizedDescription)")
            }
            lastUpdateError = error.localizedDescription
        }
    }

    private(set) var lastUpdateError: String?

    private static func downloadWheel(_ package: String, into folder: URL) async throws -> URL {
        let api = URL(string: "https://pypi.org/pypi/\(package)/json")!
        let (data, _) = try await URLSession.shared.data(from: api)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = json["urls"] as? [[String: Any]],
              let wheel = files.first(where: {
                  ($0["packagetype"] as? String) == "bdist_wheel"
                      && (($0["filename"] as? String)?.hasSuffix("py3-none-any.whl") ?? false)
              }),
              let urlString = wheel["url"] as? String, let url = URL(string: urlString),
              let filename = wheel["filename"] as? String else {
            throw URLError(.cannotParseResponse)
        }
        let (temp, _) = try await URLSession.shared.download(from: url)
        let destination = folder.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }

    // MARK: - Queue

    func enqueue(links: [String]) {
        let settings = settingsStore.settings
        for link in links {
            jobs.append(DownloadJob(link: link, mode: settings.mode, quality: settings.videoQuality))
        }
        processQueue()
    }

    func cancel(_ job: DownloadJob) {
        switch job.state {
        case .queued:
            job.state = .cancelled
            job.phase = "Cancelled"
        case .running:
            if let file = cancelFiles[job.id] {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            job.phase = "Cancelling…"
        default:
            break
        }
    }

    func retry(_ job: DownloadJob) {
        jobs.removeAll { $0.id == job.id }
        jobs.append(DownloadJob(link: job.link, mode: job.mode, quality: job.quality))
        processQueue()
    }

    func remove(_ job: DownloadJob) {
        guard !job.isActive else { return }
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll { !$0.isActive }
    }

    private func processQueue() {
        guard !isProcessing, setup == .ready else { return }
        isProcessing = true
        Task {
            var background: UIBackgroundTaskIdentifier = .invalid
            background = UIApplication.shared.beginBackgroundTask(withName: "downloads") {
                // Out of background time: stop cleanly rather than being killed mid-write.
                for file in self.cancelFiles.values {
                    FileManager.default.createFile(atPath: file.path, contents: nil)
                }
                UIApplication.shared.endBackgroundTask(background)
                background = .invalid
            }
            UIApplication.shared.isIdleTimerDisabled = settingsStore.settings.keepScreenAwake

            while let job = jobs.first(where: { $0.state == .queued }) {
                await run(job)
            }

            UIApplication.shared.isIdleTimerDisabled = false
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            isProcessing = false
        }
    }

    // MARK: - One download

    private func run(_ job: DownloadJob) async {
        job.state = .running
        job.phase = "Getting video info…"
        job.fraction = nil

        let fm = FileManager.default
        let workdir = fm.temporaryDirectory.appendingPathComponent("job-\(job.id.uuidString)", isDirectory: true)
        try? fm.createDirectory(at: workdir, withIntermediateDirectories: true)
        let progressURL = workdir.appendingPathComponent("progress.json")
        let cancelURL = workdir.appendingPathComponent("cancel")
        cancelFiles[job.id] = cancelURL
        defer {
            cancelFiles[job.id] = nil
            try? fm.removeItem(at: workdir)
        }

        // Read the progress file a few times a second while Python downloads.
        let poller = Task { @MainActor in
            while !Task.isCancelled {
                if let data = try? Data(contentsOf: progressURL),
                   let progress = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if job.phase != "Cancelling…" { job.apply(progress: progress) }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        let settings = settingsStore.settings
        var payload: [String: Any] = [
            "url": job.link,
            "mode": job.mode.rawValue,
            "workdir": workdir.path,
            "progress_path": progressURL.path,
            "cancel_path": cancelURL.path,
            "cache_dir": python.cacheURL.path,
            "rate_limit": settings.rateLimit,
        ]
        if let h = job.quality.maxHeight { payload["max_height"] = h }

        let result: [String: Any]
        do {
            result = try await python.run(action: "download", payload: payload)
        } catch {
            poller.cancel()
            fail(job, error.localizedDescription)
            return
        }
        poller.cancel()
        if let lines = result["log"] as? [String] { job.log = lines }

        if result["cancelled"] as? Bool == true {
            job.state = .cancelled
            job.phase = "Cancelled"
            job.fraction = nil
            job.detail = nil
            return
        }
        guard result["ok"] as? Bool == true else {
            fail(job, result["error"] as? String ?? "Download failed.")
            return
        }

        // A playlist or channel: queue its videos individually.
        if let entries = result["playlist"] as? [String] {
            let name = result["title"] as? String ?? "Playlist"
            job.title = name
            job.fraction = nil
            job.detail = nil
            if settings.allowPlaylists {
                for link in entries {
                    jobs.append(DownloadJob(link: link, mode: job.mode, quality: job.quality))
                }
                job.state = .finished
                job.phase = "Added \(entries.count) videos to the queue"
            } else {
                fail(job, "This is a playlist. Turn on Settings › Allow playlists to download all \(entries.count) videos.")
            }
            return
        }

        await finish(job, result: result, workdir: workdir, settings: settings)
    }

    private func finish(_ job: DownloadJob, result: [String: Any], workdir: URL, settings: AppSettings) async {
        job.phase = "Adding title, artist and cover art…"
        job.fraction = 1
        job.detail = nil

        let title = result["title"] as? String ?? "Download"
        let channel = result["channel"] as? String
        let files = (result["files"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            .map { URL(fileURLWithPath: $0) }

        let artwork = await MediaFinisher.thumbnailJPEG(
            from: (result["thumbnail"] as? String).flatMap(URL.init(string:)),
            square: job.mode == .audio && settings.squareAudioArtwork
        )
        let uploadDate = (result["upload_date"] as? String).flatMap(Self.parseUploadDate)
        let tags = MediaFinisher.Tags(
            title: title,
            artist: channel,
            album: settings.channelAsAlbum ? channel : nil,
            date: uploadDate.map { ISO8601DateFormatter.string(from: $0, timeZone: .gmt, formatOptions: [.withFullDate]) },
            description: result["description"] as? String,
            artwork: artwork
        )

        let output = workdir.appendingPathComponent(job.mode == .audio ? "final.m4a" : "final.mp4")
        do {
            try await MediaFinisher.export(inputs: files, mode: job.mode, tags: tags, to: output)
            let info = StoredInfo(
                videoID: result["id"] as? String,
                title: title,
                channel: channel,
                duration: (result["duration"] as? NSNumber)?.doubleValue,
                uploadDate: uploadDate,
                webpageURL: result["webpage_url"] as? String,
                summary: result["description"] as? String,
                viewCount: (result["view_count"] as? NSNumber)?.intValue,
                thumbnailFile: nil,
                downloadedAt: Date()
            )
            job.resultFile = try library.store(file: output, preferredName: title, info: info, thumbnail: artwork)
            job.state = .finished
            job.phase = "Downloaded"
        } catch {
            fail(job, error.localizedDescription)
        }
    }

    private func fail(_ job: DownloadJob, _ message: String) {
        job.state = .failed(message)
        job.phase = "Failed"
        job.fraction = nil
        job.detail = nil
    }

    private static func parseUploadDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd"
        return f.date(from: s)
    }
}
