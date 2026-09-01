import AppKit
import CoreGraphics

// Original artwork for BudsCtl. Drawn from primitives so there is no
// third-party asset and no licence question: an earbud silhouette plus two
// sound arcs, on the standard macOS rounded-square plate.

// Small sizes get a reduced glyph. At 16pt the second arc and the canal dot
// merge into a smudge, so below the threshold we draw one bolder arc and a
// bigger bud. This is why macOS icon sets carry per-size artwork.
func render(size: CGFloat, detailed: Bool) -> Data {
    let s = size / 1024.0   // everything below is authored at 1024
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil,
        width: Int(size), height: Int(size),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.scaleBy(x: s, y: s)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // macOS icon grid: an 824pt plate centred in 1024 with a 185.4pt radius.
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 185.4, cornerHeight: 185.4, transform: nil)

    // Soft contact shadow so it sits on light Finder backgrounds. Skipped at
    // small sizes, where it costs real pixels and only muddies the edge.
    ctx.saveGState()
    if detailed {
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
    }
    ctx.addPath(platePath)
    ctx.setFillColor(CGColor(red: 0.35, green: 0.40, blue: 0.95, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Indigo -> violet, top-left to bottom-right.
    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.38, green: 0.44, blue: 0.97, alpha: 1),
        CGColor(red: 0.60, green: 0.26, blue: 0.88, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: plate.minX, y: plate.maxY),
                           end: CGPoint(x: plate.maxX, y: plate.minY),
                           options: [])

    // Gloss: a wide, very soft highlight across the upper third.
    if detailed {
    let gloss = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.20),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gloss,
                           start: CGPoint(x: plate.midX, y: plate.maxY),
                           end: CGPoint(x: plate.midX, y: plate.midY + 40),
                           options: [])
    }
    ctx.restoreGState()

    // --- the earbud: a round bud with a straight stem, AirPods-like ---
    let budCentre = CGPoint(x: detailed ? 430 : 415, y: 600)
    let budRadius: CGFloat = detailed ? 138 : 168

    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.addEllipse(in: CGRect(x: budCentre.x - budRadius, y: budCentre.y - budRadius,
                              width: budRadius * 2, height: budRadius * 2))
    ctx.fillPath()

    let halfStem: CGFloat = detailed ? 44 : 56
    let stem = CGRect(x: budCentre.x - halfStem, y: detailed ? 300 : 280,
                      width: halfStem * 2, height: detailed ? 300 : 320)
    ctx.addPath(CGPath(roundedRect: stem, cornerWidth: halfStem, cornerHeight: halfStem, transform: nil))
    ctx.fillPath()

    // Ear canal tip. Detailed sizes only: at 16pt it is a single grey pixel
    // in the middle of the bud, which reads as dirt rather than detail.
    if detailed {
        ctx.setFillColor(CGColor(red: 0.30, green: 0.24, blue: 0.62, alpha: 0.55))
        ctx.addEllipse(in: CGRect(x: budCentre.x - 52, y: budCentre.y - 52, width: 104, height: 104))
        ctx.fillPath()
    }

    // --- two sound arcs, radiating right ---
    ctx.setLineCap(.round)
    let arcs: [(Double, Double, Double)] = detailed
        ? [(258, 0.95, 40), (348, 0.55, 40)]
        : [(300, 1.0, 62)]
    for (radius, alpha, width) in arcs {
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
        ctx.setLineWidth(width)
        ctx.addArc(center: budCentre, radius: radius,
                   startAngle: -.pi / 4.4, endAngle: .pi / 4.4, clockwise: false)
        ctx.strokePath()
    }

    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments[1]
// Every distinct pixel size the mac idiom asks for.
for size in [16.0, 32.0, 64.0, 128.0, 256.0, 512.0, 1024.0] {
    let name = "icon_\(Int(size)).png"
    // 64pt is the 32x32@2x slot: still small on screen, still wants the
    // simple glyph.
    try! render(size: size, detailed: size > 64)
        .write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
    print("wrote \(name)")
}
