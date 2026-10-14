import Darwin
import Foundation
import IOKit
import IOKit.ps

/// One reading of everything that was asked for. Rates and the CPU need two
/// readings, so they're nil the first time.
struct Sample: Sendable, Equatable {
    /// 0…1 of all cores.
    var cpu: Double?
    var memoryUsed: UInt64?
    var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var memoryPressure: MemoryPressure = .normal
    /// Bytes per second.
    var download: Double?
    var upload: Double?
    /// 0…1.
    var gpu: Double?
    var diskFree: Int64?
    var diskTotal: Int64?
    var battery: Battery?
    var busiest: BusiestApp?
    /// Every app (and lone process) with what it uses, whenever processes were scanned;
    /// memory only while a breakdown is open.
    var apps: [AppUsage]?
}

enum MemoryPressure: Int32, Sendable {
    case normal = 1, warning = 2, critical = 4
}

struct Battery: Sendable, Equatable {
    var percent: Int
    var isCharging: Bool
    var onPower: Bool
    /// Minutes to empty or to full, when macOS has worked it out.
    var minutesLeft: Int?
}

/// The app using the most CPU, its helpers counted with it.
struct BusiestApp: Sendable, Equatable {
    var name: String
    /// The .app bundle, for its icon; nil for a bare process.
    var bundlePath: String?
    /// 0…1 of all cores, comparable with `Sample.cpu`.
    var share: Double
}

/// What one app uses, its helpers counted with it.
struct AppUsage: Sendable, Equatable, Identifiable {
    var name: String
    var bundlePath: String?
    /// 0…1 of all cores; nil until a second scan can tell.
    var cpu: Double?
    /// Physical footprint, as Activity Monitor's Memory column.
    var memory: UInt64
    var processes: [ProcessUsage]

    var id: String { bundlePath ?? name }
}

struct ProcessUsage: Sendable, Equatable, Identifiable {
    var pid: pid_t
    var name: String
    var cpu: Double?
    var memory: UInt64

    var id: pid_t { pid }
}

