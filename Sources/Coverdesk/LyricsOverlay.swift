import AppKit
import SwiftUI

enum LyricsChrome {
    static let radius = 5
    static let baseRowHeight: CGFloat = 54
    /// Room for a long line at the base font size. Extra width only adds empty side space.
    static let columnWidth: CGFloat = 300
    static let sideInset: CGFloat = 24
    static var baseWidth: CGFloat { columnWidth + sideInset * 2 }
    static var baseHeight: CGFloat { baseRowHeight * CGFloat(radius * 2 + 1) + 16 }
    static var aspectRatio: CGFloat { baseWidth / baseHeight }

    static var defaultSize: NSSize {
        NSSize(width: baseWidth, height: baseHeight)
    }

    static var minimumSize: NSSize {
        let width: CGFloat = 320
        return NSSize(width: width, height: width / aspectRatio)
    }

    static var maximumSize: NSSize {
        let width: CGFloat = 760
        return NSSize(width: width, height: width / aspectRatio)
    }
}

@MainActor
final class LyricsOverlayController {
    private let model: AppModel
    private let window: FloatingPanel
    private let hosting: FirstMouseHostingView<LyricsOverlayView>
    private var rendered = ""
    private var suppressMove = false

    init(model: AppModel) {
        self.model = model
        hosting = FirstMouseHostingView(
            rootView: LyricsOverlayView(model: model, generation: model.generation)
        )
        window = FloatingPanel(contentRect: NSRect(origin: .zero, size: model.preferences.lyricsSize))
        window.dragsFromContent = true
        window.resizesFromEdges = true
        window.lockedAspect = LyricsChrome.aspectRatio
        window.resizeMinimum = LyricsChrome.minimumSize
        window.resizeMaximum = LyricsChrome.maximumSize
        window.acceptsMouseMovedEvents = true
        window.onFrameCommit = { [weak model] rect in
            model?.preferences.setLyricsOrigin(rect.origin)
            model?.preferences.setLyricsSize(rect.size)
        }
        AlignmentGuide.shared.register(window, anchor: .center)
        window.contentView = hosting
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)) - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = false
        window.becomesKeyOnlyIfNeeded = false
        window.isFloatingPanel = true
        window.animationBehavior = .none
        hosting.autoresizingMask = [.width, .height]
        hosting.clipsToBounds = false
    }

    func apply() {
        updateLevel()
        refresh()
        guard window.isVisible else { return }
        reposition()
    }

    func refresh() {
        let show = model.preferences.lyricsVisible && !model.lyrics.lines.isEmpty
        window.resizesFromEdges = show
        guard show else {
            rendered = ""
            if window.isVisible { window.orderOut(nil) }
            return
        }
        let reveal = !window.isVisible
        let signature = "\(model.trackID)|\(model.lyrics.lines.count)|\(model.lyricsResolved)|\(model.clock.isPlaying)"
        if signature != rendered {
            rendered = signature
            hosting.rootView = LyricsOverlayView(model: model, generation: model.generation)
        }
        guard reveal else { return }
        updateLevel()
        reposition()
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }

    func owns(_ candidate: NSWindow?) -> Bool {
        candidate === window
    }

    private func updateLevel() {
        if model.preferences.floatAboveWindows {
            window.level = .floating
        } else {
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)) - 1)
        }
    }

    private func reposition() {
        suppressMove = true
        defer { suppressMove = false }
        let size = model.preferences.lyricsSize
        if let origin = model.preferences.lyricsOrigin, originIsVisible(origin, size: size) {
            window.setFrame(NSRect(origin: origin, size: size), display: true)
            return
        }
        guard let screen = NSScreen.screens.first else { return }
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func originIsVisible(_ origin: NSPoint, size: NSSize) -> Bool {
        let rect = NSRect(origin: origin, size: size)
        return NSScreen.screens.contains { screen in
            let visible = screen.visibleFrame.intersection(rect)
            return visible.width >= size.width * 0.96 && visible.height >= size.height * 0.96
        }
    }
}

struct LyricsOverlayView: View {
    var model: AppModel
    var generation: Int

