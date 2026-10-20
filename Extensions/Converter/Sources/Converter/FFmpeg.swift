import Foundation
import Observation
import Security

/// Finds the ffmpeg already on the Mac, or installs one with a click.
///
/// XNotch doesn't ship ffmpeg. A copy from Homebrew, MacPorts or anywhere on
/// the login shell's PATH is used as it is, so the Mac never carries two. With
/// none, Install fetches the static build Martin Riedl signs and notarizes
/// (ffmpeg.martin-riedl.de) into XNotch's own folder, checks the signature
/// and keeps it there, where Settings can remove it again.
@MainActor @Observable
final class FFmpeg {
    struct Location: Equatable {
        let url: URL
        /// Installed by XNotch rather than found on the Mac.
        let isOwn: Bool
        var version: String?
        var encoders = Encoders.unknown
    }

    enum InstallState: Equatable {
        case idle
        /// Downloading, 0…1 once the size is known.
        case downloading(Double?)
        case verifying
        case failed(String)
    }

    private(set) var location: Location?
    private(set) var hasSearched = false
    private(set) var installState = InstallState.idle
    /// Set when the Mac has its own ffmpeg as well as XNotch's copy.
    private(set) var ownCopyIsRedundant = false

    /// A path chosen in Settings, tried before anything else.
    var customPath: String? {
        didSet { if customPath != oldValue { refresh() } }
    }

    let ownDirectory: URL
    private var ownBinary: URL { ownDirectory.appendingPathComponent("ffmpeg") }
    private var search: Task<Location?, Never>?
    private var installation: Task<URL, Error>?

    init(directory: URL, customPath: String?) {
        ownDirectory = directory.appendingPathComponent("bin", isDirectory: true)
        self.customPath = customPath
    }

    var isInstalling: Bool { installation != nil }

    /// Looks again, off the main thread.
    func refresh() {
        search?.cancel()
        let custom = customPath, own = ownBinary
        let task = Task.detached(priority: .utility) { () -> (Location?, Bool) in
            let system = Self.findSystem(custom: custom)
            let ownExists = FileManager.default.isExecutableFile(atPath: own.path)
            var found = system ?? (ownExists ? Location(url: own, isOwn: true) : nil)
            if let url = found?.url {
                found?.version = Self.version(of: url)
                if let listing = try? Self.output(of: url, ["-hide_banner", "-encoders"], timeout: 5) {
                    found?.encoders = Encoders(listing: listing)
                }
            }
            return (found, system != nil && ownExists)
        }
        search = Task {
            let (found, redundant) = await task.value
            guard !Task.isCancelled else { return found }
            location = found
            ownCopyIsRedundant = redundant
            hasSearched = true
            return found
        }
    }

    /// The ffmpeg to run, installing one first if the Mac has none.
    func resolve(onInstallProgress: @escaping @MainActor (InstallState) -> Void = { _ in }) async throws -> Location {
        if search == nil { refresh() }
        if let found = await search?.value { return found }
        try await install(onProgress: onInstallProgress)
        if let found = await search?.value { return found }
        throw ConversionError.message("ffmpeg was installed but can't be found.")
    }

    /// Downloads the static build. Callers asking while it's under way wait for it.
    @discardableResult
    func install(onProgress: @escaping @MainActor (InstallState) -> Void = { _ in }) async throws -> URL {
        if let installation { return try await installation.value }
        let task = Task { () throws -> URL in
            defer { installation = nil }
            do {
                let url = try await download { [weak self] state in
                    self?.installState = state
                    onProgress(state)
                }
                installState = .idle
                refresh()
                return url
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                installState = .failed(message)
                onProgress(.failed(message))
                throw error
            }
        }
        installation = task
        return try await task.value
    }

    /// Deletes XNotch's copy.
    func removeOwnCopy() {
        try? FileManager.default.removeItem(at: ownDirectory)
        refresh()
    }

    // MARK: Finding

