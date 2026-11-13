import Foundation

enum ControlChrome {
    static let baseWidth: CGFloat = 420
    static let baseHeight: CGFloat = 104
    static let defaultScale: CGFloat = 1.25
    /// Auto-hidden Dock still covers the bottom edge when it appears.
    static let dockClearance: CGFloat = 118

    static var defaultSize: NSSize {
        NSSize(width: baseWidth * defaultScale, height: baseHeight * defaultScale)
    }

    static var aspectRatio: CGFloat { baseWidth / baseHeight }
}
