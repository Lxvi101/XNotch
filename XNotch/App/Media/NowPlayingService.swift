/*
 * Stream merging and playback-anchor handling adapted from Atoll (DynamicIsland),
 * MediaControllers/NowPlayingController.swift
 * Copyright (C) 2024-2026 Atoll Contributors, originally from boring.notch.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import AppKit
import SwiftUI

struct NowPlayingTrack: Equatable {
    var title = ""
    var artist = ""
    var album = ""
    var duration: Double = 0
    /// Position at `anchor`; together they extrapolate the live position.
    var elapsed: Double = 0
    var anchor = Date()
    var rate: Double = 1
    var isPlaying = false
    var bundleIdentifier = ""

    var identity: String { "\(title)\u{1}\(artist)\u{1}\(album)" }

    func position(at date: Date = Date()) -> Double {
        var position = elapsed
        if isPlaying { position += date.timeIntervalSince(anchor) * rate }
        return duration > 0 ? min(max(position, 0), duration) : max(position, 0)
    }
}

/// Now-playing state from the system media session, read through
/// mediaremote-adapter (macOS 15.4+ blocks direct MediaRemote reads for
/// third-party apps) and controlled through MediaRemote commands.
@MainActor
final class NowPlayingService: ObservableObject {
    @Published private(set) var track: NowPlayingTrack?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var artworkGlow: NSImage?
    @Published private(set) var accent: Color = .white

    /// A sample older than this can't anchor a play/pause transition.
    private static let currentSampleWindow: TimeInterval = 2

    private var process: Process?
    private var isRunning = false
    private var restartDelay: TimeInterval = 1

    func start() {
        guard !isRunning else { return }
        isRunning = true
        launch()
    }

    func stop() {
        isRunning = false
        process?.terminate()
        process = nil
    }

    // MARK: Commands

    func togglePlayPause() {
        guard var current = track else { return }
        current.elapsed = current.position()
        current.anchor = Date()
        current.isPlaying.toggle()
        track = current
        MediaRemote.send(.togglePlayPause)
    }

    func nextTrack() { MediaRemote.send(.nextTrack) }
    func previousTrack() { MediaRemote.send(.previousTrack) }

    func seek(to seconds: Double) {
        guard var current = track else { return }
        current.elapsed = seconds
        current.anchor = Date()
        track = current
        MediaRemote.setElapsedTime(seconds)
    }

    // MARK: Adapter process

    private func launch() {
        guard let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let framework = Bundle.main.resourceURL?.appendingPathComponent("MediaRemoteAdapter.framework") else {
            NSLog("XNotch: mediaremote-adapter is missing from the app bundle")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, framework.path, "stream", "--micros", "--debounce=40"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let reader = AdapterLineReader { [weak self] update, image in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(update, decodedArtwork: image) }
            }
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                reader.consume(data)
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.processExited() }
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            NSLog("XNotch: failed to launch mediaremote-adapter: \(error)")
        }
    }

    private func processExited() {
        process = nil
        guard isRunning else { return }
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isRunning, self.process == nil else { return }
            self.launch()
        }
    }

    // MARK: Merging

    private func apply(_ update: NowPlayingUpdate, decodedArtwork: DecodedArtwork?) {
        restartDelay = 1
        let payload = update.payload
        let diff = update.diff ?? false
        let previous = track ?? NowPlayingTrack()
        var next = NowPlayingTrack()

        next.title = payload.title ?? (diff ? previous.title : "")
        next.artist = payload.artist ?? (diff ? previous.artist : "")
        next.album = payload.album ?? (diff ? previous.album : "")
        next.duration = payload.resolvedDuration ?? (diff ? previous.duration : 0)
        next.rate = payload.playbackRate ?? (diff ? previous.rate : 1)
        next.bundleIdentifier = payload.parentApplicationBundleIdentifier
            ?? payload.bundleIdentifier ?? (diff ? previous.bundleIdentifier : "")

        // Position and the instant it was sampled are a matched pair.
        if let elapsed = payload.resolvedElapsedTime {
            next.elapsed = elapsed
            next.anchor = payload.resolvedTimestamp ?? Date()
        } else if payload.clearsElapsedTime || !diff {
            next.elapsed = 0
            next.anchor = payload.resolvedTimestamp ?? Date()
        } else {
            next.elapsed = previous.elapsed
            next.anchor = previous.anchor
        }

        // Some senders (Spotify) never republish on pause/resume, so re-anchor
        // on the transition itself unless this update carries a current sample.
        let wasPlaying = previous.isPlaying
        next.isPlaying = payload.playing ?? (diff ? wasPlaying : false)
        let now = Date()
        let hasCurrentSample: Bool = {
            guard payload.resolvedElapsedTime != nil else { return false }
            guard let stamp = payload.resolvedTimestamp else { return true }
            return abs(now.timeIntervalSince(stamp)) <= Self.currentSampleWindow
        }()
        if wasPlaying != next.isPlaying, !hasCurrentSample {
            let instant: Date = {
                guard let stamp = payload.resolvedTimestamp,
                      abs(now.timeIntervalSince(stamp)) <= Self.currentSampleWindow else { return now }
                return stamp
            }()
            if wasPlaying {
                next.elapsed = max(0, previous.elapsed + instant.timeIntervalSince(previous.anchor) * previous.rate)
            } else {
                next.elapsed = max(0, previous.elapsed)
            }
            next.anchor = instant
        }

        if let decodedArtwork {
            artwork = decodedArtwork.image
            artworkGlow = decodedArtwork.glow
            accent = Color(nsColor: decodedArtwork.accent)
        } else if !diff || payload.clearsArtwork {
            artwork = nil
            artworkGlow = nil
            accent = .white
        }

        let resolved: NowPlayingTrack? = next.title.isEmpty && !next.isPlaying ? nil : next
        if resolved != track { track = resolved }
    }
}

struct DecodedArtwork: @unchecked Sendable {
    let image: NSImage
    let glow: NSImage?
    let accent: NSColor
}

/// Splits the adapter's stdout into JSON lines and decodes them, including the
/// base64 artwork, on the pipe's background queue.
private final class AdapterLineReader: @unchecked Sendable {
    private var buffer = Data()
    private let decoder = JSONDecoder()
    private let onUpdate: (NowPlayingUpdate, DecodedArtwork?) -> Void

    init(onUpdate: @escaping (NowPlayingUpdate, DecodedArtwork?) -> Void) {
        self.onUpdate = onUpdate
    }

    func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty, let update = try? decoder.decode(NowPlayingUpdate.self, from: line) else { continue }
            var artwork: DecodedArtwork?
            if let base64 = update.payload.artworkData,
               let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
               let image = NSImage(data: data) {
                artwork = DecodedArtwork(image: image, glow: ArtworkGlow.image(of: image), accent: ArtworkAccent.color(of: image))
            }
            onUpdate(update, artwork)
        }
    }
}

struct NowPlayingUpdate: Decodable {
    let payload: NowPlayingPayload
    let diff: Bool?
}

struct NowPlayingPayload: Decodable {
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let elapsedTime: Double?
    let durationMicros: Double?
    let elapsedTimeMicros: Double?
    let timestampEpochMicros: Double?
    let artworkData: String?
    let playbackRate: Double?
    let playing: Bool?
    let parentApplicationBundleIdentifier: String?
    let bundleIdentifier: String?
    /// A diff omits unchanged keys; a key that is present but null means the
    /// sender cleared it, which optional decoding alone can't distinguish.
    let clearsElapsedTime: Bool
    let clearsArtwork: Bool

    private enum CodingKeys: String, CodingKey {
        case title, artist, album, duration, elapsedTime
        case durationMicros, elapsedTimeMicros, timestampEpochMicros
        case artworkData, playbackRate, playing
        case parentApplicationBundleIdentifier, bundleIdentifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        artist = try container.decodeIfPresent(String.self, forKey: .artist)
        album = try container.decodeIfPresent(String.self, forKey: .album)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        elapsedTime = try container.decodeIfPresent(Double.self, forKey: .elapsedTime)
        durationMicros = try container.decodeIfPresent(Double.self, forKey: .durationMicros)
        elapsedTimeMicros = try container.decodeIfPresent(Double.self, forKey: .elapsedTimeMicros)
        timestampEpochMicros = try container.decodeIfPresent(Double.self, forKey: .timestampEpochMicros)
        artworkData = try container.decodeIfPresent(String.self, forKey: .artworkData)
        playbackRate = try container.decodeIfPresent(Double.self, forKey: .playbackRate)
        playing = try container.decodeIfPresent(Bool.self, forKey: .playing)
        parentApplicationBundleIdentifier = try container.decodeIfPresent(String.self, forKey: .parentApplicationBundleIdentifier)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)

        func isExplicitlyNull(_ key: CodingKeys) throws -> Bool {
            try container.contains(key) && container.decodeNil(forKey: key)
        }
        clearsElapsedTime = try isExplicitlyNull(.elapsedTime) || isExplicitlyNull(.elapsedTimeMicros)
        clearsArtwork = try isExplicitlyNull(.artworkData)
    }

    var resolvedDuration: Double? {
        durationMicros.map { $0 / 1_000_000 } ?? duration
    }

    var resolvedElapsedTime: Double? {
        elapsedTimeMicros.map { $0 / 1_000_000 } ?? elapsedTime
    }

    var resolvedTimestamp: Date? {
        timestampEpochMicros.map { Date(timeIntervalSince1970: $0 / 1_000_000) }
    }
}
