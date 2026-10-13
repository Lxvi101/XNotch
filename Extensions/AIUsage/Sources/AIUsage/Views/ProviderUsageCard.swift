import SwiftUI
import XNotchKit

/// A provider at a glance: its name and up to two quotas as big numbers, each with a bar and the
/// time to its reset (the local reset time while hovered). Click for details. Only connected
/// subscriptions get a tile: setting one up happens in Settings, never in the notch.
struct ProviderTile: View {
    struct Actions {
        var select: () -> Void
        var refresh: () -> Void
        var refreshAll: () -> Void
    }

    static let height: CGFloat = 146

    let provider: AIProviderID
    let state: ProviderState
    let showsRemaining: Bool
    let now: Date
    let namespace: Namespace.ID
    let actions: Actions

    private var tint: Color { Color(hex: provider.tintHex) ?? .white }

    var body: some View {
        NotchHoverReader { hovered in
            VStack(alignment: .leading, spacing: 0) {
                header
                Spacer(minLength: 0)
                if let snapshot = state.snapshot, !snapshot.coreWindows.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(snapshot.coreWindows.prefix(2)) { window in
                            WindowGlance(window: window, showsRemaining: showsRemaining, showsResetTime: hovered, now: now)
                        }
                    }
                } else {
                    Text("–")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(KitStyle.tertiaryText)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: KitStyle.tileCornerRadius, style: .continuous)
                    .fill(.white.opacity(hovered ? 0.09 : 0.06))
                    .matchedGeometryEffect(id: provider, in: namespace)
            }
            .contentShape(RoundedRectangle(cornerRadius: KitStyle.tileCornerRadius, style: .continuous))
            .onTapGesture(perform: actions.select)
            .scaleEffect(hovered ? 1.015 : 1)
            .animation(KitMotion.content, value: hovered)
        }
        .notchContextMenu {
            [.action("Refresh", symbol: "arrow.clockwise", handler: actions.refresh),
             .action("Refresh All", symbol: "arrow.triangle.2.circlepath", handler: actions.refreshAll)]
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(provider.displayName)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Show details", actions.select)
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: provider.symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(provider.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(state.snapshot == nil ? KitStyle.tertiaryText : KitStyle.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
            if state.snapshot != nil, let color = Palette.status(state.status) {
                Circle().fill(color).frame(width: 6, height: 6)
                    .accessibilityLabel(state.message ?? "Not up to date")
            }
        }
        .frame(height: 16)
    }

}

/// "54%", a bar, and the reset: the countdown, or the local time while hovered.
private struct WindowGlance: View {
    let window: QuotaWindow
    let showsRemaining: Bool
    let showsResetTime: Bool
    let now: Date

    var body: some View {
        let shown = showsRemaining ? window.displayRemaining : window.displayUsed
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(UsageFormat.percent(shown))
                    .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(shown == nil ? KitStyle.tertiaryText : KitStyle.primaryText)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 2)
                let label = window.shortLabel ?? window.label
                Text(showsRemaining ? "\(label) left" : label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(KitStyle.tertiaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            UsageBar(fraction: shown.map { $0 / 100 }, color: Palette.fill(usedPercent: window.displayUsed))
                .frame(height: 3)
            HStack(spacing: 3) {
                if let resetsAt = window.resetsAt {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 7.5, weight: .bold))
                    Text(resetsAt <= now ? "now" : showsResetTime ? UsageFormat.resetTime(resetsAt, now: now)
                         : UsageFormat.countdown(to: resetsAt, from: now))
                        .contentTransition(.numericText())
                } else if let detail = window.detail {
                    Text(detail)
                }
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(KitStyle.tertiaryText)
            .lineLimit(1)
            .frame(height: 12)
        }
        .animation(KitMotion.content, value: showsResetTime)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.label)
        .accessibilityValue(WindowAccessibility.value(window, showsRemaining: showsRemaining, now: now))
    }
}

/// Everything else about the open tile's provider: plan, every window with its local reset time,
/// spend and credits, and what's wrong when something is.
struct ProviderDetails: View {
    static let padding: CGFloat = 12
    static let headerHeight: CGFloat = 20
    static let messageHeight: CGFloat = 28
    static let rowHeight: CGFloat = 18
    static let rowSpacing: CGFloat = 5
    static let sectionSpacing: CGFloat = 10

