import XCTest
@testable import Vitals

final class VitalsTests: XCTestCase {
    func testSettingsRoundTripAndKeepEveryMetric() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "vitals.tests.\(UUID())"))
        var settings = VitalsSettings()
        settings.order = [.network, .cpu]
        settings.normalize()
        settings.shown = [.network, .gpu]
        settings.interval = 5
        settings.namesBusiestApp = false
        settings.save(to: defaults)

        let loaded = VitalsSettings.load(from: defaults)
        XCTAssertEqual(loaded, settings)
        XCTAssertEqual(loaded.order.count, Metric.allCases.count)
        XCTAssertEqual(loaded.visible, [.network, .gpu])
    }

    func testUnknownStoredValuesFallBack() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "vitals.tests.\(UUID())"))
        defaults.set(["thermals", "memory", "memory"], forKey: "order")
        defaults.set(3.0, forKey: "interval")

        let loaded = VitalsSettings.load(from: defaults)
        XCTAssertEqual(loaded.order.first, .memory)
        XCTAssertEqual(Set(loaded.order), Set(Metric.allCases))
        XCTAssertEqual(loaded.order.count, Metric.allCases.count)
        XCTAssertEqual(loaded.interval, VitalsSettings().interval)
    }

    func testAtMostFourTiles() {
        var settings = VitalsSettings()
        settings.shown = Set(Metric.allCases)
        XCTAssertEqual(settings.visible, Array(settings.order.prefix(VitalsSettings.maxShown)))
        XCTAssertTrue(settings.isFull)
    }

    func testFormatting() {
        XCTAssertEqual(VitalsFormat.rate(0).value, "0")
        XCTAssertEqual(VitalsFormat.rate(0).unit, "KB/s")
        XCTAssertEqual(VitalsFormat.rate(340_000).unit, "KB/s")
        XCTAssertEqual(VitalsFormat.rate(1_200_000).unit, "MB/s")
        XCTAssertEqual(VitalsFormat.bytes(16 * 1024 * 1024 * 1024, base: 1024).unit, "GB")
        XCTAssertEqual(VitalsFormat.bytes(999_999_999).unit, "GB")
        XCTAssertEqual(VitalsFormat.duration(minutes: 192), "3:12")
    }

    func testNetworkScaleIsLogarithmic() {
        XCTAssertEqual(Gauge.networkFraction(0), 0)
        XCTAssertLessThan(Gauge.networkFraction(1_000), 0.1)
        XCTAssertEqual(Gauge.networkFraction(1_000_000), 0.6, accuracy: 0.1)
        XCTAssertEqual(Gauge.networkFraction(10_000_000_000), 1)
    }

    func testGaugesColourOnlyWhenCareful() {
        var sample = Sample()
        sample.cpu = 0.42
        XCTAssertEqual(Gauge.make(.cpu, sample: sample, namesBusiestApp: true).value, "42")
        XCTAssertEqual(Gauge.make(.cpu, sample: sample, namesBusiestApp: true).level, .normal)
        sample.cpu = 0.95
        XCTAssertEqual(Gauge.make(.cpu, sample: sample, namesBusiestApp: true).level, .critical)

        sample.memoryUsed = 8 << 30
        sample.memoryPressure = .warning
        XCTAssertEqual(Gauge.make(.memory, sample: sample, namesBusiestApp: true).level, .caution)

        sample.battery = Battery(percent: 15, isCharging: false, onPower: false, minutesLeft: 75)
        let battery = Gauge.make(.battery, sample: sample, namesBusiestApp: true)
        XCTAssertEqual(battery.level, .caution)
        XCTAssertEqual(battery.detail, "1:15 left")
        sample.battery?.onPower = true
        XCTAssertEqual(Gauge.make(.battery, sample: sample, namesBusiestApp: true).level, .normal)
    }

    func testBusiestAppIsNamedOnlyWhenAsked() {
        var sample = Sample()
        sample.cpu = 0.3
        sample.busiest = BusiestApp(name: "Safari", bundlePath: nil, share: 0.12)
        XCTAssertEqual(Gauge.make(.cpu, sample: sample, namesBusiestApp: true).detail, "Safari 12%")
        XCTAssertNil(Gauge.make(.cpu, sample: sample, namesBusiestApp: false).detail)
    }

    func testHistoryKeepsItsLength() {
        var history = VitalsModel.emptyHistory
        for value in 0..<100 { history = VitalsModel.appending(Double(value), to: history) }
        XCTAssertEqual(history.count, VitalsModel.historyLength)
        XCTAssertEqual(history.last, 99)
    }

    func testSampleVectorInterpolates() {
        var difference = SampleVector([1, 1]) - SampleVector([0, 0.5])
        difference.scale(by: 0.5)
        XCTAssertEqual((SampleVector([0, 0.5]) + difference).values, [0.5, 0.75])
        XCTAssertEqual((SampleVector.zero + SampleVector([2])).values, [2])
    }

    /// Reads this Mac twice: everything asked for should come back sane.
    func testSamplerReadsThisMac() async throws {
        let sampler = SystemSampler()
        let request = SystemSampler.Request(metrics: Set(Metric.allCases), findsBusiestApp: true)
        _ = await sampler.sample(request)
        // The kernel's CPU counters tick at 100 Hz but can lag under load: give them a second.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let sample = await sampler.sample(request)

        let cpu = try XCTUnwrap(sample.cpu)
        XCTAssert((0...1).contains(cpu))
        let used = try XCTUnwrap(sample.memoryUsed)
        XCTAssert(used > 0 && used <= sample.memoryTotal)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(sample.download), 0)
        let free = try XCTUnwrap(sample.diskFree)
        XCTAssert(free > 0 && free <= (sample.diskTotal ?? 0))
        if let gpu = sample.gpu { XCTAssert((0...1).contains(gpu)) }
        if let busiest = sample.busiest { XCTAssertFalse(busiest.name.isEmpty) }
    }
}

