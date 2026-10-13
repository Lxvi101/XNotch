import SwiftUI

/// One version's notes from `releases/<version>.md`, bundled in
/// Contents/Resources/Releases. The same file is the GitHub release notes and
/// the update dialog's text.
struct ReleaseNote: Identifiable {
    enum Block {
        case paragraph(String)
        case bullets([String])
    }

    let version: String
    let blocks: [Block]

    var id: String { version }

    init(version: String, markdown: String) {
        self.version = version
        var blocks: [Block] = []
        for chunk in markdown.components(separatedBy: "\n\n") {
            let lines = chunk.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !lines.isEmpty else { continue }
            if lines.allSatisfy({ $0.hasPrefix("- ") }) {
                blocks.append(.bullets(lines.map { String($0.dropFirst(2)) }))
            } else {
                blocks.append(.paragraph(lines.joined(separator: " ")))
            }
        }
        self.blocks = blocks
    }

    /// Newest first.
    static func bundled() -> [ReleaseNote] {
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("Releases", isDirectory: true),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "md" }
            .compactMap { url in
                (try? String(contentsOf: url, encoding: .utf8)).map {
                    ReleaseNote(version: url.deletingPathExtension().lastPathComponent, markdown: $0)
                }
            }
            .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }
}

struct ChangelogPane: View {
    @State private var notes = ReleaseNote.bundled()

    private var installed: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        Form {
            if notes.isEmpty {
                Text("No release notes in this build.").foregroundStyle(.secondary)
            }
            ForEach(notes) { note in
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(note.blocks.enumerated()), id: \.offset) { _, block in
                            view(for: block)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    HStack(spacing: 8) {
                        Text("Version \(note.version)")
                        if note.version == installed {
                            Text("Installed")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(.quaternary))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func view(for block: ReleaseNote.Block) -> some View {
        switch block {
        case .paragraph(let text):
            Text(markdown(text))
                .fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(markdown(item))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}
