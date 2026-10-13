/*
 * Adapted from SkyLightWindow, SkyLightOperator.swift
 * Copyright (c) 2025 Lakr Aream. MIT License.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions: the above copyright
 * notice and this permission notice shall be included in all copies or
 * substantial portions of the Software.
 */

import AppKit

/// A private SkyLight space that sits above the lock screen, the only place
/// a window can be drawn while the Mac is locked.
@MainActor
final class SkyLightSpace {
    static let shared = SkyLightSpace()

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindowsAndRemoveFromSpaces = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    /// kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock
    private static let notificationCenterAtScreenLock: Int32 = 400

    private let connection: Int32
    private let space: Int32
    private let addWindows: AddWindowsAndRemoveFromSpaces?

    private init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let handle, let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard let mainConnection = symbol("SLSMainConnectionID", as: MainConnectionID.self),
              let create = symbol("SLSSpaceCreate", as: SpaceCreate.self),
              let setLevel = symbol("SLSSpaceSetAbsoluteLevel", as: SpaceSetAbsoluteLevel.self),
              let show = symbol("SLSShowSpaces", as: ShowSpaces.self) else {
            connection = 0
            space = 0
            addWindows = nil
            NSLog("XNotch: SkyLight is unavailable; lock screen widgets are disabled")
            return
        }
        connection = mainConnection()
        space = create(connection, 1, 0)
        _ = setLevel(connection, space, Self.notificationCenterAtScreenLock)
        _ = show(connection, [space] as CFArray)
        addWindows = symbol("SLSSpaceAddWindowsAndRemoveFromSpaces", as: AddWindowsAndRemoveFromSpaces.self)
    }

    /// Moves the window into the space. Do it once per window and keep the
    /// window alive afterwards: closing a delegated window can crash SkyLight.
    func adopt(_ window: NSWindow) {
        _ = addWindows?(connection, space, [window.windowNumber] as CFArray, 7)
    }
}
