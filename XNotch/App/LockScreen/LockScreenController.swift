import AppKit
import Combine
import SwiftUI

/// Shows the Now Playing card on the Lock Screen while the Mac is locked and
/// something is playing, and offers a desktop preview of the same card.
///
/// Lock state comes from the distributed lock notifications, with a poll of
/// the session dictionary while locked because the unlock notification can
/// arrive well after the user is back on the desktop.
@MainActor
final class LockScreenController {
    private(set) var isLocked = false
    var onLock: (() -> Void)?

    private let media: NowPlayingService
    private let preferences: Preferences
    private let cardState = LockScreenCardState()
    private var window: NSWindow?
    private var isAdopted = false
    private var isPreviewing = false
    private var pollTimer: Timer?
    private var hideWork: DispatchWorkItem?
    private var previewWork: DispatchWorkItem?
    private var previewMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    private static let windowMargin: CGFloat = 48

    init(media: NowPlayingService, preferences: Preferences) {
        self.media = media
        self.preferences = preferences

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.locked() }
        }
        distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.unlocked() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.unlocked() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }

        media.$track
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)
        preferences.$lockScreenMediaEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)
    }

    /// The card over the desktop for a few seconds, exactly as it appears locked.
    func preview() {
        guard !isLocked else { return }
        isPreviewing = true
        present(onLockScreen: false)
        previewWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.endPreview() }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
        if previewMonitor == nil {
            previewMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.endPreview() }
            }
        }
    }

    // MARK: Lock state

    private func locked() {
        guard !isLocked else { return }
        isLocked = true
        endPreview()
        onLock?()
        startPolling()
        update()
    }

    private func unlocked() {
        guard isLocked else { return }
        isLocked = false
        stopPolling()
        update()
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isLocked else { return }
                if !Self.sessionIsLocked() { self.unlocked() }
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private static func sessionIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private func update() {
        if isLocked {
            if preferences.lockScreenMediaEnabled && media.track != nil {
                present(onLockScreen: true)
            } else {
                dismiss()
            }
        } else if !isPreviewing {
            dismiss()
        }
    }

    private func endPreview() {
        previewWork?.cancel()
        previewWork = nil
        if let previewMonitor { NSEvent.removeMonitor(previewMonitor) }
        previewMonitor = nil
        guard isPreviewing else { return }
        isPreviewing = false
        if !isLocked { dismiss() }
    }

    // MARK: Window

    private func present(onLockScreen: Bool) {
        hideWork?.cancel()
        hideWork = nil
        let window = self.window ?? makeWindow()
        self.window = window
        reposition()
        if onLockScreen && !isAdopted {
            SkyLightSpace.shared.adopt(window)
            isAdopted = true
        }
        window.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in self?.cardState.presented = true }
    }

    private func dismiss() {
        guard let window, cardState.presented || window.isVisible else { return }
        cardState.presented = false
        let work = DispatchWorkItem { [weak self] in
            // Ordered out, never closed: a window SkyLight has adopted must stay alive.
            self?.window?.orderOut(nil)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let card = LockScreenMediaCard(media: media, state: cardState)
            .padding(Self.windowMargin)
            .fixedSize()
        let host = NotchHostingView(rootView: card)
        host.sizingOptions = [.intrinsicContentSize]
        window.contentView = host
        return window
    }

    /// Centered, a little below the middle of the screen, clear of the clock
    /// above and the login field below.
    private func reposition() {
        guard let window, let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main,
              let content = window.contentView else { return }
        let size = content.fittingSize
        let frame = screen.frame
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height + Self.windowMargin - 70)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
