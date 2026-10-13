import CoreBluetooth
import Foundation

/// The Bluetooth LE route: an L2CAP channel. The Mac advertises; its one
/// readable value is a tag derived from the pairing key plus the channel's
/// PSM, so a phone only opens channels of the Mac it's paired with.
public enum LinkBluetooth {
    public static let service = CBUUID(string: "C8E1A0B2-5D47-4F3A-9E6B-1F2D3C4B5A60")
    static let info = CBUUID(string: "C8E1A0B3-5D47-4F3A-9E6B-1F2D3C4B5A60")

    static func tag(for pairing: LinkPairing) -> Data {
        pairing.tag("xnotch-link bluetooth").prefix(16)
    }

    /// Whether macOS or iOS let this app use Bluetooth, without asking.
    public static var isAllowed: Bool { CBManager.authorization == .allowedAlways }
    public static var isUndetermined: Bool { CBManager.authorization == .notDetermined }

    /// Shows the system's Bluetooth prompt if it hasn't been answered, and
    /// returns whether Bluetooth may be used.
    public static func requestAccess() async -> Bool {
        guard isUndetermined else { return isAllowed }
        let manager = CBCentralManager(delegate: nil, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        for _ in 0..<240 where isUndetermined {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        withExtendedLifetime(manager) {}
        return isAllowed
    }
}

/// The Mac's side: advertises and accepts L2CAP channels.
public final class LinkBluetoothPeripheral: NSObject, CBPeripheralManagerDelegate, @unchecked Sendable {
    public var onChannel: ((StreamTransport) -> Void)?
    /// nil when advertising, else why not.
    public var onStatus: ((String?) -> Void)?

    private let tag: Data
    private let queue = DispatchQueue(label: "dev.levi.XNotchLink.bluetooth")
    private var manager: CBPeripheralManager?
    private var psm: CBL2CAPPSM?
    private var channels: [CBL2CAPChannel] = []

    public init(pairing: LinkPairing) {
        tag = LinkBluetooth.tag(for: pairing)
    }

    /// Creating the manager shows macOS's Bluetooth prompt if it hasn't been answered.
    public func start() {
        queue.async {
            guard self.manager == nil else { return }
            self.manager = CBPeripheralManager(delegate: self, queue: self.queue)
        }
    }

    public func stop() {
        queue.async {
            guard let manager = self.manager else { return }
            manager.stopAdvertising()
            manager.removeAllServices()
            if let psm = self.psm { manager.unpublishL2CAPChannel(psm) }
            self.channels.removeAll()
            self.psm = nil
            self.manager = nil
        }
    }

    public func peripheralManagerDidUpdateState(_ manager: CBPeripheralManager) {
        switch manager.state {
        case .poweredOn:
            if psm == nil { manager.publishL2CAPChannel(withEncryption: false) }
        case .unauthorized:
            onStatus?("Bluetooth isn't allowed for XNotch.")
        case .poweredOff:
            onStatus?("Bluetooth is off.")
        case .unsupported:
            onStatus?("This Mac can't use Bluetooth LE.")
        default:
            break
        }
    }

    public func peripheralManager(_ manager: CBPeripheralManager, didPublishL2CAPChannel psm: CBL2CAPPSM, error: Error?) {
        if let error {
            onStatus?(error.localizedDescription)
            return
        }
        self.psm = psm
        let info = CBMutableCharacteristic(type: LinkBluetooth.info, properties: .read, value: nil, permissions: .readable)
        let service = CBMutableService(type: LinkBluetooth.service, primary: true)
        service.characteristics = [info]
        manager.add(service)
        manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [LinkBluetooth.service],
                                  CBAdvertisementDataLocalNameKey: "XNotch"])
        onStatus?(nil)
    }