final class AlertMonitorTests: XCTestCase {
    private func disk(freePercent: Int64) -> Sample {
        var sample = Sample()
        sample.diskTotal = 100_000_000_000
        sample.diskFree = freePercent * 1_000_000_000
        return sample
    }

    func testFiresOnceOnCrossingThenRearmsAfterRecovery() {
        var monitor = AlertMonitor()
        let settings = VitalsSettings()
        let start = Date()
        XCTAssertTrue(monitor.evaluate(disk(freePercent: 40), thermal: .nominal, settings: settings, now: start).isEmpty)
        let alert = monitor.evaluate(disk(freePercent: 8), thermal: .nominal, settings: settings, now: start).first
        XCTAssertEqual(alert?.title, "Disk")
        XCTAssertEqual(alert?.page, VitalsExtension.pageID)
        // Staying low doesn't repeat it, nor does wobbling just over the line.
        XCTAssertTrue(monitor.evaluate(disk(freePercent: 8), thermal: .nominal, settings: settings, now: start + 60).isEmpty)
        XCTAssertTrue(monitor.evaluate(disk(freePercent: 11), thermal: .nominal, settings: settings, now: start + 120).isEmpty)
        XCTAssertTrue(monitor.evaluate(disk(freePercent: 9), thermal: .nominal, settings: settings, now: start + 180).isEmpty)
        // Recovered, then low again: only after the quiet period.
        XCTAssertTrue(monitor.evaluate(disk(freePercent: 30), thermal: .nominal, settings: settings, now: start + 240).isEmpty)
        XCTAssertTrue(monitor.evaluate(disk(freePercent: 8), thermal: .nominal, settings: settings, now: start + 300).isEmpty)
        XCTAssertTrue(monitor.evaluate(disk(freePercent: 30), thermal: .nominal, settings: settings, now: start + 360).isEmpty)
        XCTAssertFalse(monitor.evaluate(disk(freePercent: 8), thermal: .nominal, settings: settings,
                                        now: start + AlertMonitor.quietPeriod + 1).isEmpty)
    }

