import AppKit

let canvas: CGFloat = 1024
let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
    let bounds = NSRect(x: 40, y: 40, width: 944, height: 944)
    let background = NSBezierPath(roundedRect: bounds, xRadius: 220, yRadius: 220)
    NSColor(calibratedRed: 0.55, green: 0.16, blue: 0.38, alpha: 1).setFill()
    background.fill()

    let disc = NSBezierPath(ovalIn: NSRect(x: 262, y: 262, width: 500, height: 500))
    NSColor(calibratedWhite: 0.08, alpha: 0.92).setFill()
    disc.fill()

    let hole = NSBezierPath(ovalIn: NSRect(x: 470, y: 470, width: 84, height: 84))
    NSColor(calibratedRed: 0.96, green: 0.78, blue: 0.42, alpha: 1).setFill()
    hole.fill()

    guard let symbol = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil) else {
        return true
    }
    let config = NSImage.SymbolConfiguration(pointSize: 180, weight: .bold)
    guard let rendered = symbol.withSymbolConfiguration(config) else { return true }
    let iconRect = NSRect(x: 422, y: 560, width: 180, height: 180)
    let tinted = NSImage(size: NSSize(width: 180, height: 180), flipped: false) { drawRect in
        NSColor.white.setFill()
        NSBezierPath(rect: drawRect).fill()
        rendered.draw(in: drawRect, from: .zero, operation: .destinationIn, fraction: 1)
        return true
    }
    tinted.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
    return true
}

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else {
    fputs("icon render failed\n", stderr)
    exit(1)
}

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
try png.write(to: URL(fileURLWithPath: output))
