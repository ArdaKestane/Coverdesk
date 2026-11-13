import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class ControlPanelController {
    private let model: AppModel
    private let panel: FloatingPanel
    private let container: ControlContainerView
    private let mover = WindowMover()
    private var moveObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var outsideMonitor: Any?
    private var localOutsideMonitor: Any?
    private var suppressMove = false
    private var restingSize: NSSize?
    private var appliedSearchExtra: CGFloat = 0
    private var searchLayoutGeneration = 0
    private var searchLayoutScheduled = false
    private var pendingSearchExtra: CGFloat = 0

    init(model: AppModel) {
        self.model = model
        panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: model.preferences.controlSize))
        container = ControlContainerView(model: model, mover: mover)
        mover.window = panel
        mover.onEnd = { [weak model] origin in
            model?.preferences.setCustomOrigin(origin)
        }
        panel.contentView = container
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)) - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.isFloatingPanel = true
        panel.animationBehavior = .none
        panel.resizesFromEdges = true
        panel.lockedAspect = ControlChrome.aspectRatio
        panel.resizeMinimum = NSSize(width: 340, height: 84)
        panel.resizeMaximum = NSSize(width: 900, height: 230)
        panel.onFrameCommit = { [weak self, weak model] rect in
            model?.preferences.setCustomOrigin(rect.origin)
            guard self?.restingSize == nil else { return }
            model?.preferences.setControlSize(rect.size)
        }
        AlignmentGuide.shared.register(panel)
        mover.onScaleAnchor = { [weak panel] rect in
            panel?.extraResizeRect = rect
        }

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rememberDraggedOrigin()
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.model.screensChanged()
            }
        }
        model.onInterfaceChange = { [weak self] in
            self?.applyChrome()
        }
        model.onPlaybackChange = { [weak self] in
            self?.container.render()
        }
        model.onSearchChange = { [weak self] in
            self?.container.render()
        }
        model.onSearchFocus = { [weak self] in
            guard let self else { return }
            NSApp.activate()
            self.panel.makeKey()
        }
        container.onSearchHeight = { [weak self] height in
            self?.updateSearchLayout(extraHeight: height)
        }
        installOutsideMonitor()
        applyChrome()
    }

    func show() {
        applyChrome()
        if model.preferences.controlsVisible {
            panel.orderFrontRegardless()
        }
    }

    private func updateSearchLayout(extraHeight: CGFloat) {
        pendingSearchExtra = max(0, extraHeight)
        guard !searchLayoutScheduled else { return }
        searchLayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.searchLayoutScheduled = false
            self.applySearchLayout(self.pendingSearchExtra)
        }
    }

    /// Grows the strip upward so results sit above the controls without moving them.
    private func applySearchLayout(_ extra: CGFloat) {
        guard abs(extra - appliedSearchExtra) > 0.5 else { return }
        appliedSearchExtra = extra
        searchLayoutGeneration += 1
        let generation = searchLayoutGeneration

        if extra <= 0.5 {
            guard let restingSize else { return }
            animateFrame(NSRect(origin: panel.frame.origin, size: restingSize)) { [weak self] in
                guard let self, generation == self.searchLayoutGeneration, self.appliedSearchExtra <= 0.5 else { return }
                self.restingSize = nil
                self.panel.lockedAspect = ControlChrome.aspectRatio
                self.panel.resizesFromEdges = true
            }
            return
        }

        if restingSize == nil {
            restingSize = panel.frame.size
            panel.lockedAspect = nil
            panel.resizesFromEdges = false
        }
        let base = restingSize ?? panel.frame.size
        var height = base.height + extra
        if let screen = panel.screen ?? NSScreen.main {
            let available = screen.visibleFrame.maxY - panel.frame.origin.y - 8
            height = min(height, max(base.height, available))
        }
        animateFrame(NSRect(
            origin: panel.frame.origin,
            size: NSSize(width: base.width, height: height)
        ))
    }

    private func animateFrame(_ rect: NSRect, completion: (@MainActor () -> Void)? = nil) {
        let delta = abs(rect.height - panel.frame.height)
        guard delta > 0.5 || abs(rect.width - panel.frame.width) > 0.5 else {
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = min(0.38, max(0.18, Double(delta) / 1100))
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(rect, display: true)
        } completionHandler: {
            Task { @MainActor in
                completion?()
            }
        }
    }

    private func installOutsideMonitor() {
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.handleOutsideClick()
            }
        }
        localOutsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleOutsideClick()
            }
            return event
        }
    }

    private func handleOutsideClick() {
        guard model.isOverlayPresented else { return }
        let mouse = NSEvent.mouseLocation
        let hit = panel.frame.insetBy(dx: -8, dy: -8)
        guard !hit.contains(mouse) else { return }

        // In desktop mode (`!floatAboveWindows`), clicking into Chrome, Dock, Menu Bar, or another app window
        // should NOT close Coverdesk's card — Coverdesk sits on the desktop behind windows, so when the user
        // comes back from Chrome, their search results or playlist remain right where they left them.
        if !model.preferences.floatAboveWindows, !Self.clickedBareDesktop(at: mouse) {
            return
        }
        model.collapseOverlay()
    }

    private static func clickedBareDesktop(at appKitPoint: NSPoint) -> Bool {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return true }
        let quartzPoint = CGPoint(x: appKitPoint.x, y: primaryHeight - appKitPoint.y)
        let myPID = Int(getpid())
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return true
        }
        for entry in list {
            let pid = entry[kCGWindowOwnerPID as String] as? Int ?? -1
            if pid == myPID { continue }
            let layer = entry[kCGWindowLayer as String] as? Int ?? -1
            if layer < 0 { continue }
            let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1
            if alpha <= 0.01 { continue }
            guard let rawBounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: rawBounds)
            else { continue }
            if rect.contains(quartzPoint) {
                return false
            }
        }
        return true
    }

    private func applyChrome() {
        if model.preferences.floatAboveWindows {
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        } else {
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)) - 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .stationary]
        }
        reposition()
        container.render()
        if model.preferences.controlsVisible {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private func reposition() {
        suppressMove = true
        defer { suppressMove = false }
        let baseSize = model.preferences.controlSize
        if restingSize != nil {
            restingSize = baseSize
        }
        let resolvedOrigin: NSPoint
        if let origin = model.preferences.customOrigin, originIsVisible(origin, size: baseSize) {
            resolvedOrigin = origin
        } else if let screen = NSScreen.screens.first {
            let dockInset = screen.visibleFrame.minY - screen.frame.minY
            let clearance = max(dockInset + 18, ControlChrome.dockClearance)
            resolvedOrigin = NSPoint(
                x: screen.frame.midX - baseSize.width / 2,
                y: screen.frame.minY + clearance
            )
        } else {
            return
        }

        var targetHeight = baseSize.height
        if appliedSearchExtra > 0.5 {
            targetHeight = baseSize.height + appliedSearchExtra
            if let screen = panel.screen ?? NSScreen.main {
                let available = screen.visibleFrame.maxY - resolvedOrigin.y - 8
                targetHeight = min(targetHeight, max(baseSize.height, available))
            }
        }
        panel.setFrame(
            NSRect(origin: resolvedOrigin, size: NSSize(width: baseSize.width, height: targetHeight)),
            display: true
        )
    }

    private func rememberDraggedOrigin() {
        guard !suppressMove else { return }
        model.preferences.setCustomOrigin(panel.frame.origin)
    }

    func owns(_ candidate: NSWindow?) -> Bool {
        candidate === panel
    }

    private func originIsVisible(_ origin: NSPoint, size: NSSize) -> Bool {
        let rect = NSRect(origin: origin, size: size)
        return NSScreen.screens.contains { $0.frame.intersects(rect) }
    }
}

