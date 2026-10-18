import SwiftUI
import XNotchKit

/// Where the tiles are chosen and ordered, above a live copy of the page.
struct VitalsSettingsPane: View {
    @ObservedObject var model: VitalsModel
    let `extension`: VitalsExtension

    @StateObject private var pointer = NotchPointer()

    var body: some View {
        Form {
            Section {
                preview
            }

            Section {
                ForEach(model.settings.order) { metric in
                    MetricRow(metric: metric, model: model)
                }
                .onMove { model.settings.order.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("In the notch")
            } footer: {
                Text("Up to \(VitalsSettings.maxShown) fit side by side. Drag to reorder.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Show as", selection: $model.settings.alertsShowEyes) {
                    Text("Symbol and value").tag(false)
                    Text("Warning and eyes").tag(true)
                }
                ForEach(VitalAlertKind.allCases) { kind in
                    if kind != .battery || model.hasBattery {
                        AlertRow(kind: kind, model: model)
                    }
                }
            } header: {
                Text("Alerts")
            } footer: {
                Text("Shown beside the camera for a few seconds, like headphones connecting. Click one to open Vitals. "
                     + "Each comes back at most every half hour, sooner only if things get worse. "
                     + "With eyes, they look worried for a warning and shocked when it's critical.")
                    .foregroundStyle(.secondary)
            }

            Section("Details") {
                Toggle(isOn: $model.settings.namesBusiestApp) {
                    Text("Name the app using the most CPU")
                    Text("Only looked up while Vitals is open.")
                }
                Picker("Update every", selection: $model.settings.interval) {
                    ForEach(VitalsSettings.intervalChoices, id: \.self) { seconds in
                        Text(seconds == 1 ? "second" : "\(Int(seconds)) seconds").tag(seconds)
                    }
                }
                Toggle("Half as often in Low Power Mode", isOn: $model.settings.slowerOnLowPower)
            }

            Section {
                Button("Open Activity Monitor") { `extension`.openActivityMonitor() }
            }
        }
        .formStyle(.grouped)
    }

    /// The page as the notch draws it.
    private var preview: some View {
        let size = CGSize(width: NotchPageContext.contentWidth, height: 98)
        return VitalsPage(model: model, extension: nil, size: size, isActive: true)
            .padding(.top, 10)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.black))
            .environmentObject(pointer)
            .environment(\.colorScheme, .dark)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Preview")
    }
}

private struct MetricRow: View {
    let metric: Metric
    @ObservedObject var model: VitalsModel

    private var isOn: Bool { model.settings.shown.contains(metric) }
    private var isUnavailable: Bool { metric == .battery && !model.hasBattery }
    private var isBlocked: Bool { !isOn && model.settings.isFull }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill((Color(hex: metric.tintHex) ?? .gray).gradient)
                .frame(width: 26, height: 26)
                .overlay {
                    Image(systemName: metric.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .opacity(isUnavailable ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(metric.title)
                Text(isUnavailable ? "This Mac has no battery" : metric.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle(metric.title, isOn: Binding {
                isOn
            } set: { on in
                if on { model.settings.shown.insert(metric) } else { model.settings.shown.remove(metric) }
            })
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(isUnavailable || isBlocked)
            .help(isBlocked ? "Turn another off first: \(VitalsSettings.maxShown) fit in the notch." : "")
        }
    }
}

private struct AlertRow: View {
    let kind: VitalAlertKind
    @ObservedObject var model: VitalsModel

    private var isOn: Bool { model.settings.alerts.contains(kind) }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(red: 1, green: 0.62, blue: 0.2).gradient)
                .frame(width: 26, height: 26)
                .overlay {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                Text(kind.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Preview") { model.previewAlert(kind) }
                .buttonStyle(.borderless)
                .help("Show this alert in the notch now; click again for its critical look")
            Toggle(kind.title, isOn: Binding {
                isOn
            } set: { on in
                if on { model.settings.alerts.insert(kind) } else { model.settings.alerts.remove(kind) }
            })
            .labelsHidden()
            .toggleStyle(.switch)
        }
        if isOn, let threshold {
            threshold
        }
    }

    /// When it goes off, for alerts that have a choice.
    private var threshold: AnyView? {
        switch kind {
        case .disk:
            AnyView(Picker("Below", selection: $model.settings.diskAlertPercent) {
                ForEach(VitalAlertKind.diskChoices, id: \.self) { Text("\($0)% free").tag($0) }
            })
        case .battery:
            AnyView(Picker("At", selection: $model.settings.batteryAlertPercent) {
                ForEach(VitalAlertKind.batteryChoices, id: \.self) { Text("\($0)%").tag($0) }
            })
        case .cpu:
            AnyView(Picker("Above", selection: $model.settings.cpuAlertPercent) {
                ForEach(VitalAlertKind.cpuChoices, id: \.self) { Text("\($0)%").tag($0) }
            })
        case .memory:
            AnyView(Picker("When pressure is", selection: $model.settings.memoryAlertsOnlyWhenCritical) {
                Text("High").tag(false)
                Text("Critical").tag(true)
            })
        case .heat:
            nil
        }
    }
}
