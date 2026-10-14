import AppKit
import CoreBluetooth
import IOBluetooth

/// Headphones and speakers XNotch recognises. Detection by product ID and
/// name, and the Apple models' animations, come from Atoll's
/// BluetoothAudioManager (GPL-3.0-or-later, https://github.com/Ebullioscopic/Atoll).
enum HeadphonesKind: Equatable {
    case airpods, airpodsGen3, airpodsGen4, airpodsPro, airpodsPro3, airpodsMax
    case beatsStudio, beatsSolo
    case headphones, speaker

    /// Product IDs Apple and Beats devices report, under either of Apple's vendor IDs.
    private static let productIDs: [UInt16: HeadphonesKind] = [
        0x2002: .airpods, 0x200F: .airpods,
        0x2013: .airpodsGen3,
        0x2019: .airpodsGen4, 0x201B: .airpodsGen4,
        0x200E: .airpodsPro, 0x2014: .airpodsPro, 0x2024: .airpodsPro,
        0x2027: .airpodsPro3,
        0x200A: .airpodsMax, 0x201F: .airpodsMax,
        0x2009: .beatsStudio, 0x2017: .beatsStudio,
        0x2006: .beatsSolo, 0x200C: .beatsSolo
    ]
    private static let appleVendorIDs: Set<UInt16> = [0x004C, 0x05AC]

    init?(vendorID: UInt16?, productID: UInt16?) {
        guard let vendorID, let productID, Self.appleVendorIDs.contains(vendorID),
              let kind = Self.productIDs[productID] else { return nil }
        self = kind
    }

    init?(name: String) {
        let name = name.lowercased()
        func has(_ parts: String...) -> Bool { parts.contains { name.contains($0) } }
        if has("airpods") {
            if has("max") { self = .airpodsMax }
            else if has("pro") { self = has("pro 3", "pro3", "3rd gen") ? .airpodsPro3 : .airpodsPro }
            else if has("airpods 4", "airpods4", "gen 4", "4th") { self = .airpodsGen4 }
            else if has("airpods 3", "airpods3", "gen 3", "3rd") { self = .airpodsGen3 }
            else { self = .airpods }
        } else if has("beats") {
            self = has("studio") ? .beatsStudio : .beatsSolo
        } else {
            return nil
        }
    }

    /// The Bluetooth class of device's audio/video minor class, for everything else.
    init?(classOfDevice: BluetoothClassOfDevice) {
        guard (classOfDevice >> 8) & 0x1F == 0x04 else { return nil }
        switch (classOfDevice >> 2) & 0x3F {
        case 0x01, 0x02, 0x06: self = .headphones // headset, hands-free, headphones
        case 0x05, 0x07, 0x0A: self = .speaker // loudspeaker, portable audio, hi-fi
        default: return nil
        }
    }

    /// Basename of the looping animation in Resources/Headphones, if there is one.
    var animationName: String? {
        switch self {
        case .airpods: "airpods"
        case .airpodsGen3: "airpodsGen3"
        case .airpodsGen4: "airpodsGen4"
        case .airpodsPro: "airpodsPro"
        case .airpodsPro3: "airpodsPro3"
        case .airpodsMax: "airpodsMax"
        case .beatsStudio: "beatsstudio"
        case .beatsSolo: "beatssolo"
        case .headphones, .speaker: nil
        }
    }

    var symbol: String {
        let preferred = switch self {
        case .airpods: "airpods"
        case .airpodsGen3: "airpods.gen3"
        case .airpodsGen4: "airpods.gen4"
        case .airpodsPro, .airpodsPro3: "airpods.pro"
        case .airpodsMax: "airpodsmax"
        case .beatsStudio, .beatsSolo: "beats.headphones"
        case .headphones: "headphones"
        case .speaker: "hifispeaker.fill"
        }
        // Newer symbols are missing on older macOS.
        return NSImage(systemSymbolName: preferred, accessibilityDescription: nil) != nil ? preferred : "headphones"
    }
}

struct HeadphonesConnection: Equatable, Identifiable {
    let id = UUID()
    let address: String
    var name: String
    var kind: HeadphonesKind
    /// 0...100, nil until macOS reports it, which can take a few seconds.
    var battery: Int?
}

/// Reports headphones and speakers as they connect. Event-driven: IOBluetooth
/// calls back on connect and disconnect, nothing polls. The battery is read
/// from `system_profiler` off the main thread, a few times after a connect,
/// since macOS learns it a moment after the link comes up.
@MainActor
final class HeadphonesMonitor: NSObject, ObservableObject {
    /// The latest connection while its toast is relevant; updated as its battery arrives.
    @Published private(set) var latest: HeadphonesConnection?
    var onConnect: ((HeadphonesConnection) -> Void)?

    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var connected: Set<String> = []
    private var startedAt = Date.distantPast
    private var batteryReads = 0
    private var batteryWork: DispatchWorkItem?
    private let profilerQueue = DispatchQueue(label: "dev.levi.XNotch.headphones", qos: .utility)

    var isRunning: Bool { connectNotification != nil }

    func start() {
        guard !isRunning else { return }
        // Never prompt from here once the user has said no.
        switch CBCentralManager.authorization {
        case .denied, .restricted: return
        default: break
        }
        startedAt = Date()
        for device in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [] where device.isConnected() {
            track(device)
        }
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self,
                                                         selector: #selector(deviceConnected(_:device:)))
    }

