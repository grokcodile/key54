// DemoKeys — an on-screen MacBook Air bottom keyboard row for screen recordings.
//
// Shows fn / control / option / command / space / command / option / arrows as a
// floating, click-through overlay at the bottom of the screen. Keys light up as
// they are pressed; the RIGHT ⌘ key gets the Key54 blue glow so viewers can see
// exactly which physical key drives the app switch — something KeyCastr can't
// show (it doesn't distinguish left/right modifiers).
//
// Build:  swiftc -O tools/DemoKeys.swift -o build/DemoKeys
// Run:    ./build/DemoKeys [scale] [top|bottom]
//           scale defaults to 1.0 (try 1.3 for 4K).
//           position defaults to "top" so the row clears Key54's own HUD,
//           which sits at bottom-center. Pass "bottom" to force the old spot.
// Quit:   Ctrl+C in the terminal that launched it.
//
// Needs Accessibility permission (listen-only CGEventTap, same as Key54). When
// run from a terminal, grant the permission to the terminal app.

import Cocoa

let scale: CGFloat = CommandLine.arguments.count > 1
    ? CGFloat(Double(CommandLine.arguments[1]) ?? 1.0) : 1.0

// Key54's HUD lives at bottom-center, so the key row defaults to the top edge
// (just under the menu bar) to stay out of its way. Pass "bottom" to override.
let atTop: Bool = !(CommandLine.arguments.count > 2
    && CommandLine.arguments[2].lowercased() == "bottom")

// MARK: - Palette (matches key54.app)

let keyBG      = NSColor(srgbRed: 0.117, green: 0.117, blue: 0.125, alpha: 0.94)
let keyBGDown  = NSColor(srgbRed: 0.29,  green: 0.29,  blue: 0.31,  alpha: 0.97)
let keyBorder  = NSColor(white: 1.0, alpha: 0.14)
let keyText    = NSColor(white: 1.0, alpha: 0.75)
let accent     = NSColor(srgbRed: 0, green: 0.443, blue: 0.89, alpha: 1)   // #0071e3

// MARK: - Key definitions

/// Bottom row of a MacBook Air keyboard, left to right. Width is in "units" of
/// a small modifier key; the arrow cluster is handled separately.
struct KeyDef {
    let id: String        // stable id used by the highlight routing
    let symbol: String    // top line of the keycap ("" = none)
    let name: String      // bottom line of the keycap ("" = none)
    let width: CGFloat
}

let row: [KeyDef] = [
    KeyDef(id: "fn",   symbol: "fn", name: "",        width: 1.0),
    KeyDef(id: "ctrl", symbol: "⌃", name: "control",  width: 1.0),
    KeyDef(id: "optL", symbol: "⌥", name: "option",   width: 1.0),
    KeyDef(id: "cmdL", symbol: "⌘", name: "command",  width: 1.25),
    KeyDef(id: "space", symbol: "", name: "",         width: 4.9),
    KeyDef(id: "cmdR", symbol: "⌘", name: "command",  width: 1.25),
    KeyDef(id: "optR", symbol: "⌥", name: "option",   width: 1.0),
]
// Arrow cluster (left, up/down stacked, right) appended after the row.

// MARK: - Keycap layer

final class KeycapLayer: CALayer {
    private let isRightCommand: Bool
    private var labels: [CATextLayer] = []

    init(def: KeyDef, frame: CGRect, screenScale: CGFloat, arrowGlyph: String? = nil) {
        isRightCommand = def.id == "cmdR"
        super.init()
        self.frame = frame
        cornerRadius = 7 * scale
        backgroundColor = keyBG.cgColor
        borderColor = keyBorder.cgColor
        borderWidth = 1
        masksToBounds = false

        func addLabel(_ text: String, size: CGFloat, y: CGFloat, weight: NSFont.Weight) {
            guard !text.isEmpty else { return }
            let l = CATextLayer()
            l.string = text
            l.font = NSFont.systemFont(ofSize: size, weight: weight)
            l.fontSize = size
            l.alignmentMode = .center
            l.foregroundColor = keyText.cgColor
            l.contentsScale = screenScale
            l.frame = CGRect(x: 0, y: y, width: bounds.width, height: size * 1.35)
            addSublayer(l)
            labels.append(l)
        }
        if let glyph = arrowGlyph {
            addLabel(glyph, size: 11 * scale, y: (bounds.height - 11 * scale * 1.35) / 2, weight: .medium)
        } else {
            let symSize = 13 * scale, nameSize = 9 * scale
            if def.name.isEmpty {
                if !def.symbol.isEmpty {
                    addLabel(def.symbol, size: symSize, y: (bounds.height - symSize * 1.35) / 2, weight: .regular)
                }
            } else {
                addLabel(def.symbol, size: symSize, y: bounds.height - symSize * 1.35 - 5 * scale, weight: .regular)
                addLabel(def.name, size: nameSize, y: 4 * scale, weight: .regular)
            }
        }
    }

    // Core Animation instantiates a copy of any CALayer subclass via init(layer:)
    // when it builds the presentation layer for an implicit animation — and
    // setPressed() animates inside a CATransaction. Without this override the
    // runtime traps ("Use of unimplemented initializer 'init(layer:)'") the first
    // time any key is highlighted.
    override init(layer: Any) {
        isRightCommand = (layer as? KeycapLayer)?.isRightCommand ?? false
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setPressed(_ pressed: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        if pressed {
            backgroundColor = (isRightCommand ? accent : keyBGDown).cgColor
            borderColor = (isRightCommand ? accent : NSColor(white: 1, alpha: 0.3)).cgColor
            labels.forEach { $0.foregroundColor = NSColor.white.cgColor }
            if isRightCommand {
                shadowColor = accent.cgColor
                shadowRadius = 14 * scale
                shadowOpacity = 0.9
                shadowOffset = .zero
            }
        } else {
            backgroundColor = keyBG.cgColor
            borderColor = keyBorder.cgColor
            labels.forEach { $0.foregroundColor = keyText.cgColor }
            shadowOpacity = 0
        }
        CATransaction.commit()
    }
}

// MARK: - Overlay window

final class Overlay {
    let panel: NSPanel
    private var keys: [String: KeycapLayer] = [:]