    let provider: AIProviderID
    let state: ProviderState
    let settings: AIUsageSettings
    let now: Date
    let namespace: Namespace.ID
    let actions: ProviderTile.Actions

    @MainActor
    static func height(state: ProviderState, settings: AIUsageSettings) -> CGFloat {
        var height = 2 * padding + headerHeight
        if showsMessage(state) { height += sectionSpacing + messageHeight }
        let rows = rows(state.snapshot).count
        if rows > 0 { height += sectionSpacing + CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowSpacing }
        return height
    }

    private static func showsMessage(_ state: ProviderState) -> Bool {
        state.status != .fresh && state.message != nil
    }

    enum Row: Identifiable {
        case window(QuotaWindow)
        case spend(SpendLine)
        case value(id: String, label: String, value: String, trailing: String?)

        var id: String {
            switch self {
            case let .window(window): "w.\(window.id)"
            case let .spend(line): "s.\(line.id)"
            case let .value(id, _, _, _): "v.\(id)"
            }
        }
    }

    static func rows(_ snapshot: ProviderUsageSnapshot?, now: Date = Date()) -> [Row] {
        guard let snapshot else { return [] }
        var rows = snapshot.windows.map(Row.window) + (snapshot.spending?.lines ?? []).map(Row.spend)
        if let credits = snapshot.credits {
            if credits.isUnlimited {
                rows.append(.value(id: "credits", label: "Credits", value: "Unlimited", trailing: nil))
            } else if let balance = credits.balance {
                let value = credits.balanceUnit == "USD" ? Money.format(balance, "USD")
                    : balance.formatted(.number.precision(.fractionLength(0...2)))
                rows.append(.value(id: "credits", label: "Credits", value: value, trailing: nil))
            }
            if let saved = credits.savedResets, saved > 0 {
                rows.append(.value(id: "saved-resets", label: "Saved resets", value: "\(saved)",
                                   trailing: credits.savedResetsNextExpiry.map { "until \(UsageFormat.resetTime($0, now: now))" }))
            }
        }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.sectionSpacing) {
            header
            // Scrolls only when there's more than the notch can show.
            ViewThatFits(in: .vertical) {
                details
                ScrollView(.vertical, showsIndicators: false) { details }
            }
        }
        .padding(Self.padding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: KitStyle.tileCornerRadius, style: .continuous)
                .fill(KitStyle.fill)
                .matchedGeometryEffect(id: provider, in: namespace)
        }
        .notchContextMenu {
            [.action("Back", symbol: "chevron.left", handler: actions.select),
             .action("Refresh", symbol: "arrow.clockwise", handler: actions.refresh)]
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Self.sectionSpacing) {
            if Self.showsMessage(state), let message = state.message {
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.caution)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: Self.messageHeight, maxHeight: Self.messageHeight, alignment: .topLeading)
            }
            let rows = Self.rows(state.snapshot, now: now)
            if !rows.isEmpty {
                VStack(spacing: Self.rowSpacing) {
                    ForEach(rows) { row in
                        DetailRow(row: row, showsRemaining: settings.showsRemaining, now: now)
                            .frame(height: Self.rowHeight)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            BackButton(action: actions.select)
            Image(systemName: provider.symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color(hex: provider.tintHex) ?? .white)
                .accessibilityHidden(true)
            Text(provider.displayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(KitStyle.primaryText)
            if let plan = state.snapshot?.planLabel {
                Text(plan)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(KitStyle.secondaryText)
                    .padding(.horizontal, 6)
                    .frame(height: 17)
                    .background(Capsule().fill(KitStyle.hoverFill))
            }
            if settings.showsAccountLabels, let account = state.snapshot?.accountLabel {
                Text(account)
                    .font(.system(size: 10))
                    .foregroundStyle(KitStyle.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let snapshot = state.snapshot {
                Text(UsageFormat.age(of: snapshot.refreshedAt, now: now))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(KitStyle.tertiaryText)
                    .help(snapshot.source.label)
            }
            RefreshButton(isRefreshing: state.isRefreshing, action: actions.refresh)
        }
        .frame(height: Self.headerHeight)
    }
}

private struct DetailRow: View {
    let row: ProviderDetails.Row
    let showsRemaining: Bool
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            switch row {
            case let .window(window):
                label(window.label)
                let shown = showsRemaining ? window.displayRemaining : window.displayUsed
                UsageBar(fraction: shown.map { $0 / 100 }, color: Palette.fill(usedPercent: window.displayUsed))
                    .frame(height: 3)
                value(UsageFormat.percent(shown)).frame(width: 44, alignment: .trailing)
                trailing(window.resetsAt.map { $0 <= now ? "now" : UsageFormat.resetTime($0, now: now) } ?? window.detail ?? "")
            case let .spend(line):
                label(line.label)
                let used = Money.format(line.used, line.currencyCode)
                value(line.limit.map { "\(used) of \(Money.format($0, line.currencyCode))" } ?? used)
                Spacer(minLength: 0)
                trailing(line.resetsAt.map { UsageFormat.resetTime($0, now: now) } ?? "")
            case let .value(_, title, text, extra):
                label(title)
                value(text)
                Spacer(minLength: 0)
                trailing(extra ?? "")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(KitStyle.secondaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: 104, alignment: .leading)
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(KitStyle.primaryText)
            .lineLimit(1)
    }

    private func trailing(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5).monospacedDigit())
            .foregroundStyle(KitStyle.tertiaryText)
            .lineLimit(1)
            .frame(width: 78, alignment: .trailing)
    }
}

enum WindowAccessibility {
    static func value(_ window: QuotaWindow, showsRemaining: Bool, now: Date) -> String {
        var parts: [String] = []
        if let used = window.displayUsed {
            parts.append(showsRemaining ? "\(Int((100 - used).rounded())) percent remaining" : "\(Int(used.rounded())) percent used")
        } else {
            parts.append("usage unknown")
        }
        if let resetsAt = window.resetsAt, resetsAt > now {
            parts.append("resets in \(UsageFormat.countdown(to: resetsAt, from: now)), \(UsageFormat.fullResetTime(resetsAt))")
        }
        if let detail = window.detail { parts.append(detail) }
        return parts.joined(separator: ", ")
    }
}

enum Palette {
    static let caution = Color(red: 1, green: 0.74, blue: 0.3)
    static let critical = Color(red: 1, green: 0.39, blue: 0.36)

    /// White until a quota runs low: colour only ever means "careful".
    static func fill(usedPercent: Double?) -> Color {
        guard let used = usedPercent else { return .white.opacity(0.8) }
        if used >= 90 { return critical }
        if used >= 75 { return caution }
        return .white.opacity(0.8)
    }

    /// The dot on a tile whose reading isn't current.
    static func status(_ status: ProviderStatus) -> Color? {
        switch status {
        case .fresh, .loading, .notConnected: nil
        case .error: critical
        default: caution
        }
    }
}

struct UsageBar: View {
    /// 0…1, or nil when unknown (drawn as an empty, dashed track).
    let fraction: Double?
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                if let fraction {
                    Capsule()
                        .fill(color)
                        .frame(width: max(fraction > 0 ? 3 : 0, proxy.size.width * min(1, max(0, fraction))))
                } else {
                    Capsule().strokeBorder(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
            }
        }
        .animation(reduceMotion ? nil : KitMotion.content, value: fraction)
    }
}

private struct BackButton: View {
    let action: () -> Void

    var body: some View {
        NotchHoverReader { hovered in
            Button(action: action) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(hovered ? 0.95 : 0.6))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.white.opacity(hovered ? 0.14 : 0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(PressScaleStyle())
            .animation(KitMotion.content, value: hovered)
            .accessibilityLabel("Back")
        }
    }
}

private struct RefreshButton: View {
    let isRefreshing: Bool
    let action: () -> Void

    var body: some View {
        NotchHoverReader { hovered in
            Button(action: action) {
                Group {
                    if isRefreshing {
                        ProgressView().controlSize(.mini).scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                    }
                }
                .foregroundStyle(.white.opacity(hovered ? 0.9 : 0.5))
                .frame(width: 20, height: 20)
                .background(Circle().fill(.white.opacity(hovered ? 0.1 : 0)))
                .contentShape(Circle())
            }
            .buttonStyle(PressScaleStyle())
            .animation(KitMotion.content, value: hovered)
            .accessibilityLabel("Refresh")
        }
    }
}
