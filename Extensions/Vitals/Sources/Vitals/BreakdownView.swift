import AppKit
import SwiftUI
import XNotchKit

/// The measurements of an open tile.
enum Breakdown {
    static let padding: CGFloat = 10
    static let headerHeight: CGFloat = 20
    static let gap: CGFloat = 8
    static let rowHeight: CGFloat = 19
    static let processHeight: CGFloat = 15
    static let rowSpacing: CGFloat = 2

    static func height(apps: Int, processes: Int) -> CGFloat {
        let rows = CGFloat(max(1, apps))
        return 2 * padding + headerHeight + gap + rows * rowHeight + (rows - 1) * rowSpacing
            + CGFloat(processes) * (processHeight + rowSpacing)
    }
}

/// The apps behind an open tile, heaviest first, each with a bar against the
/// heaviest. An app with helpers unfolds into its busiest processes. Rows
/// resolve into focus one after another as the tile opens.
struct BreakdownList: View {
    let metric: Metric
    @ObservedObject var model: VitalsModel
    let `extension`: VitalsExtension
    /// Mounted while closed too, invisible, so opening resolves rows already in place.
    let isOpen: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let apps = model.topApps(for: metric)
        let heaviest = apps.first.map { VitalsModel.usage($0, metric) } ?? 1
        Group {
            if apps.isEmpty {
                ProgressView().controlSize(.small)
                    .opacity(isOpen ? 1 : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.focus)
            } else {
                VStack(spacing: Breakdown.rowSpacing) {
                    ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                        let isUnfolded = model.expandedApp == app.id
                        AppRow(app: app, metric: metric, heaviest: heaviest, icon: app.bundlePath.flatMap { model.icons[$0] },
                               isOpen: isUnfolded, toggle: { toggle(app) })
                            // In an overlay, so the row keeps its identity; only while open, so a
                            // closed tile's hidden rows never take a right-click.
                            .overlay { if isOpen { Color.clear.notchContextMenu { menu(for: app) } } }
                            .modifier(Focus(progress: isOpen ? 1 : 0))
                            .animation(isOpen ? VitalsMotion.resolve.delay(VitalsMotion.arrival + (reduceMotion ? 0 : 0.035 * Double(index)))
                                       : VitalsMotion.dissolve, value: isOpen)
                            .transition(.focus)
                        if isUnfolded {
                            ForEach(model.processes(of: app, for: metric)) { process in
                                ProcessRow(process: process, appName: app.name, metric: metric)
                            }
                        }
                    }
                }
                .animation(KitMotion.content, value: apps.map(\.id))
                .transition(.focus)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(KitMotion.shell, value: apps.isEmpty)
    }

    private func toggle(_ app: AppUsage) {
        guard app.processes.count > 1 else { return }
        withAnimation(KitMotion.shell) { model.expandedApp = model.expandedApp == app.id ? nil : app.id }
    }

    private func menu(for app: AppUsage) -> [NotchMenuItem] {
        var items: [NotchMenuItem] = [.action("Back", symbol: "chevron.left") {
            withAnimation(KitMotion.shell) { model.expanded = nil }
        }]
        if app.processes.count > 1 {
            items.append(.action(model.expandedApp == app.id ? "Hide Processes" : "Show Processes", symbol: "list.bullet.indent") {
                toggle(app)
            })
        }
        items.append(.action("Open Activity Monitor", symbol: "waveform.path.ecg") { `extension`.openActivityMonitor() })
        if model.canQuit(app) {
            items.append(.separator)
            items.append(.action("Quit \(app.name)", symbol: "xmark.circle") { model.quit(app, force: false) })
            items.append(.action("Force Quit \(app.name)", symbol: "exclamationmark.octagon", isDestructive: true) {
                model.quit(app, force: true)
            })
        }
        return items
    }
}

/// Icon, name, how many processes, a bar against the heaviest app, the value.
private struct AppRow: View {
    let app: AppUsage
    let metric: Metric
    let heaviest: Double
    let icon: NSImage?
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        let usage = VitalsModel.usage(app, metric)
        let unfolds = app.processes.count > 1
        NotchHoverReader { hovered in
            HStack(spacing: 7) {
                Group {
                    if let icon {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(KitStyle.tertiaryText)
                    }
                }
                .frame(width: 15, height: 15)
                Text(app.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(KitStyle.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if unfolds {
                    HStack(spacing: 2) {
                        Text("\(app.processes.count)")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .bold))
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                    }
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(hovered || isOpen ? KitStyle.secondaryText : KitStyle.tertiaryText)
                }
                Spacer(minLength: 6)
                Bar(fraction: heaviest > 0 ? usage / heaviest : 0)
                    .frame(width: 96, height: 3)
                Text(BreakdownFormat.value(usage, metric: metric, known: metric == .memory || app.cpu != nil))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(KitStyle.primaryText)
                    .contentTransition(.numericText())
                    .frame(width: 54, alignment: .trailing)
            }
            .padding(.horizontal, 5)
            .frame(height: Breakdown.rowHeight)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(hovered && unfolds ? 0.07 : 0)))
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .animation(KitMotion.content, value: hovered)
        }
        .animation(KitMotion.content, value: usage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.name)
        .accessibilityValue(BreakdownFormat.value(usage, metric: metric, known: true)
                            + (unfolds ? ", \(app.processes.count) processes" : ""))
    }
}

/// One of an app's processes, under it: its own name, its value.
private struct ProcessRow: View {
    let process: ProcessUsage
    let appName: String
    let metric: Metric

    var body: some View {
        HStack(spacing: 6) {
            Text(BreakdownFormat.processName(process.name, in: appName))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(verbatim: "\(process.pid)")
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(KitStyle.tertiaryText)
            Spacer(minLength: 6)
            Text(BreakdownFormat.value(VitalsModel.usage(process, metric), metric: metric,
                                       known: metric == .memory || process.cpu != nil))
                .monospacedDigit()
                .frame(width: 54, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(KitStyle.secondaryText)
        .padding(.leading, 27)
        .padding(.trailing, 5)
        .frame(height: Breakdown.processHeight)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityElement(children: .combine)
    }
}

private struct Bar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.08))
                Capsule()
                    .fill(.white.opacity(0.7))
                    .frame(width: max(3, proxy.size.width * min(1, max(0, fraction))))
            }
        }
    }
}

struct RoundButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        NotchHoverReader { hovered in
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.white.opacity(hovered ? 0.95 : 0.6))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.white.opacity(hovered ? 0.14 : 0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(PressScaleStyle())
            .animation(KitMotion.content, value: hovered)
            .accessibilityLabel(label)
        }
    }
}

enum BreakdownFormat {
    /// "12%" of all cores, or "1.2 GB" of memory.
    static func value(_ usage: Double, metric: Metric, known: Bool) -> String {
        guard known else { return "–" }
        if metric == .memory {
            let bytes = VitalsFormat.bytes(usage, base: 1024)
            return "\(bytes.value) \(bytes.unit)"
        }
        let percent = usage * 100
        if percent < 0.5 { return percent > 0 ? "<1%" : "0%" }
        return "\(Int(percent.rounded()))%"
    }

    /// "Google Chrome Helper (Renderer)" under Google Chrome reads "Helper (Renderer)".
    static func processName(_ name: String, in app: String) -> String {
        guard name.hasPrefix(app) else { return name }
        let rest = name.dropFirst(app.count).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? name : rest
    }
}
