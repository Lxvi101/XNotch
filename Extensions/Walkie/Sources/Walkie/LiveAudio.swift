import AVFoundation
import CryptoKit
import Foundation

/// One tenth of a second of live talk, sealed for one listener.
///
/// ```
/// frame = "XNWL" || 0x01 || session (16) || u32be seq || flags || AES-256-GCM(packets)
/// packets = u16be count || (u16be len || Opus packet)…
/// ```
/// The header is the AAD, so a frame can't be moved to another session or
/// position. The key reached the listener in a sealed, signed `live` signal,
/// so only the speaker could have sealed the frames.
enum LiveFrame {
    static let magic = Data("XNWL".utf8)
    static let version: UInt8 = 1
    static let sessionBytes = 16
    static let headerBytes = magic.count + 1 + sessionBytes + 4 + 1
    /// 20 ms Opus packets per frame.
    static let packetsPerFrame = 5

    struct Header: Equatable {
        let session: Data
        let seq: UInt32
        let last: Bool
    }

    static func header(session: Data, seq: UInt32, last: Bool) -> Data {
        magic + [version] + session + seq.bigEndianBytes + [last ? 1 : 0]
    }

    static func seal(_ packets: [Data], session: Data, seq: UInt32, last: Bool, key: SymmetricKey) throws -> Data {
        var body = UInt16(packets.count).bigEndianBytes
        for packet in packets {
            body += UInt16(packet.count).bigEndianBytes
            body += packet
        }
        let header = header(session: session, seq: seq, last: last)
        guard let combined = try AES.GCM.seal(body, using: key, authenticating: header).combined else {
            throw CryptoKitError.incorrectParameterSize
        }
        return header + combined
    }

    static func isFrame(_ data: Data) -> Bool { data.count > headerBytes && data.prefix(magic.count) == magic }

    static func peek(_ data: Data) -> Header? {
        let data = Data(data)
        guard isFrame(data), data[magic.count] == version else { return nil }
        let start = magic.count + 1
        let session = data.subdata(in: start..<(start + sessionBytes))
        let seq = data.subdata(in: (start + sessionBytes)..<(start + sessionBytes + 4)).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return Header(session: session, seq: seq, last: data[start + sessionBytes + 4] & 1 == 1)
    }

    static func open(_ data: Data, key: SymmetricKey) -> [Data]? {
        let data = Data(data)
        guard isFrame(data), let box = try? AES.GCM.SealedBox(combined: data.subdata(in: headerBytes..<data.count)),
              let opened = try? AES.GCM.open(box, using: key, authenticating: data.prefix(headerBytes)),
              opened.count >= 2 else { return nil }
        let body = Data(opened)
        let count = Int(body[0]) << 8 | Int(body[1])
        var packets: [Data] = []
        var offset = 2
        for _ in 0..<count {
            guard offset + 2 <= body.count else { return nil }
            let length = Int(body[offset]) << 8 | Int(body[offset + 1])
            offset += 2
            guard offset + length <= body.count else { return nil }
            packets.append(body.subdata(in: offset..<(offset + length)))
            offset += length
        }
        return packets
    }
}

/// Opus at 48 kHz, mono, 20 ms packets: the format on both ends.
enum LiveFormat {
    static let sampleRate = 48_000.0
    static let framesPerPacket: UInt32 = 960
    static let bitRate = 24_000

    static let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    static let opus: AVAudioFormat = {
        var description = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                                      mBytesPerPacket: 0, mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0,
                                                      mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &description)!
    }()
}

// MARK: Speaking

