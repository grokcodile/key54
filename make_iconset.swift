#!/usr/bin/swift
import AppKit

// Builds a macOS .iconset from full-bleed source art.
//
// - Fits the art into the standard macOS icon grid: a centered rounded-square
//   (squircle) occupying 824/1024 of the canvas with transparent margin —
//   matching the proportions every other Mac app icon uses.
// - Masks corners to transparency (removes the art's opaque black corners).
// - Renders a clean premultiplied 1024 master, then downsamples every size
//   from it, so transparent edges never pick up a white/black fringe.

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("usage: make_iconset.swift <source.png> <output.iconset dir>\n", stderr)
    exit(1)
}
let srcPath = args[1]
let outDir = args[2]

guard let img = NSImage(contentsOfFile: srcPath),
      let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff) else {
    fputs("could not load source image\n", stderr); exit(1)
}
let srcCG = rep.cgImage!

let cs = CGColorSpaceCreateDeviceRGB()
let alpha = CGImageAlphaInfo.premultipliedLast.rawValue

// ── Build the 1024 master ────────────────────────────────────────────────────
let canvas: CGFloat = 1024
// macOS icon grid: rounded square is 824×824 inside 1024, centered.
let rectSize: CGFloat = 824
let margin = (canvas - rectSize) / 2          // 100
let cornerR = rectSize * 0.2237               // Apple squircle-ish radius

guard let mctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas),
                           bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                           bitmapInfo: alpha) else { exit(1) }
mctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
mctx.interpolationQuality = .high

let iconRect = CGRect(x: margin, y: margin, width: rectSize, height: rectSize)
let maskPath = CGPath(roundedRect: iconRect, cornerWidth: cornerR, cornerHeight: cornerR, transform: nil)
mctx.addPath(maskPath)
mctx.clip()

// Draw the (square) source art to fill the rounded square.
mctx.draw(srcCG, in: iconRect)

guard let master = mctx.makeImage() else { exit(1) }

// ── Emit each size from the master ───────────────────────────────────────────
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func write(_ px: Int, _ name: String) {
    guard let ctx = CGContext(data: nil, width: px, height: px,
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: alpha) else { return }
    ctx.interpolationQuality = .high
    ctx.clear(CGRect(x: 0, y: 0, width: px, height: px))
    ctx.draw(master, in: CGRect(x: 0, y: 0, width: px, height: px))
    guard let out = ctx.makeImage() else { return }
    let r = NSBitmapImageRep(cgImage: out)
    guard let data = r.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (px, name) in sizes { write(px, name) }
print("iconset written to \(outDir)")
