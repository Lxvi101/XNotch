import AppKit
import Observation

/// Where converted files go and what they're called.
enum Output {
    static func directory(for source: URL, location: OutputLocation) -> URL {
        let folder = source.deletingLastPathComponent()
        if location == .besideOriginal, !isHidden(folder), FileManager.default.isWritableFile(atPath: folder.path) {
            return folder
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? folder
    }

    /// Somewhere nobody looks: a shelf's own storage in Library, or a
    /// temporary folder a drop from Photos or Mail landed in.
    static func isHidden(_ folder: URL) -> Bool {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        return path.hasPrefix(home + "/Library/") || path.hasPrefix(temporary) || path.hasPrefix("/private/var/folders/")
    }

    /// "Photo.heic" → "Photo.jpg"; a tool adds its name: "Photo (Compressed).heic".
    static func name(for source: URL, suffix: String?, extension ext: String) -> String {
        let base = source.deletingPathExtension().lastPathComponent
        return (suffix.map { "\(base) (\($0))" } ?? base) + "." + ext
    }

    /// The URL itself when free, else numbered like Finder: "Photo 2.jpg".
    static func available(_ url: URL) -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for n in 2... {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = url.deletingLastPathComponent().appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}

/// One drop on the wheel: an operation on one or more files.
@MainActor @Observable
final class ConversionJob {
    enum Phase: Equatable {
        case installing(Double?)
        case working
        case done
        case failed(String)
        case cancelled
    }

    let operation: Action
    let kind: FileKind
    let sources: [URL]
    var phase = Phase.working
    /// 0…1, or nil while there's no telling.
    var progress: Double?
    var outputs: [URL] = []
    /// Files finished so far, for a bulk job's "3 of 12".
    var completed = 0
    /// Where the outputs go besides the disk: the shelf the files came from.
    var deliver: (@MainActor ([URL]) -> Void)?
    /// What happened, when there's no file to show: "Copied 120 words".
    var note: String?
    let started = Date()
    fileprivate var task: Task<Void, Never>?

    init(operation: Action, kind: FileKind, sources: [URL]) {
        self.operation = operation
        self.kind = kind
        self.sources = sources
    }

    var isFinished: Bool {
        switch phase {
        case .done, .failed, .cancelled: true
        case .installing, .working: false
        }
    }

    func cancel() {
        task?.cancel()
    }
}

/// Runs jobs: everything heavy off the main thread, one file after another.
@MainActor
final class ConversionRunner {
    private let ffmpeg: FFmpeg
    private let preferences: ConverterPreferences
    var onFinish: ((ConversionJob) -> Void)?
    /// The folder each source's output goes to.
    var directory: (URL) -> URL

    init(ffmpeg: FFmpeg, preferences: ConverterPreferences) {
        self.ffmpeg = ffmpeg
        self.preferences = preferences
        directory = { [unowned preferences] source in Output.directory(for: source, location: preferences.output) }
    }

    func start(_ job: ConversionJob) {
        job.task = Task { [weak self] in
            guard let self else { return }
            do {
                try await run(job)
                job.phase = .done
                job.progress = 1
            } catch is CancellationError {
                job.phase = .cancelled
            } catch {
                job.phase = Task.isCancelled ? .cancelled : .failed(Self.message(for: error))
            }
            if job.phase == .done, !job.outputs.isEmpty {
                if let deliver = job.deliver {
                    deliver(job.outputs)
                } else if preferences.revealWhenDone {
                    NSWorkspace.shared.activateFileViewerSelecting(job.outputs)
                }
            }
            onFinish?(job)
        }
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func run(_ job: ConversionJob) async throws {
        let quality = preferences.quality
        if job.operation == .tool(.copyText) { return try await copyText(job) }
        var ffmpegLocation: FFmpeg.Location?
        if Catalog.needsFFmpeg(job.operation, kind: job.kind) {
            ffmpegLocation = try await ffmpeg.resolve { [weak job] state in
                guard let job else { return }
                switch state {
                case .downloading(let fraction): job.phase = .installing(fraction)
                case .verifying: job.phase = .installing(1)
                case .idle, .failed: break
                }
            }
            job.phase = .working
        }
        let count = Double(job.sources.count)
        for (index, source) in job.sources.enumerated() {
            try Task.checkCancellation()
            let report: @Sendable (Double) -> Void = { [weak job] fraction in
                Task { @MainActor in job?.progress = (Double(index) + fraction) / count }
            }
            let directory = directory(source)
            let outputs = try await perform(job.operation, kind: job.kind, source: source, directory: directory,
                                            ffmpeg: ffmpegLocation, quality: quality, progress: report)
            job.outputs += outputs
            job.completed = index + 1
            job.progress = Double(index + 1) / count
        }
    }

    private func perform(_ operation: Action, kind: FileKind, source: URL, directory: URL, ffmpeg: FFmpeg.Location?,
                         quality: Quality, progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        let ext = source.pathExtension.lowercased()
        switch operation {
        case .convert(let format):
            // In a batch, the files already in this format stay as they are.
            if format.aliases.contains(ext) { return [] }
            let output = Output.available(directory.appendingPathComponent(Output.name(for: source, suffix: nil, extension: format.fileExtension)))
            if let ffmpeg {
                try await convertWithFFmpeg(operation, kind: kind, source: source, output: output, ffmpeg: ffmpeg,
                                            quality: quality, progress: progress)
                return [output]
            }
            switch kind {
            case .image, .gif:
                try await offMain { try ImageEngine.convert(source, to: format, output: output, quality: quality) }
                return [output]
            case .pdf where ImageEngine.type(for: format) != nil:
                return try await offMain {
                    try ImageEngine.renderPages(of: source, as: format, output: output, quality: quality, progress: progress)
                }
            case .pdf, .document:
                if DocumentEngine.needsMainThread(source) {
                    try DocumentEngine.write(DocumentEngine.read(source), as: format, to: output)
                } else {
                    try await offMain { try DocumentEngine.write(DocumentEngine.read(source), as: format, to: output) }
                }
                return [output]
            case .video, .audio:
                throw ConversionError.message("ffmpeg is needed for this.")
            }

        case .tool(let tool):
            let isMedia = kind == .video || kind == .audio
            let toolExt: String
            switch tool {
            case .removeBackground: toolExt = "png"
            case _ where isMedia: toolExt = MediaRecipe.toolExtension(tool, source: ext)
            case _ where kind == .pdf: toolExt = "pdf"
            default: toolExt = ImageEngine.outputType(for: source).preferredFilenameExtension ?? "png"
            }
            var output = Output.available(directory.appendingPathComponent(Output.name(for: source, suffix: tool.suffix, extension: toolExt)))
            if isMedia {
                guard let ffmpeg else { throw ConversionError.message("ffmpeg is needed for this.") }
                try await MediaEngine.run(operation, kind: kind, input: source, output: output, ffmpeg: ffmpeg.url,
                                          encoders: ffmpeg.encoders, quality: quality, progress: progress)
            } else {
                let target = output
                output = try await offMain { () -> URL in
                    switch (tool, kind) {
                    case (.compress, .pdf): try ImageEngine.compressPDF(source, output: target)
                    case (.compress, _): return try ImageEngine.compress(source, output: target, quality: quality)
                    case (.halfSize, _): try ImageEngine.halfSize(source, output: target, quality: quality)
                    case (.stripMetadata, _): try ImageEngine.stripMetadata(source, output: target)
                    case (.removeBackground, _): try ImageEngine.removeBackground(source, output: target)
                    default: throw ConversionError.message("\(tool.title) doesn't work on this file.")
                    }
                    return target
                }
            }
            if tool == .compress { try Self.keepIfSmaller(output, than: source) }
            return [output]
        }
    }

    /// Images go to ffmpeg as PNG, so it never has to read HEIC or RAW itself.
    private func convertWithFFmpeg(_ operation: Action, kind: FileKind, source: URL, output: URL, ffmpeg: FFmpeg.Location,
                                   quality: Quality, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard MediaRecipe.isSupported(operation, kind: kind, encoders: ffmpeg.encoders) else {
            throw ConversionError.message("This ffmpeg can't make \(operation.title). Remove it in Settings to use XNotch's.")
        }
        guard kind == .image else {
            return try await MediaEngine.run(operation, kind: kind, input: source, output: output, ffmpeg: ffmpeg.url,
                                             encoders: ffmpeg.encoders, quality: quality, progress: progress)
        }
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("xnotch-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: png) }
        try await offMain {
            let image = try ImageEngine.loadImage(source)
            try ImageEngine.write(image, type: .png, to: png, quality: 1)
        }
        try await MediaEngine.run(operation, kind: kind, input: png, output: output, ffmpeg: ffmpeg.url,
                                  encoders: ffmpeg.encoders, quality: quality, progress: progress)
    }

    /// A "compressed" file that came out bigger is no use to anyone.
    private static func keepIfSmaller(_ output: URL, than source: URL) throws {
        func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        guard size(output) >= size(source) else { return }
        try? FileManager.default.removeItem(at: output)
        throw ConversionError.message("It's already as small as it gets.")
    }

    private func copyText(_ job: ConversionJob) async throws {
        var texts: [String] = []
        for source in job.sources {
            let kind = job.kind
            let text: String
            if kind == .document, DocumentEngine.needsMainThread(source) {
                text = try DocumentEngine.read(source).string
            } else {
                text = try await offMain {
                    switch kind {
                    case .pdf: try ImageEngine.pdfText(source)
                    case .document: try DocumentEngine.read(source).string
                    default: try ImageEngine.recognizeText(in: ImageEngine.loadImage(source))
                    }
                }
            }
            texts.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let text = texts.filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard !text.isEmpty else { throw ConversionError.message("There's no text to copy.") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        job.note = words == 1 ? "Copied 1 word" : "Copied \(words.formatted()) words"
    }
}

/// Runs work on a background thread; cancelling the caller cancels it.
func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    let task = Task.detached(priority: .userInitiated, operation: work)
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
}
