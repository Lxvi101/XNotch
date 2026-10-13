import AppKit
import Foundation
import Security
import os

/// Settings, uploads and the links made so far.
@MainActor
final class CloudLinks: ObservableObject {
    struct SharedLink: Codable, Identifiable, Hashable {
        let id: String
        let url: URL
        let title: String
        let fileCount: Int
        let createdAt: Date
        let expiresAt: Date

        var isExpired: Bool { expiresAt <= Date() }
    }

    enum Transfer: Equatable {
        case idle
        case uploading(Double)
        case copied
        case failed(String)
    }

    enum Check: Equatable {
        case none, checking, ok(String), failed(String)
    }

    static let expiryChoices: [(title: String, seconds: TimeInterval)] = [
        ("1 Hour", 3600), ("1 Day", 86_400), ("7 Days", 7 * 86_400), ("30 Days", 30 * 86_400)
    ]

    @Published var server: String {
        didSet { defaults.set(server, forKey: Keys.server); check = .none }
    }
    @Published var token: String {
        didSet { Keychain.write(token); check = .none }
    }
    @Published var defaultExpiry: TimeInterval {
        didSet { defaults.set(defaultExpiry, forKey: Keys.expiry) }
    }
    @Published private(set) var links: [SharedLink] = []
    @Published private(set) var transfer: Transfer = .idle
    @Published private(set) var check: Check = .none

    var onCopied: (() -> Void)?

    private let defaults: UserDefaults
    private let log: Logger
    private var transferReset: DispatchWorkItem?
    private var generation = 0

    private enum Keys {
        static let server = "server", expiry = "defaultExpiry", links = "links"
    }

    init(defaults: UserDefaults, log: Logger) {
        self.defaults = defaults
        self.log = log
        server = defaults.string(forKey: Keys.server) ?? ""
        token = Keychain.read() ?? ""
        let expiry = defaults.double(forKey: Keys.expiry)
        defaultExpiry = expiry > 0 ? expiry : 86_400
        if let data = defaults.data(forKey: Keys.links),
           let saved = try? JSONDecoder().decode([SharedLink].self, from: data) {
            links = saved.filter { !$0.isExpired }
        }
    }

    var client: CloudClient? { CloudClient(server: server, token: token) }
    var isConfigured: Bool { client != nil }
    var isUploading: Bool {
        if case .uploading = transfer { return true }
        return false
    }

    static func title(for seconds: TimeInterval) -> String {
        expiryChoices.first { $0.seconds == seconds }?.title ?? "\(Int(seconds / 3600)) Hours"
    }

    // MARK: Sharing

    /// Uploads the files into one drop and copies its link.
    func share(_ urls: [URL], expiresIn: TimeInterval) {
        guard !urls.isEmpty, !isUploading else { return }
        guard let client else { return setTransfer(.failed(CloudClient.Failure.notConfigured.localizedDescription)) }
        generation += 1
        let current = generation
        setTransfer(.uploading(0))
        Task {
            do {
                let sizes = urls.map(Self.size(of:))
                let total = max(1, sizes.reduce(0, +))
                let title = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
                let drop = try await client.createDrop(expiresIn: expiresIn, title: title)
                var done: Int64 = 0
                for (url, size) in zip(urls, sizes) {
                    let prepared = try await PreparedFile.make(for: url)
                    defer { prepared.cleanUp() }
                    let base = done
                    try await client.upload(prepared.url, name: prepared.name, to: drop.id) { fraction in
                        Task { @MainActor in
                            guard self.generation == current, self.isUploading else { return }
                            self.transfer = .uploading(Double(base + Int64(Double(size) * fraction)) / Double(total))
                        }
                    }
                    done += size
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(drop.url.absoluteString, forType: .string)
                remember(SharedLink(id: drop.id, url: drop.url, title: title, fileCount: urls.count,
                                    createdAt: Date(), expiresAt: drop.expiresAt))
                setTransfer(.copied)
                onCopied?()
            } catch {
                log.error("Upload failed: \(error.localizedDescription, privacy: .public)")
                setTransfer(.failed(error.localizedDescription))
            }
        }
    }

    func copy(_ link: SharedLink) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
    }

    /// Deletes the drop on the server, so the link stops working now.
    func revoke(_ link: SharedLink) {
        links.removeAll { $0.id == link.id }
        save()
        guard let client else { return }
        Task {
            do {
                try await client.delete(drop: link.id)
            } catch {
                log.error("Couldn't delete \(link.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func testConnection() {
        guard let client else {
            check = .failed("Enter an http or https URL and an access token.")
            return
        }
        check = .checking
        Task {
            do {
                let info = try await client.info()
                check = .ok("Connected to \(info.name) \(info.version)")
            } catch {
                check = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Internals

    private func remember(_ link: SharedLink) {
        links = ([link] + links.filter { !$0.isExpired }).prefix(30).map { $0 }
        save()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(links), forKey: Keys.links)
    }

    private func setTransfer(_ value: Transfer) {
        transferReset?.cancel()
        transfer = value
        if case .uploading = value { return }
        let work = DispatchWorkItem { [weak self] in self?.transfer = .idle }
        transferReset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (value == .copied ? 2.5 : 4), execute: work)
    }

    private static func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true { return 1 }
        return Int64(values?.fileSize ?? 1)
    }
}

/// The access token, in the login Keychain.
private enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.levi.XNotch.cloud",
        kSecAttrAccount as String: "api-token"
    ]

    static func read() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ token: String) {
        SecItemDelete(query as CFDictionary)
        guard !token.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrLabel as String] = "XNotch Cloud Links token"
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// A file ready to upload: folders are zipped first.
struct PreparedFile {
    let url: URL
    let name: String
    private let temporary: URL?

    static func make(for url: URL) async throws -> PreparedFile {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard isDirectory.boolValue else { return PreparedFile(url: url, name: url.lastPathComponent, temporary: nil) }
        let zip = try await Task.detached { try zipped(url) }.value
        return PreparedFile(url: zip, name: url.lastPathComponent + ".zip", temporary: zip.deletingLastPathComponent())
    }

    /// The coordinator's `.forUploading` read hands back a zip of a folder.
    private static func zipped(_ folder: URL) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var coordinationError: NSError?
        var result: Result<URL, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) { zip in
            let target = directory.appendingPathComponent(folder.lastPathComponent + ".zip")
            result = Result { try FileManager.default.copyItem(at: zip, to: target); return target }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    func cleanUp() {
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
    }
}