final class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }

    var dragsFromContent = false
    var resizesFromEdges = false
    var lockedAspect: CGFloat?
    var resizeMinimum = NSSize(width: 240, height: 80)
    var resizeMaximum = NSSize(width: 1600, height: 1200)
    var onDragFinished: ((NSPoint) -> Void)?
    var onFrameCommit: ((NSRect) -> Void)?
    var extraResizeRect: NSRect?
    private var dragAnchor: NSPoint?
    private var dragOrigin: NSPoint?
    private var didDrag = false
    private var activeResize: ResizeEdge?
    private var resizeStartFrame: NSRect?
    private var resizeStartMouse: NSPoint?
    private var didResize = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            NSApp.activate()
            if !isKeyWindow {
                makeKey()
            }
            if let edge = resizeEdge(at: event.locationInWindow) {
                activeResize = edge
                resizeStartFrame = frame
                resizeStartMouse = NSEvent.mouseLocation
                didResize = false
                return
            }
            if dragsFromContent {
                dragAnchor = NSEvent.mouseLocation
                dragOrigin = frame.origin
                didDrag = false
            }
        }
        if event.type == .leftMouseDragged, activeResize != nil {
            applyResize()
            return
        }
        if event.type == .leftMouseUp, activeResize != nil {
            let resized = didResize
            activeResize = nil
            resizeStartFrame = nil
            resizeStartMouse = nil
            didResize = false
            if resized {
                onFrameCommit?(frame)
            }
            return
        }
        if dragsFromContent, event.type == .leftMouseDragged, let dragAnchor, let dragOrigin {
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - dragAnchor.x
            let dy = mouse.y - dragAnchor.y
            if hypot(dx, dy) >= 3 {
                didDrag = true
                let proposed = NSPoint(x: dragOrigin.x + dx, y: dragOrigin.y + dy)
                let snapped = MainActor.assumeIsolated {
                    AlignmentGuide.shared.snap(self, to: proposed)
                }
                setFrameOrigin(snapped)
                return
            }
        }
        if dragsFromContent, event.type == .leftMouseUp {
            let dragged = didDrag
            let origin = frame.origin
            dragAnchor = nil
            dragOrigin = nil
            didDrag = false
            MainActor.assumeIsolated {
                AlignmentGuide.shared.hide()
            }
            if dragged {
                onDragFinished?(origin)
                onFrameCommit?(frame)
                return
            }
        }
        if event.type == .mouseMoved, let edge = resizeEdge(at: event.locationInWindow) {
            resizeCursor(for: edge).set()
        }
        super.sendEvent(event)
    }

    private func resizeEdge(at point: NSPoint) -> ResizeEdge? {
        guard resizesFromEdges else { return nil }
        let right = point.x >= frame.width - 40
        let bottom = point.y <= 32
        if bottom && right { return .bottomRight }
        if let extraResizeRect, extraResizeRect.contains(point) { return .bottomRight }
        return nil
    }

    private func applyResize() {
        guard let edge = activeResize, let start = resizeStartFrame, let anchor = resizeStartMouse else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - anchor.x
        let dy = mouse.y - anchor.y
        if hypot(dx, dy) < 2, !didResize { return }
        didResize = true
        resizeCursor(for: edge).set()

        let touchesLeft = edge == .left || edge == .topLeft || edge == .bottomLeft
        let touchesRight = edge == .right || edge == .topRight || edge == .bottomRight
        let touchesTop = edge == .top || edge == .topLeft || edge == .topRight
        let touchesBottom = edge == .bottom || edge == .bottomLeft || edge == .bottomRight
        var rect = start

        if let aspectRatio = lockedAspect {
            let widthDelta = touchesLeft ? -dx : (touchesRight ? dx : 0)
            let heightDelta = touchesBottom ? -dy : (touchesTop ? dy : 0)
            var width = start.width
            var height = start.height
            if abs(heightDelta) > abs(widthDelta), touchesTop || touchesBottom {
                height = clamp(start.height + heightDelta, min: resizeMinimum.height, max: resizeMaximum.height)
                width = clamp(height * aspectRatio, min: resizeMinimum.width, max: resizeMaximum.width)
                height = width / aspectRatio
            } else {
                width = clamp(start.width + widthDelta, min: resizeMinimum.width, max: resizeMaximum.width)
                height = clamp(width / aspectRatio, min: resizeMinimum.height, max: resizeMaximum.height)
                width = height * aspectRatio
            }
            rect.size = NSSize(width: width, height: height)
            if touchesLeft {
                rect.origin.x = start.maxX - width
            } else if touchesRight {
                rect.origin.x = start.origin.x
            } else {
                rect.origin.x = start.midX - width / 2
            }
            if touchesBottom {
                rect.origin.y = start.maxY - height
            } else if touchesTop {
                rect.origin.y = start.origin.y
            } else {
                rect.origin.y = start.midY - height / 2
            }
        } else {
            if touchesRight {
                rect.size.width = clamp(start.width + dx, min: resizeMinimum.width, max: resizeMaximum.width)
            }
            if touchesLeft {
                let width = clamp(start.width - dx, min: resizeMinimum.width, max: resizeMaximum.width)
                rect.origin.x = start.maxX - width
                rect.size.width = width
            }
            if touchesTop {
                rect.size.height = clamp(start.height + dy, min: resizeMinimum.height, max: resizeMaximum.height)
            }
            if touchesBottom {
                let height = clamp(start.height - dy, min: resizeMinimum.height, max: resizeMaximum.height)
                rect.origin.y = start.maxY - height
                rect.size.height = height
            }
        }
        setFrame(rect, display: true)
    }

    private func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        Swift.min(upper, Swift.max(lower, value))
    }

    private func resizeCursor(for edge: ResizeEdge) -> NSCursor {
        switch edge {
        case .left, .right:
            .resizeLeftRight
        case .top, .bottom:
            .resizeUpDown
        case .topLeft, .bottomRight:
            .crosshair
        case .topRight, .bottomLeft:
            .crosshair
        }
    }
}

private enum ResizeEdge {
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class ControlContainerView: NSView {
    private let hosting: FirstMouseHostingView<ControlBarView>
    private let model: AppModel
    private let mover: WindowMover
    var onSearchHeight: (CGFloat) -> Void = { _ in }

    init(model: AppModel, mover: WindowMover) {
        self.model = model
        self.mover = mover
        hosting = FirstMouseHostingView(
            rootView: ControlBarView(
                model: model,
                generation: model.generation,
                mover: mover,
                onSearchHeight: { _ in }
            )
        )
        super.init(frame: NSRect(origin: .zero, size: ControlChrome.defaultSize))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render() {
        hosting.rootView = ControlBarView(
            model: model,
            generation: model.generation,
            mover: mover,
            onSearchHeight: onSearchHeight
        )
    }

    override func layout() {
        super.layout()
        hosting.frame = bounds
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