/// The microphone, encoded to Opus as you speak and handed out a frame
/// (100 ms) at a time, on its own queue.
final class LiveCapture: @unchecked Sendable {
    /// Packets of one frame, its number, and whether it's the last.
    typealias FrameHandler = @Sendable (_ packets: [Data], _ seq: UInt32, _ last: Bool) -> Void

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "dev.levi.XNotch.walkie.live", qos: .userInteractive)
    private let onFrame: FrameHandler
    private var resampler: AVAudioConverter?
    private let encoder: AVAudioConverter
    private var packets: [Data] = []
    private var seq: UInt32 = 0
    private var ended = false

    enum CaptureError: LocalizedError {
        case noMicrophone, noEncoder

        var errorDescription: String? {
            switch self {
            case .noMicrophone: "No microphone is available."
            case .noEncoder: "This Mac can't encode live audio."
            }
        }
    }

    init(onFrame: @escaping FrameHandler) throws {
        guard let encoder = AVAudioConverter(from: LiveFormat.pcm, to: LiveFormat.opus) else { throw CaptureError.noEncoder }
        encoder.bitRate = LiveFormat.bitRate
        self.encoder = encoder
        self.onFrame = onFrame
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let resampler = AVAudioConverter(from: format, to: LiveFormat.pcm) else { throw CaptureError.noMicrophone }
        self.resampler = resampler
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
            self.queue.async { self.encode(copy) }
        }
        engine.prepare()
        try engine.start()
    }

    /// Sends what's left as the last frame.
    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        queue.async {
            guard !self.ended else { return }
            self.ended = true
            self.onFrame(self.packets, self.seq, true)
            self.packets = []
        }
    }

    private func encode(_ buffer: AVAudioPCMBuffer) {
        guard !ended, let resampler else { return }
        let ratio = LiveFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let mono = AVAudioPCMBuffer(pcmFormat: LiveFormat.pcm, frameCapacity: capacity) else { return }
        var fed = false
        _ = resampler.convert(to: mono, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard mono.frameLength > 0 else { return }

        let out = AVAudioCompressedBuffer(format: LiveFormat.opus, packetCapacity: 8,
                                          maximumPacketSize: max(encoder.maximumOutputPacketSize, 1500))
        var given = false
        _ = encoder.convert(to: out, error: nil) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return mono
        }
        guard out.packetCount > 0, let descriptions = out.packetDescriptions else { return }
        for index in 0..<Int(out.packetCount) {
            let description = descriptions[index]
            packets.append(Data(bytes: out.data.advanced(by: Int(description.mStartOffset)), count: Int(description.mDataByteSize)))
        }
        while packets.count >= LiveFrame.packetsPerFrame {
            let frame = Array(packets.prefix(LiveFrame.packetsPerFrame))
            packets.removeFirst(LiveFrame.packetsPerFrame)
            onFrame(frame, seq, false)
            seq += 1
        }
    }
}

// MARK: Listening

/// Plays everyone talking live, each on their own voice, in the order
/// their frames were sent. A frame that doesn't come within a quarter
/// second is skipped rather than waited for.
@MainActor
final class LivePlayer {
    /// A talk ended (its last frame played, or it went quiet), for this contact.
    var onEnd: ((String) -> Void)?

    private final class Stream {
        let box: String
        let key: SymmetricKey
        let node = AVAudioPlayerNode()
        let decoder: AVAudioConverter
        var nextSeq: UInt32 = 0
        var pending: [UInt32: (packets: [Data], last: Bool)] = [:]
        var lastHeard = Date()
        var finished = false
        var skipWork: DispatchWorkItem?

        init?(box: String, key: SymmetricKey) {
            guard let decoder = AVAudioConverter(from: LiveFormat.opus, to: LiveFormat.pcm) else { return nil }
            self.box = box
            self.key = key
            self.decoder = decoder
        }
    }

    private let engine = AVAudioEngine()
    private var streams: [Data: Stream] = [:]
    /// Frames that beat their session's key here, briefly.
    private var early: [Data: [(at: Date, frame: Data)]] = [:]
    private var watchdog: Timer?

    var isPlaying: Bool { !streams.isEmpty }

    func begin(session: Data, key: Data, box: String) {
        guard key.count == 32, streams[session] == nil, let stream = Stream(box: box, key: SymmetricKey(data: key)) else { return }
        // One voice per person: a new talk replaces one still open.
        for (old, other) in streams where other.box == box { end(old) }
        engine.attach(stream.node)
        engine.connect(stream.node, to: engine.mainMixerNode, format: LiveFormat.pcm)
        if !engine.isRunning {
            engine.prepare()
            guard (try? engine.start()) != nil else {
                engine.detach(stream.node)
                return
            }
        }
        stream.node.play()
        streams[session] = stream
        startWatchdog()
        for item in early.removeValue(forKey: session) ?? [] { receive(item.frame) }
    }

