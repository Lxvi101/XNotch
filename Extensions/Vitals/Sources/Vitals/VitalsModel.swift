import AppKit
import SwiftUI
import XNotchKit

enum Metric: String, CaseIterable, Identifiable, Sendable {
    case cpu, memory, network, gpu, disk, battery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .network: "Network"
        case .gpu: "GPU"
        case .disk: "Disk"
        case .battery: "Battery"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .network: "arrow.up.arrow.down"
        case .gpu: "square.stack.3d.up.fill"
        case .disk: "internaldrive"
        case .battery: "battery.75percent"
        }
    }

    /// Opens into the apps behind it.
    var breaksDown: Bool { self == .cpu || self == .memory }

    var tintHex: String {
        switch self {
        case .cpu: "#FF9F0A"
        case .memory: "#64D2FF"
        case .network: "#0A84FF"
        case .gpu: "#BF5AF2"
        case .disk: "#98989D"
        case .battery: "#30D158"
        }
    }

    /// What its tile says, for Settings.
    var summary: String {
        switch self {
        case .cpu: "Load across all cores, and the app using the most"
        case .memory: "Memory in use; turns amber under pressure"
        case .network: "Download speed, with upload underneath"
        case .gpu: "How busy the graphics processor is"
        case .disk: "Free space on your startup disk"
        case .battery: "Charge, and the time left"
        }
    }
}

/// What the user chose in Settings, persisted in the extension's defaults.
struct VitalsSettings: Equatable, Sendable {
    /// The notch is 400 pt wide: more tiles than this stop being readable.
    static let maxShown = 4
    static let intervalChoices: [Double] = [1, 2, 5]

    /// Every metric, in the user's order.
    var order: [Metric] = Metric.allCases
    var shown: Set<Metric> = [.cpu, .memory, .network]
    var interval: Double = 2
    var namesBusiestApp = true
    var slowerOnLowPower = true

    /// Alerts in the closed notch's wings.
    var alerts: Set<VitalAlertKind> = [.disk, .memory, .battery, .heat]
    var diskAlertPercent = 10
    var batteryAlertPercent = 20
    var cpuAlertPercent = 90
    var memoryAlertsOnlyWhenCritical = false
    /// A warning sign with the notch's eyes showing how serious it is, instead of the symbol and value.
    var alertsShowEyes = false

    /// The tiles in the notch, left to right.
    var visible: [Metric] { Array(order.filter(shown.contains).prefix(Self.maxShown)) }

    var isFull: Bool { visible.count >= Self.maxShown }

    /// What has to be read: the tiles, and whatever the alerts watch.
    var sampled: Set<Metric> {
        Set(visible).union(alerts.compactMap(\.metric))
    }

    static func load(from defaults: UserDefaults) -> VitalsSettings {
        var settings = VitalsSettings()
        if let raw = defaults.array(forKey: Keys.order) as? [String] {
            settings.order = raw.compactMap(Metric.init(rawValue:))
        }
        if let raw = defaults.array(forKey: Keys.shown) as? [String] {
            settings.shown = Set(raw.compactMap(Metric.init(rawValue:)))
        }
        if let interval = defaults.object(forKey: Keys.interval) as? Double, intervalChoices.contains(interval) {
            settings.interval = interval
        }
        settings.namesBusiestApp = defaults.object(forKey: Keys.namesBusiestApp) as? Bool ?? settings.namesBusiestApp
        settings.slowerOnLowPower = defaults.object(forKey: Keys.slowerOnLowPower) as? Bool ?? settings.slowerOnLowPower
        if let raw = defaults.array(forKey: Keys.alerts) as? [String] {
            settings.alerts = Set(raw.compactMap(VitalAlertKind.init(rawValue:)))
        }
        func choice(_ key: String, in choices: [Int], default value: Int) -> Int {
            (defaults.object(forKey: key) as? Int).flatMap { choices.contains($0) ? $0 : nil } ?? value
        }
        settings.diskAlertPercent = choice(Keys.diskAlertPercent, in: VitalAlertKind.diskChoices, default: settings.diskAlertPercent)
        settings.batteryAlertPercent = choice(Keys.batteryAlertPercent, in: VitalAlertKind.batteryChoices,
                                              default: settings.batteryAlertPercent)
        settings.cpuAlertPercent = choice(Keys.cpuAlertPercent, in: VitalAlertKind.cpuChoices, default: settings.cpuAlertPercent)
        settings.memoryAlertsOnlyWhenCritical = defaults.object(forKey: Keys.memoryAlertsOnlyWhenCritical) as? Bool
            ?? settings.memoryAlertsOnlyWhenCritical
        settings.alertsShowEyes = defaults.object(forKey: Keys.alertsShowEyes) as? Bool ?? settings.alertsShowEyes
        settings.normalize()
        return settings
    }

