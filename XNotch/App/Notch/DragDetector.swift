/*
 * Adapted from boring.notch, boringNotch/observers/DragDetector.swift
 * Copyright (C) 2025 boring.notch contributors (Alexander).
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import AppKit

/// Notices file drags anywhere on screen. A mouse-down snapshots the drag
/// pasteboard's change count; once a drag changes it and carries droppable
/// types, every subsequent drag event is reported with its location.
final class DragDetector {
    static let droppableTypes: [NSPasteboard.PasteboardType] =
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    var onDragBegan: (() -> Void)?
    var onDragMoved: ((CGPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    private(set) var isContentDragging = false

    private var monitors: [Any] = []
    private var pasteboardChangeCount = -1
    private var isMouseDown = false
    private let dragPasteboard = NSPasteboard(name: .drag)

    private var hasDroppableContent: Bool {
        dragPasteboard.types?.contains(where: Self.droppableTypes.contains) ?? false
    }

    func start() {
        stop()
        add(.leftMouseDown) { [weak self] _ in
            guard let self else { return }
            pasteboardChangeCount = dragPasteboard.changeCount
            isMouseDown = true
            isContentDragging = false
        }
        add(.leftMouseDragged) { [weak self] _ in
            guard let self, isMouseDown else { return }
            if !isContentDragging,
               dragPasteboard.changeCount != pasteboardChangeCount,
               hasDroppableContent {
                isContentDragging = true
                onDragBegan?()
            }
            if isContentDragging { onDragMoved?(NSEvent.mouseLocation) }
        }
        add(.leftMouseUp) { [weak self] _ in
            guard let self, isMouseDown else { return }
            let wasDragging = isContentDragging
            isMouseDown = false
            isContentDragging = false
            pasteboardChangeCount = -1
            if wasDragging { onDragEnded?() }
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        isMouseDown = false
        isContentDragging = false
    }

    private func add(_ type: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) {
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: type, handler: handler) {
            monitors.append(monitor)
        }
    }

    deinit { stop() }
}
