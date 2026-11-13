import AppKit

@MainActor
final class WindowMover {
    weak var window: NSWindow?
    var onEnd: ((NSPoint) -> Void)?
    var onScaleAnchor: ((NSRect) -> Void)?
    private var origin: NSPoint?
    private var anchor: NSPoint?
    private var moved = false
    private var suppressTap = false

    func track(translation _: CGSize) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        if origin == nil || anchor == nil {
            origin = window.frame.origin
            anchor = mouse
        }
        guard let origin, let anchor else { return }
        let dx = mouse.x - anchor.x
        let dy = mouse.y - anchor.y
        guard hypot(dx, dy) >= 4 else { return }
        moved = true
        let proposed = NSPoint(x: origin.x + dx, y: origin.y + dy)
        window.setFrameOrigin(AlignmentGuide.shared.snap(window, to: proposed))
    }

    func reportScaleAnchor(_ rect: NSRect) {
        onScaleAnchor?(rect)
    }

    func consumeTap() -> Bool {
        !moved && !suppressTap
    }

    func finish() {
        if moved, let origin = window?.frame.origin {
            onEnd?(origin)
        }
        let didMove = moved
        origin = nil
        anchor = nil
        moved = false
        AlignmentGuide.shared.hide()
        guard didMove else { return }
        suppressTap = true
        Task { @MainActor in
            self.suppressTap = false
        }
    }
}
