import Foundation
import Network

/// The USB route. The phone listens on a loopback port; the Mac reaches it
/// through usbmuxd, the service Xcode and Finder use to talk to a cabled
/// iPhone. The Mac connects, so it's the `SecureChannel` initiator here.
public enum LinkUSB {
    /// The phone's port, on its loopback interface only.
    public static let port: UInt16 = 47_812

    /// The phone's side: accepts the Mac's connections while the app is open.
    public static func listener() throws -> NWListener {
        let parameters = LinkNetwork.parameters()
        parameters.includePeerToPeer = false
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        return try NWListener(using: parameters)
    }
}

#if os(macOS)
/// Talks usbmuxd's plist protocol: a 16-byte little-endian header (length,
/// version 1, type 8 = plist, tag), then an XML property list.
public final class USBMux: @unchecked Sendable {
    public struct Device: Hashable, Sendable {
        public let id: Int
        public let serial: String
    }

    public static let defaultSocket = "/var/run/usbmuxd"
    private let socketPath: String

    public init(socketPath: String = USBMux.defaultSocket) {
        self.socketPath = socketPath
    }

    /// Attached and detached USB devices, until the stream is cancelled or usbmuxd goes away.
    public func devices() -> AsyncThrowingStream<(Device, attached: Bool), Error> {
        AsyncThrowingStream { continuation in
            let transport = NetworkTransport(NWConnection(to: .unix(path: socketPath), using: .tcp), route: .usb)
            let task = Task {
                do {
                    try await transport.start(timeout: 3)
                    try await Self.write(["MessageType": "Listen"], to: transport)
                    var serials: [Int: String] = [:]
                    while true {
                        let message = try await Self.read(from: transport)
                        switch message["MessageType"] as? String {
                        case "Result":
                            if let number = message["Number"] as? Int, number != 0 {
                                throw LinkError.unavailable("usbmuxd refused to list devices (\(number))")
                            }
                        case "Attached":
                            guard let id = message["DeviceID"] as? Int,
                                  let properties = message["Properties"] as? [String: Any],
                                  properties["ConnectionType"] as? String == "USB" else { continue }
                            let serial = properties["SerialNumber"] as? String ?? "\(id)"
                            serials[id] = serial
                            continuation.yield((Device(id: id, serial: serial), true))
                        case "Detached":
                            guard let id = message["DeviceID"] as? Int, let serial = serials.removeValue(forKey: id) else { continue }
                            continuation.yield((Device(id: id, serial: serial), false))
                        default:
                            continue
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                transport.close()
            }
        }
    }

    /// A byte stream to `port` on the device; fails fast when nothing listens there.
    public func connect(to device: Device, port: UInt16) async throws -> NetworkTransport {
        let transport = NetworkTransport(NWConnection(to: .unix(path: socketPath), using: .tcp), route: .usb)
        do {
            try await transport.start(timeout: 3)
            try await Self.write(["MessageType": "Connect", "DeviceID": device.id,
                                  "PortNumber": Int(port.byteSwapped)], to: transport)
            let result = try await Self.read(from: transport)
            guard result["MessageType"] as? String == "Result", result["Number"] as? Int == 0 else {
                throw LinkError.unavailable("Nothing is listening on the device")
            }
            // From here on the socket is a plain stream to the device's port.
            return transport
        } catch {
            transport.close()
            throw error
        }
    }

    static func write(_ message: [String: Any], to transport: LinkTransport) async throws {
        var message = message
        message["ClientVersionString"] = "XNotch"
        message["ProgName"] = "XNotch"
        message["kLibUSBMuxVersion"] = 3
        let body = try PropertyListSerialization.data(fromPropertyList: message, format: .xml, options: 0)
        var header = Data()
        for value in [UInt32(16 + body.count), 1, 8, 1] {
            var little = value.littleEndian
            header += Data(bytes: &little, count: 4)
        }
        try await transport.send(header + body)
    }

    static func read(from transport: LinkTransport) async throws -> [String: Any] {
        let header = try await transport.receive(exactly: 16)
        let length = Int(header.prefix(4).reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard length >= 16, length <= 1 << 20 else { throw LinkError.protocolViolation("Bad usbmuxd packet") }
        let body = length == 16 ? Data() : try await transport.receive(exactly: length - 16)
        guard let message = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] else {
            throw LinkError.protocolViolation("Bad usbmuxd message")
        }
        return message
    }
}
#endif
