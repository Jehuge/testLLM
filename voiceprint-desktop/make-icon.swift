import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        let inset = Double(pixels) * 0.06
        let shape = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset),
                                 xRadius: Double(pixels) * 0.22, yRadius: Double(pixels) * 0.22)
        NSGradient(colors: [NSColor(red: 0.39, green: 0.48, blue: 1, alpha: 1),
                            NSColor(red: 0.27, green: 0.23, blue: 0.82, alpha: 1)])!.draw(in: shape, angle: -60)
        NSColor.white.setFill()
        for (i, height) in [0.21, 0.38, 0.55, 0.31, 0.46, 0.2].enumerated() {
            let width = Double(pixels) * 0.055
            let bar = NSRect(x: Double(pixels) * (0.22 + Double(i) * 0.1),
                             y: Double(pixels) * (1 - height) / 2,
                             width: width, height: Double(pixels) * height)
            NSBezierPath(roundedRect: bar, xRadius: width / 2, yRadius: width / 2).fill()
        }
        image.unlockFocus()
        let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        let url = directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        try representation.representation(using: .png, properties: [:])!.write(to: url)
    }
}
