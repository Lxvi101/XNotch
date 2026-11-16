import SwiftUI
import XNotchKit

/// The notch page: a tile per provider, just its numbers. Clicking a tile grows it into that
/// provider's details, in place; its back button shrinks it again.
struct AIUsagePage: View {
    static let gap: CGFloat = 8
    /// The notch's canvas is 260 pt tall, notch and bottom padding included: stay inside it.
    static let maxHeight: CGFloat = 208

    @ObservedObject var store: AIUsageStore
    let `extension`: AIUsageExtension
    let size: CGSize
    let isActive: Bool

    @Environment(\.isNotchSurfaceVisible) private var isVisible
    @Namespace private var namespace

    /// The tiles, or the open provider's details. The extension reports it so XNotch can size the notch.
    @MainActor
    static func height(for store: AIUsageStore) -> CGFloat {
        guard !store.connectedProviders.isEmpty else { return 60 }
        if let selected = store.selected, store.connectedProviders.contains(selected) {
            let details = ProviderDetails.height(state: store.state(for: selected), settings: store.settings)
            return min(maxHeight, details + 4)
        }
        return ProviderTile.height + 4
    }

    var body: some View {
        // Countdowns tick twice a minute while the page is on screen, and not at all while it's hidden.
        TimelineView(PausableSchedule(interval: 30, isPaused: !isVisible || !isActive)) { timeline in
            content(now: timeline.date)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .onAppear { if isActive { `extension`.pageBecameActive() } }
        .onChange(of: isActive) { _, active in
            if active { `extension`.pageBecameActive() }
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let providers = store.connectedProviders
        if let reason = store.emptyReason {
            UsageEmptyState(reason: reason, isRetrying: store.isRetrying,
                            retry: { `extension`.refresh() }, openSettings: { `extension`.openSettings() })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
        } else {
            ZStack(alignment: .top) {
                if let selected = store.selected, providers.contains(selected) {
                    ProviderDetails(provider: selected, state: store.state(for: selected), settings: store.settings, now: now,
                                    namespace: namespace, actions: actions(for: selected))
                        .transition(.opacity)
                } else {
                    HStack(spacing: Self.gap) {
                        ForEach(providers) { id in
                            ProviderTile(provider: id, state: store.state(for: id), showsRemaining: store.settings.showsRemaining,
                                         showsTodayPace: store.settings.showsTodayPace, now: now, namespace: namespace,
                                         actions: actions(for: id))
                        }
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func actions(for id: AIProviderID) -> ProviderTile.Actions {
        ProviderTile.Actions(
            select: {
                withAnimation(KitMotion.content) { store.selected = store.selected == id ? nil : id }
            },
            refresh: { `extension`.refresh(id) },
            refreshAll: { `extension`.refresh() })
    }
}

/// What the page says instead of tiles: why there's nothing to show, and the one thing to do about it.
struct UsageEmptyState: View {
    let reason: AIUsageStore.EmptyReason
    let isRetrying: Bool
    let retry: () -> Void
    let openSettings: () -> Void

    private enum Action { case retry, settings }

    var body: some View {
        if reason == .loading {
            ProgressView().controlSize(.small)
        } else {
            HStack(spacing: 12) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(tint.opacity(0.14)))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(symbol == nil ? KitStyle.tertiaryText : KitStyle.secondaryText)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(KitStyle.tertiaryText)
                    }
                }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityElement(children: .combine)
                if let action {
                    switch action {
                    case .retry:
                        EmptyStateButton(title: "Try Again", symbol: "arrow.clockwise", isBusy: isRetrying, action: retry)
                    case .settings:
                        EmptyStateButton(title: "Open Settings", symbol: "gearshape", isBusy: false, action: openSettings)
                    }
                }
            }
            .padding(.horizontal, 16)
            .animation(KitMotion.content, value: reason)
        }
    }

    private static func names(_ ids: [AIProviderID]) -> String {
        // The rest of XNotch is English, so the list is too, whatever the system language.
        let names = ids.map(\.displayName)
        guard let last = names.last, names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    private var symbol: String? {
        switch reason {
        case .offline: "wifi.slash"
        case .unreachable: "wifi.exclamationmark"
        case .waiting: "hourglass"
        case .needsAttention: "person.crop.circle.badge.exclamationmark"
        case .loading, .notSetUp: nil
        }
    }

    private var tint: Color {
        switch reason {
        case .offline, .waiting: .white.opacity(0.7)
        default: Palette.caution
        }
    }

    private var title: String {
        switch reason {
        case .offline: "You're offline"
        case let .unreachable(ids): "Can't reach \(Self.names(ids))"
        case let .waiting(ids): "\(Self.names(ids)) asked XNotch to wait"
        case let .needsAttention(ids): "\(Self.names(ids)) \(ids.count == 1 ? "needs" : "need") attention"
        case .loading, .notSetUp: "No subscriptions connected"
        }
    }

    private var detail: String? {
        switch reason {
        case .offline: "Your limits come back as soon as you reconnect."
        case .unreachable: "The network may be down or want you to sign in. XNotch keeps trying."
        case .waiting: "Too many requests. XNotch asks again shortly."
        case .needsAttention: "Sign in again, or allow Keychain access, in Settings."
        case .loading, .notSetUp: nil
        }
    }

    private var action: Action? {
        switch reason {
        case .offline, .unreachable: .retry
        case .needsAttention, .notSetUp: .settings
        case .waiting, .loading: nil
        }
    }
}

private struct EmptyStateButton: View {
    let title: String
    let symbol: String
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        NotchHoverReader { hovered in
            Button(action: action) {
                HStack(spacing: 5) {
                    if isBusy {
                        ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 11, height: 11)
                    } else {
                        Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                    }
                    Text(title).font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(hovered && !isBusy ? 0.95 : 0.7))
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(Capsule().fill(.white.opacity(hovered && !isBusy ? 0.16 : 0.1)))
                .contentShape(Capsule())
            }
            .buttonStyle(PressScaleStyle(scale: 0.94))
            .disabled(isBusy)
            .accessibilityValue(isBusy ? "Trying" : "")
            .animation(KitMotion.content, value: hovered)
            .animation(KitMotion.content, value: isBusy)
        }
    }
}

/// Every `interval` seconds, or a single entry while paused.
struct PausableSchedule: TimelineSchedule {
    var interval: TimeInterval
    var isPaused: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next: Date? = startDate
        let interval = interval
        let isPaused = isPaused
        return AnyIterator {
            defer { next = isPaused ? nil : next?.addingTimeInterval(interval) }
            return next
        }
    }
}
