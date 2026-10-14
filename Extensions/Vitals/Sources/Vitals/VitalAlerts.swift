import Foundation
import XNotchKit

enum VitalAlertKind: String, CaseIterable, Identifiable, Sendable {
    case disk, memory, battery, heat, cpu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .disk: "Disk almost full"
        case .memory: "Memory pressure"
        case .battery: "Battery low"
        case .heat: "Running hot"
        case .cpu: "CPU busy"
        }
    }

    var summary: String {
        switch self {
        case .disk: "When free space on your startup disk runs low"
        case .memory: "When macOS runs short of memory"
        case .battery: "On battery, when the charge gets low"
        case .heat: "When your Mac slows itself down to cool off"
        case .cpu: "After a minute of heavy load, with the app behind it"
        }
    }

    var symbol: String {
        switch self {
        case .disk: "internaldrive.fill"
        case .memory: "memorychip.fill"
        case .battery: "battery.25percent"
        case .heat: "thermometer.high"
        case .cpu: "cpu.fill"
        }
    }

    /// The readings it watches.
    var metric: Metric? {
        switch self {
        case .disk: .disk
        case .memory: .memory
        case .battery: .battery
        case .heat: nil
        case .cpu: .cpu
        }
    }

    static let diskChoices = [5, 10, 15, 20]
    static let batteryChoices = [10, 20, 30]
    static let cpuChoices = [75, 90]
}

/// Decides when a reading deserves an alert: when something crosses into
/// trouble, not while it stays there. An alert re-arms once its reading has
/// recovered, comes back at most every half hour, and sooner only when things
/// get worse.
struct AlertMonitor {
    static let quietPeriod: TimeInterval = 30 * 60
    /// How long the CPU has to stay busy before it's worth mentioning.
    static let cpuSustain: TimeInterval = 60

    private enum Status {
        case unknown
        case fine
        case trouble(Gauge.Level)
    }

    /// Alerts whose reading is in trouble, at the level they were last at.
    private var active: [VitalAlertKind: Gauge.Level] = [:]
    private var lastFired: [VitalAlertKind: Date] = [:]
    private(set) var cpuBusySince: Date?

    /// The alerts this reading calls for, most serious first.
    mutating func evaluate(_ sample: Sample, thermal: ProcessInfo.ThermalState, settings: VitalsSettings,
                           now: Date) -> [NotchAlert] {
        var fired: [(kind: VitalAlertKind, level: Gauge.Level)] = []
        for kind in VitalAlertKind.allCases {
            guard settings.alerts.contains(kind) else {
                active[kind] = nil
                if kind == .cpu { cpuBusySince = nil }
                continue
            }
            switch status(kind, sample: sample, thermal: thermal, settings: settings, now: now) {
            case .unknown:
                continue
            case .fine:
                active[kind] = nil
            case let .trouble(level):
                let previous = active[kind]
                active[kind] = level
                let worse = previous == .caution && level == .critical
                let quiet = lastFired[kind].map { now.timeIntervalSince($0) < Self.quietPeriod } ?? false
                guard previous == nil ? !quiet : worse else { continue }
                lastFired[kind] = now
                fired.append((kind, level))
            }
        }
        return fired
            .sorted { $0.level == .critical && $1.level != .critical }
            .map { Self.alert($0.kind, level: $0.level, sample: sample, thermal: thermal) }
    }

    private mutating func status(_ kind: VitalAlertKind, sample: Sample, thermal: ProcessInfo.ThermalState,
                                 settings: VitalsSettings, now: Date) -> Status {
        switch kind {
        case .disk:
            guard let free = sample.diskFree, let total = sample.diskTotal, total > 0 else { return .unknown }
            let percent = Double(free) / Double(total) * 100
            let threshold = Double(settings.diskAlertPercent)
            // Two points of slack, so hovering at the line doesn't re-arm it.
            if percent >= threshold + (active[.disk] == nil ? 0 : 2) { return .fine }
            return .trouble(percent < threshold / 2 ? .critical : .caution)

        case .memory:
            guard sample.memoryUsed != nil else { return .unknown }
            switch sample.memoryPressure {
            case .normal: return .fine
            case .warning: return settings.memoryAlertsOnlyWhenCritical ? .fine : .trouble(.caution)
            case .critical: return .trouble(.critical)
            }

        case .battery:
            guard let battery = sample.battery else { return .unknown }
            let threshold = settings.batteryAlertPercent
            if battery.onPower || battery.percent > threshold { return .fine }
            return .trouble(battery.percent <= min(10, threshold / 2) ? .critical : .caution)

        case .heat:
            switch thermal {
            case .serious: return .trouble(.caution)
            case .critical: return .trouble(.critical)
            default: return .fine
            }

        case .cpu:
            guard let cpu = sample.cpu else { return .unknown }
            guard cpu * 100 >= Double(settings.cpuAlertPercent) else {
                cpuBusySince = nil
                return .fine
            }
            let since = cpuBusySince ?? now
            cpuBusySince = since
            return now.timeIntervalSince(since) >= Self.cpuSustain ? .trouble(cpu >= 0.95 ? .critical : .caution) : .fine
        }
    }

    /// What the wings say. Also used for a preview from Settings, with
    /// whatever was last read.
    static func alert(_ kind: VitalAlertKind, level: Gauge.Level, sample: Sample?,
                      thermal: ProcessInfo.ThermalState) -> NotchAlert {
        let tint = level == .critical ? "#FF6359" : "#FFBD4D"
        func make(_ title: String, _ value: String, progress: Double? = nil) -> NotchAlert {
            NotchAlert(symbol: kind.symbol, tint: tint, title: title, value: value, progress: progress,
                       page: VitalsExtension.pageID)
        }
        switch kind {
        case .disk:
            guard let free = sample?.diskFree, let total = sample?.diskTotal, total > 0 else { return make("Disk", "Full") }
            let text = VitalsFormat.bytes(Double(free))
            return make("Disk", "\(text.value) \(text.unit)", progress: Double(free) / Double(total))
        case .memory:
            return make("Memory", level == .critical ? "Critical" : "High")
        case .battery:
            let percent = sample?.battery?.percent ?? 20
            return make("Battery", "\(percent)%", progress: Double(percent) / 100)
        case .heat:
            return make("Heat", thermal == .critical || level == .critical ? "Critical" : "Throttling")
        case .cpu:
            let cpu = sample?.cpu ?? 1
            return make(sample?.busiest?.name ?? "CPU", "\(Int((cpu * 100).rounded()))%", progress: cpu)
        }
    }
}
