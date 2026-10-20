import Foundation

/// What `ffmpeg -i` says about a file.
struct MediaInfo: Equatable, Sendable {
    var duration: Double?
    var videoCodec: String?
    var audioCodec: String?

    /// Parses ffmpeg's description of its input, from stderr.
    init(ffmpegOutput text: String) {
        for line in text.split(separator: "\n") {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Duration:"), duration == nil {
                let value = line.dropFirst("Duration:".count).split(separator: ",").first?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                duration = Self.seconds(value)
            } else if line.hasPrefix("Stream #") {
                if videoCodec == nil, !line.contains("(attached pic)"), let codec = Self.codec(after: "Video: ", in: line) {
                    videoCodec = codec
                } else if audioCodec == nil, let codec = Self.codec(after: "Audio: ", in: line) {
                    audioCodec = codec
                }
            }
        }
    }

    init(duration: Double? = nil, videoCodec: String? = nil, audioCodec: String? = nil) {
        self.duration = duration
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
    }

    /// "00:01:02.50" → 62.5; nil for "N/A".
    static func seconds(_ text: String) -> Double? {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    private static func codec(after marker: String, in line: String) -> String? {
        guard let range = line.range(of: marker) else { return nil }
        let word = line[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return word.isEmpty ? nil : String(word)
    }
}

/// The encoders an ffmpeg has. Builds differ: Homebrew's has no WebP or
/// libaom, the static build has everything.
struct Encoders: Equatable, Sendable {
    /// nil until known; then everything is assumed, as in the static build.
    let names: Set<String>?

    static let unknown = Encoders(names: nil)

    /// The first of these the build has.
    func first(_ candidates: String...) -> String? {
        guard let names else { return candidates.first }
        return candidates.first(where: names.contains)
    }

    /// Parses `ffmpeg -encoders`: " V....D libx264  libx264 H.264 …".
    init(listing: String) {
        var names = Set<String>()
        for line in listing.split(separator: "\n") {
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            guard words.count >= 2, let flags = words.first, flags.count == 6, words[1] != "=",
                  flags.first.map({ "VAS".contains($0) }) == true else { continue }
            names.insert(String(words[1]))
        }
        self.names = names
    }

    init(names: Set<String>?) {
        self.names = names
    }
}

/// The ffmpeg arguments for each action, between the input and the output.
enum MediaRecipe {
    /// Codecs MP4 and MOV take as they are, so a remux needs no re-encode.
    static let copyableVideo: Set<String> = ["h264", "hevc"]
    static let copyableAudio: Set<String> = ["aac", "alac", "mp3"]
    static let evenSize = "scale=trunc(iw/2)*2:trunc(ih/2)*2"

    /// Whether this ffmpeg can do it at all, so the wheel only offers what works.
    static func isSupported(_ action: Action, kind: FileKind, encoders: Encoders) -> Bool {
        switch action {
        case .convert(let format):
            switch format {
            case .mp4, .mov: return h264Encoder(encoders) != nil
            case .webm: return encoders.first("libvpx-vp9") != nil
            case .webp: return encoders.first(kind == .gif ? "libwebp_anim" : "libwebp") != nil
            case .avif: return encoders.first("libaom-av1", "libsvtav1") != nil
            case .mp3: return encoders.first("libmp3lame") != nil
            case .ogg: return encoders.first("libvorbis", "vorbis") != nil
            case .opus: return encoders.first("libopus", "opus") != nil
            default: return true
            }
        case .tool(let tool):
            return tool == .compress || tool == .halfSize ? h264Encoder(encoders) != nil : true
        }
    }

    static func arguments(for action: Action, kind: FileKind, info: MediaInfo, quality: Quality,
                          encoders: Encoders = .unknown) -> [String] {
        switch action {
        case .convert(let format): convert(to: format, kind: kind, info: info, quality: quality, encoders: encoders)
        case .tool(let tool): apply(tool, info: info, quality: quality, encoders: encoders)
        }
    }

    /// The output's extension when a tool keeps the format.
    static func toolExtension(_ tool: Tool, source: String) -> String {
        switch tool {
        case .compress, .halfSize: ["mp4", "mov", "m4v"].contains(source.lowercased()) ? source.lowercased() : "mp4"
        default: source.lowercased()
        }
    }

    private static func convert(to format: Format, kind: FileKind, info: MediaInfo, quality: Quality,
                                encoders: Encoders) -> [String] {
        let audio = info.audioCodec != nil
        let level = quality == .high ? 0 : quality == .balanced ? 1 : 2
        func pick(_ values: [String]) -> String { values[level] }
        switch format {
        case .mp4, .mov:
            let faststart = format == .mp4 ? ["-movflags", "+faststart"] : []
            if kind == .video, let video = info.videoCodec, copyableVideo.contains(video),
               info.audioCodec.map(copyableAudio.contains) ?? true {
                // Already H.264 or HEVC: rewrap in a moment, losing nothing.
                let tag = video == "hevc" ? ["-tag:v", "hvc1"] : []
                return ["-map", "0:v:0", "-map", "0:a:0?", "-c", "copy"] + tag + faststart
            }
            let sound = audio ? ["-map", "0:a:0", "-c:a", "aac", "-b:a", "160k"] : ["-an"]
            let video = ["-map", "0:v:0"] + h264(quality.crf, encoders: encoders) + ["-vf", evenSize]
            return video + sound + faststart
        case .webm:
            // A GIF's transparency carries over; VP9 refuses its RGB pixels as they are.
            let video = ["-map", "0:v:0", "-c:v", "libvpx-vp9", "-crf", String(quality.crf + 9), "-b:v", "0",
                         "-row-mt", "1", "-deadline", "good", "-cpu-used", "4",
                         "-pix_fmt", kind == .gif ? "yuva420p" : "yuv420p"]
            guard audio, kind == .video, let opus = encoders.first("libopus", "opus") else { return video + ["-an"] }
            return video + ["-map", "0:a:0", "-c:a", opus, "-b:a", "128k"] + (opus == "opus" ? ["-strict", "-2", "-ac", "2"] : [])
        case .gif:
            let width = pick(["960", "720", "480"])
            let fps = quality == .small ? 12 : 15
            let filter = "fps=\(fps),scale='min(\(width),iw)':-2:flags=lanczos,split[a][b];"
                + "[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4"
            return ["-vf", filter, "-loop", "0", "-an"]
        case .webp:
            if kind == .gif {
                return ["-c:v", "libwebp_anim", "-quality", String(quality.webp), "-loop", "0", "-an"]
            }
            return ["-frames:v", "1", "-c:v", "libwebp", "-quality", String(quality.webp)]
        case .avif:
            let still = ["-frames:v", "1", "-pix_fmt", "yuv420p", "-vf", evenSize]
            if encoders.first("libaom-av1") != nil {
                return still + ["-c:v", "libaom-av1", "-still-picture", "1", "-crf", String(quality.crf + 6), "-cpu-used", "6"]
            }
            return still + ["-c:v", "libsvtav1", "-crf", String(quality.crf + 8), "-preset", "6"]
        case .mp3:
            return ["-vn", "-map", "0:a:0", "-c:a", "libmp3lame", "-q:a", pick(["0", "2", "5"])]
        case .m4a:
            return ["-vn", "-map", "0:a:0", "-c:a", "aac", "-b:a", pick(["256k", "192k", "128k"])]
        case .wav:
            return ["-vn", "-map", "0:a:0", "-c:a", "pcm_s16le"]
        case .aiff:
            return ["-vn", "-map", "0:a:0", "-c:a", "pcm_s16be"]
        case .flac:
            return ["-vn", "-map", "0:a:0", "-c:a", "flac"]
        case .ogg:
            let quality = ["-q:a", pick(["7", "5", "3"])]
            // ffmpeg's own Vorbis encoder is experimental and stereo only, but it works.
            if encoders.first("libvorbis") != nil { return ["-vn", "-map", "0:a:0", "-c:a", "libvorbis"] + quality }
            return ["-vn", "-map", "0:a:0", "-c:a", "vorbis", "-strict", "-2", "-ac", "2"] + quality
        case .opus:
            let opus = encoders.first("libopus", "opus") ?? "libopus"
            let extra = opus == "opus" ? ["-strict", "-2", "-ac", "2", "-ar", "48000"] : []
            return ["-vn", "-map", "0:a:0", "-c:a", opus, "-b:a", pick(["160k", "128k", "96k"])] + extra
        default:
            return []
        }
    }

    private static func apply(_ tool: Tool, info: MediaInfo, quality: Quality, encoders: Encoders) -> [String] {
        let sound = info.audioCodec != nil ? ["-map", "0:a:0", "-c:a", "aac", "-b:a", "128k"] : ["-an"]
        switch tool {
        case .compress:
            let video = ["-map", "0:v:0"] + h264(quality.crf + 5, preset: "slow", encoders: encoders) + ["-vf", evenSize]
            return video + sound + ["-movflags", "+faststart"]
        case .halfSize:
            let video = ["-map", "0:v:0"] + h264(quality.crf, encoders: encoders) + ["-vf", "scale=trunc(iw/4)*2:trunc(ih/4)*2"]
            return video + sound + ["-movflags", "+faststart"]
        case .mute:
            return ["-map", "0:v", "-c", "copy", "-an"]
        case .stripMetadata:
            return ["-map", "0:v?", "-map", "0:a?", "-map_metadata", "-1", "-map_chapters", "-1", "-c", "copy"]
        case .removeBackground, .copyText:
            return []
        }
    }

    private static func h264Encoder(_ encoders: Encoders) -> String? {
        encoders.first("libx264", "h264_videotoolbox")
    }

    /// x264 when the build has it; otherwise the Mac's hardware encoder.
    private static func h264(_ crf: Int, preset: String = "medium", encoders: Encoders) -> [String] {
        if h264Encoder(encoders) == "h264_videotoolbox" {
            // Constant quality, roughly matching the CRF.
            return ["-c:v", "h264_videotoolbox", "-q:v", String(max(30, 100 - crf * 2)), "-pix_fmt", "yuv420p"]
        }
        return ["-c:v", "libx264", "-preset", preset, "-crf", String(crf), "-pix_fmt", "yuv420p"]
    }
}

/// Follows `-progress pipe:1` output: time encoded so far, in seconds.
struct ProgressParser {
    private var buffer = ""

    /// Feeds a chunk of output; returns the latest time it reports, if any.
    mutating func feed(_ chunk: String) -> Double? {
        buffer += chunk
        var latest: Double?
        while let newline = buffer.firstIndex(of: "\n") {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if line.hasPrefix("out_time_us="), let micro = Double(line.dropFirst("out_time_us=".count)), micro >= 0 {
                latest = micro / 1_000_000
            }
        }
        return latest
    }
}

/// Runs ffmpeg, reporting progress and stopping it when the task is cancelled.
enum MediaEngine {
    static func probe(_ input: URL, ffmpeg: URL) async throws -> MediaInfo {
        let result = try await execute(ffmpeg, ["-hide_banner", "-nostdin", "-i", input.path], progress: nil)
        return MediaInfo(ffmpegOutput: result.stderr)
    }

    static func run(_ action: Action, kind: FileKind, input: URL, output: URL, ffmpeg: URL, encoders: Encoders,
                    quality: Quality, progress: @escaping @Sendable (Double) -> Void) async throws {
        let info = try await probe(input, ffmpeg: ffmpeg)
        let arguments = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-nostats", "-progress", "pipe:1",
                         "-i", input.path]
            + MediaRecipe.arguments(for: action, kind: kind, info: info, quality: quality, encoders: encoders)
            + [output.path]
        let duration = info.duration
        do {
            let result = try await execute(ffmpeg, arguments) { seconds in
                guard let duration, duration > 0 else { return }
                progress(min(max(seconds / duration, 0), 1))
            }
            guard result.status == 0 else { throw ConversionError.message(Self.reason(result.stderr)) }
        } catch {
            // Half a file is worse than none.
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// The first line that names the problem, without ffmpeg's "[component @ 0x…]" prefixes.
    static func reason(_ stderr: String) -> String {
        let lines = stderr.split(separator: "\n").map { line -> String in
            var text = Substring(line)
            while text.hasPrefix("["), let close = text.firstIndex(of: "]") {
                text = text[text.index(after: close)...].drop { $0 == " " }
            }
            return text.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        if lines.contains(where: { $0.contains("does not contain any stream") || $0.contains("matches no streams") }) {
            return "There's nothing to convert in this file."
        }
        let markers = ["Error", "error", "Invalid", "not found", "No such", "Unknown", "not supported", "Unsupported"]
        let line = lines.first { line in markers.contains(where: line.contains) } ?? lines.last
        return line.map { String($0.prefix(160)) } ?? "ffmpeg couldn't convert this file."
    }

    private struct Result {
        var status: Int32
        var stderr: String
    }

    private static func execute(_ ffmpeg: URL, _ arguments: [String], progress: (@Sendable (Double) -> Void)?) async throws -> Result {
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        // SVT-AV1 talks on stderr whatever the log level; errors only.
        process.environment = ProcessInfo.processInfo.environment.merging(["SVT_LOG": "1"]) { $1 }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let state = PipeState()
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let progress, let seconds = state.parse(data) else { return }
            progress(seconds)
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { state.appendError(data) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                process.terminationHandler = { process in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    state.appendError(err.fileHandleForReading.readDataToEndOfFile())
                    if state.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(returning: Result(status: process.terminationStatus, stderr: state.errorText))
                    }
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            state.cancel()
            if process.isRunning { process.terminate() }
        }
    }

    private final class PipeState: @unchecked Sendable {
        private let lock = NSLock()
        private var parser = ProgressParser()
        private var error = Data()
        private var cancelled = false

        func parse(_ data: Data) -> Double? {
            lock.withLock { parser.feed(String(decoding: data, as: UTF8.self)) }
        }

        func appendError(_ data: Data) {
            lock.withLock {
                error.append(data)
                // Only the end matters, and a chatty file shouldn't fill memory.
                if error.count > 64_000 { error = error.suffix(16_000) }
            }
        }

        var errorText: String { lock.withLock { String(decoding: error, as: UTF8.self) } }

        func cancel() { lock.withLock { cancelled = true } }
        var isCancelled: Bool { lock.withLock { cancelled } }
    }
}