    func testGettingWorseAlertsAgain() {
        var monitor = AlertMonitor()
        let settings = VitalsSettings()
        let start = Date()
        XCTAssertEqual(monitor.evaluate(disk(freePercent: 8), thermal: .nominal, settings: settings, now: start).first?.tint, "#FFBD4D")
        XCTAssertEqual(monitor.evaluate(disk(freePercent: 3), thermal: .nominal, settings: settings, now: start + 5).first?.tint, "#FF6359")
    }

    func testOffAlertsStayQuiet() {
        var monitor = AlertMonitor()
        var settings = VitalsSettings()
        settings.alerts = []
        XCTAssertTrue(monitor.evaluate(disk(freePercent: 1), thermal: .critical, settings: settings, now: Date()).isEmpty)
    }

    func testMemoryRespectsLevel() {
        var monitor = AlertMonitor()
        var settings = VitalsSettings()
        settings.memoryAlertsOnlyWhenCritical = true
        var sample = Sample()
        sample.memoryUsed = 1
        sample.memoryPressure = .warning
        XCTAssertTrue(monitor.evaluate(sample, thermal: .nominal, settings: settings, now: Date()).isEmpty)
        sample.memoryPressure = .critical
        XCTAssertEqual(monitor.evaluate(sample, thermal: .nominal, settings: settings, now: Date()).first?.value, "Critical")
    }

    func testBatteryOnlyOnBattery() {
        var monitor = AlertMonitor()
        let settings = VitalsSettings()
        var sample = Sample()
        sample.battery = Battery(percent: 15, isCharging: true, onPower: true, minutesLeft: nil)
        XCTAssertTrue(monitor.evaluate(sample, thermal: .nominal, settings: settings, now: Date()).isEmpty)
        sample.battery = Battery(percent: 15, isCharging: false, onPower: false, minutesLeft: 40)
        XCTAssertEqual(monitor.evaluate(sample, thermal: .nominal, settings: settings, now: Date()).first?.value, "15%")
    }

    func testCPUNeedsAMinuteAndNamesTheApp() {
        var monitor = AlertMonitor()
        var settings = VitalsSettings()
        settings.alerts = [.cpu]
        var sample = Sample()
        sample.cpu = 0.97
        sample.busiest = BusiestApp(name: "Xcode", bundlePath: nil, share: 0.8)
        let start = Date()
        XCTAssertTrue(monitor.evaluate(sample, thermal: .nominal, settings: settings, now: start).isEmpty)
        XCTAssertNotNil(monitor.cpuBusySince)
        XCTAssertTrue(monitor.evaluate(sample, thermal: .nominal, settings: settings, now: start + 30).isEmpty)
        let alert = monitor.evaluate(sample, thermal: .nominal, settings: settings, now: start + 61).first
        XCTAssertEqual(alert?.title, "Xcode")
        XCTAssertEqual(alert?.value, "97%")
    }

    func testSimultaneousAlertsAllComeMostSeriousFirst() {
        var monitor = AlertMonitor()
        var sample = disk(freePercent: 8)
        sample.memoryUsed = 1
        sample.memoryPressure = .critical
        let alerts = monitor.evaluate(sample, thermal: .nominal, settings: VitalsSettings(), now: Date())
        XCTAssertEqual(alerts.map(\.title), ["Memory", "Disk"])
    }

    func testAlertSettingsRoundTrip() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "vitals.tests.\(UUID())"))
        var settings = VitalsSettings()
        settings.alerts = [.cpu, .heat]
        settings.diskAlertPercent = 20
        settings.memoryAlertsOnlyWhenCritical = true
        settings.save(to: defaults)
        XCTAssertEqual(VitalsSettings.load(from: defaults), settings)
        XCTAssertTrue(settings.sampled.contains(.cpu))
    }
}

final class BreakdownTests: XCTestCase {
    private func app(_ name: String, cpu: Double?, memory: UInt64, processes: Int = 1) -> AppUsage {
        AppUsage(name: name, bundlePath: nil, cpu: cpu, memory: memory,
                 processes: (0..<processes).map { ProcessUsage(pid: pid_t($0 + 1), name: "\(name) Helper \($0)",
                                                               cpu: cpu.map { $0 / Double(processes) },
                                                               memory: memory / UInt64(processes)) })
    }