    func save(to defaults: UserDefaults) {
        defaults.set(order.map(\.rawValue), forKey: Keys.order)
        defaults.set(order.filter(shown.contains).map(\.rawValue), forKey: Keys.shown)
        defaults.set(interval, forKey: Keys.interval)
        defaults.set(namesBusiestApp, forKey: Keys.namesBusiestApp)
        defaults.set(slowerOnLowPower, forKey: Keys.slowerOnLowPower)
        defaults.set(VitalAlertKind.allCases.filter(alerts.contains).map(\.rawValue), forKey: Keys.alerts)
        defaults.set(diskAlertPercent, forKey: Keys.diskAlertPercent)
        defaults.set(batteryAlertPercent, forKey: Keys.batteryAlertPercent)
        defaults.set(cpuAlertPercent, forKey: Keys.cpuAlertPercent)
        defaults.set(memoryAlertsOnlyWhenCritical, forKey: Keys.memoryAlertsOnlyWhenCritical)
        defaults.set(alertsShowEyes, forKey: Keys.alertsShowEyes)
    }

    /// Every metric exactly once, newer ones at the end.
    mutating func normalize() {
        var seen = Set<Metric>()
        order = order.filter { seen.insert($0).inserted } + Metric.allCases.filter { !seen.contains($0) }
    }

    private enum Keys {
        static let order = "order"
        static let shown = "shown"
        static let interval = "interval"
        static let namesBusiestApp = "namesBusiestApp"
        static let slowerOnLowPower = "slowerOnLowPower"
        static let alerts = "alerts"
        static let diskAlertPercent = "diskAlertPercent"
        static let batteryAlertPercent = "batteryAlertPercent"
        static let cpuAlertPercent = "cpuAlertPercent"
        static let memoryAlertsOnlyWhenCritical = "memoryAlertsOnlyWhenCritical"
        static let alertsShowEyes = "alertsShowEyes"
    }
}

/// Settings, the latest reading and a minute or so of history per metric.
/// Samples on a timer for as long as the extension is on, so the graphs are
/// already full when the page opens; the per-process scan only runs while a
/// page or the Settings preview is on screen.
@MainActor
final class VitalsModel: ObservableObject {
    /// Points in each graph.
    nonisolated static let historyLength = 40

    @Published var settings = VitalsSettings() {
        didSet { settingsChanged(from: oldValue) }
    }
    @Published private(set) var sample: Sample?
    @Published private(set) var history: [Metric: [Double]] = [:]
    @Published private(set) var uploadHistory: [Double] = VitalsModel.emptyHistory
    /// The busiest app's icon, looked up once per app rather than on render.
    @Published private(set) var busiestIcon: NSImage?
    /// The tile grown into the apps behind it. Kept here, not in the view, so
    /// it survives the page being rebuilt.
    @Published var expanded: Metric? {
        didSet {
            guard expanded != oldValue else { return }
            expandedApp = nil
            tick()
            onLayoutChange?()
        }
    }
    /// The app in the breakdown unfolded into its processes.
    @Published var expandedApp: AppUsage.ID? {
        didSet { if expandedApp != oldValue { onLayoutChange?() } }
    }
    /// App icons by bundle path, looked up once rather than on render.
    @Published private(set) var icons: [String: NSImage] = [:]
    /// The page's height may have changed.
    var onLayoutChange: (() -> Void)?

    nonisolated static let breakdownLimit = 5
    nonisolated static let processLimit = 3
    private(set) var hasBattery = true
    /// Hands an alert to the notch.
    var onAlert: ((NotchAlert) -> Void)?
    private var alertMonitor = AlertMonitor()
    /// Alerts that fired together, shown one after another.
    private var alertQueue: [NotchAlert] = []
    private var alertTimer: Timer?
    /// The notch shows an alert for five seconds; the next follows once it has folded away.
    static let alertSpacing: TimeInterval = 6

    private let sampler = SystemSampler()
    private var defaults: UserDefaults?
    private var timer: Timer?
    private var isSampling = false
    /// A reading was asked for while one was under way: take it right after.
    private var needsTick = false
    private var watchers = Set<UUID>()
    private var hasUploadHistory = false
    private var powerObserver: NSObjectProtocol?

    nonisolated static let emptyHistory = [Double](repeating: 0, count: historyLength)

    func load(defaults: UserDefaults) {
        self.defaults = defaults
        hasBattery = SystemSampler.hasBattery
        settings = .load(from: defaults)
    }

