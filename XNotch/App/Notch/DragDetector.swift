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
/// types, every subsequent drag event is reported with its location. One
/// detector serves every display's notch.
@MainActor
final class DragDetector {
    static let droppableTypes: [NSPasteboard.PasteboardType] =
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    struct Observer {
        let began: () -> Void
        let moved: (CGPoint) -> Void
        let ended: () -> Void
    }

    private(set) var isContentDragging = false

    private var observers: [ObjectIdentifier: Observer] = [:]
    private var monitors: [Any] = []
    private var pasteboardChangeCount = -1
    private var isMouseDown = false
    private var mouseDownTime: TimeInterval = 0
    private var draggedEvents = 0
    private let dragPasteboard = NSPasteboard(name: .drag)

    private var hasDroppableContent: Bool {
        dragPasteboard.types?.contains(where: Self.droppableTypes.contains) ?? false
    }

    func add(_ owner: AnyObject, _ observer: Observer) {
        observers[ObjectIdentifier(owner)] = observer
        if monitors.isEmpty { start() }
    }

    func remove(_ owner: AnyObject) {
        observers[ObjectIdentifier(owner)] = nil
        if observers.isEmpty { stop() }
    }

    private func start() {
        add(.leftMouseDown) { detector, event in
            detector.pasteboardChangeCount = detector.dragPasteboard.changeCount
            detector.isMouseDown = true
            detector.isContentDragging = false
            detector.mouseDownTime = event.timestamp
            detector.draggedEvents = 0
        }
        add(.leftMouseDragged) { detector, event in
            guard detector.isMouseDown else { return }
            if !detector.isContentDragging {
                // Every drag in every app lands here. Reading the drag pasteboard
                // is a round trip to the pasteboard server, so after the first
                // second, when a file drag would long have begun, only every
                // eighth event looks.
                detector.draggedEvents += 1
                if event.timestamp - detector.mouseDownTime > 1, detector.draggedEvents % 8 != 0 { return }
                guard detector.dragPasteboard.changeCount != detector.pasteboardChangeCount,
                      detector.hasDroppableContent else { return }
                detector.isContentDragging = true
                detector.observers.values.forEach { $0.began() }
            }
            let point = NSEvent.mouseLocation
            detector.observers.values.forEach { $0.moved(point) }
        }
        add(.leftMouseUp) { detector, _ in
            guard detector.isMouseDown else { return }
            let wasDragging = detector.isContentDragging
            detector.isMouseDown = false
            detector.isContentDragging = false
            detector.pasteboardChangeCount = -1
            if wasDragging { detector.observers.values.forEach { $0.ended() } }
        }
    }

    private func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        isMouseDown = false
        isContentDragging = false
    }

    private func add(_ type: NSEvent.EventTypeMask, handler: @escaping (DragDetector, NSEvent) -> Void) {
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: type, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self, event)
            }
        }) {
            monitors.append(monitor)
        }
    }
}
