import AVFoundation
import Speech

/// Records a voice note while a face is held: AAC to a file, a live level
/// for the waveform, and an on-device transcript as you speak.
@MainActor
final class VoiceRecorder: ObservableObject {
    /// Recent loudness, 0…1, newest last; the waveform scrolls through it.
    @Published private(set) var levels: [Float] = []
    @Published private(set) var transcript = ""
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var isRecording = false

    struct Take {
        let url: URL
        let duration: TimeInterval
        /// The whole take's loudness, about 24 samples a second.
        let levels: [UInt8]
        let transcript: String
    }

    static let levelsPerSecond = 24.0
    static let maxDuration: TimeInterval = 120

    private var engine: AVAudioEngine?
    private var writer: TapWriter?
    private var recognition: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var startedAt: Date?
    private var clock: Timer?
    private var allLevels: [Float] = []
    private var onLimit: (() -> Void)?

    var micAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    static func requestMic() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static var speechAuthorized: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }

    static func requestSpeech() async -> Bool {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return speechAuthorized }
        return await withCheckedContinuation { done in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0 == .authorized) }
        }
    }

    /// Starts at once; `onLimit` runs if the take reaches `maxDuration`.
    func start(directory: URL, transcribe: Bool, onLimit: @escaping () -> Void) throws {
        guard !isRecording else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noMicrophone }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        // The file's processing format must match the tap's buffers, so it
        // keeps the microphone's rate and channels; AAC keeps it small.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 40_000 * Int(format.channelCount)
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: format.commonFormat,
                                   interleaved: format.isInterleaved)

        var request: SFSpeechAudioBufferRecognitionRequest?
        if transcribe, Self.speechAuthorized, let recognizer = SFSpeechRecognizer(), recognizer.isAvailable {
            let r = SFSpeechAudioBufferRecognitionRequest()
            r.shouldReportPartialResults = true
            // Never leaves the Mac: no transcript at all rather than a server one.
            if recognizer.supportsOnDeviceRecognition {
                r.requiresOnDeviceRecognition = true
                r.addsPunctuation = true
                request = r
                recognition = recognizer.recognitionTask(with: r) { [weak self] result, _ in
                    guard let text = result?.bestTranscription.formattedString else { return }
                    Task { @MainActor in self?.transcript = text }
                }
            }
        }

        let writer = TapWriter(file: file, request: request) { [weak self] level in
            Task { @MainActor in self?.append(level) }
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in writer.write(buffer) }
        engine.prepare()
        try engine.start()

        self.engine = engine
        self.writer = writer
        self.request = request
        self.onLimit = onLimit
        levels = Array(repeating: 0, count: 64)
        allLevels = []
        transcript = ""
        elapsed = 0
        startedAt = Date()
        isRecording = true
        clock = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Ends the take. `nil` when it was too short to be meant.
    func stop() async -> Take? {
        guard isRecording, let engine, let writer, let startedAt else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        clock?.invalidate()
        isRecording = false
        request?.endAudio()
        let duration = Date().timeIntervalSince(startedAt)
        let url = writer.finish()
        // Give the recognizer a beat to settle on the final words.
        if recognition != nil { try? await Task.sleep(nanoseconds: 450_000_000) }
        recognition?.cancel()
        let take = Take(url: url, duration: duration, levels: Self.downsample(allLevels, duration: duration),
                        transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines))
        reset()
        guard duration >= 0.35 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return take
    }

    func cancel() {
        guard isRecording, let engine, let writer else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        clock?.invalidate()
        isRecording = false
        recognition?.cancel()
        try? FileManager.default.removeItem(at: writer.finish())
        reset()
    }

    private func reset() {
        engine = nil
        writer = nil
        recognition = nil
        request = nil
        startedAt = nil
        onLimit = nil
    }

    private func tick() {
        guard let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        if elapsed >= Self.maxDuration { onLimit?() }
    }

    private func append(_ level: Float) {
        guard isRecording else { return }
        allLevels.append(level)
        levels.append(level)
        if levels.count > 64 { levels.removeFirst(levels.count - 64) }
    }

    static func downsample(_ levels: [Float], duration: TimeInterval) -> [UInt8] {
        let count = max(1, min(Int(duration * levelsPerSecond), 4_000))
        guard !levels.isEmpty else { return Array(repeating: 0, count: count) }
        return (0..<count).map { index in
            let from = index * levels.count / count
            let to = max(from + 1, (index + 1) * levels.count / count)
            let peak = levels[from..<min(to, levels.count)].max() ?? 0
            return UInt8(max(0, min(255, peak * 255)))
        }
    }

    enum RecorderError: LocalizedError {
        case noMicrophone

        var errorDescription: String? { "No microphone is available." }
    }
}

#if DEBUG
extension VoiceRecorder {
    /// Plays a recording without a microphone, for demos.
    func demoBegin() {
        levels = Array(repeating: 0, count: 64)
        transcript = ""
        elapsed = 0
        isRecording = true
    }

    func demoFeed(level: Float, elapsed: TimeInterval, transcript: String) {
        levels.append(level)
        if levels.count > 64 { levels.removeFirst(levels.count - 64) }
        self.elapsed = elapsed
        self.transcript = transcript
    }

    func demoEnd() {
        isRecording = false
    }
}
#endif

/// Runs on the audio thread: writes buffers, feeds the recognizer and
/// measures loudness.
private final class TapWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private let url: URL
    private let request: SFSpeechAudioBufferRecognitionRequest?
    private let report: (Float) -> Void

    init(file: AVAudioFile, request: SFSpeechAudioBufferRecognitionRequest?, report: @escaping (Float) -> Void) {
        self.file = file
        url = file.url
        self.request = request
        self.report = report
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        try? file?.write(from: buffer)
        lock.unlock()
        request?.append(buffer)
        report(Self.level(of: buffer))
    }

    /// Closes the file, so the AAC trailer is written.
    func finish() -> URL {
        lock.lock()
        file = nil
        lock.unlock()
        return url
    }

    /// RMS mapped from about -50…-8 dBFS to 0…1, so speech fills the range.
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        return max(0, min(1, (db + 50) / 42))
    }
}

/// Plays voice notes one at a time and reports progress for the waveform.
@MainActor
final class VoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playing: String?
    @Published private(set) var progress: Double = 0

    private var player: AVAudioPlayer?
    private var clock: Timer?
    private var queue: [(id: String, url: URL)] = []
    var onFinish: ((String) -> Void)?

    func toggle(_ id: String, url: URL) {
        if playing == id {
            stop()
        } else {
            queue.removeAll()
            play(id, url: url)
        }
    }

    /// Plays after whatever is playing, as messages arrive in a row.
    func enqueue(_ id: String, url: URL) {
        if playing == nil { play(id, url: url) } else { queue.append((id, url)) }
    }

    func stop() {
        player?.stop()
        finish()
        queue.removeAll()
    }

    #if DEBUG
    func demoPlay(_ id: String?, progress: Double) {
        playing = id
        self.progress = progress
    }
    #endif

    private func play(_ id: String, url: URL) {
        player?.stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.delegate = self
        player.play()
        self.player = player
        playing = id
        progress = 0
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player, player.duration > 0 else { return }
                self.progress = player.currentTime / player.duration
            }
        }
    }

    private func finish() {
        clock?.invalidate()
        clock = nil
        if let playing { onFinish?(playing) }
        player = nil
        playing = nil
        progress = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.finish()
            if !self.queue.isEmpty {
                let next = self.queue.removeFirst()
                self.play(next.id, url: next.url)
            }
        }
    }
}