    func receive(_ frame: Data) {
        guard let header = LiveFrame.peek(frame) else { return }
        guard let stream = streams[header.session] else {
            // Its key may still be on the way.
            let now = Date()
            early = early.filter { $0.value.last.map { now.timeIntervalSince($0.at) < 1.5 } ?? false }
            if early.count < 16, early[header.session, default: []].count < 30 {
                early[header.session, default: []].append((now, frame))
            }
            return
        }
        guard !stream.finished, header.seq >= stream.nextSeq, let packets = LiveFrame.open(frame, key: stream.key) else { return }
        stream.lastHeard = Date()
        stream.pending[header.seq] = (packets, header.last)
        drain(header.session)
    }

    func stopAll() {
        for session in streams.keys { end(session) }
        early.removeAll()
        engine.stop()
    }

    private func drain(_ session: Data) {
        guard let stream = streams[session] else { return }
        while let next = stream.pending.removeValue(forKey: stream.nextSeq) {
            stream.nextSeq += 1
            schedule(next.packets, on: stream)
            if next.last {
                stream.finished = true
                // Done once what's queued has played.
                let silence = AVAudioPCMBuffer(pcmFormat: LiveFormat.pcm, frameCapacity: 1)!
                silence.frameLength = 1
                stream.node.scheduleBuffer(silence) { [weak self] in
                    DispatchQueue.main.async { self?.end(session) }
                }
                return
            }
        }
        stream.skipWork?.cancel()
        stream.skipWork = nil
        guard !stream.pending.isEmpty else { return }
        // A gap: wait a moment for the missing frame, then go on without it.
        let work = DispatchWorkItem { [weak self] in
            guard let self, let stream = self.streams[session], let first = stream.pending.keys.min() else { return }
            stream.nextSeq = first
            self.drain(session)
        }
        stream.skipWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func schedule(_ packets: [Data], on stream: Stream) {
        guard !packets.isEmpty else { return }
        let total = packets.reduce(0) { $0 + $1.count }
        let compressed = AVAudioCompressedBuffer(format: LiveFormat.opus, packetCapacity: AVAudioPacketCount(packets.count),
                                                 maximumPacketSize: max(packets.map(\.count).max() ?? 0, 1))
        guard let descriptions = compressed.packetDescriptions, total <= Int(compressed.byteCapacity) else { return }
        var offset = 0
        for (index, packet) in packets.enumerated() {
            packet.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress { compressed.data.advanced(by: offset).copyMemory(from: base, byteCount: packet.count) }
            }
            descriptions[index] = AudioStreamPacketDescription(mStartOffset: Int64(offset), mVariableFramesInPacket: 0,
                                                               mDataByteSize: UInt32(packet.count))
            offset += packet.count
        }
        compressed.packetCount = AVAudioPacketCount(packets.count)
        compressed.byteLength = UInt32(offset)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: LiveFormat.pcm,
                                         frameCapacity: LiveFormat.framesPerPacket * AVAudioFrameCount(packets.count)) else { return }
        var given = false
        _ = stream.decoder.convert(to: pcm, error: nil) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return compressed
        }
        guard pcm.frameLength > 0 else { return }
        stream.node.scheduleBuffer(pcm)
    }

    private func end(_ session: Data) {
        guard let stream = streams.removeValue(forKey: session) else { return }
        stream.skipWork?.cancel()
        stream.node.stop()
        engine.detach(stream.node)
        onEnd?(stream.box)
        if streams.isEmpty {
            watchdog?.invalidate()
            watchdog = nil
            // Let go of the output device while nobody talks.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.streams.isEmpty else { return }
                self.engine.stop()
            }
        }
    }

    /// A talk whose last frame never came ends after three quiet seconds.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date()
                for (session, stream) in self.streams where now.timeIntervalSince(stream.lastHeard) > 3 { self.end(session) }
            }
        }
    }
}