/// Reads the system off the main actor. Everything here is a cheap syscall,
/// except the per-process scan, which only runs while someone is looking.
actor SystemSampler {
    struct Request: Sendable {
        var metrics: Set<Metric>
        var findsBusiestApp: Bool
        /// Every app's CPU and memory, for an open breakdown.
        var breaksDown = false
    }

    private let host = mach_host_self()
    private let coreCount = Double(ProcessInfo.processInfo.activeProcessorCount)
    private let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    private var lastCPU: (busy: UInt64, total: UInt64)?
    private var lastNetwork: (counters: [String: (rx: UInt32, tx: UInt32)], at: TimeInterval)?
    private var lastTasks: (times: [pid_t: UInt64], at: TimeInterval)?
    private var identities: [pid_t: Identity] = [:]
    private var lastDisk: (free: Int64, total: Int64, at: TimeInterval)?

    func sample(_ request: Request) -> Sample {
        var sample = Sample()
        let metrics = request.metrics
        if metrics.contains(.cpu) { sample.cpu = cpu() }
        if metrics.contains(.memory) {
            sample.memoryUsed = memoryUsed()
            sample.memoryPressure = memoryPressure()
        }
        if metrics.contains(.network), let rates = network() {
            sample.download = rates.down
            sample.upload = rates.up
        }
        if metrics.contains(.gpu) { sample.gpu = gpu() }
        if metrics.contains(.disk), let disk = disk() {
            sample.diskFree = disk.free
            sample.diskTotal = disk.total
        }
        if metrics.contains(.battery) { sample.battery = Self.battery() }
        if request.findsBusiestApp || request.breaksDown {
            let apps = scanProcesses(memory: request.breaksDown)
            // Without memory when not breaking down, but CPU per app is ready for a tile that opens.
            sample.apps = apps
            sample.busiest = apps
                .compactMap { app in app.cpu.map { BusiestApp(name: app.name, bundlePath: app.bundlePath, share: $0) } }
                .max { $0.share < $1.share }
        } else {
            lastTasks = nil
        }
        return sample
    }

    // MARK: CPU

    private func cpu() -> Double? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = load.cpu_ticks
        let busy = UInt64(ticks.0) + UInt64(ticks.1) + UInt64(ticks.3) // user, system, nice
        let total = busy + UInt64(ticks.2)
        defer { lastCPU = (busy, total) }
        guard let last = lastCPU, total > last.total else { return nil }
        return min(1, max(0, Double(busy &- last.busy) / Double(total - last.total)))
    }

    // MARK: Memory

    /// What Activity Monitor calls Memory Used: app memory, wired and compressed.
    private func memoryUsed() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let app = UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))
        let pages = app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return pages * UInt64(vm_kernel_page_size)
    }

    private func memoryPressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        return MemoryPressure(rawValue: level) ?? .normal
    }

    // MARK: Network

    /// Wi-Fi and Ethernet (`en*`), so VPN tunnels don't count traffic twice.
    private func network() -> (down: Double, up: Double)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }

        var counters: [String: (rx: UInt32, tx: UInt32)] = [:]
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.ifa_data,
                  Int32(entry.ifa_flags) & IFF_UP != 0, Int32(entry.ifa_flags) & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            counters[name] = (stats.ifi_ibytes, stats.ifi_obytes)
        }

        let now = ProcessInfo.processInfo.systemUptime
        defer { lastNetwork = (counters, now) }
        guard let last = lastNetwork, now > last.at else { return nil }
        var rx: UInt64 = 0, tx: UInt64 = 0
        for (name, current) in counters {
            guard let previous = last.counters[name] else { continue }
            // The counters are 32-bit: wrapping subtraction survives a rollover.
            rx += UInt64(current.rx &- previous.rx)
            tx += UInt64(current.tx &- previous.tx)
        }
        let elapsed = now - last.at
        return (Double(rx) / elapsed, Double(tx) / elapsed)
    }

    // MARK: GPU

    private func gpu() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var busiest: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let property = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                                 kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let stats = property as? [String: Any],
                  let percent = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { continue }
            busiest = max(busiest ?? 0, percent / 100)
        }
        return busiest.map { min(1, max(0, $0)) }
    }

    // MARK: Disk

    /// The startup disk. Free space counts what macOS would purge for you, as
    /// Finder does; that's slow to work out, so it's read twice a minute.
    private func disk() -> (free: Int64, total: Int64)? {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastDisk, now - last.at < 30 { return (last.free, last.total) }
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacityForImportantUsage else { return nil }
        lastDisk = (free, Int64(total), now)
        return (free, Int64(total))
    }

    // MARK: Battery

    static func battery() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description["Type"] as? String == "InternalBattery",
                  let current = description["Current Capacity"] as? Int,
                  let maximum = description["Max Capacity"] as? Int, maximum > 0 else { continue }
            let charging = description["Is Charging"] as? Bool ?? false
            let minutes = (charging ? description["Time to Full Charge"] : description["Time to Empty"]) as? Int
            return Battery(percent: min(100, max(0, current * 100 / maximum)), isCharging: charging,
                           onPower: description["Power Source State"] as? String == "AC Power",
                           minutesLeft: minutes.flatMap { $0 > 0 ? $0 : nil })
        }
        return nil
    }

    static var hasBattery: Bool { battery() != nil }

    // MARK: Processes

    /// Which app a process belongs to, and its own name.
    private struct Identity {
        var app: String
        var bundlePath: String?
        var process: String
    }

    /// Every process we may read (the user's own; system daemons are off
    /// limits without privileges), grouped by app. CPU is the time used since
    /// the last scan; memory is read only when asked, as it costs a call per process.
    private func scanProcesses(memory readsMemory: Bool) -> [AppUsage] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let found = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard found > 0 else { return [] }

        let now = ProcessInfo.processInfo.systemUptime
        let last = lastTasks.flatMap { now > $0.at ? $0 : nil }
        let scale = last.map { timebase / 1_000_000_000 / (now - $0.at) / coreCount }
        var times: [pid_t: UInt64] = [:]
        var apps: [String: AppUsage] = [:]
        for pid in pids.prefix(Int(found)) where pid > 0 {
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }
            let time = info.pti_total_user + info.pti_total_system
            times[pid] = time
            let identity = identity(for: pid)
            guard !identity.app.isEmpty else { continue }

            var cpu: Double?
            if let scale {
                // A process that's new since the last scan is counted from zero.
                let previous = last?.times[pid] ?? 0
                cpu = time >= previous ? Double(time - previous) * scale : 0
            }
            let footprint = readsMemory ? Self.footprint(of: pid) : 0
            let key = identity.bundlePath ?? identity.app
            var app = apps[key] ?? AppUsage(name: identity.app, bundlePath: identity.bundlePath,
                                            cpu: scale == nil ? nil : 0, memory: 0, processes: [])
            app.cpu = app.cpu.map { $0 + (cpu ?? 0) }
            app.memory += footprint
            app.processes.append(ProcessUsage(pid: pid, name: identity.process, cpu: cpu, memory: footprint))
            apps[key] = app
        }

        lastTasks = (times, now)
        identities = identities.filter { times[$0.key] != nil }
        return Array(apps.values)
    }

    private static func footprint(of pid: pid_t) -> UInt64 {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? usage.ri_phys_footprint : 0
    }

    /// A command-line tool's name. Some install one binary per version
    /// (`~/.local/share/claude/versions/2.1.299`): those take the folder's name.
    static func toolName(path: String) -> String {
        let generic: Set<String> = ["versions", "bin", "sbin", "libexec", "current", "latest", "MacOS"]
        for component in (path as NSString).pathComponents.reversed() where component != "/" {
            guard let first = component.first, !first.isNumber, !generic.contains(component) else { continue }
            return component
        }
        return (path as NSString).lastPathComponent
    }

    /// The outermost .app a process lives in, so Chrome's helpers count as Chrome.
    private func identity(for pid: pid_t) -> Identity {
        if let known = identities[pid] { return known }
        var name = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        proc_name(pid, &name, UInt32(name.count))
        var process = String(cString: name)
        var identity = Identity(app: process, bundlePath: nil, process: process)
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            let path = String(cString: buffer)
            if process.isEmpty { process = (path as NSString).lastPathComponent }
            if let range = path.range(of: ".app/") {
                let bundle = String(path[..<range.lowerBound]) + ".app"
                identity = Identity(app: ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension,
                                    bundlePath: bundle, process: process)
            } else {
                let name = Self.toolName(path: path)
                identity = Identity(app: name, bundlePath: nil, process: process == (path as NSString).lastPathComponent ? name : process)
            }
        }
        identities[pid] = identity
        return identity
    }
}
