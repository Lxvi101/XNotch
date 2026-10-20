import AppKit
import Combine
import SwiftUI
import XNotchKit

@objc(ConverterPrincipal)
public final class ConverterPrincipal: NSObject, XNotchExtensionPrincipal {
    public override init() { super.init() }

    @MainActor public func makeExtension() -> AnyObject { ConverterExtension() }
}

/// Hold a key while dragging files (and pause or shake, as set) and a wheel
/// of formats and tools opens under the pointer; drop on one and the
/// converted file lands next to the original. Shelves open the same wheel
/// for all their files at once. Images, PDFs and documents use macOS itself;
/// video and audio use ffmpeg, found on the Mac or installed with a click.
@MainActor
final class ConverterExtension: XNotchExtension {
    static let id: ExtensionID = "converter"

    private var host: ExtensionHost?
    private var preferences: ConverterPreferences?
    private var ffmpeg: FFmpeg?
    private var runner: ConversionRunner?
    private var watcher: DragWatcher?
    /// The wheel the current drag opened, until it's dropped on or let go.
    private weak var openWheel: WheelController?
    /// Every wheel and pill on screen.
    private var wheels: [WheelController] = []
    private var observers: Set<AnyCancellable> = []

    func activate(host: ExtensionHost) throws {
        self.host = host
        let preferences = ConverterPreferences(defaults: host.storage.defaults)
        let ffmpeg = FFmpeg(directory: host.storage.directory, customPath: preferences.ffmpegPath)
        ffmpeg.refresh()
        let runner = ConversionRunner(ffmpeg: ffmpeg, preferences: preferences)
        runner.onFinish = { [weak self] job in self?.finished(job) }

        let watcher = DragWatcher(preferences: preferences)
        watcher.onTrigger = { [weak self] point, files in self?.showWheel(at: point, for: files) }
        watcher.onTriggeringDragEnded = { [weak self] in
            self?.openWheel?.triggeringDragEnded()
            self?.openWheel = nil
        }
        watcher.start()

        preferences.$ffmpegPath.dropFirst().sink { [weak ffmpeg] path in ffmpeg?.customPath = path }.store(in: &observers)
        // A drag with the wheel's key held is the wheel's: Shelves leaves its shakes alone.
        preferences.$modifier.sink { modifier in
            DragModifierClaims.set(modifier.flags, for: Self.id)
        }.store(in: &observers)

        self.preferences = preferences
        self.ffmpeg = ffmpeg
        self.runner = runner
        self.watcher = watcher
    }

    func deactivate() {
        DragModifierClaims.set(nil, for: Self.id)
        watcher?.stop()
        wheels.forEach { $0.tearDown() }
        wheels.removeAll()
        observers.removeAll()
        watcher = nil
        runner = nil
        ffmpeg = nil
        preferences = nil
        host = nil
    }

    /// What the wheel can do with these files here. The ffmpeg on the Mac may
    /// lack an encoder (Homebrew's has no WebP), so what it can't make is left
    /// out. Without one, everything's offered: a drop installs the static
    /// build, which has them all.
    private func available(_ files: WheelFiles) -> WheelFiles? {
        var files = files
        if let encoders = ffmpeg?.location?.encoders {
            let kind = files.kind
            func works(_ action: Action) -> Bool {
                !Catalog.needsFFmpeg(action, kind: kind) || MediaRecipe.isSupported(action, kind: kind, encoders: encoders)
            }
            files.offer.formats.removeAll { !works(.convert($0)) }
            files.offer.tools.removeAll { !works(.tool($0)) }
        }
        return files.offer.isEmpty ? nil : files
    }

    private func showWheel(at point: CGPoint, for files: WheelFiles, mode: WheelMode = .drag) {
        guard let runner, let ffmpeg, let files = available(files) else { return }
        openWheel?.dismiss()
        // Until a search says otherwise, ffmpeg is assumed to be there.
        let missing = ffmpeg.hasSearched && ffmpeg.location == nil
        let actions = files.offer.formats.map(Action.convert) + files.offer.tools.map(Action.tool)
        let needsFFmpeg = missing ? Set(actions.filter { Catalog.needsFFmpeg($0, kind: files.kind) }) : []
        let wheel = WheelController(files: files, at: point, needsFFmpeg: needsFFmpeg, mode: mode)
        wheel.tick = { [weak host] in host?.feedback.tick() }
        wheel.start = { job in runner.start(job) }
        wheel.onClose = { [weak self] wheel in self?.wheels.removeAll { $0 === wheel } }
        wheels.append(wheel)
        openWheel = wheel
        wheel.show()
        host?.feedback.tick()
    }

    private func finished(_ job: ConversionJob) {
        wheels.first { $0.model.job === job }?.jobFinished()
        // A long job finishes while you're elsewhere: the notch says so. A
        // shelf's job shows itself, its files landing on the shelf.
        guard job.phase == .done, job.deliver == nil, Date().timeIntervalSince(job.started) > 6 else { return }
        host?.notch.showAlert(NotchAlert(symbol: "checkmark.circle.fill", tint: "#5CE68F",
                                         title: job.operation.title, value: job.note == nil ? "Saved" : "Copied"))
    }
}

// MARK: Shelves

extension ConverterExtension: ShelfFileActing {
    /// "Convert 12 Images…" on a shelf whose files are all one kind. The wheel
    /// opens at the pointer, to be clicked, and what it makes joins the shelf.
    func shelfActions(for request: ShelfFileRequest) -> [NotchMenuItem] {
        guard let kind = FileKind.shared(by: request.files),
              available(WheelFiles(request.files, kind: kind)) != nil else { return [] }
        let count = request.files.count
        let title = count == 1 ? "Convert \(kind.noun(1))…" : "Convert \(count) \(kind.noun(count))…"
        return [.action(title, symbol: "arrow.triangle.2.circlepath") { [weak self] in
            self?.openFromShelf(request.files, kind: kind, deliver: request.deliver)
        }]
    }

    private func openFromShelf(_ urls: [URL], kind: FileKind, deliver: @escaping @MainActor ([URL]) -> Void) {
        showWheel(at: NSEvent.mouseLocation, for: WheelFiles(urls, kind: kind), mode: .click(deliver: deliver))
    }
}

extension ConverterExtension: ShelfAccessoryProviding {
    /// A button in the notch shelf's header while its files are all one kind.
    func makeShelfAccessory(context: ShelfContext) -> AnyView? {
        let files = context.targets
        guard let kind = FileKind.shared(by: files), available(WheelFiles(files, kind: kind)) != nil else { return nil }
        return AnyView(ShelfHeaderButton(symbol: "arrow.triangle.2.circlepath") { [weak self] in
            // The selection as it is now, not when the header was drawn.
            let targets = context.targets
            guard let self, let kind = FileKind.shared(by: targets) else { return }
            openFromShelf(targets, kind: kind) { [weak host] urls in host?.shelf.add(urls) }
        }
        .help(files.count == 1 ? "Convert \(kind.noun(1).lowercased())" : "Convert \(files.count) \(kind.noun(files.count).lowercased())"))
    }

    /// The menu entry comes from `shelfActions(for:)`, which knows where to put the results.
    func shelfMenuItems(for files: [URL]) -> [NotchMenuItem] { [] }
}

extension ConverterExtension: SettingsPaneProviding {
    func makeSettingsPane() -> AnyView {
        guard let preferences, let ffmpeg else { return AnyView(EmptyView()) }
        return AnyView(ConverterSettingsPane(preferences: preferences, ffmpeg: ffmpeg))
    }
}
