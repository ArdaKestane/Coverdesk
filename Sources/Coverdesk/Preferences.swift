import AppKit
import Observation

enum WallpaperStyle: String, CaseIterable, Identifiable {
    case fill
    case poster

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fill: "Tam kapak"
        case .poster: "Poster"
        }
    }
}

@MainActor
@Observable
final class Preferences {
    var onInterfaceChange: (() -> Void)?
    var onAppearanceChange: (() -> Void)?

    var style: WallpaperStyle {
        didSet { publishAppearance(style != oldValue) }
    }

    var dim: Double {
        didSet { publishAppearance(abs(dim - oldValue) > 0.0001) }
    }

    var allScreens: Bool {
        didSet { publishAppearance(allScreens != oldValue) }
    }

    var restoreOnQuit: Bool {
        didSet { persist() }
    }

    var keepArtworkWhenIdle: Bool {
        didSet { publishAppearance(keepArtworkWhenIdle != oldValue) }
    }

    var controlsVisible: Bool {
        didSet { publishInterface(controlsVisible != oldValue) }
    }

    var floatAboveWindows: Bool {
        didSet { publishInterface(floatAboveWindows != oldValue) }
    }

    var lyricsVisible: Bool {
        didSet { publishInterface(lyricsVisible != oldValue) }
    }

    var searchScope: SearchScope {
        didSet {
            guard searchScope != oldValue else { return }
            persist()
        }
    }

    private(set) var customOrigin: NSPoint?
    private(set) var lyricsOrigin: NSPoint?
    private(set) var controlSize: NSSize
    private(set) var lyricsSize: NSSize

    private enum Key {
        static let style = "coverdesk.style"
        static let dim = "coverdesk.dim"
        static let allScreens = "coverdesk.allScreens"
        static let restoreOnQuit = "coverdesk.restoreOnQuit"
        static let keepArtworkWhenIdle = "coverdesk.keepArtworkWhenIdle"
        static let controlsVisible = "coverdesk.controlsVisible"
        static let floatAboveWindows = "coverdesk.floatAboveWindows"
        static let lyricsVisible = "coverdesk.lyricsVisible"
        static let hasOrigin = "coverdesk.hasOrigin"
        static let originX = "coverdesk.originX"
        static let originY = "coverdesk.originY"
        static let hasLyricsOrigin = "coverdesk.lyricsHasOrigin"
        static let lyricsOriginX = "coverdesk.lyricsOriginX"
        static let lyricsOriginY = "coverdesk.lyricsOriginY"
        static let controlWidth = "coverdesk.controlWidth"
        static let controlHeight = "coverdesk.controlHeight"
        static let lyricsWidth = "coverdesk.lyricsWidth"
        static let lyricsHeight = "coverdesk.lyricsHeight"
        static let searchScope = "coverdesk.searchScope"
    }