    func start() {
        powerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
        schedule()
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        powerObserver.map(NotificationCenter.default.removeObserver)
        powerObserver = nil
        watchers.removeAll()
        alertTimer?.invalidate()
        alertTimer = nil
        alertQueue.removeAll()
    }

    func history(for metric: Metric) -> [Double] {
        history[metric] ?? Self.emptyHistory
    }

    func gauge(for metric: Metric) -> Gauge {
        Gauge.make(metric, sample: sample, namesBusiestApp: settings.namesBusiestApp)
    }

    /// A page or preview is on screen (or no longer is). While any is, the
    /// busiest app is looked for.
    func setWatching(_ token: UUID, _ watching: Bool) {
        let wasWatched = !watchers.isEmpty
        if watching { watchers.insert(token) } else { watchers.remove(token) }
        if !wasWatched, !watchers.isEmpty { tick() }
    }

    private func showNextAlert() {
        guard !alertQueue.isEmpty else {
            alertTimer = nil
            return
        }
        onAlert?(alertQueue.removeFirst())
        alertTimer = Timer.scheduledTimer(withTimeInterval: Self.alertSpacing, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showNextAlert() }
        }
    }

    /// Shows an alert now, with the latest readings, so its look can be checked from Settings.
    /// Previews alternate between a caution and a critical one, so both looks can be seen.
    func previewAlert(_ kind: VitalAlertKind) {
        defer { previewsCritical.toggle() }
        onAlert?(AlertMonitor.alert(kind, level: previewsCritical ? .critical : .caution, sample: sample,
                                    thermal: ProcessInfo.processInfo.thermalState))
    }
    private var previewsCritical = false

    var effectiveInterval: TimeInterval {
        let lowPower = settings.slowerOnLowPower && ProcessInfo.processInfo.isLowPowerModeEnabled
        return settings.interval * (lowPower ? 2 : 1)
    }

    private func settingsChanged(from old: VitalsSettings) {
        guard settings != old else { return }
        defaults.map(settings.save)
        if settings.interval != old.interval || settings.slowerOnLowPower != old.slowerOnLowPower { schedule() }
        if let expanded, !settings.visible.contains(expanded) { self.expanded = nil }
        if settings.sampled != old.sampled || settings.namesBusiestApp != old.namesBusiestApp { tick() }
    }

    private func schedule() {
        timer?.invalidate()
        let timer = Timer(timeInterval: effectiveInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = effectiveInterval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard timer != nil else { return }
        guard !isSampling else {
            needsTick = true
            return
        }
        let metrics = settings.sampled
        guard !metrics.isEmpty else { return }
        isSampling = true
        // The app is named while someone's looking, and while a CPU alert is building, for the alert to name it.
        let shown = settings.namesBusiestApp && !watchers.isEmpty && settings.visible.contains(.cpu)
        let request = SystemSampler.Request(metrics: metrics, findsBusiestApp: shown || alertMonitor.cpuBusySince != nil,
                                            // While the page is up, so a tile opens onto rows already in place.
                                            breaksDown: !watchers.isEmpty && settings.visible.contains(where: \.breaksDown),
                                            isWatched: !watchers.isEmpty)
        Task {
            let sample = await sampler.sample(request)
            isSampling = false
            apply(sample, metrics: metrics)
            if needsTick {
                needsTick = false
                tick()
            }
            // CPU per app needs a second scan: take it soon rather than at the next tick.
            if request.breaksDown, sample.apps?.contains(where: { $0.cpu == nil }) == true {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.tick() }
            }
        }
    }

    private func apply(_ sample: Sample, metrics: Set<Metric>) {
        var history = history
        for metric in metrics {
            guard let fraction = Gauge.fraction(metric, sample: sample) else { continue }
            // The first reading fills the graph, so it starts level instead of climbing out of zero.
            history[metric] = Self.appending(fraction, to: history[metric] ?? Self.seeded(fraction))
        }
        if metrics.contains(.network), let upload = sample.upload {
            let fraction = Gauge.networkFraction(upload)
            uploadHistory = Self.appending(fraction, to: hasUploadHistory ? uploadHistory : Self.seeded(fraction))
            hasUploadHistory = true
        }
        self.history = history
        self.sample = sample
        let alerts = alertMonitor.evaluate(sample, thermal: ProcessInfo.processInfo.thermalState,
                                           settings: settings, now: Date())
        if !alerts.isEmpty {
            alertQueue += alerts
            if alertTimer == nil { showNextAlert() }
        }

        var paths = [sample.busiest?.bundlePath].compactMap { $0 }
        for metric in settings.visible where metric.breaksDown { paths += topApps(for: metric).compactMap(\.bundlePath) }
        let missing = paths.filter { icons[$0] == nil }
        if !missing.isEmpty {
            var icons = icons
            for path in missing { icons[path] = NSWorkspace.shared.icon(forFile: path) }
            self.icons = icons
        }
        let busiest = sample.busiest?.bundlePath.flatMap { icons[$0] }
        if busiest !== busiestIcon { busiestIcon = busiest }
        if expanded != nil { onLayoutChange?() }
    }

    // MARK: Breakdown

    func topApps(for metric: Metric) -> [AppUsage] {
        Self.ranked(sample?.apps ?? [], by: metric)
    }

    /// The processes worth listing under an app: only when there's more than one.
    func processes(of app: AppUsage, for metric: Metric) -> [ProcessUsage] {
        Self.rankedProcesses(app, by: metric)
    }

    nonisolated static func usage(_ app: AppUsage, _ metric: Metric) -> Double {
        metric == .memory ? Double(app.memory) : app.cpu ?? 0
    }

    nonisolated static func usage(_ process: ProcessUsage, _ metric: Metric) -> Double {
        metric == .memory ? Double(process.memory) : process.cpu ?? 0
    }

    /// The heaviest apps for a metric, leaving out the ones using none of it.
    nonisolated static func ranked(_ apps: [AppUsage], by metric: Metric) -> [AppUsage] {
        Array(apps.filter { usage($0, metric) > 0 }
            .sorted { usage($0, metric) != usage($1, metric) ? usage($0, metric) > usage($1, metric) : $0.name < $1.name }
            .prefix(breakdownLimit))
    }

    nonisolated static func rankedProcesses(_ app: AppUsage, by metric: Metric) -> [ProcessUsage] {
        guard app.processes.count > 1 else { return [] }
        return Array(app.processes.sorted { usage($0, metric) > usage($1, metric) }.prefix(processLimit))
    }

    /// Quits an app from the breakdown; `force` as Activity Monitor's Force Quit.
    func quit(_ app: AppUsage, force: Bool) {
        guard let path = app.bundlePath else { return }
        for running in NSWorkspace.shared.runningApplications where running.bundleURL?.path == path {
            _ = force ? running.forceTerminate() : running.terminate()
        }
    }

    func canQuit(_ app: AppUsage) -> Bool { app.bundlePath != nil }

    nonisolated static func seeded(_ value: Double) -> [Double] {
        [Double](repeating: value, count: historyLength)
    }

    nonisolated static func appending(_ value: Double, to history: [Double]) -> [Double] {
        var history = history
        history.removeFirst(max(0, history.count - historyLength + 1))
        history.append(value)
        return history
    }
}

