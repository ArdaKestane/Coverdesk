import AppKit

struct AlignmentMark: Equatable {
    enum Axis: Equatable {
        case vertical
        case horizontal
    }

    var axis: Axis
    var position: CGFloat
    var emphasized: Bool
}

enum AlignmentAnchor {
    /// Snap the window's edges and its center.
    case bounds
    /// Snap only the window's center, so the lyrics container itself lines up with the screen.
    case center
}

@MainActor
final class AlignmentGuide {
    static let shared = AlignmentGuide()

    private let attract: CGFloat = 12
    private let release: CGFloat = 18
    private var windows: [NSWindow] = []
    private var anchors: [ObjectIdentifier: AlignmentAnchor] = [:]
    private var heldX: Hold?
    private var heldY: Hold?
    private var showing = false
    private let panel = GuidePanel()
    private let canvas = GuideCanvas()

    private init() {
        panel.contentView = canvas
        canvas.autoresizingMask = [.width, .height]
    }

    func register(_ window: NSWindow, anchor: AlignmentAnchor = .bounds) {
        anchors[ObjectIdentifier(window)] = anchor
        guard !windows.contains(where: { $0 === window }) else { return }
        windows.append(window)
    }

    func snap(_ window: NSWindow, to proposed: NSPoint) -> NSPoint {
        let size = window.frame.size
        let proposedFrame = NSRect(origin: proposed, size: size)
        guard let screen = screen(containing: proposedFrame) else { return proposed }
        let siblings = windows.filter { other in
            other !== window && other.isVisible && screen.frame.intersects(other.frame)
        }
        let centerOnly = anchors[ObjectIdentifier(window)] == .center
        let x = resolve(
            raw: proposed.x,
            held: &heldX,
            candidates: xCandidates(size: size, screen: screen, siblings: siblings, centerOnly: centerOnly)
        )
        let y = resolve(
            raw: proposed.y,
            held: &heldY,
            candidates: yCandidates(size: size, screen: screen, siblings: siblings, centerOnly: centerOnly)
        )
        present(xGuide: x.guide, yGuide: y.guide, on: screen)
        return NSPoint(x: x.origin, y: y.origin)
    }

    func hide() {
        heldX = nil
        heldY = nil
        showing = false
        panel.orderOut(nil)
    }

    private func xCandidates(
        size: NSSize,
        screen: NSScreen,
        siblings: [NSWindow],
        centerOnly: Bool
    ) -> [Candidate] {
        var items = [
            Candidate(origin: screen.frame.midX - size.width / 2, guide: screen.frame.midX, prefersCenter: true)
        ]
        for sibling in siblings {
            let frame = sibling.frame
            items.append(Candidate(origin: frame.midX - size.width / 2, guide: frame.midX, prefersCenter: true))
            if centerOnly || anchors[ObjectIdentifier(sibling)] == .center { continue }
            items.append(Candidate(origin: frame.minX, guide: frame.minX, prefersCenter: false))
            items.append(Candidate(origin: frame.maxX - size.width, guide: frame.maxX, prefersCenter: false))
        }
        return items
    }

    private func yCandidates(
        size: NSSize,
        screen: NSScreen,
        siblings: [NSWindow],
        centerOnly: Bool
    ) -> [Candidate] {
        var items = [
            Candidate(origin: screen.frame.midY - size.height / 2, guide: screen.frame.midY, prefersCenter: true)
        ]
        if !centerOnly {
            let dockInset = screen.visibleFrame.minY - screen.frame.minY
            let clearance = max(dockInset + 18, ControlChrome.dockClearance)
            items.append(Candidate(origin: screen.frame.minY + clearance, guide: screen.frame.minY + clearance, prefersCenter: false))
        }
        for sibling in siblings {
            let frame = sibling.frame
            items.append(Candidate(origin: frame.midY - size.height / 2, guide: frame.midY, prefersCenter: true))
            if centerOnly || anchors[ObjectIdentifier(sibling)] == .center { continue }
            items.append(Candidate(origin: frame.minY, guide: frame.minY, prefersCenter: false))
            items.append(Candidate(origin: frame.maxY - size.height, guide: frame.maxY, prefersCenter: false))
        }
        return items
    }

    private func resolve(raw: CGFloat, held: inout Hold?, candidates: [Candidate]) -> (origin: CGFloat, guide: CGFloat?) {
        if let held, abs(raw - held.origin) <= release {
            return (held.origin, held.guide)
        }
        let best = candidates.min { lhs, rhs in
            let left = abs(lhs.origin - raw) - (lhs.prefersCenter ? 6 : 0)
            let right = abs(rhs.origin - raw) - (rhs.prefersCenter ? 6 : 0)
            return left < right
        }
        if let best, abs(best.origin - raw) <= attract {
            held = Hold(origin: best.origin, guide: best.guide)
            return (best.origin, best.guide)
        }
        held = nil
        return (raw, nil)
    }

    private func present(xGuide: CGFloat?, yGuide: CGFloat?, on screen: NSScreen) {
        var marks = [
            AlignmentMark(axis: .vertical, position: screen.frame.midX, emphasized: xGuide == screen.frame.midX),
            AlignmentMark(axis: .horizontal, position: screen.frame.midY, emphasized: yGuide == screen.frame.midY)
        ]
        if let xGuide, xGuide != screen.frame.midX {
            marks.append(AlignmentMark(axis: .vertical, position: xGuide, emphasized: true))
        }
        if let yGuide, yGuide != screen.frame.midY {
            marks.append(AlignmentMark(axis: .horizontal, position: yGuide, emphasized: true))
        }
        if panel.frame != screen.frame {
            panel.setFrame(screen.frame, display: false)
        }
        canvas.screenOrigin = screen.frame.origin
        canvas.marks = marks
        guard !showing else { return }
        panel.orderFrontRegardless()
        showing = true
    }

    private func screen(containing frame: NSRect) -> NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        if let match = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return match
        }
        return NSScreen.screens.max { lhs, rhs in
            let left = lhs.frame.intersection(frame)
            let right = rhs.frame.intersection(frame)
            return left.width * left.height < right.width * right.height
        }
    }
}

private struct Hold {
    var origin: CGFloat
    var guide: CGFloat
}

private struct Candidate {
    var origin: CGFloat
    var guide: CGFloat
    var prefersCenter: Bool
}

private final class GuidePanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)) - 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class GuideCanvas: NSView {
    var screenOrigin = NSPoint.zero {
        didSet { needsDisplay = true }
    }
    var marks: [AlignmentMark] = [] {
        didSet {
            guard marks != oldValue else { return }
            needsDisplay = true
        }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for mark in marks {
            let width: CGFloat = mark.emphasized ? 1.25 : 1
            let start: CGPoint
            let end: CGPoint
            switch mark.axis {
            case .vertical:
                let x = (mark.position - screenOrigin.x).rounded() + 0.5
                start = CGPoint(x: x, y: 0)
                end = CGPoint(x: x, y: bounds.height)
            case .horizontal:
                let y = (mark.position - screenOrigin.y).rounded() + 0.5
                start = CGPoint(x: 0, y: y)
                end = CGPoint(x: bounds.width, y: y)
            }
            context.setStrokeColor(NSColor.black.withAlphaComponent(mark.emphasized ? 0.45 : 0.22).cgColor)
            context.setLineWidth(width + 1.6)
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
            context.setStrokeColor(NSColor.white.withAlphaComponent(mark.emphasized ? 0.96 : 0.38).cgColor)
            context.setLineWidth(width)
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
        }
    }
}
