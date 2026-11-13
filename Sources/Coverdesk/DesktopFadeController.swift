import AppKit
import CoreGraphics
import Darwin

/// Pins non-floating desktop windows directly onto user Desktop Spaces (type == 0) via SkyLight
/// so macOS Space-swipe gestures slide the album cover, lyrics, and control bar smoothly with the
/// desktop card itself instead of hiding `.stationary` windows until the gesture finishes settling.
enum SpacePinning {
    static var isAvailable: Bool { SkyLightSpaces.shared.isAvailable }

    @MainActor
    static func desktopSpaceIDs(for screen: NSScreen?) -> [Int] {
        guard let screen else {
            return SkyLightSpaces.shared.allDesktopSpaceIDs()
        }
        if let uuid = screen.displayUUIDString {
            let ids = SkyLightSpaces.shared.desktopSpaceIDs(forDisplayUUID: uuid)
            if !ids.isEmpty { return ids }
        }
        return SkyLightSpaces.shared.allDesktopSpaceIDs()
    }

    @MainActor
    @discardableResult
    static func pinToDesktopSpaces(_ window: NSWindow, on screen: NSScreen?) -> Bool {
        let targetSpaces = desktopSpaceIDs(for: screen)
        guard !targetSpaces.isEmpty else { return false }
        let windowNumber = window.windowNumber
        guard windowNumber > 0 else { return false }
        return SkyLightSpaces.shared.assignWindow(windowNumber, toSpaces: targetSpaces)
    }

    @MainActor
    static func activeSpaceIsDesktop(on screen: NSScreen) -> Bool {
        guard let uuid = screen.displayUUIDString else { return true }
        return SkyLightSpaces.shared.activeSpaceType(forDisplayUUID: uuid) == 0
    }
}

private final class SkyLightSpaces: @unchecked Sendable {
    static let shared = SkyLightSpaces()

    private typealias MainConnFn = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> CFArray?
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> CFArray?
    private typealias AddWindowsToSpacesFn = @convention(c) (Int32, CFArray, CFArray) -> Int32
    private typealias RemoveWindowsFromSpacesFn = @convention(c) (Int32, CFArray, CFArray) -> Int32

    private let mainConn: MainConnFn?
    private let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn?
    private let copySpacesForWindows: CopySpacesForWindowsFn?
    private let addWindowsToSpaces: AddWindowsToSpacesFn?
    private let removeWindowsFromSpaces: RemoveWindowsFromSpacesFn?

    var isAvailable: Bool {
        mainConn != nil
            && copyManagedDisplaySpaces != nil
            && copySpacesForWindows != nil
            && addWindowsToSpaces != nil
            && removeWindowsFromSpaces != nil
    }

    private init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
        mainConn = handle.flatMap { dlsym($0, "CGSMainConnectionID") }.map {
            unsafeBitCast($0, to: MainConnFn.self)
        }
        copyManagedDisplaySpaces = handle.flatMap { dlsym($0, "CGSCopyManagedDisplaySpaces") }.map {
            unsafeBitCast($0, to: CopyManagedDisplaySpacesFn.self)
        }
        copySpacesForWindows = handle.flatMap { dlsym($0, "CGSCopySpacesForWindows") }.map {
            unsafeBitCast($0, to: CopySpacesForWindowsFn.self)
        }
        addWindowsToSpaces = handle.flatMap { dlsym($0, "CGSAddWindowsToSpaces") }.map {
            unsafeBitCast($0, to: AddWindowsToSpacesFn.self)
        }
        removeWindowsFromSpaces = handle.flatMap { dlsym($0, "CGSRemoveWindowsFromSpaces") }.map {
            unsafeBitCast($0, to: RemoveWindowsFromSpacesFn.self)
        }
    }

    func desktopSpaceIDs(forDisplayUUID uuid: String) -> [Int] {
        guard let groups = managedDisplayGroups() else { return [] }
        for group in groups {
            let identifier = (group["Display Identifier"] as? String) ?? ""
            guard identifier.caseInsensitiveCompare(uuid) == .orderedSame else { continue }
            return extractDesktopSpaceIDs(from: group)
        }
        if groups.count == 1, let single = groups.first {
            return extractDesktopSpaceIDs(from: single)
        }
        return []
    }

    func allDesktopSpaceIDs() -> [Int] {
        guard let groups = managedDisplayGroups() else { return [] }
        var result: [Int] = []
        for group in groups {
            for id in extractDesktopSpaceIDs(from: group) where !result.contains(id) {
                result.append(id)
            }
        }
        return result
    }

    func activeSpaceType(forDisplayUUID uuid: String) -> Int? {
        guard let groups = managedDisplayGroups() else { return nil }
        for group in groups {
            let identifier = (group["Display Identifier"] as? String) ?? ""
            guard identifier.caseInsensitiveCompare(uuid) == .orderedSame else { continue }
            if let current = group["Current Space"] as? [String: Any],
               let type = (current["type"] as? NSNumber)?.intValue {
                return type
            }
        }
        return nil
    }

    func assignWindow(_ windowNumber: Int, toSpaces targetSpaces: [Int]) -> Bool {
        guard let mainConn,
              let copySpacesForWindows,
              let addWindowsToSpaces,
              let removeWindowsFromSpaces,
              !targetSpaces.isEmpty
        else { return false }

        let cid = mainConn()
        let windowArray = [NSNumber(value: windowNumber)] as CFArray
        let currentNumbers = (copySpacesForWindows(cid, 0x7, windowArray) as? [NSNumber]) ?? []
        let currentSet = Set(currentNumbers.map(\.intValue))
        let targetSet = Set(targetSpaces)

        let toAdd = targetSpaces.filter { !currentSet.contains($0) }.map { NSNumber(value: $0) }
        let toRemove = currentSet.subtracting(targetSet).map { NSNumber(value: $0) }

        if !toAdd.isEmpty {
            _ = addWindowsToSpaces(cid, windowArray, toAdd as CFArray)
        }
        if !toRemove.isEmpty {
            _ = removeWindowsFromSpaces(cid, windowArray, toRemove as CFArray)
        }
        return true
    }

    private func managedDisplayGroups() -> [[String: Any]]? {
        guard let mainConn, let copyManagedDisplaySpaces else { return nil }
        return copyManagedDisplaySpaces(mainConn()) as? [[String: Any]]
    }

    private func extractDesktopSpaceIDs(from group: [String: Any]) -> [Int] {
        guard let spaces = group["Spaces"] as? [[String: Any]] else { return [] }
        var ids: [Int] = []
        for space in spaces {
            let type = (space["type"] as? NSNumber)?.intValue ?? -1
            if type == 0, let id = (space["id64"] as? NSNumber)?.intValue, id > 0 {
                ids.append(id)
            }
        }
        return ids
    }
}

