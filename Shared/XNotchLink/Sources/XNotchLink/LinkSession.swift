import Foundation

/// A paired, connected device. Both ends run the same session: files and
/// text go either way, and every item is acknowledged once the receiver has
/// it, so the sender can say "Sent" truthfully.
public actor LinkSession {
    public enum Incoming: Sendable {
        /// A file streamed to a temporary location. Move it away before returning.
        case file(URL, name: String)
        case text(String)
    }

    public nonisolated let channel: SecureChannel
    public private(set) var peer: LinkDevice?
    /// The relay the Mac named in its hello.
    public private(set) var peerRelay: URL?

    public nonisolated var route: LinkRoute { channel.transport.route }
    /// "USB", "Wi-Fi", "Nearby"…
    public nonisolated var routeTitle: String { channel.transport.detail ?? route.title }

    private let incomingDirectory: URL
    private var pendingAcks: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var isSending = false
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []
    /// Acknowledgements jump the queue: they go out between a file's chunks,
    /// so two devices sending to each other never wait on each other.
    private var controlQueue: [LinkMessage] = []
    private var isFinished = false

    private static let chunkSize = 256 * 1024

    /// `incomingDirectory` holds files while they arrive.
    public init(channel: SecureChannel, incomingDirectory: URL) {
        self.channel = channel
        self.incomingDirectory = incomingDirectory
    }

    /// Exchanges device descriptions. The side that connected speaks first.
    @discardableResult
    public func handshake(as device: LinkDevice, isInitiator: Bool, relay: URL? = nil) async throws -> LinkDevice {
        let mine = LinkMessage(kind: .hello, device: device, relay: relay)
        if isInitiator { try await send(mine) }
        guard case .message(let hello) = try await receiveFrame(), hello.kind == .hello, let other = hello.device else {
            throw LinkError.protocolViolation("Expected hello")
        }
        if !isInitiator { try await send(mine) }
        peer = other
        peerRelay = hello.relay
        return other
    }

    /// Reads until the connection ends, handing each item to `onReceive`.
    /// Throwing from it tells the sender the item was refused. `onProgress`
    /// reports incoming files as (name, fraction).
    public func run(onReceive: @escaping @Sendable (Incoming) async throws -> Void,
                    onProgress: (@Sendable (String, Double) -> Void)? = nil) async {
        var incoming: IncomingFile?
        defer {
            incoming?.discard()
            finish()
        }
        do {
            while true {
                switch try await receiveFrame() {
                case .data(let chunk):
                    guard let file = incoming else { throw LinkError.protocolViolation("Data without a file") }
                    try file.append(chunk)
                    if let fraction = file.progressToReport() { onProgress?(file.name, fraction) }
                    if file.isComplete {
                        incoming = nil
                        await deliver(file, onReceive)
                    }
                case .message(let message):
                    switch message.kind {
                    case .ack:
                        pendingAcks.removeValue(forKey: message.id)?.resume()
                    case .failure:
                        pendingAcks.removeValue(forKey: message.id)?
                            .resume(throwing: LinkError.rejected(message.reason ?? "The other device refused it."))
                    case .text:
                        let text = message.text ?? ""
                        await reply(to: message.id) { try await onReceive(.text(text)) }
                    case .file:
                        guard incoming == nil, let size = message.size, size >= 0 else {
                            throw LinkError.protocolViolation("Unexpected file")
                        }
                        let file = try IncomingFile(id: message.id, name: linkSafeFileName(message.name ?? "File"),
                                                    size: size, directory: incomingDirectory)
                        if file.isComplete {
                            await deliver(file, onReceive)
                        } else {
                            incoming = file
                        }
                    case .hello:
                        throw LinkError.protocolViolation("Unexpected hello")
                    }
                }
            }
        } catch {
            // The connection ended; pending sends fail in `finish`.
        }
    }

    /// Sends a file and waits until the other device has saved it.
    public func sendFile(_ url: URL, name: String? = nil, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard !isFinished else { throw LinkError.closed }
        let size = try (FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let message = LinkMessage(kind: .file, name: name ?? url.lastPathComponent, size: size)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try await awaitingAck(for: message.id) {
            try await self.send(message)
            var sent: Int64 = 0
            progress?(size == 0 ? 1 : 0)
            while sent < size {
                let chunk = try handle.read(upToCount: Int(min(Int64(Self.chunkSize), size - sent))) ?? Data()
                guard !chunk.isEmpty else { throw LinkError.protocolViolation("The file changed while sending") }
                try await self.flushControl()
                try await self.channel.send(LinkFrame.data(chunk).encoded())
                sent += Int64(chunk.count)
                progress?(Double(sent) / Double(size))
            }
        }
    }

    /// Sends text for the other device's clipboard and waits until it's there.
    public func sendText(_ text: String) async throws {
        guard !isFinished else { throw LinkError.closed }
        let message = LinkMessage(kind: .text, text: text)
        // Escaping can make the encoded message several times longer than the text.
        guard text.utf8.count <= LinkService.maxTextBytes, (try? LinkFrame.message(message).encoded()) != nil else {
            throw LinkError.rejected("That text is too long to send.")
        }
        try await awaitingAck(for: message.id) { try await self.send(message) }
    }

    public func close() {
        finish()
    }

    // MARK: Internals

    /// Registers for the acknowledgement, sends under the send lock, then waits.
    /// Cancelling ends the session: a half-sent file can't be taken back.
    private func awaitingAck(for id: UUID, send: @escaping () async throws -> Void) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !isFinished else { return continuation.resume(throwing: LinkError.closed) }
                pendingAcks[id] = continuation
                Task {
                    do {
                        try await self.withSendLock(send)
                    } catch {
                        self.failPending(id, error)
                        self.finish()
                    }
                }
            }
        } onCancel: {
            Task { await self.close() }
        }
    }

    private func failPending(_ id: UUID, _ error: Error) {
        pendingAcks.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func deliver(_ file: IncomingFile, _ onReceive: @Sendable (Incoming) async throws -> Void) async {
        await reply(to: file.id) {
            defer { file.discard() }
            try file.close()
            try await onReceive(.file(file.url, name: file.name))
        }
    }

    private func reply(to id: UUID, _ handle: () async throws -> Void) async {
        let answer: LinkMessage
        do {
            try await handle()
            answer = LinkMessage(kind: .ack, id: id)
        } catch {
            answer = LinkMessage(kind: .failure, id: id, reason: error.localizedDescription)
        }
        controlQueue.append(answer)
        if !isSending { try? await withSendLock {} }
    }

    private func send(_ message: LinkMessage) async throws {
        try await channel.send(LinkFrame.message(message).encoded())
    }

    private func receiveFrame() async throws -> LinkFrame {
        try LinkFrame.decode(try await channel.receive())
    }

    private func flushControl() async throws {
        while !controlQueue.isEmpty {
            try await send(controlQueue.removeFirst())
        }
    }

    /// Frames from concurrent sends must not interleave on the stream.
    private func withSendLock(_ body: () async throws -> Void) async throws {
        if isSending {
            await withCheckedContinuation { sendWaiters.append($0) }
        }
        isSending = true
        defer {
            if sendWaiters.isEmpty {
                isSending = false
            } else {
                sendWaiters.removeFirst().resume()
            }
        }
        try await body()
        try await flushControl()
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        channel.close()
        let pending = pendingAcks
        pendingAcks.removeAll()
        pending.values.forEach { $0.resume(throwing: LinkError.closed) }
    }
}

/// A file arriving in chunks, written to a temporary file.
private final class IncomingFile {
    let id: UUID
    let name: String
    let size: Int64
    let url: URL
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var reported = -1.0

    init(id: UUID, name: String, size: Int64, directory: URL) throws {
        self.id = id
        self.name = name
        self.size = size
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    var isComplete: Bool { received == size }

    func append(_ chunk: Data) throws {
        guard received + Int64(chunk.count) <= size else { throw LinkError.protocolViolation("File larger than announced") }
        try handle?.write(contentsOf: chunk)
        received += Int64(chunk.count)
    }

    /// Every whole percent, and at the end.
    func progressToReport() -> Double? {
        let fraction = size == 0 ? 1 : Double(received) / Double(size)
        guard fraction - reported >= 0.01 || isComplete else { return nil }
        reported = fraction
        return fraction
    }

    func close() throws {
        try handle?.close()
        handle = nil
    }

    func discard() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: url)
    }
}
