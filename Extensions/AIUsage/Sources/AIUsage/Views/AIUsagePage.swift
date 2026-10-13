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
        if providers.isEmpty {
            Group {
                if store.isLoadingFirstReading {
                    ProgressView().controlSize(.small)
                } else {
                    Text("No subscriptions connected")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(KitStyle.tertiaryText)
                        .accessibilityHint("Connect Claude Code, Cursor or Codex in XNotch Settings, AI Usage.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                                         now: now, namespace: namespace, actions: actions(for: id))
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
