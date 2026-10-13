/*
 * Adapted from Atoll (DynamicIsland), components/Shelf/Services/ThumbnailService.swift
 * Copyright (C) 2024-2026 Atoll Contributors, originally from boring.notch.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import AppKit
import QuickLookThumbnailing

/// Finder icons and finished thumbnails by path, readable synchronously so a
/// tile that is created again (the shelf unmounts while closed) starts out
/// with its image instead of fading it in.
@MainActor
enum FileIcons {
    private static var icons: [String: NSImage] = [:]
    private static var thumbnails: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        if let icon = icons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }

    static func thumbnail(for path: String) -> NSImage? { thumbnails[path] }

    static func setThumbnail(_ image: NSImage?, for path: String) {
        thumbnails[path] = image
    }
}

actor ThumbnailService {
    static let shared = ThumbnailService()

    private var cache: [String: NSImage] = [:]
    private var pending: [String: Task<NSImage?, Never>] = [:]

    func thumbnail(for url: URL, size: CGSize) async -> NSImage? {
        let key = "\(url.path)_\(size.width)x\(size.height)"
        if let cached = cache[key] { return cached }
        if let task = pending[key] { return await task.value }

        let task = Task<NSImage?, Never> {
            let image = await Self.generate(for: url, size: size)
            if let image { cache[key] = image }
            pending[key] = nil
            return image
        }
        pending[key] = task
        return await task.value
    }

    private static func generate(for url: URL, size: CGSize) async -> NSImage? {
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .all)
        request.iconMode = true
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                guard let cgImage = representation?.cgImage else {
                    continuation.resume(returning: nil)
                    return
                }
                let image = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / scale,
                                                                    height: CGFloat(cgImage.height) / scale))
                continuation.resume(returning: image)
            }
        }
    }
}