/// What a tile shows for a metric: a big number, its unit and a quieter line
/// underneath. Colour only ever means "careful".
struct Gauge: Equatable {
    enum Level { case normal, caution, critical }

    var value: String
    var unit: String
    var valueSymbol: String?
    var detail: String?
    var detailSymbol: String?
    var level: Level = .normal
    var accessibilityValue: String

    static let unknown = Gauge(value: "–", unit: "", accessibilityValue: "Not measured yet")

    /// The graph's height for a reading, 0…1.
    static func fraction(_ metric: Metric, sample: Sample) -> Double? {
        switch metric {
        case .cpu: sample.cpu
        case .memory: sample.memoryUsed.map { min(1, Double($0) / Double(max(1, sample.memoryTotal))) }
        case .network: sample.download.map(networkFraction)
        case .gpu: sample.gpu
        case .disk:
            sample.diskFree.flatMap { free in
                sample.diskTotal.map { total in total > 0 ? 1 - Double(free) / Double(total) : 0 }
            }
        case .battery: sample.battery.map { Double($0.percent) / 100 }
        }
    }

    /// Logarithmic, so a page loading and a big download both show: 1 KB/s
    /// barely lifts it, 1 MB/s is about halfway, 1 Gbps fills it.
    static func networkFraction(_ bytesPerSecond: Double) -> Double {
        let ceiling = log10(1 + 125_000_000.0 / 1000)
        return min(1, max(0, log10(1 + max(0, bytesPerSecond) / 1000) / ceiling))
    }