    var body: some View {
        let _ = generation
        GeometryReader { geo in
            let rows = CGFloat(LyricsChrome.radius * 2 + 1)
            let rowHeight = max(28, (geo.size.height - 16) / rows)
            let fontScale = geo.size.width / LyricsChrome.baseWidth
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !model.clock.isPlaying)) { timeline in
                lyrics(at: model.clock.elapsed(at: timeline.date), rowHeight: rowHeight, fontScale: fontScale, viewport: geo.size.height)
            }
        }
        .overlay {
            if !model.lyrics.lines.isEmpty {
                CornerHandles()
            }
        }
    }

    @ViewBuilder
    private func lyrics(at elapsed: TimeInterval, rowHeight: CGFloat, fontScale: CGFloat, viewport: CGFloat) -> some View {
        if model.lyrics.lines.isEmpty {
            if model.lyricsResolved {
                Text("Bu parça için söz bulunamadı")
                    .font(.system(size: 18 * fontScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .shadow(color: .black.opacity(0.7), radius: 10, y: 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            let lines = model.lyrics.lines
            let current = model.lyrics.index(at: elapsed)
            let focus = restingFocus(current: current, count: lines.count)
            let travel = viewport / 2 - (CGFloat(focus) + 0.5) * rowHeight
            VStack(spacing: 0) {
                ForEach(lines.indices, id: \.self) { index in
                    let distance = index - current
                    let lineEnd = index + 1 < lines.count ? lines[index + 1].time : lines[index].time + 4
                    LyricRow(
                        line: lines[index],
                        lineEnd: lineEnd,
                        elapsed: distance == 0 && model.lyrics.isSynced ? elapsed : nil,
                        distance: distance,
                        rowHeight: rowHeight,
                        fontScale: fontScale,
                        onSeek: { model.seek(to: lines[index].time) }
                    )
                }
            }
            .offset(y: travel)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: focus)
        }
    }

    /// The line that sits in the middle of the container. The active line stays put until it
    /// reaches that middle, so the opening lines fill the window instead of hanging below center.
    private func restingFocus(current: Int, count: Int) -> Int {
        let lead = LyricsChrome.radius
        guard count > 1 else { return 0 }
        if count <= lead * 2 + 1 { return (count - 1) / 2 }
        return min(max(current, lead), count - 1 - lead)
    }
}

private struct LyricRow: View {
    var line: LyricLine
    var lineEnd: TimeInterval
    var elapsed: TimeInterval?
    var distance: Int
    var rowHeight: CGFloat
    var fontScale: CGFloat
    var onSeek: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onSeek) {
            lineText
                .font(.system(size: 28 * fontScale, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .shadow(color: .black.opacity(distance == 0 ? 0.7 : 0.45), radius: distance == 0 ? 8 : 4, y: 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, LyricsChrome.sideInset * fontScale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(height: rowHeight)
        .scaleEffect(scale, anchor: .center)
        .opacity(rowOpacity)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: distance)
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .accessibilityLabel(line.text)
    }

    private var scale: CGFloat {
        switch abs(distance) {
        case 0: 1
        case 1: 0.8
        case 2: 0.66
        case 3: 0.56
        default: 0.48
        }
    }

    private var rowOpacity: Double {
        let base: Double
        switch abs(distance) {
        case 0: base = 1
        case 1: base = 0.72
        case 2: base = 0.4
        case 3: base = 0.24
        default: base = 0.12
        }
        return isHovering ? min(1, base + 0.16) : base
    }

    @ViewBuilder
    private var lineText: some View {
        if let elapsed {
            karaoke(line.spokenWords(until: lineEnd), elapsed: elapsed)
        } else {
            Text(line.text)
                .foregroundStyle(.white)
        }
    }

    private func karaoke(
        _ words: [(text: String, start: TimeInterval, end: TimeInterval)],
        elapsed: TimeInterval
    ) -> Text {
        let vocalElapsed = elapsed + 0.14
        return words.enumerated().reduce(Text("")) { partial, item in
            let gap = item.offset == 0 ? "" : " "
            let amount = wordProgress(elapsed: vocalElapsed, start: item.element.start, end: item.element.end)
            return partial + Text(gap + item.element.text)
                .foregroundStyle(Color.white.opacity(0.44 + 0.56 * amount))
        }
    }

    private func wordProgress(elapsed: TimeInterval, start: TimeInterval, end: TimeInterval) -> Double {
        if elapsed >= end { return 1 }
        if elapsed <= start { return 0 }
        let span = max(0.05, end - start)
        let t = min(1, max(0, (elapsed - start) / span))
        let inv = 1 - t
        return 1 - inv * inv
    }
}