@MainActor
final class DesktopFadeController {
    private var windows: [UInt32: FadeWindow] = [:]
    private var spaceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    init() {
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSpacePinning()
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSpacePinning()
            }
        }
    }

    func crossfade(_ files: [RenderedWallpaper]) {
        let activeIDs = Set(files.map(\.displayID))
        for (displayID, window) in windows where !activeIDs.contains(displayID) {
            window.orderOut(nil)
        }
        for file in files {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == file.displayID }) else { continue }
            let window = windows[file.displayID] ?? FadeWindow()
            windows[file.displayID] = window
            window.crossfade(to: URL(fileURLWithPath: file.filePath), on: screen)
        }
    }

    func hide() {
        for window in windows.values {
            window.clearAndHide()
        }
    }

    func refreshSpacePinning() {
        for (displayID, window) in windows where window.isVisible {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { continue }
            window.syncFrameAndSpace(on: screen)
        }
    }
}

private final class FadeWindow: NSWindow {
    private var current: NSImageView?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        if SpacePinning.isAvailable {
            collectionBehavior = [.managed, .ignoresCycle]
        } else {
            collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        }
        hidesOnDeactivate = false
        animationBehavior = .none
        contentView = NSView()
    }

    func syncFrameAndSpace(on screen: NSScreen) {
        if frame != screen.frame {
            setFrame(screen.frame, display: true)
        }
        if SpacePinning.isAvailable {
            if !SpacePinning.pinToDesktopSpaces(self, on: screen) {
                collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            }
        }
    }

    func crossfade(to url: URL, on screen: NSScreen) {
        guard let image = NSImage(contentsOf: url) else { return }
        if (contentView?.subviews.count ?? 0) > 1 {
            dropFinishedLayers()
        }
        setFrame(screen.frame, display: false)
        let next = NSImageView(frame: contentView?.bounds ?? screen.frame)
        next.image = image
        next.imageScaling = .scaleAxesIndependently
        next.imageAlignment = .alignCenter
        next.autoresizingMask = [.width, .height]
        next.wantsLayer = true
        next.alphaValue = current == nil ? 1 : 0
        contentView?.addSubview(next)
        current = next
        orderFrontRegardless()
        syncFrameAndSpace(on: screen)
        guard contentView?.subviews.count ?? 0 > 1 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.65
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            next.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.dropFinishedLayers()
            }
        }
    }

    func clearAndHide() {
        orderOut(nil)
        for subview in contentView?.subviews ?? [] {
            subview.removeFromSuperview()
        }
        current = nil
    }

    private func dropFinishedLayers() {
        guard let current else { return }
        for subview in contentView?.subviews ?? [] where subview !== current {
            subview.removeFromSuperview()
        }
    }
}
