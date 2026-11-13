import AppKit

@MainActor
final class DesktopFadeController {
    private var windows: [UInt32: FadeWindow] = [:]

    func crossfade(_ files: [RenderedWallpaper]) {
        for file in files {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == file.displayID }) else { continue }
            let window = windows[file.displayID] ?? FadeWindow()
            windows[file.displayID] = window
            window.crossfade(to: URL(fileURLWithPath: file.filePath), on: screen)
        }
    }

    func hide() {
        for window in windows.values {
            window.orderOut(nil)
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
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        animationBehavior = .none
        contentView = NSView()
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

    private func dropFinishedLayers() {
        guard let current else { return }
        for subview in contentView?.subviews ?? [] where subview !== current {
            subview.removeFromSuperview()
        }
    }
}
