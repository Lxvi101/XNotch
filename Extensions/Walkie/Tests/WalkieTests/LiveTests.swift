import AVFoundation
import CryptoKit
import XCTest
@testable import Walkie

final class LiveTests: XCTestCase {
    private let session = Data((0..<16).map { UInt8($0) })

    func testFramesRoundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let packets = [Data([1, 2, 3]), Data(), Data(repeating: 7, count: 300)]
        let frame = try LiveFrame.seal(packets, session: session, seq: 41, last: true, key: key)
        XCTAssertEqual(LiveFrame.peek(frame), LiveFrame.Header(session: session, seq: 41, last: true))
        XCTAssertEqual(LiveFrame.open(frame, key: key), packets)
        XCTAssertNil(frame.range(of: Data(repeating: 7, count: 300)), "the audio is not readable in the frame")
    }

    func testFramesNeedTheirKeyAndHeader() throws {
        let key = SymmetricKey(size: .bits256)
        let frame = try LiveFrame.seal([Data([9, 9])], session: session, seq: 3, last: false, key: key)
        XCTAssertNil(LiveFrame.open(frame, key: SymmetricKey(size: .bits256)), "another key can't open it")
        // Moving a frame to another place in the talk breaks it.
        var moved = frame
        moved[LiveFrame.magic.count + 1 + LiveFrame.sessionBytes + 3] ^= 1
        XCTAssertNil(LiveFrame.open(moved, key: key))
        var ended = frame
        ended[LiveFrame.headerBytes - 1] = 1
        XCTAssertNil(LiveFrame.open(ended, key: key))
    }

    func testFramesAreNotEnvelopes() throws {
        let frame = try LiveFrame.seal([], session: session, seq: 0, last: true, key: SymmetricKey(size: .bits256))
        XCTAssertTrue(LiveFrame.isFrame(frame))
        XCTAssertFalse(LiveFrame.isFrame(WalkieCrypto.magic + Data(repeating: 0, count: 40)))
    }

    func testOpusRoundTrip() throws {
        let encoder = try XCTUnwrap(AVAudioConverter(from: LiveFormat.pcm, to: LiveFormat.opus))
        let decoder = try XCTUnwrap(AVAudioConverter(from: LiveFormat.opus, to: LiveFormat.pcm))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: LiveFormat.pcm, frameCapacity: 4800))
        input.frameLength = 4800
        for i in 0..<4800 { input.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.3 }
        let out = AVAudioCompressedBuffer(format: LiveFormat.opus, packetCapacity: 8, maximumPacketSize: 1500)
        var given = false
        _ = encoder.convert(to: out, error: nil) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return input
        }
        XCTAssertEqual(out.packetCount, 5, "100 ms is five 20 ms packets")
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: LiveFormat.pcm, frameCapacity: 4800))
        var fed = false
        _ = decoder.convert(to: pcm, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return out
        }
        XCTAssertGreaterThan(pcm.frameLength, 4000)
    }

    func testMenuBarMessagesTravel() throws {
        var message = WireMessage(kind: .menuBar)
        message.active = true
        let (decoded, attachments) = try WireCodec.decode(try WireCodec.encode(message))
        XCTAssertEqual(decoded, message)
        XCTAssertTrue(attachments.isEmpty)

        var live = WireMessage(kind: .live)
        live.ref = session.hex
        live.key = Data(repeating: 4, count: 32)
        XCTAssertEqual(try WireCodec.decode(try WireCodec.encode(live)).0, live)
    }

    /// People saved before the menu bar was a choice stay in it, and nobody is live until they say so.
    func testContactsFromBeforeStayInTheMenuBar() throws {
        let keys = WalkieCrypto.PublicKeys(kem: Data([1]), mldsa: Data([2]), ed: Data([3]))
        var contact = Contact(box: String(repeating: "a", count: 64), server: "https://example.com", postToken: Data(count: 32),
                              name: "Mira", avatar: nil, keys: keys, verified: true, accepted: true, knowsUs: true,
                              addedAt: Date(), lastActivity: Date())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: WalkieJSON.encoder.encode(contact)) as? [String: Any])
        json.removeValue(forKey: "inMenuBar")
        let old = try WalkieJSON.decoder.decode(Contact.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(old.isInMenuBar)
        XCTAssertFalse(old.isLive)
        contact.hasUsInMenuBar = true
        XCTAssertTrue(contact.isLive)
        contact.inMenuBar = false
        XCTAssertFalse(contact.isLive, "live needs both of you")
    }

    /// Frames out of order, one arriving before its key: all of it plays, then the talk ends.
    @MainActor
    func testPlayerPlaysATalkToTheEnd() throws {
        let encoder = try XCTUnwrap(AVAudioConverter(from: LiveFormat.pcm, to: LiveFormat.opus))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: LiveFormat.pcm, frameCapacity: 14_400))
        input.frameLength = 14_400
        let samples = input.floatChannelData![0]
        for i in 0..<14_400 {
            let phase = Float(i) * 0.05
            samples[i] = sin(phase) * 0.05
        }
        let out = AVAudioCompressedBuffer(format: LiveFormat.opus, packetCapacity: 20, maximumPacketSize: 1500)
        var given = false
        _ = encoder.convert(to: out, error: nil) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return input
        }
        let packets = (0..<Int(out.packetCount)).map { index -> Data in
            let d = out.packetDescriptions![index]
            return Data(bytes: out.data.advanced(by: Int(d.mStartOffset)), count: Int(d.mDataByteSize))
        }
        XCTAssertEqual(packets.count, 15)
        let key = SymmetricKey(size: .bits256)
        var frames: [Data] = []
        for seq in 0..<3 {
            let slice = Array(packets[(seq * 5)..<(seq * 5 + 5)])
            frames.append(try LiveFrame.seal(slice, session: session, seq: UInt32(seq), last: seq == 2, key: key))
        }
        let player = LivePlayer()
        let ended = expectation(description: "the talk ends")
        player.onEnd = { box in
            XCTAssertEqual(box, "mira")
            ended.fulfill()
        }
        player.receive(frames[1])
        player.begin(session: session, key: key.withUnsafeBytes { Data($0) }, box: "mira")
        XCTAssertTrue(player.isPlaying)
        player.receive(frames[2])
        player.receive(frames[0])
        wait(for: [ended], timeout: 3)
        XCTAssertFalse(player.isPlaying)
    }
}