    init() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "coverdesk.layoutV2") == false {
            defaults.set(true, forKey: "coverdesk.layoutV2")
            defaults.set(false, forKey: Key.hasOrigin)
            defaults.set(false, forKey: Key.floatAboveWindows)
        }
        if defaults.bool(forKey: "coverdesk.layoutV3") == false {
            defaults.set(true, forKey: "coverdesk.layoutV3")
            defaults.set(false, forKey: Key.hasOrigin)
        }
        if defaults.bool(forKey: "coverdesk.layoutV4") == false {
            defaults.set(true, forKey: "coverdesk.layoutV4")
            Self.fitLyricsColumn(defaults)
        }
        if defaults.bool(forKey: "coverdesk.layoutV5") == false {
            defaults.set(true, forKey: "coverdesk.layoutV5")
            Self.fitLyricsColumn(defaults)
        }
        style = WallpaperStyle(rawValue: defaults.string(forKey: Key.style) ?? "") ?? .fill
        dim = (defaults.object(forKey: Key.dim) as? Double).map { min(0.55, max(0, $0)) } ?? 0.12
        allScreens = defaults.object(forKey: Key.allScreens) as? Bool ?? true
        restoreOnQuit = defaults.object(forKey: Key.restoreOnQuit) as? Bool ?? true
        keepArtworkWhenIdle = defaults.object(forKey: Key.keepArtworkWhenIdle) as? Bool ?? true
        controlsVisible = defaults.object(forKey: Key.controlsVisible) as? Bool ?? true
        floatAboveWindows = defaults.object(forKey: Key.floatAboveWindows) as? Bool ?? false
        lyricsVisible = defaults.object(forKey: Key.lyricsVisible) as? Bool ?? false
        searchScope = SearchScope(rawValue: defaults.string(forKey: Key.searchScope) ?? "") ?? .library
        if defaults.bool(forKey: Key.hasOrigin),
           let x = defaults.object(forKey: Key.originX) as? Double,
           let y = defaults.object(forKey: Key.originY) as? Double {
            customOrigin = NSPoint(x: x, y: y)
        }
        if defaults.bool(forKey: Key.hasLyricsOrigin),
           let x = defaults.object(forKey: Key.lyricsOriginX) as? Double,
           let y = defaults.object(forKey: Key.lyricsOriginY) as? Double {
            lyricsOrigin = NSPoint(x: x, y: y)
        }
        controlSize = Self.storedSize(
            defaults: defaults,
            widthKey: Key.controlWidth,
            heightKey: Key.controlHeight,
            fallback: ControlChrome.defaultSize
        )
        lyricsSize = Self.storedSize(
            defaults: defaults,
            widthKey: Key.lyricsWidth,
            heightKey: Key.lyricsHeight,
            fallback: LyricsChrome.defaultSize
        )
    }

    func setControlSize(_ size: NSSize) {
        controlSize = size
        let defaults = UserDefaults.standard
        defaults.set(size.width, forKey: Key.controlWidth)
        defaults.set(size.height, forKey: Key.controlHeight)
    }

    /// Keeps the chosen height and the horizontal center, then drops the extra side width.
    private static func fitLyricsColumn(_ defaults: UserDefaults) {
        guard let width = defaults.object(forKey: Key.lyricsWidth) as? Double,
              let height = defaults.object(forKey: Key.lyricsHeight) as? Double,
              width > 40, height > 40
        else { return }
        let aspect = LyricsChrome.aspectRatio
        var fittedWidth = height * aspect
        var fittedHeight = height
        if fittedWidth > LyricsChrome.maximumSize.width {
            fittedWidth = LyricsChrome.maximumSize.width
            fittedHeight = fittedWidth / aspect
        } else if fittedWidth < LyricsChrome.minimumSize.width {
            fittedWidth = LyricsChrome.minimumSize.width
            fittedHeight = fittedWidth / aspect
        }
        defaults.set(fittedWidth, forKey: Key.lyricsWidth)
        defaults.set(fittedHeight, forKey: Key.lyricsHeight)
        guard defaults.bool(forKey: Key.hasLyricsOrigin),
              let x = defaults.object(forKey: Key.lyricsOriginX) as? Double,
              let y = defaults.object(forKey: Key.lyricsOriginY) as? Double
        else { return }
        let centerX = x + width / 2
        var originX = centerX - fittedWidth / 2
        var originY = y + (height - fittedHeight) / 2
        let probe = NSPoint(x: centerX, y: originY + fittedHeight / 2)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(probe) }) ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            originX = min(max(originX, frame.minX), max(frame.minX, frame.maxX - fittedWidth))
            originY = min(max(originY, frame.minY), max(frame.minY, frame.maxY - fittedHeight))
        }
        defaults.set(originX, forKey: Key.lyricsOriginX)
        defaults.set(originY, forKey: Key.lyricsOriginY)
    }

    func setLyricsSize(_ size: NSSize) {
        lyricsSize = size
        let defaults = UserDefaults.standard
        defaults.set(size.width, forKey: Key.lyricsWidth)
        defaults.set(size.height, forKey: Key.lyricsHeight)
    }

    private static func storedSize(
        defaults: UserDefaults,
        widthKey: String,
        heightKey: String,
        fallback: NSSize
    ) -> NSSize {
        guard let width = defaults.object(forKey: widthKey) as? Double,
              let height = defaults.object(forKey: heightKey) as? Double,
              width > 40, height > 40
        else { return fallback }
        return NSSize(width: width, height: height)
    }

    func setCustomOrigin(_ origin: NSPoint) {
        customOrigin = origin
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: Key.hasOrigin)
        defaults.set(origin.x, forKey: Key.originX)
        defaults.set(origin.y, forKey: Key.originY)
    }

    func setLyricsOrigin(_ origin: NSPoint) {
        lyricsOrigin = origin
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: Key.hasLyricsOrigin)
        defaults.set(origin.x, forKey: Key.lyricsOriginX)
        defaults.set(origin.y, forKey: Key.lyricsOriginY)
    }

    func clearCustomOrigin() {
        customOrigin = nil
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: Key.hasOrigin)
        defaults.removeObject(forKey: Key.originX)
        defaults.removeObject(forKey: Key.originY)
        onInterfaceChange?()
    }

    private func publishAppearance(_ changed: Bool) {
        guard changed else { return }
        persist()
        onAppearanceChange?()
    }

    private func publishInterface(_ changed: Bool) {
        guard changed else { return }
        persist()
        onInterfaceChange?()
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(style.rawValue, forKey: Key.style)
        defaults.set(dim, forKey: Key.dim)
        defaults.set(allScreens, forKey: Key.allScreens)
        defaults.set(restoreOnQuit, forKey: Key.restoreOnQuit)
        defaults.set(keepArtworkWhenIdle, forKey: Key.keepArtworkWhenIdle)
        defaults.set(controlsVisible, forKey: Key.controlsVisible)
        defaults.set(floatAboveWindows, forKey: Key.floatAboveWindows)
        defaults.set(lyricsVisible, forKey: Key.lyricsVisible)
        defaults.set(searchScope.rawValue, forKey: Key.searchScope)
    }
}