    static func make(_ metric: Metric, sample: Sample?, namesBusiestApp: Bool) -> Gauge {
        guard let sample else { return .unknown }
        switch metric {
        case .cpu:
            guard let cpu = sample.cpu else { return .unknown }
            var gauge = percent(cpu, caution: 0.75, critical: 0.9)
            if namesBusiestApp, let app = sample.busiest, app.share >= 0.005 {
                gauge.detail = "\(app.name) \(Int((app.share * 100).rounded()))%"
                gauge.accessibilityValue += ", most used by \(app.name)"
            }
            return gauge

        case .memory:
            guard let used = sample.memoryUsed else { return .unknown }
            let shown = VitalsFormat.bytes(Double(used), base: 1024)
            let total = VitalsFormat.bytes(Double(sample.memoryTotal), base: 1024)
            let level: Level = switch sample.memoryPressure {
            case .normal: .normal
            case .warning: .caution
            case .critical: .critical
            }
            return Gauge(value: shown.value, unit: shown.unit,
                         detail: level == .normal ? "of \(total.value) \(total.unit)" : "Pressure high",
                         level: level, accessibilityValue: "\(shown.value) \(shown.unit) of \(total.value) \(total.unit) used")

        case .network:
            guard let down = sample.download, let up = sample.upload else { return .unknown }
            let downText = VitalsFormat.rate(down)
            let upText = VitalsFormat.rate(up)
            return Gauge(value: downText.value, unit: downText.unit, valueSymbol: "arrow.down",
                         detail: "\(upText.value) \(upText.unit)", detailSymbol: "arrow.up",
                         accessibilityValue: "\(downText.value) \(downText.unit) down, \(upText.value) \(upText.unit) up")

        case .gpu:
            guard let gpu = sample.gpu else { return .unknown }
            return percent(gpu, caution: 0.8, critical: 0.95)

        case .disk:
            guard let free = sample.diskFree, let total = sample.diskTotal, total > 0 else { return .unknown }
            let freeText = VitalsFormat.bytes(Double(free))
            let ratio = Double(free) / Double(total)
            return Gauge(value: freeText.value, unit: freeText.unit, detail: "\(Int((ratio * 100).rounded()))% free",
                         level: ratio < 0.05 ? .critical : ratio < 0.1 ? .caution : .normal,
                         accessibilityValue: "\(freeText.value) \(freeText.unit) free, \(Int((ratio * 100).rounded())) percent")

        case .battery:
            guard let battery = sample.battery else {
                return Gauge(value: "–", unit: "", detail: "No battery", accessibilityValue: "No battery")
            }
            let detail: String
            if battery.isCharging {
                detail = battery.minutesLeft.map { "Full in \(VitalsFormat.duration(minutes: $0))" } ?? "Charging"
            } else if battery.onPower {
                detail = battery.percent >= 100 ? "Charged" : "On power"
            } else {
                detail = battery.minutesLeft.map { "\(VitalsFormat.duration(minutes: $0)) left" } ?? "On battery"
            }
            let level: Level = battery.onPower ? .normal : battery.percent <= 10 ? .critical : battery.percent <= 20 ? .caution : .normal
            return Gauge(value: "\(battery.percent)", unit: "%", detail: detail, level: level,
                         accessibilityValue: "\(battery.percent) percent, \(detail)")
        }
    }

    private static func percent(_ fraction: Double, caution: Double, critical: Double) -> Gauge {
        let percent = Int((fraction * 100).rounded())
        return Gauge(value: "\(percent)", unit: "%",
                     level: fraction >= critical ? .critical : fraction >= caution ? .caution : .normal,
                     accessibilityValue: "\(percent) percent")
    }
}

enum VitalsFormat {
    /// "11.2" "GB": one decimal under ten, whole numbers above.
    static func bytes(_ bytes: Double, base: Double = 1000) -> (value: String, unit: String) {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = max(0, bytes)
        var index = 0
        // Rolls over at a thousand either way, so it never reads "1,020 MB".
        while value >= 999.5, index < units.count - 1 {
            value /= base
            index += 1
        }
        return (number(value), units[index])
    }

    /// Kilobytes at least, so a quiet connection reads "0 KB/s", not bytes.
    static func rate(_ bytesPerSecond: Double) -> (value: String, unit: String) {
        let kilobytes = max(0, bytesPerSecond) / 1000
        if kilobytes < 999.5 { return (number(kilobytes), "KB/s") }
        let scaled = bytes(bytesPerSecond)
        return (scaled.value, scaled.unit + "/s")
    }

    static func number(_ value: Double) -> String {
        if value < 0.05 { return "0" }
        return value.formatted(.number.precision(.fractionLength(value < 9.95 ? 1 : 0)))
    }

    /// "3:12", hours and minutes.
    static func duration(minutes: Int) -> String {
        "\(minutes / 60):\(String(format: "%02d", minutes % 60))"
    }
}
