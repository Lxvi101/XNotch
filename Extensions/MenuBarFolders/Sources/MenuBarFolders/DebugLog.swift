import Foundation

/// A plain text log while the extension is being shaken out:
/// ~/Library/Application Support/XNotch/ExtensionData/menubarfolders/debug.log
enum DebugLog {
    nonisolated(unsafe) static var url: URL?

    static func write(_ message: String) {
        guard let url else { return }
        let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
