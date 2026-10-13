import AppKit
import Foundation
import os

enum RefreshTrigger: Equatable, Sendable {
    case activation
    case timer
    case manual
    case pageOpened
    case wake
    case settingsChanged
    /// The user clicked Allow Access: the one trigger that may show a Keychain prompt.
    case keychainGrant

    var isInteractive: Bool { self == .keychainGrant }
    /// Automatic triggers wait for the interval and back off after failures; the rest run now.
    var isAutomatic: Bool { self == .timer || self == .pageOpened || self == .wake }
}

/// Schedules provider fetches: one at a time per provider, on a bounded timer, with backoff after
/// failures and Retry-After honoured even for manual refreshes.
@MainActor
final class UsageCoordinator {
    private let store: AIUsageStore
    private let providers: [AIProviderID: UsageProvider]
    private let log: Logger?
    private let now: () -> Date
    private let tick: TimeInterval
    private let isLowPower: () -> Bool

    private var inFlight: [AIProviderID: (task: Task<Void, Never>, interactive: Bool)] = [:]
    private var blockedUntil: [AIProviderID: Date] = [:]
    private var failures: [AIProviderID: Int] = [:]
    private var loop: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    init(store: AIUsageStore, providers: [UsageProvider], log: Logger? = nil, now: @escaping () -> Date = Date.init,
         tick: TimeInterval = 60, isLowPower: @escaping () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }) {
        self.store = store
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        self.log = log
        self.now = now
        self.tick = tick
        self.isLowPower = isLowPower
    }

    var isRunning: Bool { loop != nil }

    func start() {
        guard loop == nil else { return }
        refresh(trigger: .activation)
        let tick = tick
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.refresh(trigger: .timer)
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.refresh(trigger: .wake) }
        }
    }

    /// Cancels the timer and every fetch in flight. Results of cancelled fetches are dropped.
    func stop() {
        loop?.cancel()
        loop = nil
        for entry in inFlight.values { entry.task.cancel() }
        inFlight.removeAll()
        for id in AIProviderID.allCases { store.endRefresh(id) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    /// Drops a provider's fetch in flight, for a provider that was just switched off.
    func cancel(_ id: AIProviderID) {
        inFlight.removeValue(forKey: id)?.task.cancel()
        store.endRefresh(id)
    }

    /// The refresh interval, doubled in Low Power Mode when the user allows it.
    var interval: TimeInterval {
        let base = TimeInterval(store.settings.refreshMinutes * 60)
        return store.settings.slowerOnLowPower && isLowPower() ? base * 2 : base
    }

    @discardableResult
    func refresh(_ ids: [AIProviderID]? = nil, trigger: RefreshTrigger) -> [Task<Void, Never>] {
        (ids ?? AIProviderID.allCases).compactMap { refresh($0, trigger: trigger) }
    }

    /// Waits for every fetch in flight, for tests and for callers that need the result.
    func waitUntilIdle() async {
        while let task = inFlight.values.first?.task {
            await task.value
        }
    }

    private func refresh(_ id: AIProviderID, trigger: RefreshTrigger) -> Task<Void, Never>? {
        guard let provider = providers[id], store.settings.isEnabled(id) else { return nil }
        let date = now()

        if let running = inFlight[id] {
            // Quick repeat presses share the fetch already running, unless this one may prompt and that one can't.
            guard trigger.isInteractive, !running.interactive else { return running.task }
            running.task.cancel()
        }
        if let until = blockedUntil[id], date < until { return nil }
        if trigger.isAutomatic, !isDue(id, trigger: trigger, at: date) { return nil }

        let context = FetchContext(isInteractive: trigger.isInteractive, includeExtras: store.settings.showsExtras, now: date)
        store.beginRefresh(id, at: date)
        let task = Task { [weak self] in
            let result: Result<ProviderUsageSnapshot, ProviderFailure>
            do {
                result = .success(try await provider.fetch(context))
            } catch {
                result = .failure(ProviderFailure.from(error, provider: id))
            }
            guard !Task.isCancelled else { return }
            self?.finish(id, result)
        }
        inFlight[id] = (task, trigger.isInteractive)
        return task
    }

    private func finish(_ id: AIProviderID, _ result: Result<ProviderUsageSnapshot, ProviderFailure>) {
        inFlight[id] = nil
        // A provider switched off mid-fetch keeps nothing.
        guard store.settings.isEnabled(id) else {
            store.clear(id)
            return
        }
        switch result {
        case let .success(snapshot):
            failures[id] = nil
            blockedUntil[id] = nil
            store.apply(snapshot)
            log?.debug("AI Usage: \(id.rawValue, privacy: .public) refreshed")
        case let .failure(failure):
            if case let .rateLimited(retryAfter) = failure.kind {
                // Without Retry-After, wait a full interval.
                blockedUntil[id] = max(retryAfter ?? .distantPast, now().addingTimeInterval(interval))
            }
            if failure.kind != .notConnected { failures[id, default: 0] += 1 }
            store.apply(failure, for: id)
            log?.info("AI Usage: \(id.rawValue, privacy: .public) refresh failed: \(String(describing: failure.kind), privacy: .public)")
        }
    }

    private func isDue(_ id: AIProviderID, trigger: RefreshTrigger, at date: Date) -> Bool {
        let state = store.state(for: id)
        // Back off after consecutive failures: 1×, 2×, 4× the interval, up to 30 minutes.
        let failureCount = failures[id] ?? 0
        let backoff = failureCount == 0 ? 0 : min(interval * pow(2, Double(failureCount - 1)), max(interval, 30 * 60))
        if let lastAttempt = state.lastAttempt, date.timeIntervalSince(lastAttempt) < backoff { return false }
        switch trigger {
        case .timer:
            guard let lastAttempt = state.lastAttempt else { return true }
            return date.timeIntervalSince(lastAttempt) >= interval - 1
        default:
            // Opening the page or waking only refreshes a reading that's out of date, and not twice in 30 s.
            if let lastAttempt = state.lastAttempt, date.timeIntervalSince(lastAttempt) < 30 { return false }
            guard let refreshedAt = state.snapshot?.refreshedAt, state.status == .fresh else { return true }
            return date.timeIntervalSince(refreshedAt) >= interval
        }
    }
}
