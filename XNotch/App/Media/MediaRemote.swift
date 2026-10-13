import Foundation

/// Transport commands through the private MediaRemote framework. Sending
/// commands still works for third-party apps; only reading is restricted.
enum MediaRemote {
    enum Command: Int32 {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    private typealias SendCommand = @convention(c) (Int32, CFDictionary?) -> Bool
    private typealias SetElapsedTime = @convention(c) (Double) -> Void

    private static let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)
    private static let sendCommand: SendCommand? = symbol("MRMediaRemoteSendCommand")
    private static let setElapsed: SetElapsedTime? = symbol("MRMediaRemoteSetElapsedTime")

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    static func send(_ command: Command) {
        _ = sendCommand?(command.rawValue, nil)
    }

    static func setElapsedTime(_ seconds: Double) {
        setElapsed?(seconds)
    }
}
