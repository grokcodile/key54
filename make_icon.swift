#!/usr/bin/swift
import AppKit

// Regenerates cmd54_icon.png: the icon *is* a MacBook-style keycap — the
// standard icon squircle plays the part of the chiclet key, with a raised
// top surface, rounded edges, and backlit legends (⌘ top-right, "command"
// below it).
//
// usage: swift make_icon.swift [output.png] [wallInset] [nudge] [taper]
//   wallInset — how much key wall shows around the top surface (default 34)
//   nudge     — upward shift of the top surface, the perspective cue (default 12)
//   taper     — extra top-surface corner rounding beyond the mask's (default 8)
//
// Emits full-bleed square art; make_iconset.swift masks it into the standard
// macOS icon-grid squircle, which forms the key's silhouette.

let argv = CommandLine.arguments
let out = argv.count > 1 ? argv[1] : "cmd54_icon.png"
func arg(_ i: Int, _ fallback: CGFloat) -> CGFloat {
    argv.count > i ? CGFloat(Double(argv[i]) ?? Double(fallback)) : fallback
}
let wallInset = arg(2, 38)
let nudge = arg(3, 6)
let taper = arg(4, -22)
let cmdSize = arg(5, 432)
let S: CGFloat = 1024

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

// ── Keycap body (the squircle itself) ────────────────────────────────────────

// Key sides: full bleed — after masking, this is the key's walls, darker
// toward the bottom like a chiclet key.
let sideGradient = NSGradient(colors: [
    NSColor(srgbRed: 0.14, green: 0.145, blue: 0.16, alpha: 1),
    NSColor(srgbRed: 0.04, green: 0.045, blue: 0.055, alpha: 1),
])!
sideGradient.draw(in: full, angle: -90)

// Raised top surface: inset and nudged upward so more wall shows along the
// bottom. Its corners are *more* rounded than the silhouette's — a parallel
// inset (radius minus inset) pinches the corners, but a real keycap tapers
// as it rises, so the top reads rounder than the base.
let topRect = full.insetBy(dx: wallInset, dy: wallInset).offsetBy(dx: 0, dy: nudge)
let topR = S * 0.2237 + taper
let topSurface = NSBezierPath(roundedRect: topRect, xRadius: topR, yRadius: topR)
let topGradient = NSGradient(colors: [
    NSColor(srgbRed: 0.175, green: 0.18, blue: 0.20, alpha: 1),
    NSColor(srgbRed: 0.10, green: 0.105, blue: 0.125, alpha: 1),
])!
topGradient.draw(in: topSurface, angle: -90)

// Hairline catch-light along the top surface's edge.
NSColor(white: 1, alpha: 0.09).setStroke()
topSurface.lineWidth = 3
topSurface.stroke()

// ── Backlit legends ──────────────────────────────────────────────────────────

// Apple keycap legends have used San Francisco since the 2015–16 keyboard
// redesign — exactly what systemFont returns — with the lowercase word
// tracked out a touch.
let legend = NSColor(white: 0.98, alpha: 1)
let wordMargin: CGFloat = 110
let legendRight = topRect.maxX - wordMargin   // shared right alignment edge

func drawLegend(_ text: NSString, size: CGFloat, topEdge: CGFloat, kern: CGFloat = 0) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: .regular),
        .foregroundColor: legend,
        .kern: kern,
    ]
    // Kerning pads every glyph's advance, including the last — back the
    // trailing pad out so the right edge stays truly aligned.
    let sz = text.size(withAttributes: attrs)
    let at = NSPoint(x: legendRight - sz.width + kern, y: topEdge - sz.height)
    // Backlit: a tight white halo behind a solid legend.
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

// "command" spans the key's width like the real engraving: size it to fit
// between equal margins, so its left edge mirrors the shared right edge.
let word: NSString = "command"
let kernRatio: CGFloat = 0.075
let probe: CGFloat = 100
let probeAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: probe, weight: .regular),
    .kern: probe * kernRatio,
]
let probeW = word.size(withAttributes: probeAttrs).width - probe * kernRatio
let wordSize = probe * (topRect.width - wordMargin * 2) / probeW
let wordH = word.size(withAttributes: [
    .font: NSFont.systemFont(ofSize: wordSize, weight: .regular),
    .kern: wordSize * kernRatio,
]).height

// ⌘ rides high on the key, right-aligned with the word below.
drawLegend("\u{2318}", size: cmdSize, topEdge: topRect.maxY - 16)
drawLegend(word, size: wordSize, topEdge: topRect.minY + 88 + wordH,
           kern: wordSize * kernRatio)

gctx.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("could not encode png\n", stderr); exit(1)
}
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
