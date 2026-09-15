import AppKit

// 生成 Transend 应用图标：渐变 squircle 背景 + 白色圆圈 + 蓝色粗体 T（呼应菜单栏图标）
// 用法: swift make-icon.swift <输出目录(icon_*.png 存放处)>

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let S: CGFloat = 1024
let blue = NSColor(calibratedRed: 0.16, green: 0.50, blue: 0.98, alpha: 1)   // #2980F9
let purple = NSColor(calibratedRed: 0.42, green: 0.28, blue: 0.96, alpha: 1) // #6B48F5

let master = NSImage(size: NSSize(width: S, height: S), flipped: false) { rect in
    guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

    // 圆角方块 + 对角渐变
    let squircle = NSBezierPath(roundedRect: rect, xRadius: 200, yRadius: 200)
    squircle.addClip()
    let grad = NSGradient(starting: blue, ending: purple)!
    grad.draw(in: squircle, angle: -45)

    // 白色圆圈
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: 212, y: 212, width: 600, height: 600)).fill()

    // 蓝色大写 T（视觉居中）
    let font = NSFont.systemFont(ofSize: 430, weight: .heavy)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: blue]
    let t = "T" as NSString
    let ts = t.size(withAttributes: attrs)
    t.draw(at: NSPoint(x: (S - ts.width) / 2, y: (S - ts.height) / 2 - 24), withAttributes: attrs)
    return true
}

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for s in sizes {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: s.px, pixelsHigh: s.px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: s.px, height: s.px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    master.draw(in: NSRect(x: 0, y: 0, width: CGFloat(s.px), height: CGFloat(s.px)))
    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: outDir.appendingPathComponent(s.name))
}
print("PNG 已生成: \(outDir.path)")
