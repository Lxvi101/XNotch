import AppKit
import SwiftUI

struct ConverterSettingsPane: View {
    @ObservedObject var preferences: ConverterPreferences
    let ffmpeg: FFmpeg

    var body: some View {
        Form {
            opening
            output
            FFmpegSection(ffmpeg: ffmpeg, preferences: preferences)
        }
        .formStyle(.grouped)
        .onAppear { ffmpeg.refresh() }
    }

    private var opening: some View {
        Section {
            Picker("Hold", selection: $preferences.modifier) {
                ForEach(WheelModifier.allCases) { Text($0.title).tag($0) }
            }
            Picker(selection: $preferences.gesture) {
                ForEach(WheelGesture.allCases) { Text($0.title).tag($0) }
            } label: {
                Text("And")
                Text(preferences.gesture.detail)
            }
            if preferences.gesture == .pause {
                Picker("Pause for", selection: $preferences.pauseDelay) {
                    ForEach(PauseDelay.allCases) { Text($0.title).tag($0) }
                }
            }
        } header: {
            Text("Opening the Wheel")
        } footer: {
            Text("While dragging files, hold the key to open the wheel under the pointer. Without it, drags are left alone. Drop on a format to convert, on the outer ring for tools, or in the middle to cancel. When the files in the tray or on a shelf are all one kind, Convert in its menu opens the wheel for all of them at once.")
                .foregroundStyle(.secondary)
        }
    }

    private var output: some View {
        Section {
            Picker("Save to", selection: $preferences.output) {
                ForEach(OutputLocation.allCases) { Text($0.title).tag($0) }
            }
            Picker("Quality", selection: $preferences.quality) {
                ForEach(Quality.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Show in Finder when done", isOn: $preferences.revealWhenDone)
        } header: {
            Text("Converted Files")
        } footer: {
            Text("Originals are never changed. Files whose folder can't be written to go to Downloads.")
                .foregroundStyle(.secondary)
        }
    }
}

/// Where ffmpeg comes from, and the one click that gets it.
private struct FFmpegSection: View {
    let ffmpeg: FFmpeg
    @ObservedObject var preferences: ConverterPreferences

    var body: some View {
        Section {
            HStack(spacing: 10) {
                status
                Spacer()
                actions
            }
            if case .failed(let message) = ffmpeg.installState {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if ffmpeg.ownCopyIsRedundant {
                HStack {
                    Text("Your Mac has its own ffmpeg now, so XNotch's copy isn't needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove Copy") { ffmpeg.removeOwnCopy() }
                        .controlSize(.small)
                }
            }
        } header: {
            Text("Video and Audio")
        } footer: {
            Text("Video, audio, WebP and AVIF go through ffmpeg. XNotch uses the one already on your Mac, from Homebrew, MacPorts or your shell's PATH. Without one, Install downloads the signed build from ffmpeg.martin-riedl.de (about 30 MB) into XNotch's folder. Dropping on a format that needs ffmpeg installs it too.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var status: some View {
        let icon = Image(systemName: ffmpeg.location == nil ? "film" : "film.fill")
            .font(.system(size: 18))
            .foregroundStyle(ffmpeg.location == nil ? Color.secondary : Color.accentColor)
            .frame(width: 26)
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                switch ffmpeg.installState {
                case .downloading(let fraction):
                    Text("Downloading ffmpeg…")
                    ProgressView(value: fraction ?? 0)
                        .progressViewStyle(.linear)
                        .frame(width: 180)
                case .verifying:
                    Text("Checking ffmpeg's signature…")
                default:
                    if let location = ffmpeg.location {
                        Text(location.version.map { "ffmpeg \($0)" } ?? "ffmpeg")
                        Text(location.isOwn ? "Installed by XNotch" : location.url.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else if ffmpeg.hasSearched {
                        Text("ffmpeg isn't installed")
                        Text("Images, PDFs and documents convert without it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Looking for ffmpeg…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if ffmpeg.location == nil, ffmpeg.hasSearched, !ffmpeg.isInstalling {
                Button("Install") { Task { try? await ffmpeg.install() } }
                    .buttonStyle(.borderedProminent)
            }
            Menu {
                Button("Choose ffmpeg…", action: choose)
                if preferences.ffmpegPath != nil {
                    Button("Find Automatically") { preferences.ffmpegPath = nil }
                }
                if let location = ffmpeg.location {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([location.url]) }
                    if location.isOwn {
                        Divider()
                        Button("Remove XNotch's Copy", role: .destructive) { ffmpeg.removeOwnCopy() }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        panel.prompt = "Use"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.ffmpegPath = url.path
    }
}
