import AppKit

let width: CGFloat = 680
let height: CGFloat = 400
let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
    NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.10, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()

    let arrow = NSBezierPath()
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 268, y: 214))
    arrow.line(to: NSPoint(x: 398, y: 214))
    arrow.move(to: NSPoint(x: 378, y: 232))
    arrow.line(to: NSPoint(x: 400, y: 214))
    arrow.line(to: NSPoint(x: 378, y: 196))
    NSColor.white.withAlphaComponent(0.55).setStroke()
    arrow.stroke()

    let title = "Uygulamalar klasörüne sürükleyin"
    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.88)
    ]
    let titleSize = title.size(withAttributes: titleAttrs)
    title.draw(
        at: NSPoint(x: (width - titleSize.width) / 2, y: 78),
        withAttributes: titleAttrs
    )

    let note = "macOS 14 veya daha yenisi"
    let noteAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .regular),
        .foregroundColor: NSColor.white.withAlphaComponent(0.42)
    ]
    let noteSize = note.size(withAttributes: noteAttrs)
    note.draw(
        at: NSPoint(x: (width - noteSize.width) / 2, y: 54),
        withAttributes: noteAttrs
    )
    return true
}

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else {
    fputs("background render failed\n", stderr)
    exit(1)
}

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "background.png"
try png.write(to: URL(fileURLWithPath: output))