    func stop() {
        connectNotification?.unregister()
        connectNotification = nil
        disconnectNotifications.values.forEach { $0.unregister() }
        disconnectNotifications.removeAll()
        connected.removeAll()
        cancelBatteryReads()
        latest = nil
    }

    /// Clears the connection once its toast is gone, so stale batteries don't linger.
    func dismiss() {
        cancelBatteryReads()
        latest = nil
    }

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        MainActor.assumeIsolated {
            guard let address = device.addressString, !connected.contains(address),
                  let kind = Self.kind(of: device) else { return }
            track(device)
            // IOBluetooth also reports devices that were connected before XNotch started.
            guard Date().timeIntervalSince(startedAt) > 2 else { return }
            let connection = HeadphonesConnection(address: address, name: device.name ?? "Headphones", kind: kind)
            latest = connection
            onConnect?(connection)
            scheduleBatteryReads()
        }
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        MainActor.assumeIsolated {
            guard let address = device.addressString else { return }
            connected.remove(address)
            disconnectNotifications.removeValue(forKey: address)?.unregister()
        }
    }

    private func track(_ device: IOBluetoothDevice) {
        guard let address = device.addressString, Self.kind(of: device) != nil else { return }
        connected.insert(address)
        if disconnectNotifications[address] == nil {
            disconnectNotifications[address] = device.register(forDisconnectNotification: self,
                                                               selector: #selector(deviceDisconnected(_:device:)))
        }
    }

    /// Nil for anything that isn't headphones or a speaker: mice, phones, keyboards.
    private static func kind(of device: IOBluetoothDevice) -> HeadphonesKind? {
        let generic = HeadphonesKind(classOfDevice: device.classOfDevice)
        let isAudio = generic != nil || device.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: 0x110B)) != nil
        guard isAudio else { return nil }
        let ids = deviceID(of: device)
        return HeadphonesKind(vendorID: ids.vendor, productID: ids.product)
            ?? device.name.flatMap(HeadphonesKind.init(name:))
            ?? generic
            ?? .headphones
    }

    /// Vendor and product from the Device ID SDP record, when macOS has it cached.
    private static func deviceID(of device: IOBluetoothDevice) -> (vendor: UInt16?, product: UInt16?) {
        guard let record = device.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: 0x1200)) else { return (nil, nil) }
        func value(_ attribute: BluetoothSDPServiceAttributeID) -> UInt16? {
            record.getAttributeDataElement(attribute)?.getNumberValue().map { UInt16(truncatingIfNeeded: $0.intValue) }
        }
        return (value(0x0201), value(0x0202))
    }

    // MARK: Battery

    private static let batteryReadDelays: [TimeInterval] = [0.4, 1.2, 2.5]

    private func scheduleBatteryReads() {
        cancelBatteryReads()
        readBatteryLater()
    }

    private func cancelBatteryReads() {
        batteryWork?.cancel()
        batteryWork = nil
        batteryReads = 0
    }

    private func readBatteryLater() {
        guard batteryReads < Self.batteryReadDelays.count, let address = latest?.address else { return }
        let delay = Self.batteryReadDelays[batteryReads]
        batteryReads += 1
        let work = DispatchWorkItem { [weak self] in
            self?.profilerQueue.async {
                let info = Self.profilerInfo(address: address)
                DispatchQueue.main.async { self?.received(info, for: address) }
            }
        }
        batteryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func received(_ info: ProfilerInfo?, for address: String) {
        guard var connection = latest, connection.address == address else { return }
        if let info {
            // The profiler knows the model even when the SDP record wasn't cached.
            if let kind = HeadphonesKind(vendorID: info.vendorID, productID: info.productID), kind != connection.kind {
                connection.kind = kind
            }
            connection.battery = info.battery
            if connection != latest { latest = connection }
        }
        if connection.battery == nil { readBatteryLater() }
    }

    private struct ProfilerInfo {
        var vendorID: UInt16?
        var productID: UInt16?
        var battery: Int?
    }

    /// One device's entry in `system_profiler SPBluetoothDataType`. Runs a
    /// subprocess (~200 ms), so only off the main thread and only after a connect.
    nonisolated private static func profilerInfo(address: String) -> ProfilerInfo? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        let target = normalized(address)
        for controller in controllers {
            for group in (controller["device_connected"] as? [[String: Any]]) ?? [] {
                for case let info as [String: Any] in group.values
                where (info["device_address"] as? String).map(normalized) == target {
                    return ProfilerInfo(vendorID: hex(info["device_vendorID"]), productID: hex(info["device_productID"]),
                                        battery: battery(in: info))
                }
            }
        }
        return nil
    }

    /// Earbuds report each bud and the case; show the emptier bud, as it runs out first.
    nonisolated private static func battery(in info: [String: Any]) -> Int? {
        func percent(_ key: String) -> Int? {
            (info[key] as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) }
        }
        let buds = [percent("device_batteryLevelLeft"), percent("device_batteryLevelRight")].compactMap { $0 }
        if let lowest = buds.min() { return min(max(lowest, 0), 100) }
        return percent("device_batteryLevelMain").map { min(max($0, 0), 100) }
    }

    nonisolated private static func hex(_ value: Any?) -> UInt16? {
        guard let string = value as? String else { return nil }
        return UInt16(string.lowercased().replacingOccurrences(of: "0x", with: ""), radix: 16)
    }

    nonisolated private static func normalized(_ address: String) -> String {
        address.lowercased().filter(\.isHexDigit)
    }
}
