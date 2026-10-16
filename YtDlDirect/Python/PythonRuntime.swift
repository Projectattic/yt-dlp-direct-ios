import Foundation

/// Owns the embedded Python interpreter and runs `ytdl_bridge` actions on a
/// dedicated background queue, one at a time.
final class PythonRuntime: @unchecked Sendable {
    static let shared = PythonRuntime()

    enum RuntimeError: LocalizedError {
        case missingPython
        case startFailed(Int32)
        case noResult

        var errorDescription: String? {
            switch self {
            case .missingPython:
                "Python isn't bundled in the app. Run setup_python.sh, then rebuild in Xcode."
            case .startFailed(let code):
                "Python failed to start (code \(code))."
            case .noResult:
                "Python stopped unexpectedly. Check the Xcode console for details."
            }
        }
    }

    private let queue = DispatchQueue(label: "dk.benjy.ytdldirect.python", qos: .userInitiated)
    private var started = false

    /// Writable folder where yt-dlp and certifi are installed (and updated).
    let packagesURL: URL
    /// yt-dlp's cache (player JS etc.).
    let cacheURL: URL
    /// Scratch space for job/result files.
    let scratchURL: URL

    private init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        packagesURL = support.appendingPathComponent("python-packages", isDirectory: true)
        cacheURL = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("yt-dlp", isDirectory: true)
        scratchURL = fm.temporaryDirectory.appendingPathComponent("python-jobs", isDirectory: true)
        for url in [packagesURL, cacheURL, scratchURL] {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// Runs `ytdl_bridge.main` with `action` plus `payload`, returning the decoded result.
    func run(action: String, payload: [String: Any] = [:]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.startIfNeeded()
                    continuation.resume(returning: try self.runSync(action: action, payload: payload))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Queue-only

    private func startIfNeeded() throws {
        guard !started else { return }
        guard let resources = Bundle.main.resourceURL else { throw RuntimeError.missingPython }
        let home = resources.appendingPathComponent("python")
        guard FileManager.default.fileExists(atPath: home.path) else { throw RuntimeError.missingPython }

        setenv("NO_COLOR", "1", 1)
        setenv("PYTHON_COLORS", "0", 1)
        let rc = ytdl_python_initialize(home.path)
        guard rc == 0 else { throw RuntimeError.startFailed(rc) }
        started = true

        let appPath = resources.appendingPathComponent("app").path
        let bootstrap = """
        import sys, site
        sys.path.insert(0, \(Self.pythonLiteral(appPath)))
        site.addsitedir(\(Self.pythonLiteral(packagesURL.path)))
        """
        _ = ytdl_python_run(bootstrap)
    }

    private func runSync(action: String, payload: [String: Any]) throws -> [String: Any] {
        let id = UUID().uuidString
        let jobURL = scratchURL.appendingPathComponent("\(id)-job.json")
        let resultURL = scratchURL.appendingPathComponent("\(id)-result.json")
        defer {
            try? FileManager.default.removeItem(at: jobURL)
            try? FileManager.default.removeItem(at: resultURL)
        }

        var job = payload
        job["action"] = action
        job["result_path"] = resultURL.path
        let data = try JSONSerialization.data(withJSONObject: job, options: [.withoutEscapingSlashes])
        try data.write(to: jobURL)

        _ = ytdl_python_run("import ytdl_bridge\nytdl_bridge.main(\(Self.pythonLiteral(jobURL.path)))")

        guard let resultData = try? Data(contentsOf: resultURL),
              let result = try JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
            throw RuntimeError.noResult
        }
        return result
    }

    /// A string as a Python literal (JSON strings are valid Python strings).
    static func pythonLiteral(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}
