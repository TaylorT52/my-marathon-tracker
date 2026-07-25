import AppKit

struct Screenshot {
    let source: String
    let output: String
    let headline: String
    let subtitle: String
    let background: NSColor
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let warm = NSColor(red: 1, green: 0.953, blue: 0.925, alpha: 1)
let screenshots = [
    Screenshot(
        source: "Raw/04-watch-race.png",
        output: "Final/04-watch-live.png",
        headline: "Cheer from anywhere",
        subtitle: "Watch live — no account needed",
        background: warm
    )
]

let canvasSize = NSSize(width: 1_284, height: 2_778)
let appRect = NSRect(x: 129, y: 64, width: 1_026, height: 2_223)
let ink = NSColor(red: 0.08, green: 0.10, blue: 0.16, alpha: 1)
let muted = NSColor(red: 0.39, green: 0.42, blue: 0.50, alpha: 1)
let orange = NSColor(red: 1, green: 0.35, blue: 0.12, alpha: 1)

func centeredOrigin(for text: NSAttributedString, top: CGFloat) -> NSPoint {
    let size = text.size()
    return NSPoint(
        x: (canvasSize.width - size.width) / 2,
        y: canvasSize.height - top - size.height
    )
}

for screenshot in screenshots {
    let sourceURL = root.appendingPathComponent(screenshot.source)
    let outputURL = root.appendingPathComponent(screenshot.output)
    guard let sourceImage = NSImage(contentsOf: sourceURL) else {
        fatalError("Could not load \(sourceURL.path)")
    }
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(canvasSize.width),
        pixelsHigh: Int(canvasSize.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Could not create the screenshot canvas.")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    screenshot.background.setFill()
    NSRect(origin: .zero, size: canvasSize).fill()
    orange.setFill()
    NSRect(x: 0, y: canvasSize.height - 22, width: canvasSize.width, height: 22).fill()

    let headline = NSAttributedString(
        string: screenshot.headline,
        attributes: [
            .font: NSFont.systemFont(ofSize: 82, weight: .heavy),
            .foregroundColor: ink
        ]
    )
    headline.draw(at: centeredOrigin(for: headline, top: 105))

    let subtitle = NSAttributedString(
        string: screenshot.subtitle,
        attributes: [
            .font: NSFont.systemFont(ofSize: 43, weight: .medium),
            .foregroundColor: muted
        ]
    )
    subtitle.draw(at: centeredOrigin(for: subtitle, top: 245))

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = ink.withAlphaComponent(0.16)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.set()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: appRect, xRadius: 34, yRadius: 34).fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: appRect, xRadius: 34, yRadius: 34).addClip()
    sourceImage.draw(
        in: appRect,
        from: NSRect(origin: .zero, size: sourceImage.size),
        operation: .sourceOver,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not render \(outputURL.path)")
    }
    try png.write(to: outputURL)
}
