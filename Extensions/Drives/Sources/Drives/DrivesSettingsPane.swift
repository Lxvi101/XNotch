import SwiftUI

struct DrivesSettingsPane: View {
    @ObservedObject var monitor: DriveMonitor

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $monitor.settings.alertsOnConnect) {
                    Text("When a drive connects")
                    Text("Its name and free space, beside the camera for a few seconds. Click it to open Drives.")
                }
                Toggle(isOn: $monitor.settings.alertsOnEject) {
                    Text("When it's safe to unplug")
                    Text("After you eject a drive from the notch.")
                }
            } header: {
                Text("Alerts")
            }

            Section {
                Toggle(isOn: $monitor.settings.includesDiskImages) {
                    Text("Include disk images")
                    Text("Opened .dmg files, which Finder also lists as ejectable.")
                }
            } footer: {
                Text("Drives get a page in the notch while one is connected: USB sticks, SD cards and external disks, "
                     + "with how much space is free and an eject button.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
