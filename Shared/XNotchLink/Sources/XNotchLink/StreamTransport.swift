import Foundation

/// A Foundation stream pair as a transport, for Bluetooth L2CAP channels.
/// The streams live on their own thread's run loop.
public final class StreamTransport: NSObject, LinkTransport, StreamDelegate, @unchecked Sendable {
    public let route: LinkRoute
    private let input: InputStream
    private let output: OutputStream
    /// Keeps the owner of the streams (a `CBL2CAPChannel`) alive.
    private let owner: AnyObject?
    private let lock = NSLock()
    private var thread: Thread?

    private var readBuffer = Data()
    private var readWaiter: (max: Int, continuation: CheckedContinuation<Data, Error>)?
    private var writes: [(data: Data, continuation: CheckedContinuation<Void, Error>)] = []
    private var writeOffset = 0
    private var failure: LinkError?

    public init(input: InputStream, output: OutputStream, route: LinkRoute, owner: AnyObject? = nil) {
        self.input = input
        self.output = output
        self.route = route
        self.owner = owner
        super.init()
        let thread = Thread { [weak self] in self?.runLoop() }
        thread.name = "dev.levi.XNotchLink.stream"
        self.thread = thread
        thread.start()
    }

    private func runLoop() {
        input.delegate = self
        output.delegate = self
        input.schedule(in: .current, forMode: .default)
        output.schedule(in: .current, forMode: .default)
        input.open()
        output.open()
        while !isClosed {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.25))
        }
        input.close()
        output.close()
        input.remove(from: .current, forMode: .default)
        output.remove(from: .current, forMode: .default)
    }

    private var isClosed: Bool { lock.withLock { failure != nil } }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let error: LinkError? = lock.withLock {
                if let failure { return failure }
                writes.append((data, continuation))
                return nil
            }
            if let error { return continuation.resume(throwing: error) }
            perform { self.pumpWrites() }
        }
    }

    public func receive(upTo maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let ready: Result<Data, Error>? = lock.withLock {
                if !readBuffer.isEmpty {
                    let chunk = Data(readBuffer.prefix(maximum))
                    readBuffer.removeFirst(chunk.count)
                    return .success(chunk)
                }
                if let failure { return .failure(failure) }
                readWaiter = (maximum, continuation)
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    public func close() {
        fail(.closed)
    }

    // MARK: Stream events (stream thread)

    public func stream(_ stream: Stream, handle event: Stream.Event) {
        switch event {
        case .hasBytesAvailable:
            pumpReads()
        case .hasSpaceAvailable:
            pumpWrites()
        case .errorOccurred:
            fail(.connectionFailed(stream.streamError?.localizedDescription ?? "Stream error"))
        case .endEncountered:
            fail(.closed)
        default:
            break
        }
    }

    private func pumpReads() {
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while input.hasBytesAvailable {
            let count = input.read(&bytes, maxLength: bytes.count)
            guard count > 0 else { break }
            lock.withLock { readBuffer.append(contentsOf: bytes[0..<count]) }
        }
        let delivery: (CheckedContinuation<Data, Error>, Data)? = lock.withLock {
            guard let waiter = readWaiter, !readBuffer.isEmpty else { return nil }
            readWaiter = nil
            let chunk = Data(readBuffer.prefix(waiter.max))
            readBuffer.removeFirst(chunk.count)
            return (waiter.continuation, chunk)
        }
        if let (continuation, chunk) = delivery { continuation.resume(returning: chunk) }
    }

    private func pumpWrites() {
        while output.hasSpaceAvailable {
            let next: Data? = lock.withLock { writes.first?.data }
            guard let next else { return }
            let written = next.withUnsafeBytes { buffer -> Int in
                let start = buffer.bindMemory(to: UInt8.self).baseAddress!.advanced(by: writeOffset)
                return output.write(start, maxLength: next.count - writeOffset)
            }
            guard written > 0 else {
                if written < 0 { fail(.connectionFailed(output.streamError?.localizedDescription ?? "Write failed")) }
                return
            }
            writeOffset += written
            if writeOffset == next.count {
                writeOffset = 0
                let done = lock.withLock { writes.removeFirst().continuation }
                done.resume()
            }
        }
    }

    private func fail(_ error: LinkError) {
        let (reader, writers): (CheckedContinuation<Data, Error>?, [CheckedContinuation<Void, Error>]) = lock.withLock {
            guard failure == nil else { return (nil, []) }
            failure = error
            defer { readWaiter = nil; writes.removeAll() }
            return (readWaiter?.continuation, writes.map(\.continuation))
        }
        reader?.resume(throwing: error)
        writers.forEach { $0.resume(throwing: error) }
    }

    private func perform(_ block: @escaping () -> Void) {
        guard let thread else { return }
        let work = BlockOperation(block: block)
        work.perform(#selector(Operation.start), on: thread, with: nil, waitUntilDone: false)
    }
}