    init() {
        guard let screen = NSScreen.main else { fatalError("no screen") }
        let bs = screen.backingScaleFactor

        let unit = 52 * scale                 // width of a 1.0-unit key
        let keyH = 52 * scale
        let gap  = 5 * scale
        let pad  = 10 * scale

        let rowUnits = row.reduce(0) { $0 + $1.width }
        let arrowUnits: CGFloat = 3.0
        let totalW = (rowUnits + arrowUnits) * unit
            + gap * CGFloat(row.count + 2)    // gaps between keys + 3 arrow columns
            + pad * 2
        let totalH = keyH + pad * 2

        let sf = screen.frame
        let vf = screen.visibleFrame   // excludes the menu bar
        let y = atTop ? vf.maxY - totalH - 12 * scale : sf.minY + 64 * scale
        let rect = NSRect(x: sf.midX - totalW / 2, y: y,
                          width: totalW, height: totalH)

        panel = NSPanel(contentRect: rect,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = false

        let root = NSView(frame: NSRect(origin: .zero, size: rect.size))
        root.wantsLayer = true
        let bg = CALayer()
        bg.frame = root.bounds
        bg.backgroundColor = NSColor(white: 0.04, alpha: 0.55).cgColor
        bg.cornerRadius = 14 * scale
        root.layer!.addSublayer(bg)

        var x = pad
        for def in row {
            let w = def.width * unit
            let layer = KeycapLayer(def: def,
                                    frame: CGRect(x: x, y: pad, width: w, height: keyH),
                                    screenScale: bs)
            root.layer!.addSublayer(layer)
            keys[def.id] = layer
            x += w + gap
        }
        // Arrow cluster: full-height left/right, half-height up over down.
        let halfH = (keyH - 3 * scale) / 2
        let arrows: [(String, String, CGRect)] = [
            ("left",  "◀", CGRect(x: x, y: pad, width: unit, height: halfH)),
            ("up",    "▲", CGRect(x: x + unit + gap, y: pad + halfH + 3 * scale, width: unit, height: halfH)),
            ("down",  "▼", CGRect(x: x + unit + gap, y: pad, width: unit, height: halfH)),
            ("right", "▶", CGRect(x: x + (unit + gap) * 2, y: pad, width: unit, height: halfH)),
        ]
        for (id, glyph, frame) in arrows {
            let layer = KeycapLayer(def: KeyDef(id: id, symbol: "", name: "", width: 1),
                                    frame: frame, screenScale: bs, arrowGlyph: glyph)
            root.layer!.addSublayer(layer)
            keys[id] = layer
        }

        panel.contentView = root
        panel.orderFrontRegardless()
    }

    func set(_ id: String, pressed: Bool) {
        keys[id]?.setPressed(pressed)
    }
}

// MARK: - Event tap (listen-only, same approach as Key54 itself)

final class TapController {
    private let overlay: Overlay
    private var tap: CFMachPort?

    // Device-specific modifier bits (NX_DEVICE…KEYMASK).
    private static let bits: [(mask: UInt64, id: String)] = [
        (0x0000_0001, "ctrl"),   // left control (Air has no right control)
        (0x0000_0008, "cmdL"),
        (0x0000_0010, "cmdR"),
        (0x0000_0020, "optL"),
        (0x0000_0040, "optR"),
        (0x0080_0000, "fn"),     // NX_SECONDARYFNMASK
    ]
    private static let keycodes: [Int64: String] = [
        49: "space", 123: "left", 124: "right", 125: "down", 126: "up",
    ]

    init?(overlay: Overlay) {
        self.overlay = overlay
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                let me = Unmanaged<TapController>.fromOpaque(userInfo!).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                if type == .flagsChanged {
                    let flags = event.flags.rawValue
                    let states = TapController.bits.map { ($0.id, flags & $0.mask != 0) }
                    DispatchQueue.main.async {
                        for (id, down) in states { me.overlay.set(id, pressed: down) }
                    }
                } else if let id = TapController.keycodes[event.getIntegerValueField(.keyboardEventKeycode)] {
                    let down = type == .keyDown
                    DispatchQueue.main.async { me.overlay.set(id, pressed: down) }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return nil }
        tap = newTap
        let source = CFMachPortCreateRunLoopSource(nil, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

if !AXIsProcessTrusted() {
    let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    AXIsProcessTrustedWithOptions(opts)
    print("DemoKeys needs Accessibility permission (it watches keys with a")
    print("listen-only event tap, exactly like Key54). Grant it to the app you")
    print("launched this from — usually your terminal — in System Settings >")
    print("Privacy & Security > Accessibility, then run DemoKeys again.")
    exit(1)
}

let overlay = Overlay()
guard let controller = TapController(overlay: overlay) else {
    print("Could not create the event tap. Is Accessibility granted?")
    exit(1)
}
_ = controller
print("DemoKeys running — the key row floats at the bottom of the screen.")
print("It is click-through; press Ctrl+C here to quit.")
app.run()
