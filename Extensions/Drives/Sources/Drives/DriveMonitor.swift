import AppKit

struct DrivesSettings: Equatable {
    var alertsOnConnect = true
    var alertsOnEject = true
    var includesDiskImages = false

    private enum Key {
        static let connect = "alertsOnConnect"
        static let eject = "alertsOnEject"
        static let diskImages = "includesDiskImages"
    }

    static func load(from defaults: UserDefaults) -> DrivesSettings {
        var settings = DrivesSettings()
        if defaults.object(forKey: Key.connect) != nil { settings.alertsOnConnect = defaults.bool(forKey: Key.connect) }
        if defaults.object(forKey: Key.eject) != nil { settings.alertsOnEject = defaults.bool(forKey: Key.eject) }
        settings.includesDiskImages = defaults.bool(forKey: Key.diskImages)
        return settings
    }

    func save(to defaults: UserDefaults) {
        defaults.set(alertsOnConnect, forKey: Key.connect)
        defaults.set(alertsOnEject, forKey: Key.eject)
        defaults.set(includesDiskImages, forKey: Key.diskImages)
    }
}

/// The drives that are mounted, kept current from NSWorkspace's mount and
/// unmount notifications; nothing polls. Volumes are inspected off the main
/// thread, since a failing disk can take its time to answer.
@MainActor
final class DriveMonitor: ObservableObject {
    @Published private(set) var drives: [Drive] = []
    /// Drives with an eject under way.
    @Published private(set) var ejecting: Set<String> = []
    /// Why an eject failed, shown on the drive for a few seconds.
    @Published private(set) var failures: [String: String] = [:]
    @Published var settings = DrivesSettings() {
        didSet {
            guard settings != oldValue else { return }
            defaults.map(settings.save)
            if settings.includesDiskImages != oldValue.includesDiskImages, isRunning { reload() }
        }
    }

    var onConnect: ((Drive) -> Void)?
    var onEjected: ((Drive) -> Void)?
    /// Drives came or went.
    var onChange: (() -> Void)?

    private var defaults: UserDefaults?
    private var observers: [NSObjectProtocol] = []
    /// Mounts until then are drives that were already there (at launch, after
    /// waking), not ones just plugged in.
    private var quietUntil = Date.distantPast
    /// Bumped by every reload, so an older one finishing late is dropped.
    private var generation = 0
    private let queue = DispatchQueue(label: "dev.levi.XNotch.drives", qos: .userInitiated)

    var isRunning: Bool { !observers.isEmpty }

    func load(defaults: UserDefaults) {
        self.defaults = defaults
        settings = DrivesSettings.load(from: defaults)
    }

    func start() {
        guard !isRunning else { return }
        let center = NSWorkspace.shared.notificationCenter
        func observe(_ name: Notification.Name, _ handler: @escaping @MainActor (Notification) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { handler(note) }
            })
        }
        observe(NSWorkspace.didMountNotification) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            self?.mounted(url)
        }
        observe(NSWorkspace.didUnmountNotification) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            self?.unmounted(url)
        }
        observe(NSWorkspace.didRenameVolumeNotification) { [weak self] _ in self?.reload() }
        observe(NSWorkspace.didWakeNotification) { [weak self] _ in
            self?.quietUntil = Date().addingTimeInterval(10)
            self?.reload()
        }
        quietUntil = Date().addingTimeInterval(3)
        reload()
    }

    func stop() {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        generation += 1
        drives = []
        ejecting = []
        failures = [:]
    }

    /// Reads every mounted volume again, for fresh free space or changed settings.
    func reload() {
        generation += 1
        let generation = generation
        let includeDiskImages = settings.includesDiskImages
        queue.async { [weak self] in
            let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                             options: [.skipHiddenVolumes]) ?? []
            let found = urls.compactMap { DriveClassifier.drive(at: $0, includeDiskImages: includeDiskImages) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isRunning, self.generation == generation else { return }
                    // Keep the order drives arrived in; new ones go last.
                    let known = self.drives.compactMap { drive in found.first { $0.id == drive.id } }
                    self.setDrives(known + found.filter { drive in !known.contains { $0.id == drive.id } })
                }
            }
        }
    }

    func eject(_ drive: Drive) {
        guard !ejecting.contains(drive.id) else { return }
        ejecting.insert(drive.id)
        failures[drive.id] = nil
        // Also ejects the drive's other volumes, and the disk itself, as Finder does.
        FileManager.default.unmountVolume(at: drive.url, options: [.allPartitionsAndEjectDisk, .withoutUI]) { error in
            let failure = error.map { $0 as NSError }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in self?.ejectFinished(drive, error: failure) }
            }
        }
    }

    // MARK: Events

    private func mounted(_ url: URL) {
        let includeDiskImages = settings.includesDiskImages
        let announce = Date() >= quietUntil
        queue.async { [weak self] in
            guard let drive = DriveClassifier.drive(at: url, includeDiskImages: includeDiskImages) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isRunning, !self.drives.contains(where: { $0.id == drive.id }) else { return }
                    self.setDrives(self.drives + [drive])
                    if announce { self.onConnect?(drive) }
                }
            }
        }
    }

    private func unmounted(_ url: URL) {
        guard let drive = drives.first(where: { $0.id == url.path }) else { return }
        let wasEjecting = ejecting.remove(drive.id) != nil
        failures[drive.id] = nil
        setDrives(drives.filter { $0.id != drive.id })
        if wasEjecting { onEjected?(drive) }
    }

    private func ejectFinished(_ drive: Drive, error: NSError?) {
        guard let error else {
            // The unmount notification has usually reported it already.
            if drives.contains(where: { $0.id == drive.id }) { unmounted(drive.url) }
            return
        }
        ejecting.remove(drive.id)
        guard drives.contains(where: { $0.id == drive.id }) else { return }
        guard error.domain == NSCocoaErrorDomain, error.code == NSFileManagerUnmountBusyError else {
            showFailure("Couldn't eject", for: drive)
            return
        }
        // Name what's holding it, which is what the user needs to quit.
        let pid = (error.userInfo[NSFileManagerUnmountDissentingProcessIdentifierErrorKey] as? NSNumber)?.int32Value
        showFailure(pid.flatMap(Self.processName).map { "In use by \($0)" } ?? "In use", for: drive)
    }

    private func showFailure(_ message: String, for drive: Drive) {
        failures[drive.id] = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.failures[drive.id] == message else { return }
                self.failures[drive.id] = nil
            }
        }
    }

    private func setDrives(_ new: [Drive]) {
        guard new != drives else { return }
        drives = new
        onChange?()
    }

    /// "Preview" for an app, the executable's name for anything else.
    private static func processName(_ pid: pid_t) -> String? {
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }
}