    public func peripheralManager(_ manager: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == LinkBluetooth.info, let psm else {
            return manager.respond(to: request, withResult: .attributeNotFound)
        }
        var big = psm.bigEndian
        let value = tag + Data(bytes: &big, count: 2)
        guard request.offset <= value.count else { return manager.respond(to: request, withResult: .invalidOffset) }
        request.value = value.dropFirst(request.offset)
        manager.respond(to: request, withResult: .success)
    }

    public func peripheralManager(_ manager: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let channel, let input = channel.inputStream, let output = channel.outputStream else { return }
        channels.append(channel)
        onChannel?(StreamTransport(input: input, output: output, route: .bluetooth, owner: channel))
    }
}

/// The phone's side: finds the paired Mac and opens its channel.
public final class LinkBluetoothCentral: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    private let tag: Data
    private let queue = DispatchQueue(label: "dev.levi.XNotchLink.bluetooth.central")
    private var manager: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var continuation: CheckedContinuation<StreamTransport, Error>?

    private init(pairing: LinkPairing) {
        tag = LinkBluetooth.tag(for: pairing)
    }

    /// A channel to the paired Mac. Keeps Bluetooth objects alive for as
    /// long as the returned transport is.
    public static func connect(to pairing: LinkPairing, timeout: TimeInterval = 12) async throws -> StreamTransport {
        let central = LinkBluetoothCentral(pairing: pairing)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                central.queue.async {
                    central.continuation = continuation
                    central.manager = CBCentralManager(delegate: central, queue: central.queue)
                    central.queue.asyncAfter(deadline: .now() + timeout) {
                        central.finish(.failure(LinkError.notFound(pairing.name)))
                    }
                }
            }
        } onCancel: {
            central.queue.async { central.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<StreamTransport, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        manager?.stopScan()
        if case .failure = result {
            peripherals.values.forEach { manager?.cancelPeripheralConnection($0) }
            peripherals.removeAll()
        }
        continuation.resume(with: result)
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            central.scanForPeripherals(withServices: [LinkBluetooth.service])
        case .unauthorized:
            finish(.failure(LinkError.unavailable("Allow Bluetooth for XNotch in Settings to connect without Wi-Fi.")))
        case .poweredOff:
            finish(.failure(LinkError.unavailable("Bluetooth is off.")))
        case .unsupported:
            finish(.failure(LinkError.unavailable("This device can't use Bluetooth LE.")))
        default:
            break
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi: NSNumber) {
        guard peripherals[peripheral.identifier] == nil else { return }
        peripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([LinkBluetooth.service])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        peripherals[peripheral.identifier] = nil
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == LinkBluetooth.service }) else { return drop(peripheral) }
        peripheral.discoverCharacteristics([LinkBluetooth.info], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let info = service.characteristics?.first(where: { $0.uuid == LinkBluetooth.info }) else { return drop(peripheral) }
        peripheral.readValue(for: info)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // Another Mac with XNotch, or a stale pairing: let it go and keep looking.
        guard let value = characteristic.value, value.count == 18, value.prefix(16) == tag else { return drop(peripheral) }
        let psm = CBL2CAPPSM(value[value.startIndex + 16]) << 8 | CBL2CAPPSM(value[value.startIndex + 17])
        peripheral.openL2CAPChannel(psm)
    }

    public func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let channel, let input = channel.inputStream, let output = channel.outputStream else { return drop(peripheral) }
        // The transport owns the channel, the peripheral and this central.
        let owner = BluetoothOwner(channel: channel, peripheral: peripheral, central: self)
        finish(.success(StreamTransport(input: input, output: output, route: .bluetooth, owner: owner)))
    }

    private func drop(_ peripheral: CBPeripheral) {
        manager?.cancelPeripheralConnection(peripheral)
    }
}

private final class BluetoothOwner {
    let channel: CBL2CAPChannel
    let peripheral: CBPeripheral
    let central: LinkBluetoothCentral

    init(channel: CBL2CAPChannel, peripheral: CBPeripheral, central: LinkBluetoothCentral) {
        self.channel = channel
        self.peripheral = peripheral
        self.central = central
    }
}