    func testRanksByMetricAndDropsIdleApps() {
        let apps = [app("A", cpu: 0.1, memory: 5), app("B", cpu: 0.3, memory: 1), app("C", cpu: 0, memory: 9),
                    app("D", cpu: 0.2, memory: 0), app("E", cpu: 0.05, memory: 2), app("F", cpu: 0.01, memory: 3),
                    app("G", cpu: 0.02, memory: 4)]
        XCTAssertEqual(VitalsModel.ranked(apps, by: .cpu).map(\.name), ["B", "D", "A", "E", "G"])
        XCTAssertEqual(VitalsModel.ranked(apps, by: .memory).map(\.name), ["C", "A", "G", "F", "E"])
    }

    func testOnlyAppsWithSeveralProcessesUnfold() {
        XCTAssertTrue(VitalsModel.rankedProcesses(app("Solo", cpu: 0.1, memory: 1), by: .cpu).isEmpty)
        let many = VitalsModel.rankedProcesses(app("Chrome", cpu: 0.4, memory: 10, processes: 8), by: .memory)
        XCTAssertEqual(many.count, VitalsModel.processLimit)
    }

    func testFormatting() {
        XCTAssertEqual(BreakdownFormat.value(0.123, metric: .cpu, known: true), "12%")
        XCTAssertEqual(BreakdownFormat.value(0.001, metric: .cpu, known: true), "<1%")
        XCTAssertEqual(BreakdownFormat.value(0.5, metric: .cpu, known: false), "–")
        XCTAssertTrue(BreakdownFormat.value(1.5 * 1024 * 1024 * 1024, metric: .memory, known: true).hasSuffix("GB"))
        XCTAssertEqual(BreakdownFormat.processName("Google Chrome Helper (Renderer)", in: "Google Chrome"), "Helper (Renderer)")
        XCTAssertEqual(BreakdownFormat.processName("Google Chrome", in: "Google Chrome"), "Google Chrome")
        XCTAssertEqual(BreakdownFormat.processName("mds", in: "Spotlight"), "mds")
    }

    func testToolsAreNamedAfterTheirFolderWhenVersioned() {
        XCTAssertEqual(SystemSampler.toolName(path: "/Users/me/.local/share/claude/versions/2.1.299"), "claude")
        XCTAssertEqual(SystemSampler.toolName(path: "/opt/homebrew/bin/node"), "node")
        XCTAssertEqual(SystemSampler.toolName(path: "/usr/libexec/trustd"), "trustd")
    }

    func testMemoryRollsOverAtAThousand() {
        XCTAssertEqual(VitalsFormat.bytes(1020 * 1024 * 1024, base: 1024).unit, "GB")
    }

    func testHeightStaysInsideTheNotch() {
        XCTAssertLessThanOrEqual(Breakdown.height(apps: VitalsModel.breakdownLimit, processes: VitalsModel.processLimit) + 4,
                                 VitalsPage.maxHeight)
    }

    /// Scans this Mac twice: apps come back with memory, then with CPU.
    func testScansThisMacsApps() async throws {
        let sampler = SystemSampler()
        let request = SystemSampler.Request(metrics: [.cpu], findsBusiestApp: false, breaksDown: true)
        let firstSample = await sampler.sample(request)
        let first = try XCTUnwrap(firstSample.apps)
        XCTAssertFalse(first.isEmpty)
        XCTAssertTrue(first.allSatisfy { $0.cpu == nil })
        XCTAssertTrue(first.contains { $0.memory > 0 })
        try await Task.sleep(nanoseconds: 300_000_000)
        let secondSample = await sampler.sample(request)
        let second = try XCTUnwrap(secondSample.apps)
        XCTAssertTrue(second.allSatisfy { $0.cpu != nil })
        let total = second.compactMap(\.cpu).reduce(0, +)
        XCTAssert((0...1.05).contains(total), "Apps add up to \(total) of all cores")
        // This test runner lives in Xcode or the toolchain; either way it's listed with its own process.
        XCTAssertTrue(second.contains { $0.processes.contains { $0.pid == getpid() } })
    }
}
