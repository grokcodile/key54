#!/usr/bin/swift
import AppKit

// Generates every icon asset for Key54 in one pass: the AppIcon.iconset (all
// sizes) and the README header icon. The icon *is* a MacBook-style keycap —
// a raised top surface with backlit ⌘ + "command" legends — drawn full-bleed,
// then fitted into the standard macOS icon-grid squircle (824/1024 + margin),
// downsampling every size from a single premultiplied master to avoid edge
// fringing.
//
// usage: swift make_icon.swift [iconset-dir]   (default: AppIcon.iconset)
//
// build.sh runs this, then pngquant + iconutil turn the .iconset into .icns.

let argv = CommandLine.arguments
let iconsetDir = argv.count > 1 ? argv[1] : "AppIcon.iconset"
let readmeIcon = "screenshots/icon_readme.png"

// ── Keycap geometry / styling (tweak the look here) ──────────────────────────
let artSize: CGFloat = 1024
let wallInset: CGFloat = 38     // key wall showing around the top surface
let nudge: CGFloat = 6          // upward shift of the top surface (perspective)
let taper: CGFloat = -22        // top-surface corner rounding vs. the silhouette
let cmdSize: CGFloat = 432      // ⌘ glyph size
let wordMargin: CGFloat = 110   // side margin for the "command" legend
let kernRatio: CGFloat = 0.075  // letter-spacing of "command"

let cs = CGColorSpaceCreateDeviceRGB()
let alpha = CGImageAlphaInfo.premultipliedLast.rawValue

// ── 1. Draw the full-bleed keycap art ────────────────────────────────────────
func renderKeycap() -> CGImage {
    let S = artSize
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let gctx = NSGraphicsContext(bitmapImageRep: rep) else {
        fputs("could not create render context\n", stderr); exit(1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    let full = NSRect(x: 0, y: 0, width: S, height: S)
    gctx.cgContext.clear(full)

    // Key sides: full bleed — after the squircle mask, these are the walls,
    // darker toward the bottom like a chiclet key.
    NSGradient(colors: [
        NSColor(srgbRed: 0.14, green: 0.145, blue: 0.16, alpha: 1),
        NSColor(srgbRed: 0.04, green: 0.045, blue: 0.055, alpha: 1),
    ])!.draw(in: full, angle: -90)

    // Raised top surface — corners *more* rounded than the silhouette, so the
    // key reads as tapering inward as it rises; nudged up so more wall shows
    // along the bottom.
    let topRect = full.insetBy(dx: wallInset, dy: wallInset).offsetBy(dx: 0, dy: nudge)
    let topR = S * 0.2237 + taper
    let topSurface = NSBezierPath(roundedRect: topRect, xRadius: topR, yRadius: topR)
    NSGradient(colors: [
        NSColor(srgbRed: 0.175, green: 0.18, blue: 0.20, alpha: 1),
        NSColor(srgbRed: 0.10, green: 0.105, blue: 0.125, alpha: 1),
    ])!.draw(in: topSurface, angle: -90)
    NSColor(white: 1, alpha: 0.09).setStroke()
    topSurface.lineWidth = 3
    topSurface.stroke()

    // Backlit legends in San Francisco (Apple's keycap face since the 2015–16
    // keyboard redesign — exactly what systemFont returns).
    let legend = NSColor(white: 0.98, alpha: 1)
    let legendRight = topRect.maxX - wordMargin   // shared right alignment edge
    func drawLegend(_ text: NSString, size: CGFloat, topEdge: CGFloat, kern: CGFloat = 0) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .regular),
            .foregroundColor: legend, .kern: kern,
        ]
        // Kerning pads every glyph's advance, including the last — back the
        // trailing pad out so the right edge stays truly aligned.
        let sz = text.size(withAttributes: attrs)
        let at = NSPoint(x: legendRight - sz.width + kern, y: topEdge - sz.height)
        NSGraphicsContext.current?.saveGraphicsState()
        let backlight = NSShadow()
        backlight.shadowColor = NSColor(white: 1, alpha: 0.85)
        backlight.shadowBlurRadius = 16
        backlight.shadowOffset = .zero
        backlight.set()
        text.draw(at: at, withAttributes: attrs)
        NSGraphicsContext.current?.restoreGraphicsState()
        text.draw(at: at, withAttributes: attrs)
    }

    // "command" spans the key width between equal margins; ⌘ rides high above
    // it, sharing the right edge.
    let word: NSString = "command"
    let probe: CGFloat = 100
    let probeW = word.size(withAttributes: [
        .font: NSFont.systemFont(ofSize: probe, weight: .regular),
        .kern: probe * kernRatio,
    ]).width - probe * kernRatio
    let wordSize = probe * (topRect.width - wordMargin * 2) / probeW
    let wordH = word.size(withAttributes: [
        .font: NSFont.systemFont(ofSize: wordSize, weight: .regular),
        .kern: wordSize * kernRatio,
    ]).height
    drawLegend("\u{2318}", size: cmdSize, topEdge: topRect.maxY - 16)
    drawLegend(word, size: wordSize, topEdge: topRect.minY + 88 + wordH,
               kern: wordSize * kernRatio)

    gctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let cg = rep.cgImage else { fputs("keycap render failed\n", stderr); exit(1) }
    return cg
}

// ── 2. Fit the art into the macOS icon-grid squircle (1024 master) ───────────
func makeCtx(_ px: Int) -> CGContext? {
    CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: alpha)
}

func renderMaster(_ art: CGImage) -> CGImage {
    let canvas: CGFloat = 1024
    let rectSize: CGFloat = 824            // icon content area inside 1024
    let margin = (canvas - rectSize) / 2   // 100
    let cornerR = rectSize * 0.2237        // Apple squircle-ish radius
    guard let ctx = makeCtx(Int(canvas)) else { exit(1) }
    ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    ctx.interpolationQuality = .high
    let iconRect = CGRect(x: margin, y: margin, width: rectSize, height: rectSize)
    ctx.addPath(CGPath(roundedRect: iconRect, cornerWidth: cornerR,
                       cornerHeight: cornerR, transform: nil))
    ctx.clip()
    ctx.draw(art, in: iconRect)
    guard let master = ctx.makeImage() else { exit(1) }
    return master
}

// ── 3. Emit one size from the master ─────────────────────────────────────────
func write(_ master: CGImage, _ px: Int, to path: String) {
    guard let ctx = makeCtx(px) else { return }
    ctx.interpolationQuality = .high
    ctx.clear(CGRect(x: 0, y: 0, width: px, height: px))
    ctx.draw(master, in: CGRect(x: 0, y: 0, width: px, height: px))
    guard let out = ctx.makeImage(),
          let data = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    else { return }
    try? data.write(to: URL(fileURLWithPath: path))
}

// ── Run ───────────────────────────────────────────────────────────────────────
let master = renderMaster(renderKeycap())

try? FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (px, name) in sizes { write(master, px, to: "\(iconsetDir)/\(name)") }

// README header icon (displayed at 128; emit 512 for retina).
write(master, 512, to: readmeIcon)

print("wrote \(iconsetDir) (\(sizes.count) sizes) + \(readmeIcon)")
