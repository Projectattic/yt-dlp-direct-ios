import Foundation
import Observation

/// The download folder (the app's own Documents, or a folder you picked such as VLC's)
/// and everything the app knows about the files in it.
@MainActor
@Observable
final class LibraryStore {
    private(set) var items: [MediaItem] = []
    private(set) var isLoading = false
    private(set) var customFolderURL: URL?
    var lastError: String?

    private var database: [String: StoredInfo] = [:]
    private var accessedURL: URL?

    private static let bookmarkKey = "downloadFolderBookmark"
    private let supportURL: URL
    private let databaseURL: URL
    let thumbnailsURL: URL
    let documentsURL: URL

    init() {
        let fm = FileManager.default
        supportURL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        databaseURL = supportURL.appendingPathComponent("library.json")
        thumbnailsURL = supportURL.appendingPathComponent("thumbnails", isDirectory: true)
        documentsURL = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: thumbnailsURL, withIntermediateDirectories: true)
        loadDatabase()
        restoreFolder()
        refresh()
    }

    /// Where finished downloads go.
    var folderURL: URL { customFolderURL ?? documentsURL }

    var folderDescription: String {
        customFolderURL?.lastPathComponent ?? "This app (On My iPhone)"
    }

    /// True when the file lives in this app's own container. VLC can't read those
    /// directly, so they play in the built-in player instead.
    func isInOwnContainer(_ url: URL) -> Bool {
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        return url.resolvingSymlinksInPath().path.hasPrefix(home)
    }

    // MARK: Folder choice

    func setCustomFolder(_ url: URL) {
        let started = url.startAccessingSecurityScopedResource()
        do {
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
            beginAccess(url, alreadyStarted: started)
            refresh()
        } catch {
            if started { url.stopAccessingSecurityScopedResource() }
            lastError = "Couldn't use that folder: \(error.localizedDescription)"
        }
    }

    func useAppFolder() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
        customFolderURL = nil
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        refresh()
    }

    private func restoreFolder() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            let started = url.startAccessingSecurityScopedResource()
            if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
            }
            beginAccess(url, alreadyStarted: started)
        } catch {
            lastError = "The chosen download folder can't be found any more, so downloads go to this app's folder. Pick it again in Settings."
        }
    }

    private func beginAccess(_ url: URL, alreadyStarted: Bool) {
        accessedURL?.stopAccessingSecurityScopedResource()
        if !alreadyStarted { _ = url.startAccessingSecurityScopedResource() }
        accessedURL = url
        customFolderURL = url
    }

    // MARK: Database

    private func loadDatabase() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: databaseURL),
           let saved = try? decoder.decode([String: StoredInfo].self, from: data) {
            database = saved
        }
    }

    private func saveDatabase() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(database) {
            try? data.write(to: databaseURL, options: .atomic)
        }
    }

    // MARK: Adding downloads

    /// Moves a finished file into the download folder under a readable, unique name.
    func store(file: URL, preferredName: String, info: StoredInfo, thumbnail: Data?) throws -> URL {
        let fm = FileManager.default
        let folder = folderURL
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let ext = file.pathExtension
        let base = Self.safeFileName(preferredName)
        var destination = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while fm.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            n += 1
        }

        do {
            try fm.moveItem(at: file, to: destination)
        } catch {
            // Moving into another app's folder can fail; copying works.
            try fm.copyItem(at: file, to: destination)
            try? fm.removeItem(at: file)
        }

        var info = info
        if let thumbnail {
            let name = (info.videoID ?? UUID().uuidString) + ".jpg"
            try? thumbnail.write(to: thumbnailsURL.appendingPathComponent(name), options: .atomic)
            info.thumbnailFile = name
        }
        database[destination.lastPathComponent] = info
        saveDatabase()
        refresh()
        return destination
    }

    static func safeFileName(_ name: String) -> String {
        let replacements: [Character: String] = ["/": "⧸", "\\": "⧹", ":": "：", "*": "＊", "?": "？",
                                                 "\"": "＂", "<": "＜", ">": "＞", "|": "｜"]
        var out = ""
        for ch in name where !ch.isNewline {
            out += replacements[ch] ?? String(ch)
        }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if out.isEmpty { out = "Download" }
        return String(out.prefix(150))
    }

    // MARK: Scanning

    func refresh() {
        Task { await reload() }
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        let folder = folderURL
        let database = database
        let thumbs = thumbnailsURL
        do {
            items = try await Task.detached(priority: .userInitiated) {
                try Self.scan(folder: folder, database: database, thumbnails: thumbs)
            }.value
            if customFolderURL != nil || lastError?.hasPrefix("Couldn't read") == true { lastError = nil }
        } catch {
            lastError = "Couldn't read the download folder: \(error.localizedDescription)"
        }
    }

    nonisolated private static func scan(folder: URL, database: [String: StoredInfo], thumbnails: URL) throws -> [MediaItem] {
        let video: Set<String> = ["mp4", "m4v", "mov", "mkv", "webm"]
        let audio: Set<String> = ["m4a", "mp3", "aac", "opus", "ogg", "flac", "wav"]
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey, .contentModificationDateKey]
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])
        var items: [MediaItem] = []
        for file in files {
            let ext = file.pathExtension.lowercased()
            let kind: MediaKind
            if video.contains(ext) { kind = .video } else if audio.contains(ext) { kind = .audio } else { continue }
            let values = try? file.resourceValues(forKeys: Set(keys))
            let info = database[file.lastPathComponent]
            let thumb = info?.thumbnailFile.map { thumbnails.appendingPathComponent($0) }
            items.append(MediaItem(
                url: file,
                kind: kind,
                info: info,
                thumbnailURL: thumb,
                fileSize: values?.fileSize.map { Int64($0) },
                dateAdded: info?.downloadedAt ?? values?.creationDate ?? values?.contentModificationDate ?? .distantPast
            ))
        }
        return items.sorted { $0.dateAdded > $1.dateAdded }
    }

    // MARK: Deleting

    func delete(_ item: MediaItem) {
        do {
            try FileManager.default.removeItem(at: item.url)
            if let info = database.removeValue(forKey: item.fileName) {
                let stillUsed = database.values.contains { $0.thumbnailFile == info.thumbnailFile }
                if !stillUsed, let thumb = info.thumbnailFile {
                    try? FileManager.default.removeItem(at: thumbnailsURL.appendingPathComponent(thumb))
                }
                saveDatabase()
            }
            items.removeAll { $0.url == item.url }
        } catch {
            lastError = "Couldn't delete “\(item.title)”: \(error.localizedDescription)"
        }
    }
}
