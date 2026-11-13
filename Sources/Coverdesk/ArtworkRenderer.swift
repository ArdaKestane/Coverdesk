import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ScreenRenderSpec: Sendable, Equatable {
    var displayID: UInt32
    var pixelWidth: Int
    var pixelHeight: Int
}

enum ImageDecoding {
    static func cgImage(from data: Data, maxPixelSize: Int = 4500) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            if width > 0, height > 0, max(width, height) <= maxPixelSize {
                return CGImageSourceCreateImageAtIndex(source, 0, nil)
            }
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

enum ArtworkRenderer {
    static let renderQueue = DispatchQueue(label: "com.coverdesk.render")
    private static let blurContext = CIContext(options: [.cacheIntermediates: false])

    static func jpeg(
        artwork: CGImage,
        spec: ScreenRenderSpec,
        style: WallpaperStyle,
        dim: CGFloat
    ) -> Data? {
        guard spec.pixelWidth > 10, spec.pixelHeight > 10 else { return nil }
        guard let context = CGContext(
            data: nil,
            width: spec.pixelWidth,
            height: spec.pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let canvas = CGRect(x: 0, y: 0, width: spec.pixelWidth, height: spec.pixelHeight)
        context.interpolationQuality = .high
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(canvas)

        switch style {
        case .fill:
            drawFittedCover(artwork, in: context, canvas: canvas)
        case .poster:
            if let background = blurredFill(artwork, pixelWidth: min(1400, spec.pixelWidth)) {
                drawAspectFill(background, in: context, canvas: canvas)
            } else {
                drawAspectFill(artwork, in: context, canvas: canvas)
            }
            context.setFillColor(CGColor(gray: 0, alpha: 0.28))
            context.fill(canvas)
            drawPosterCover(artwork, in: context, canvas: canvas)
            drawVignette(in: context, canvas: canvas)
        }

        if dim > 0.001 {
            context.setFillColor(CGColor(gray: 0, alpha: dim))
            context.fill(canvas)
        }
        drawBottomShade(in: context, canvas: canvas, alpha: style == .fill ? 0.28 : 0.45)

        guard let image = context.makeImage() else { return nil }
        return jpegData(from: image, quality: 0.92)
    }

    private static func drawFittedCover(_ image: CGImage, in context: CGContext, canvas: CGRect) {
        if let background = blurredFill(image, pixelWidth: min(1600, Int(canvas.width))) {
            drawAspectFill(background, in: context, canvas: canvas)
        } else {
            drawAspectFill(image, in: context, canvas: canvas)
        }
        context.setFillColor(CGColor(gray: 0, alpha: 0.2))
        context.fill(canvas)

        let artSize = CGSize(width: image.width, height: image.height)
        guard artSize.width > 0, artSize.height > 0 else { return }
        let inset = min(canvas.width, canvas.height) * 0.04
        let available = canvas.insetBy(dx: inset, dy: inset)
        let scale = min(available.width / artSize.width, available.height / artSize.height)
        let drawSize = CGSize(width: artSize.width * scale, height: artSize.height * scale)
        let rect = CGRect(
            x: canvas.midX - drawSize.width / 2,
            y: canvas.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        context.saveGState()
        context.interpolationQuality = .high
        context.setShadow(offset: CGSize(width: 0, height: -12), blur: 36, color: CGColor(gray: 0, alpha: 0.35))
        context.draw(image, in: rect)
        context.restoreGState()
    }

    private static func drawAspectFill(_ image: CGImage, in context: CGContext, canvas: CGRect) {
        let artSize = CGSize(width: image.width, height: image.height)
        guard artSize.width > 0, artSize.height > 0 else { return }
        let scale = max(canvas.width / artSize.width, canvas.height / artSize.height)
        let drawSize = CGSize(width: artSize.width * scale, height: artSize.height * scale)
        let rect = CGRect(
            x: canvas.midX - drawSize.width / 2,
            y: canvas.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        context.draw(image, in: rect)
    }

    private static func drawPosterCover(_ image: CGImage, in context: CGContext, canvas: CGRect) {
        let side = min(canvas.width, canvas.height) * 0.62
        let rect = CGRect(
            x: canvas.midX - side / 2,
            y: canvas.midY - side / 2,
            width: side,
            height: side
        )
        let radius = side * 0.045
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -side * 0.015),
            blur: side * 0.06,
            color: CGColor(gray: 0, alpha: 0.55)
        )
        context.addPath(path)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(path)
        context.clip()
        drawAspectFill(image, in: context, canvas: rect)
        context.restoreGState()

        context.saveGState()
        context.addPath(path)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.22))
        context.setLineWidth(max(2, side * 0.004))
        context.strokePath()
        context.restoreGState()
    }

    private static func drawVignette(in context: CGContext, canvas: CGRect) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(gray: 0, alpha: 0),
                CGColor(gray: 0, alpha: 0.34),
            ] as CFArray,
            locations: [0, 1]
        ) else { return }
        let radius = max(canvas.width, canvas.height) * 0.72
        context.drawRadialGradient(
            gradient,
            startCenter: CGPoint(x: canvas.midX, y: canvas.midY),
            startRadius: min(canvas.width, canvas.height) * 0.28,
            endCenter: CGPoint(x: canvas.midX, y: canvas.midY),
            endRadius: radius,
            options: []
        )
    }

    private static func drawBottomShade(in context: CGContext, canvas: CGRect, alpha: CGFloat) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(gray: 0, alpha: alpha),
                CGColor(gray: 0, alpha: 0),
            ] as CFArray,
            locations: [0, 1]
        ) else { return }
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: canvas.midX, y: 0),
            end: CGPoint(x: canvas.midX, y: canvas.height * 0.2),
            options: []
        )
    }

    private static func blurredFill(_ image: CGImage, pixelWidth: Int) -> CGImage? {
        let aspect = CGFloat(image.height) / CGFloat(max(image.width, 1))
        let width = max(pixelWidth, 64)
        let height = max(Int(CGFloat(width) * aspect), 64)
        guard let small = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        small.interpolationQuality = .medium
        small.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = small.makeImage() else { return nil }

        let input = CIImage(cgImage: scaled).clampedToExtent()
        let blurred = input
            .applyingGaussianBlur(sigma: 26)
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        return blurContext.createCGImage(blurred, from: blurred.extent)
    }

    private static func jpegData(from image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
