import AppKit
import CoreGraphics

extension NSScreen {
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = deviceDescription[key] as? NSNumber {
            return number.uint32Value
        }
        return 0
    }

    var displayUUIDString: String? {
        let id = displayID
        guard id != 0, let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String
    }

    var renderSpec: ScreenRenderSpec {
        let displayID = displayID
        var pixelWidth = Int(CGDisplayPixelsWide(displayID))
        var pixelHeight = Int(CGDisplayPixelsHigh(displayID))
        if pixelWidth <= 1 || pixelHeight <= 1 {
            let scale = backingScaleFactor
            pixelWidth = max(1, Int((frame.width * scale).rounded()))
            pixelHeight = max(1, Int((frame.height * scale).rounded()))
        }
        let longest = max(pixelWidth, pixelHeight)
        let limit = 7680
        if longest > limit {
            let scale = Double(limit) / Double(longest)
            pixelWidth = max(1, Int((Double(pixelWidth) * scale).rounded()))
            pixelHeight = max(1, Int((Double(pixelHeight) * scale).rounded()))
        }
        return ScreenRenderSpec(displayID: displayID, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }
}
