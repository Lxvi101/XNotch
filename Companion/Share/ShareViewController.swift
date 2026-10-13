import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XNotchLink

/// Share → XNotch: sends what was shared to the chosen Mac and closes.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let host = UIHostingController(rootView: ShareView(model: model))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        model.onFinish = { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        model.start(providers)
    }
}

@MainActor
final class ShareModel: ObservableObject {
    enum Phase: Equatable {
        case preparing
        case connecting
        case sending(Double)
        case sent
        case failed(String)
        case unpaired
    }

    @Published private(set) var phase: Phase = .preparing
    @Published private(set) var summary = ""
    @Published private(set) var route: String?
    let macName: String?
    var onFinish: (() -> Void)?

    private let pairing: LinkPairing?
    private var providers: [NSItemProvider] = []
    private var task: Task<Void, Never>?
    #if targetEnvironment(simulator)
    private static let routes: Set<LinkRoute> = [.local, .internet]
    #else
    private static let routes: Set<LinkRoute> = [.usb, .local, .internet]
    #endif
    private static let staging = FileManager.default.temporaryDirectory.appendingPathComponent("Share", isDirectory: true)

    init() {
        pairing = PairingKeychain.load().selected
        macName = pairing?.name
    }

    func start(_ providers: [NSItemProvider]) {
        self.providers = providers
        guard pairing != nil else { phase = .unpaired; return }
        run()
    }

    func retry() { run() }

    func cancel() {
        task?.cancel()
        cleanUp()
        onFinish?()
    }

    private func run() {
        guard let pairing else { return }
        task?.cancel()
        phase = .preparing
        task = Task {
            do {
                let shared = try await SharedContent.load(providers, into: Self.staging)
                summary = shared.summary
                phase = .connecting
                // Bluetooth is left to the app: it's slow, and extensions are short-lived.
                let session = try await LinkClient.connectBest(to: pairing, as: ThisDevice.link,
                                                               incomingDirectory: ThisDevice.incomingDirectory,
                                                               routes: Self.routes)
                route = session.routeTitle
                Task { await session.run { _ in } }
                let total = Double(max(1, shared.files.count + (shared.text == nil ? 0 : 1)))
                phase = .sending(0)
                for (index, file) in shared.files.enumerated() {
                    try await session.sendFile(file) { fraction in
                        Task { @MainActor in
                            if case .sending = self.phase { self.phase = .sending((Double(index) + fraction) / total) }
                        }
                    }
                }
                if let text = shared.text { try await session.sendText(text) }
                await session.close()
                cleanUp()
                phase = .sent
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                try? await Task.sleep(nanoseconds: 900_000_000)
                onFinish?()
            } catch is CancellationError {
            } catch {
                phase = .failed(error.localizedDescription)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: Self.staging)
    }
}

/// Files to send and, for links and plain text, one text for the clipboard.
struct SharedContent {
    var files: [URL] = []
    var text: String?

    var summary: String {
        var parts: [String] = []
        if files.count == 1 { parts.append(files[0].lastPathComponent) }
        if files.count > 1 { parts.append("\(files.count) files") }
        if text != nil { parts.append(files.isEmpty ? "Text for the clipboard" : "text") }
        return parts.joined(separator: " and ")
    }

    /// Real content beats its description: a shared PDF is the file, not
    /// its web address. Links and plain text go to the clipboard.
    static func load(_ providers: [NSItemProvider], into directory: URL) async throws -> SharedContent {
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var content = SharedContent()
        var links: [String] = []
        var texts: [String] = []
        for provider in providers {
            if let file = try await loadFile(provider, into: directory) {
                content.files.append(file)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                      let url = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                links.append(url.absoluteString)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let text = try await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                texts.append(text)
            }
        }
        // A page shared from Safari brings its title as text too: the link alone is what's wanted.
        let text = (links.isEmpty ? texts : links).joined(separator: "\n")
        content.text = text.isEmpty ? nil : text
        if content.files.isEmpty && content.text == nil {
            throw LinkError.rejected("There's nothing here XNotch can send.")
        }
        return content
    }