    nonisolated static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]

    nonisolated private static func findSystem(custom: String?) -> Location? {
        let fileManager = FileManager.default
        if let custom, fileManager.isExecutableFile(atPath: custom) {
            return Location(url: URL(fileURLWithPath: custom), isOwn: false)
        }
        let home = fileManager.homeDirectoryForCurrentUser.path
        for directory in searchDirectories + ["\(home)/.local/bin", "\(home)/bin"] {
            let path = "\(directory)/ffmpeg"
            if fileManager.isExecutableFile(atPath: path) { return Location(url: URL(fileURLWithPath: path), isOwn: false) }
        }
        // Anywhere else the user's shell knows about, such as a Nix profile.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let output = try? Self.output(of: URL(fileURLWithPath: shell), ["-lc", "command -v ffmpeg"], timeout: 3) else { return nil }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), fileManager.isExecutableFile(atPath: path) else { return nil }
        return Location(url: URL(fileURLWithPath: path), isOwn: false)
    }

    nonisolated private static func version(of url: URL) -> String? {
        guard let output = try? Self.output(of: url, ["-hide_banner", "-version"], timeout: 5),
              let line = output.split(separator: "\n").first else { return nil }
        let words = line.split(separator: " ")
        guard let index = words.firstIndex(of: "version"), index + 1 < words.count else { return nil }
        // "n7.1-tessus" and "9.0.2" alike, without build suffixes.
        let version = words[index + 1].split(separator: "-").first.map(String.init) ?? String(words[index + 1])
        return version.hasPrefix("n") ? String(version.dropFirst()) : version
    }

    nonisolated private static func output(of executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global().asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Installing

    /// The builds' signing team, checked before the binary is kept.
    nonisolated static let signingTeam = "KU3N25YGLU"

    nonisolated static var downloadURL: URL {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "amd64"
        #endif
        return URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/\(architecture)/release/ffmpeg.zip")!
    }

    private func download(progress: @escaping @MainActor (InstallState) -> Void) async throws -> URL {
        progress(.downloading(nil))
        let archive = try await DownloadTask.run(Self.downloadURL) { fraction in
            Task { @MainActor in progress(.downloading(fraction)) }
        }
        progress(.verifying)
        let destination = ownBinary
        try await Task.detached(priority: .userInitiated) {
            try Self.unpack(archive, to: destination)
        }.value
        return destination
    }

    nonisolated private static func unpack(_ archive: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appendingPathComponent("xnotch-ffmpeg-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: work)
            try? fileManager.removeItem(at: archive)
        }
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, work.path]
        try ditto.run()
        ditto.waitUntilExit()
        let binary = work.appendingPathComponent("ffmpeg")
        guard ditto.terminationStatus == 0, fileManager.fileExists(atPath: binary.path) else {
            throw ConversionError.message("The download wasn't an ffmpeg archive.")
        }
        guard isSigned(binary, team: signingTeam) else {
            throw ConversionError.message("The downloaded ffmpeg isn't signed by its builder, so it wasn't kept.")
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: binary, to: destination)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
    }

    /// A valid Developer ID signature from one team.
    nonisolated static func isSigned(_ url: URL, team: String) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess, let requirement
        else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
    }
}

/// A download with progress, to a temporary file the caller owns.
private enum DownloadTask {
    static func run(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = URLSession.shared.downloadTask(with: url) { location, response, error in
                    box.observation?.invalidate()
                    if let error { return continuation.resume(throwing: error) }
                    guard let location, let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        return continuation.resume(throwing: ConversionError.message("ffmpeg couldn't be downloaded. Check your connection and try again."))
                    }
                    // The file is deleted when this returns, so it moves first.
                    let kept = FileManager.default.temporaryDirectory.appendingPathComponent("ffmpeg-\(UUID().uuidString).zip")
                    do {
                        try FileManager.default.moveItem(at: location, to: kept)
                        continuation.resume(returning: kept)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.observation = task.progress.observe(\.fractionCompleted) { value, _ in
                    progress(value.fractionCompleted)
                }
                box.task = task
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    private final class TaskBox: @unchecked Sendable {
        var task: URLSessionDownloadTask?
        var observation: NSKeyValueObservation?
    }
}
