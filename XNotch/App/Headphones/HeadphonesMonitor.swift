import AppKit
import CoreAudio
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

/// Reports headphones and speakers as macOS starts playing through them.
/// Event-driven: Core Audio calls back when the default output device
/// changes, nothing polls. That catches AirPods however they arrive (a fresh
/// connect, a hand-off from the iPhone, picking them in Control Center),
/// which IOBluetooth's connect notifications miss. The battery is read from
/// `system_profiler` off the main thread, a few times after a switch, since
/// macOS learns it a moment after the link comes up.
@MainActor
final class HeadphonesMonitor: NSObject, ObservableObject {
    /// The latest connection while its toast is relevant; updated as its battery arrives.
    @Published private(set) var latest: HeadphonesConnection?
    var onConnect: ((HeadphonesConnection) -> Void)?

    private var outputListener: AudioObjectPropertyListenerBlock?
    /// Bluetooth address of the current output, nil when it isn't Bluetooth.
    private var currentAddress: String?
    private var batteryReads = 0
    private var batteryWork: DispatchWorkItem?
    private let profilerQueue = DispatchQueue(label: "dev.levi.XNotch.headphones", qos: .utility)

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    var isRunning: Bool { outputListener != nil }

    func start() {
        guard !isRunning else { return }
        // Whatever plays at launch was already in use; only later switches show.
        currentAddress = Self.defaultOutput().flatMap(Self.bluetoothAddress(of:))
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.outputChanged() }
        }
        outputListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress,
                                            .main, listener)
    }

    func stop() {
        if let outputListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress,
                                                   .main, outputListener)
        }
        outputListener = nil
        currentAddress = nil
        cancelBatteryReads()
        latest = nil
    }

    /// Clears the connection once its toast is gone, so stale batteries don't linger.
    func dismiss() {
        cancelBatteryReads()
        latest = nil
    }

    private func outputChanged() {
        guard let device = Self.defaultOutput() else { return }
        let address = Self.bluetoothAddress(of: device)
        // Core Audio can hand the same headphones a new device ID, say when
        // the microphone turns on; that isn't a new arrival.
        guard address != currentAddress else { return }
        currentAddress = address
        guard let address else { return }
        let name = Self.name(of: device) ?? "Headphones"
        let connection = HeadphonesConnection(address: address, name: name, kind: Self.kind(address: address, name: name))
        latest = connection
        onConnect?(connection)
        scheduleBatteryReads()
    }

    /// Nameless or unknown devices fall back to plain headphones; the profiler
    /// refines Apple models by product ID once the battery read lands.
    private static func kind(address: String, name: String) -> HeadphonesKind {
        if let kind = HeadphonesKind(name: name) { return kind }
        // Asking IOBluetooth without Bluetooth access would prompt, and this can do without it.
        if CBCentralManager.authorization == .allowedAlways,
           let device = IOBluetoothDevice(addressString: address) {
            let ids = deviceID(of: device)
            if let kind = HeadphonesKind(vendorID: ids.vendor, productID: ids.product)
                ?? HeadphonesKind(classOfDevice: device.classOfDevice) {
                return kind
            }
        }
        return .headphones
    }

    /// Vendor and product from the Device ID SDP record, when macOS has it cached.
    private static func deviceID(of device: IOBluetoothDevice) -> (vendor: UInt16?, product: UInt16?) {
        guard let record = device.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: 0x1200)) else { return (nil, nil) }
        func value(_ attribute: BluetoothSDPServiceAttributeID) -> UInt16? {
            record.getAttributeDataElement(attribute)?.getNumberValue().map { UInt16(truncatingIfNeeded: $0.intValue) }
        }
        return (value(0x0201), value(0x0202))
    }

    // MARK: Core Audio

    private static func defaultOutput() -> AudioDeviceID? {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress,
                                                0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    /// The device's Bluetooth address, from its UID ("BC-80-4E-64-F0-6E:output"),
    /// or nil for anything that isn't Bluetooth. A UID that isn't an address
    /// still identifies the device; it just finds no battery.
    private static func bluetoothAddress(of device: AudioDeviceID) -> String? {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr,
              transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
              let uid = string(kAudioDevicePropertyDeviceUID, of: device) else { return nil }
        let prefix = String(uid.prefix { $0 != ":" })
        return normalized(prefix).count == 12 ? prefix : uid
    }

    private static func name(of device: AudioDeviceID) -> String? {
        string(kAudioObjectPropertyName, of: device)
    }

    private static func string(_ selector: AudioObjectPropertySelector, of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
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