    private static func loadFile(_ provider: NSItemProvider, into directory: URL) async throws -> URL? {
        let types = provider.registeredContentTypes
        let isFileURL = types.contains { $0.conforms(to: .fileURL) }
        let fileType = types.first { type in
            !type.conforms(to: .url) && !type.conforms(to: .plainText) && (type.conforms(to: .data) || type.conforms(to: .folder))
        }
        guard let type = isFileURL ? (fileType ?? .item) : fileType else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                guard let url else {
                    continuation.resume(throwing: error ?? LinkError.rejected("A shared item couldn't be read."))
                    return
                }
                // Copy now: the system deletes `url` when this returns.
                let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    var name = provider.suggestedName ?? url.deletingPathExtension().lastPathComponent
                    if (name as NSString).pathExtension.isEmpty, let ext = type.preferredFilenameExtension ?? url.pathExtension.nonEmpty {
                        name += "." + ext
                    }
                    let target = folder.appendingPathComponent(linkSafeFileName(name))
                    try FileManager.default.copyItem(at: url, to: target)
                    continuation.resume(returning: target)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

struct ShareView: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.35).ignoresSafeArea()
                .onTapGesture { if !isBusy { model.cancel() } }
            card
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
                .frame(maxWidth: 520)
                .transition(.move(edge: .bottom))
        }
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: model.phase)
    }

    private var isBusy: Bool {
        if case .sending = model.phase { return true }
        return false
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Palette.raised))
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.macName ?? "No Mac paired")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    status
                }
                Spacer()
                if !isBusy && model.phase != .sent {
                    Button { model.cancel() } label: { CircleButtonLabel(symbol: "xmark", size: 38) }
                }
            }
            if !model.summary.isEmpty {
                Text(model.summary)
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            progress
            switch model.phase {
            case .failed:
                Button("Try Again") { model.retry() }.buttonStyle(PillButtonStyle(prominent: true))
            case .unpaired:
                Text("Open XNotch on this device and scan the code your Mac shows in XNotch Settings → Extensions → iPhone & iPad.")
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.secondary)
            default:
                EmptyView()
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 34, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .preparing: StatusCaps(text: "Preparing", color: Palette.secondary)
        case .connecting: StatusCaps(text: "Connecting", color: Palette.secondary)
        case .sending: StatusCaps(text: model.route.map { "Sending · \($0)" } ?? "Sending", color: Palette.cyan)
        case .sent: StatusCaps(text: "On your Mac", color: Palette.green)
        case .failed(let reason):
            Text(reason).font(.system(size: 13, weight: .medium)).foregroundStyle(.orange).lineLimit(3)
        case .unpaired: StatusCaps(text: "Not paired", color: .orange)
        }
    }

    @ViewBuilder
    private var progress: some View {
        switch model.phase {
        case .preparing, .connecting:
            ProgressBar(fraction: nil)
        case .sending(let fraction):
            ProgressBar(fraction: fraction)
        case .sent:
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(Palette.green)
                Text("Sent to the shelf").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            }
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        default:
            EmptyView()
        }
    }
}

/// A slim bar, like the volume bar in the reference design; nil sweeps.
private struct ProgressBar: View {
    let fraction: Double?
    @State private var sweep = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.raised)
                if let fraction {
                    Capsule()
                        .fill(LinearGradient(colors: [Palette.blue, Palette.cyan, Palette.green], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(12, proxy.size.width * fraction))
                        .animation(.linear(duration: 0.15), value: fraction)
                } else {
                    Capsule()
                        .fill(LinearGradient(colors: [Palette.blue.opacity(0), Palette.cyan, Palette.blue.opacity(0)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: proxy.size.width * 0.35)
                        .offset(x: sweep ? proxy.size.width * 0.65 : 0)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { sweep = true }
                        }
                }
            }
        }
        .frame(height: 10)
    }
}
