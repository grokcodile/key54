import Cocoa
import ServiceManagement

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var tap: CFMachPort?
    private var previousApp: NSRunningApplication?
    private var settingsWindow: SettingsWindow?
    let fallbackBundleID = "com.apple.Terminal"

    // Cached target so the app-switch notification path does no disk I/O.
    private var cachedURL: URL?
    private var cachedBundleID: String?

    // Trigger animation HUD + preference.
    private lazy var hud = TriggerHUD()
    private var bufferTimer: Timer?
    private var hudVisible = false
    var showAnimation: Bool {
        get { UserDefaults.standard.object(forKey: "showAnimation") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showAnimation") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--screenshot <path>`: render the settings window over a fixed
        // neutral backdrop, capture it, write the PNG, and quit. Used by
        // install.sh to keep the README screenshot current. Skips all the
        // normal agent setup (no event tap, no login item).
        if let i = CommandLine.arguments.firstIndex(of: "--screenshot") {
            let path = i + 1 < CommandLine.arguments.count
                ? CommandLine.arguments[i + 1] : "screenshots/settings.png"
            captureSettingsScreenshot(to: path)
            return
        }

        NSApp.setActivationPolicy(.accessory)

        // Show tooltips (the bare Tip Jar emoji's hint) after a brief delay,
        // rather than the long system default.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 150])

        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        startEventTap()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func showSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindow(delegate: self) }
        settingsWindow?.updateAppDisplay()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Screenshot capture (--screenshot)

    /// Show the settings window, capture just the window — transparent outside
    /// its rounded corners, no drop shadow, no background — write a PNG to
    /// `path`, and quit. Driven by the standalone screenshot.sh.
    private func captureSettingsScreenshot(to path: String) {
        NSApp.setActivationPolicy(.regular)
        SettingsWindow.screenshotMode = true

        let win = SettingsWindow(delegate: self)
        settingsWindow = win
        win.updateAppDisplay()
        win.hasShadow = false
        NSApp.activate(ignoringOtherApps: true)
        win.center()
        win.makeKeyAndOrderFront(nil)

        // Let the window server composite before capturing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.writeSettingsCapture(of: win, to: path)
            NSApp.terminate(nil)
        }
    }

    private func writeSettingsCapture(of win: NSWindow, to path: String) {
        // .boundsIgnoreFraming → just the window rect, no shadow; the rounded
        // corners and anything outside the window stay transparent.
        guard let shot = CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(win.windowNumber), .boundsIgnoreFraming) else {
            fputs("screenshot: capture failed — grant Screen Recording permission " +
                  "to Key54 in System Settings → Privacy & Security.\n", stderr)
            return
        }
        // The capture is in Retina pixels; downsample to the window's logical
        // (1x) size so the PNG matches the on-screen dimensions.
        let scale = win.backingScaleFactor
        let w = Int((CGFloat(shot.width) / scale).rounded())
        let h = Int((CGFloat(shot.height) / scale).rounded())
        var image = shot
        if scale != 1, w > 0, h > 0,
           let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                               bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.interpolationQuality = .high
            ctx.draw(shot, in: CGRect(x: 0, y: 0, width: w, height: h))
            image = ctx.makeImage() ?? shot
        }
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("wrote \(path) (\(image.width)×\(image.height))")
        } catch {
            fputs("screenshot: could not write \(path): \(error)\n", stderr)
        }
    }

    // MARK: - App tracking

    @objc private func appDidActivate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
        let bundleID = app.bundleIdentifier
        // Track the app to return to — but never the target itself.
        guard bundleID != resolvedBundleID() else { return }
        if bundleID == Bundle.main.bundleIdentifier {
            // Track ourselves only while the settings window is open, so
            // summoning out of Settings returns to it. Background
            // activations with no window never claim the "previous" slot.
            if settingsWindow?.isVisible == true { previousApp = app }
        } else {
            previousApp = app
        }
    }

    /// Called when the settings window closes: returning to Key54 only
    /// makes sense while the window is up, so forget it as the previous app.
    func settingsClosed() {
        if previousApp?.bundleIdentifier == Bundle.main.bundleIdentifier {
            previousApp = nil
        }
    }

    // MARK: - Toggle

    func toggleApp() {
        let url = targetAppURL()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier == resolvedBundleID() {
            dismiss(frontmost)
        } else {
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
        }
    }

    /// Return to the previous app by bringing it forward with `openApplication`
    /// (like clicking its Dock icon) — this reliably leaves a Space even when
    /// the previous app has no window. Hide the target first *unless it is
    /// full-screen*, because hiding a full-screen window leaves an empty Space;
    /// in that case we leave it as-is so it stays full-screen for next time.
    private func dismiss(_ frontmost: NSRunningApplication) {
        let prev = previousApp.flatMap { $0.isTerminated ? nil : $0 }
        let prevURL = prev?.bundleURL
            ?? URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")

        if !isAppFullScreen(pid: frontmost.processIdentifier) {
            frontmost.hide()
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: prevURL, configuration: config, completionHandler: nil)

        // Raise the previous app's focused window. For a full-screen previous
        // window this switches to its Space — which `openApplication` alone
        // won't do for an omnipresent app like Finder.
        if let prev {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                self.raiseFocusedWindow(pid: prev.processIdentifier)
            }
        }
    }

    private func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let w = winRef, CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
        return (w as! AXUIElement)
    }

    /// Whether the app's focused window is in native full-screen, via the
    /// Accessibility API (permission is already required for the event tap).
    private func isAppFullScreen(pid: pid_t) -> Bool {
        guard let window = focusedWindow(pid: pid) else { return false }
        var fsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fsRef) == .success else { return false }
        return (fsRef as? Bool) ?? false
    }

    /// Raise (and so switch Spaces to) the app's focused window.
    private func raiseFocusedWindow(pid: pid_t) {
        guard let window = focusedWindow(pid: pid) else { return }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    func targetAppURL() -> URL {
        if let cachedURL { return cachedURL }
        let url: URL
        if let path = UserDefaults.standard.string(forKey: "targetAppPath"),
           FileManager.default.fileExists(atPath: path) {
            url = URL(fileURLWithPath: path)
        } else {
            url = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        }
        cachedURL = url
        return url
    }

    func resolvedBundleID() -> String {
        if let cachedBundleID { return cachedBundleID }
        let id = Bundle(url: targetAppURL())?.bundleIdentifier ?? fallbackBundleID
        cachedBundleID = id
        return id
    }

    /// Clear the cache after the user picks a different application.
    func invalidateTargetCache() {
        cachedURL = nil
        cachedBundleID = nil
    }

    // MARK: - Event tap

    private var holdTimer: Timer?
    /// Which preset is active (0 = Instant … 4 = Custom). Defaults to Medium.
    var selectedPreset: Int {
        get { max(0, min(4, UserDefaults.standard.object(forKey: "presetIndex") as? Int ?? 2)) }
        set { UserDefaults.standard.set(newValue, forKey: "presetIndex") }
    }

    /// Animation style (0 = Power Up ring, 1 = Level Up fill). Defaults to Power Up.
    var animationStyle: Int {
        get { UserDefaults.standard.integer(forKey: "animationStyle") }
        set { UserDefaults.standard.set(newValue, forKey: "animationStyle") }
    }

    // The Custom preset's two values (seeded from whichever preset the user
    // moved to Custom from).
    var customKeyDelay: TimeInterval {
        get { UserDefaults.standard.object(forKey: "customKeyDelay") as? Double ?? 0.5 }
        set { UserDefaults.standard.set(newValue, forKey: "customKeyDelay") }
    }
    var customAnimationLength: TimeInterval {
        get { UserDefaults.standard.object(forKey: "customAnimationLength") as? Double ?? 0.4 }
        set { UserDefaults.standard.set(newValue, forKey: "customAnimationLength") }
    }

    /// Seed Custom from a preset the first time Custom is ever selected, so
    /// it starts as "tweak what I had". After that Custom always remembers
    /// its own values.
    func seedCustomIfNeeded(fromPreset idx: Int) {
        guard UserDefaults.standard.object(forKey: "customKeyDelay") == nil else { return }
        customKeyDelay = SettingsWindow.keyDelayValues[idx]
        customAnimationLength = SettingsWindow.animationLengthValues[idx]
    }

    /// Effective dead-zone / charge for the active preset.
    var activeKeyDelay: TimeInterval {
        selectedPreset == 4 ? customKeyDelay : SettingsWindow.keyDelayValues[selectedPreset]
    }
    var activeAnimationLength: TimeInterval {
        selectedPreset == 4 ? customAnimationLength : SettingsWindow.animationLengthValues[selectedPreset]
    }

    private func startEventTap() {
        // NOTE: must be an active (.defaultTap) tap — a .listenOnly tap here
        // stops delivering after the first toggle in practice. We pass every
        // event through unchanged and only observe the right Command key.
        let mask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo!).takeUnretainedValue()
                // Re-enable if the system ever disables the tap.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    delegate.reenableTap()
                    return Unmanaged.passRetained(event)
                }
                guard event.getIntegerValueField(.keyboardEventKeycode) == 54 else {
                    return Unmanaged.passRetained(event)
                }
                if event.flags.contains(.maskCommand) {
                    DispatchQueue.main.async { delegate.scheduleToggle() }
                } else {
                    DispatchQueue.main.async { delegate.cancelToggle() }
                }
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap else {
            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(axPermissionChanged),
                name: NSNotification.Name("com.apple.accessibility.api"),
                object: nil
            )
            return
        }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func reenableTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func scheduleToggle() {
        guard bufferTimer == nil, holdTimer == nil else { return }
        // Per-preset dead-zone buffer. Only if right-⌘ is still held past it do
        // we engage and start the charge countdown, so a quick tap or chord
        // isn't hijacked. (Instant's buffer is 0 — it triggers immediately.)
        let buffer = activeKeyDelay
        bufferTimer = Timer.scheduledTimer(withTimeInterval: buffer, repeats: false) { [weak self] _ in
            self?.bufferTimer = nil
            self?.arm()
        }
    }

    /// Engaged after the buffer: show the ring's charge sweep, then fire + toggle.
    private func arm() {
        let charge = activeAnimationLength
        // A zero charge means no ring sweep, so give the dissolve extra
        // time — at the normal fade the icon just flashes.
        let fade = charge <= 0 ? 0.6 : SettingsWindow.fadeConstant
        let swell = SettingsWindow.swellConstant

        // No dead-zone and no charge (Instant, or Custom dialed to zero):
        // no HUD, no ceremony — switch the moment the key is held.
        if charge <= 0, activeKeyDelay <= 0 {
            toggleApp()
            return
        }

        if showAnimation {
            // Show the icon of the app we'll end up in — the previous app if
            // we're dismissing the target, otherwise the target itself.
            let dismissing = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == resolvedBundleID()
            let icon = dismissing
                ? (previousApp?.icon ?? NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app"))
                : NSWorkspace.shared.icon(forFile: targetAppURL().path)
            hudVisible = true
            hud.begin(fill: charge, icon: icon)
        }

        holdTimer = Timer.scheduledTimer(withTimeInterval: charge, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.holdTimer = nil
            guard self.hudVisible else { self.toggleApp(); return }
            self.hudVisible = false

            // Always dissolve the HUD fully *in place first*, then switch —
            // full-screen and normal toggles behave identically. Letting the
            // fade order the panel out before the toggle means the HUD is gone
            // before any full-screen slide snapshots the outgoing Space, so the
            // "ghost ring" can never reappear; normal toggles get the same
            // unhurried feel for free. The brief extra beat lets the window
            // server composite the removal before the transition begins.
            self.hud.fire(fade: fade, swellTo: swell)
            DispatchQueue.main.asyncAfter(deadline: .now() + fade + 0.05) {
                self.hud.hideNow()
                self.toggleApp()
            }
        }
    }

    func cancelToggle() {
        bufferTimer?.invalidate(); bufferTimer = nil
        holdTimer?.invalidate(); holdTimer = nil
        if hudVisible { hud.cancel(fade: SettingsWindow.fadeConstant); hudVisible = false }
    }

    @objc private func axPermissionChanged() {
        if AXIsProcessTrusted() {
            DistributedNotificationCenter.default().removeObserver(self)
            startEventTap()
            settingsWindow?.refreshAxBanner()
        }
    }
}

// MARK: - Settings Window

/// A borderless button that shows the pointing-hand cursor on hover, so a bare
/// emoji or text link reads as clickable.
class LinkButton: NSButton {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// A flat, pill-shaped button with a translucent white fill that brightens on
/// hover (and shows the pointing-hand cursor via LinkButton).
final class HoverButton: LinkButton {
    private var tracking: NSTrackingArea?
    private let restColor = NSColor(white: 1, alpha: 0.07).cgColor
    private let hoverColor = NSColor(white: 1, alpha: 0.20).cgColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = restColor
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = hoverColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = restColor }
}

/// A small static HUD glyph that represents an Animation Style next to its radio
/// button: a ¾-filled Power Up ring, or a ¾-filled Level Up glass.
final class StyleGlyph: NSView {
    init(levelUp: Bool, size: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let accent = NSColor.controlAccentColor
        let radius = size * 0.28

        let tile = CALayer()
        tile.frame = bounds
        tile.cornerRadius = radius
        tile.backgroundColor = NSColor(white: 0.5, alpha: 0.16).cgColor
        layer?.addSublayer(tile)

        if levelUp {
            let clip = CALayer()
            clip.frame = bounds
            clip.cornerRadius = radius
            clip.masksToBounds = true
            layer?.addSublayer(clip)
            let water = CAShapeLayer()
            water.path = CGPath(rect: CGRect(x: 0, y: 0, width: size, height: size * 0.65), transform: nil)
            water.frame = bounds
            water.fillColor = accent.cgColor
            water.contentsScale = scale
            clip.addSublayer(water)
        } else {
            let center = CGPoint(x: size / 2, y: size / 2)
            let arc = CGMutablePath()
            arc.addArc(center: center, radius: size * 0.30, startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 2, clockwise: true)
            let track = CAShapeLayer()
            track.path = arc
            track.fillColor = NSColor.clear.cgColor
            track.strokeColor = NSColor(white: 1, alpha: 0.14).cgColor
            track.lineWidth = 3
            layer?.addSublayer(track)
            let ring = CAShapeLayer()
            ring.path = arc
            ring.fillColor = NSColor.clear.cgColor
            ring.strokeColor = accent.cgColor
            ring.lineWidth = 3
            ring.lineCap = .round
            ring.strokeEnd = 0.65
            ring.contentsScale = scale
            layer?.addSublayer(ring)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// A selectable pill for an Animation Style: the style's glyph and its name in a
/// rounded button that highlights (accent tint + border) when chosen. Click to
/// select; the SettingsWindow keeps the two mutually exclusive.
final class StylePill: NSView {
    let styleTag: Int
    private let onSelect: () -> Void
    private var isSelected: Bool
    private let glyphSize: CGFloat = 26

    init(tag: Int, levelUp: Bool, title: String, selected: Bool, onSelect: @escaping () -> Void) {
        self.styleTag = tag
        self.onSelect = onSelect
        self.isSelected = selected

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)

        let padH: CGFloat = 12, gap: CGFloat = 8, padV: CGFloat = 7
        label.sizeToFit()
        let h = glyphSize + padV * 2
        let w = padH + glyphSize + gap + ceil(label.frame.width) + padH
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: h))
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1

        let glyph = StyleGlyph(levelUp: levelUp, size: glyphSize)
        glyph.frame = NSRect(x: padH, y: padV, width: glyphSize, height: glyphSize)
        addSubview(glyph)

        label.frame = NSRect(x: padH + glyphSize + gap, y: (h - label.frame.height) / 2,
                             width: ceil(label.frame.width), height: label.frame.height)
        addSubview(label)

        applySelection()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSelected(_ on: Bool) { isSelected = on; applySelection() }

    private func applySelection() {
        let accent = NSColor.controlAccentColor
        layer?.backgroundColor = (isSelected ? accent.withAlphaComponent(0.18)
                                             : NSColor(white: 0.5, alpha: 0.10)).cgColor
        layer?.borderColor = (isSelected ? accent : .separatorColor).cgColor
    }

    override func mouseDown(with event: NSEvent) { onSelect() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

class SettingsWindow: NSWindow {
    weak var appDelegate: AppDelegate?
    private var axPollTimer: Timer?
    private var tipPopover: NSPopover?
    private var stylePills: [StylePill] = []   // the two Animation Style buttons
    private let contentW: CGFloat = 460
    private let pad: CGFloat = 32
    private let bannerH: CGFloat = 84
    private let bannerGap: CGFloat = 16

    // Hold-duration presets. Each stop has its own dead-zone buffer and charge
    // sweep (how long the ring fills); the dissolve and swell are constant. The
    // full trigger time is buffer + charge. "Instant" skips the animation
    // entirely and switches the moment the key is held. "Custom" (the fifth
    // stop) reads its two values from defaults instead of these tables.
    /// Set during `--screenshot` capture so the window renders in its normal
    /// state (the AX-permission banner is suppressed).
    static var screenshotMode = false
    static let holdDurationLabels = ["Instant", "Short", "Medium", "Long", "Custom"]
    static let keyDelayValues:   [TimeInterval] = [0.0, 0.5, 0.5, 0.7]   // pre-buffer dead-zone
    static let animationLengthValues: [TimeInterval] = [0.0, 0.0, 0.4, 0.6]   // charge sweep
    static let fadeConstant: TimeInterval = 0.4                        // dissolve
    static let swellConstant: CGFloat = 1.12                           // gel-release expansion
    static let customMax: TimeInterval = 1.5    // ceiling for each Custom slider
    static let customStep: TimeInterval = 0.05  // Custom slider snap increment

    init(delegate: AppDelegate) {
        self.appDelegate = delegate
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 100),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.title = ""
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = true
        self.isReleasedWhenClosed = false
        self.isRestorable = false
        rebuild()
        self.center()

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(refreshAxBanner),
            name: NSNotification.Name("com.apple.accessibility.api"),
            object: nil
        )
    }

    // MARK: - Layout

    private func rebuild() {
        let needsBanner = !AXIsProcessTrusted() && !Self.screenshotMode
        let showsCustom = appDelegate?.selectedPreset == 4
        let innerW = contentW - pad * 2

        // Intro text — built first so the layout can size to the measured text.
        let descW: CGFloat = 350
        let descPara = NSMutableParagraphStyle()
        descPara.alignment = .center
        descPara.paragraphSpacing = 10
        descPara.lineBreakMode = .byWordWrapping
        let descStr = NSAttributedString(
            string: "Hold the Command (⌘) key on the right side of your keyboard to summon the application below—hold it again to return to whatever you were doing.",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize + 1),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: descPara,
            ])
        let descH = ceil(descStr.boundingRect(
            with: NSSize(width: descW, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 2

        // Fixed vertical metrics (top → bottom). The content view runs under
        // the transparent titlebar, so the top margin includes its height.
        let topMargin: CGFloat = 56
        let titleH: CGFloat = 36
        let chooseH: CGFloat = 32
        let sliderBlockH: CGFloat = 68  // caption + slider + tick labels
        // The style selector only matters when there's a charge to visualize, so
        // it's hidden for Instant/Short (preset < 2 — no charge animation).
        let showsAnimationStyle = (appDelegate?.selectedPreset ?? 2) >= 2
        let animationStyleBlockH: CGFloat = 68   // caption + a row of two selectable pills
        let customBlockH: CGFloat = showsCustom ? 132 : 0   // Custom timing sub-panel
        let bottomBarH: CGFloat = 64    // Quit / Done row + bottom margin
        let unitGap: CGFloat = 10       // within a unit (title ↔ description)
        let sectionGap: CGFloat = 28    // between sections — the layout's rhythm

        // App-selection box (icon + name + change button) metrics
        let iconH: CGFloat = 48
        let nameH: CGFloat = 22
        let boxPadV: CGFloat = 16
        let iconNameGap: CGFloat = 6
        let nameButtonGap: CGFloat = 14
        let appBoxH = boxPadV + iconH + iconNameGap + nameH + nameButtonGap + chooseH + boxPadV

        let bannerBlock = needsBanner ? (bannerGap + bannerH) : 0
        let totalH = topMargin + titleH + unitGap + descH + sectionGap + appBoxH
                   + sectionGap + sliderBlockH + customBlockH + bannerBlock
                   + (showsAnimationStyle ? sectionGap + animationStyleBlockH : 0)
                   + sectionGap + bottomBarH

        setContentSize(NSSize(width: contentW, height: totalH))

        // Fresh content view — a behind-window material so the whole window
        // (titlebar included) reads as one translucent system surface.
        let c = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: contentW, height: totalH))
        c.material = .underWindowBackground
        c.blendingMode = .behindWindow
        c.state = .followsWindowActiveState
        var y = totalH - topMargin

        // Accessibility banner (above title)
        if needsBanner {
            y -= bannerH
            let box = NSBox(frame: NSRect(x: pad, y: y, width: innerW, height: bannerH))
            box.boxType = .custom
            box.fillColor = NSColor.systemOrange.withAlphaComponent(0.12)
            box.borderColor = NSColor.systemOrange.withAlphaComponent(0.45)
            box.borderWidth = 1; box.cornerRadius = 10; box.titlePosition = .noTitle
            c.addSubview(box)

            let msg = NSTextField(labelWithString: "Accessibility Permission Required")
            msg.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            msg.textColor = .systemOrange
            msg.frame = NSRect(x: 10, y: bannerH - 32, width: innerW - 20, height: 20)
            msg.alignment = .center
            box.addSubview(msg)

            let btn = NSButton(title: "Open Privacy & Security Settings", target: self,
                               action: #selector(openAxSettings))
            btn.bezelStyle = .rounded
            btn.frame = NSRect(x: (innerW - 260) / 2, y: 12, width: 260, height: 26)
            box.addSubview(btn)

            y -= bannerGap

            axPollTimer?.invalidate()
            axPollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                if AXIsProcessTrusted() { self?.refreshAxBanner() }
            }
        } else {
            axPollTimer?.invalidate(); axPollTimer = nil
        }

        // Title
        y -= titleH
        let titleLabel = NSTextField(labelWithString: "Key54")
        titleLabel.frame = NSRect(x: pad, y: y, width: innerW, height: titleH)
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.alignment = .center
        c.addSubview(titleLabel)

        // Description
        y -= unitGap + descH
        let desc = NSTextField(labelWithAttributedString: descStr)
        desc.frame = NSRect(x: (contentW - descW) / 2, y: y, width: descW, height: descH)
        desc.alignment = .center
        desc.usesSingleLineMode = false
        desc.cell?.wraps = true
        desc.maximumNumberOfLines = 0
        c.addSubview(desc)

        // App-selection section — icon + name + change button inside a gray box
        y -= sectionGap + appBoxH
        let boxW: CGFloat = 320
        let boxX = (contentW - boxW) / 2

        let appBox = NSBox(frame: NSRect(x: boxX, y: y, width: boxW, height: appBoxH))
        appBox.boxType = .custom
        appBox.fillColor = NSColor(white: 0.5, alpha: 0.12)
        appBox.borderColor = .separatorColor
        appBox.borderWidth = 1
        appBox.cornerRadius = 10
        appBox.titlePosition = .noTitle
        c.addSubview(appBox)

        let cIcon = iconH
        let iconY = y + appBoxH - boxPadV - iconH
        let cardIcon = NSImageView(frame: NSRect(x: boxX + (boxW - cIcon) / 2, y: iconY, width: cIcon, height: cIcon))
        cardIcon.imageScaling = .scaleProportionallyUpOrDown
        cardIcon.tag = 11
        c.addSubview(cardIcon)

        let nameY = iconY - iconNameGap - nameH
        let nameField = NSTextField(labelWithString: "")
        nameField.frame = NSRect(x: boxX, y: nameY, width: boxW, height: nameH)
        nameField.font = .systemFont(ofSize: 15, weight: .medium)
        nameField.alignment = .center
        nameField.tag = 12
        c.addSubview(nameField)

        let chooseBtn = NSButton(title: "Change Application…", target: self, action: #selector(chooseApp))
        chooseBtn.bezelStyle = .rounded
        chooseBtn.sizeToFit()
        let chooseW = chooseBtn.frame.width + 24
        chooseBtn.frame = NSRect(x: boxX + (boxW - chooseW) / 2, y: y + boxPadV, width: chooseW, height: chooseH)
        c.addSubview(chooseBtn)

        // Hold-duration: five discrete stops (Instant … Custom).
        y -= sectionGap + sliderBlockH
        let caption = NSTextField(labelWithString: "Hold Duration")
        caption.frame = NSRect(x: pad, y: y + sliderBlockH - 20, width: innerW, height: 18)
        caption.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        caption.textColor = .secondaryLabelColor
        caption.alignment = .center
        c.addSubview(caption)

        let sliderW: CGFloat = 320
        let sliderX = (contentW - sliderW) / 2
        let sliderY = y + 16
        let labels = SettingsWindow.holdDurationLabels
        let last = labels.count - 1

        let slider = NSSlider(value: Double(appDelegate?.selectedPreset ?? 1),
                              minValue: 0, maxValue: Double(last),
                              target: self, action: #selector(sliderChanged(_:)))
        slider.frame = NSRect(x: sliderX, y: sliderY, width: sliderW, height: 22)
        slider.numberOfTickMarks = labels.count
        slider.allowsTickMarkValuesOnly = true
        slider.tickMarkPosition = .below
        c.addSubview(slider)

        // Stop labels under each tick.
        let knobInset: CGFloat = 8
        let trackLeft = sliderX + knobInset
        let trackW = sliderW - knobInset * 2
        for (i, text) in labels.enumerated() {
            let lbl = NSTextField(labelWithString: text)
            lbl.font = .systemFont(ofSize: 10)
            lbl.textColor = .secondaryLabelColor
            lbl.alignment = .center
            let lw: CGFloat = 70
            let cx = trackLeft + (CGFloat(i) / CGFloat(last)) * trackW
            lbl.frame = NSRect(x: cx - lw / 2, y: y - 3, width: lw, height: 13)
            c.addSubview(lbl)
        }

        // Custom preset: an inset sub-panel — an outlined box holding the
        // dead-zone + charge sliders with live readouts.
        if showsCustom {
            y -= customBlockH

            let cBoxW: CGFloat = 360
            let cBoxX = (contentW - cBoxW) / 2
            let cBoxH: CGFloat = 116
            let cBoxTop = y + customBlockH - 16   // gap below the tick labels

            let box = NSBox(frame: NSRect(x: cBoxX, y: cBoxTop - cBoxH, width: cBoxW, height: cBoxH))
            box.boxType = .custom
            box.fillColor = NSColor(white: 0.5, alpha: 0.12)
            box.borderColor = .separatorColor
            box.borderWidth = 1
            box.cornerRadius = 10
            box.titlePosition = .noTitle
            c.addSubview(box)

            let row1 = cBoxTop - 14
            addCustomRow(to: c, top: row1, title: "Key Delay",
                         value: appDelegate?.customKeyDelay ?? 0.5,
                         sliderTag: 21, labelTag: 23)
            addCustomRow(to: c, top: row1 - 48, title: "Animation Length",
                         value: appDelegate?.customAnimationLength ?? 0.4,
                         sliderTag: 22, labelTag: 24)
        }

        // Animation Style: two selectable pills, each showing the style's glyph
        // (¾ ring / ¾ fill) and its name. Only shown when a charge is drawn.
        if showsAnimationStyle {
            y -= sectionGap + animationStyleBlockH
            let styleCaption = NSTextField(labelWithString: "Animation Style")
            styleCaption.frame = NSRect(x: pad, y: y + animationStyleBlockH - 20, width: innerW, height: 18)
            styleCaption.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
            styleCaption.textColor = .secondaryLabelColor
            styleCaption.alignment = .center
            c.addSubview(styleCaption)

            let selected = appDelegate?.animationStyle ?? 0
            stylePills = [(false, "Power Up"), (true, "Level Up")].enumerated().map { i, opt in
                StylePill(tag: i, levelUp: opt.0, title: opt.1, selected: selected == i) { [weak self] in
                    self?.selectStyle(i)
                }
            }
            let gapX: CGFloat = 16
            let totalW = stylePills.reduce(0) { $0 + $1.frame.width } + gapX * CGFloat(stylePills.count - 1)
            var px = (contentW - totalW) / 2
            for pill in stylePills {
                pill.setFrameOrigin(NSPoint(x: px, y: y))   // row sits at the block bottom
                c.addSubview(pill)
                px += pill.frame.width + gapX
            }
        }

        // Bottom bar: Quit (secondary, left) + Done (primary, right).
        let btnW: CGFloat = 100
        let barY: CGFloat = 20
        let quitBtn = NSButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quitBtn.frame = NSRect(x: pad, y: barY, width: btnW, height: 32)
        quitBtn.bezelStyle = .rounded
        c.addSubview(quitBtn)

        let doneBtn = NSButton(title: "Done", target: self, action: #selector(saveAndClose))
        doneBtn.frame = NSRect(x: contentW - pad - btnW, y: barY, width: btnW, height: 32)
        doneBtn.bezelStyle = .rounded
        doneBtn.keyEquivalent = "\r"
        c.addSubview(doneBtn)

        // Tip Jar easter egg: a lone jar emoji tucked into the top-right of the
        // titlebar, mirroring the traffic lights on the left. Tooltip + hand
        // cursor (LinkButton) hint it's clickable; NSControl isn't part of the
        // titlebar drag region, so the click still registers.
        let tipBtn = LinkButton(title: "", target: self, action: #selector(openTipJar(_:)))
        tipBtn.isBordered = false
        let jarPara = NSMutableParagraphStyle(); jarPara.alignment = .center
        tipBtn.attributedTitle = NSAttributedString(string: "🫙", attributes: [
            .font: NSFont.systemFont(ofSize: 14), .paragraphStyle: jarPara])   // sized to ~match the traffic lights
        let tipW: CGFloat = 34
        // Mirror the traffic lights: the jar's top/right padding matches their
        // top/left padding (≈9 pt each).
        tipBtn.frame = NSRect(x: contentW - 34, y: totalH - 30, width: tipW, height: 26)
        tipBtn.toolTip = "Tip Jar"
        c.addSubview(tipBtn)

        contentView = c
        updateAppDisplay()
    }

    @objc func refreshAxBanner() { rebuild(); center() }

    func updateAppDisplay() {
        guard let appDelegate else { return }
        let url = appDelegate.targetAppURL()
        let name = url.deletingPathExtension().lastPathComponent
        let icon = NSWorkspace.shared.icon(forFile: url.path)

        if let iconView = contentView?.viewWithTag(11) as? NSImageView {
            iconView.image = icon
        }
        if let nameField = contentView?.viewWithTag(12) as? NSTextField {
            nameField.stringValue = name
        }
    }

    // MARK: - Actions

    @objc private func saveAndClose() {
        appDelegate?.settingsClosed()
        orderOut(nil)
    }

    // The titlebar close button takes this path rather than saveAndClose.
    override func close() {
        appDelegate?.settingsClosed()
        super.close()
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let idx = max(0, min(Self.holdDurationLabels.count - 1, Int(sender.doubleValue.rounded())))
        guard let appDelegate, idx != appDelegate.selectedPreset else { return }
        let old = appDelegate.selectedPreset
        // First-ever visit to Custom seeds from the preset being left;
        // afterwards Custom keeps its own remembered values.
        if idx == 4, old < 4 { appDelegate.seedCustomIfNeeded(fromPreset: old) }
        appDelegate.selectedPreset = idx
        // The Custom rows and the Style selector appear/disappear with the
        // selection (Style is hidden for Instant/Short). Rebuild after the
        // slider finishes tracking — tearing it down mid-drag confuses AppKit.
        if (idx == 4) != (old == 4) || (idx >= 2) != (old >= 2) {
            DispatchQueue.main.async { [weak self] in
                self?.rebuild()
                self?.center()
            }
        }
    }

    /// Select an Animation Style (0 = Power Up, 1 = Level Up) and update the pills.
    private func selectStyle(_ idx: Int) {
        appDelegate?.animationStyle = idx
        stylePills.forEach { $0.setSelected($0.styleTag == idx) }
    }

    /// One labeled slider row of the Custom preset editor.
    private func addCustomRow(to c: NSView, top: CGFloat, title: String,
                              value: TimeInterval, sliderTag: Int, labelTag: Int) {
        let sliderW: CGFloat = 320
        let x = (contentW - sliderW) / 2

        let caption = NSTextField(labelWithString: title)
        caption.font = .systemFont(ofSize: NSFont.systemFontSize - 1)
        caption.textColor = .secondaryLabelColor
        caption.frame = NSRect(x: x, y: top - 16, width: 180, height: 16)
        c.addSubview(caption)

        let readout = NSTextField(labelWithString: Self.fmt(value))
        readout.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1,
                                                  weight: .regular)
        readout.textColor = .secondaryLabelColor
        readout.alignment = .right
        readout.frame = NSRect(x: x + sliderW - 80, y: top - 16, width: 80, height: 16)
        readout.tag = labelTag
        c.addSubview(readout)

        let slider = NSSlider(value: value, minValue: 0, maxValue: Self.customMax,
                              target: self, action: #selector(customSliderChanged(_:)))
        slider.frame = NSRect(x: x, y: top - 40, width: sliderW, height: 22)
        slider.tag = sliderTag
        c.addSubview(slider)
    }

    @objc private func customSliderChanged(_ sender: NSSlider) {
        // Continuous drag, snapped to the step so values read cleanly.
        let snapped = (sender.doubleValue / Self.customStep).rounded() * Self.customStep
        sender.doubleValue = snapped
        if sender.tag == 21 {
            appDelegate?.customKeyDelay = snapped
            (contentView?.viewWithTag(23) as? NSTextField)?.stringValue = Self.fmt(snapped)
        } else {
            appDelegate?.customAnimationLength = snapped
            (contentView?.viewWithTag(24) as? NSTextField)?.stringValue = Self.fmt(snapped)
        }
    }

    private static func fmt(_ v: TimeInterval) -> String { String(format: "%.2f s", v) }

    @objc private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            UserDefaults.standard.set(url.path, forKey: "targetAppPath")
            self.appDelegate?.invalidateTargetCache()
            self.updateAppDisplay()
        }
    }

    @objc private func openAxSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }

    @objc private func openCoffee() {
        NSWorkspace.shared.open(URL(string: "https://ko-fi.com/grokcodile")!)
    }

    @objc private func openSponsors() {
        NSWorkspace.shared.open(URL(string: "https://github.com/sponsors/grokcodile")!)
    }

    /// A little "note from the developer" popover that slides out of the Tip
    /// Jar link: a round headshot, a personal message, the two ways to support
    /// Key54, and a link to file issues.
    @objc private func openTipJar(_ sender: NSButton) {
        let w: CGFloat = 285, h: CGFloat = 284
        let v = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        // Round headshot — `headshot.png` bundled into Resources by build.sh.
        let d: CGFloat = 64
        let photo = NSView(frame: NSRect(x: (w - d) / 2, y: 204, width: d, height: d))
        photo.wantsLayer = true
        photo.layer?.cornerRadius = d / 2
        photo.layer?.masksToBounds = true
        photo.layer?.borderWidth = 1
        photo.layer?.borderColor = NSColor.separatorColor.cgColor
        if let url = Bundle.main.url(forResource: "headshot", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            var rect = CGRect(origin: .zero, size: img.size)
            photo.layer?.contents = img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            photo.layer?.contentsGravity = .resizeAspectFill
        } else {
            photo.layer?.backgroundColor = NSColor(white: 0.85, alpha: 1).cgColor
        }
        v.addSubview(photo)

        let greeting = NSTextField(labelWithString: "Hi, I'm Ethan 👋")
        greeting.font = .systemFont(ofSize: 15, weight: .semibold)
        greeting.alignment = .center
        greeting.frame = NSRect(x: 16, y: 176, width: w - 32, height: 20)
        v.addSubview(greeting)

        let body = NSTextField(wrappingLabelWithString:
            "Key54 is 100% free, but if it's earned a spot on your Mac, a small donation helps me keep it updated and supported!")
        body.font = .systemFont(ofSize: NSFont.systemFontSize - 1)
        body.textColor = .secondaryLabelColor
        body.alignment = .center
        body.frame = NSRect(x: 18, y: 118, width: w - 36, height: 52)
        v.addSubview(body)

        let btnW: CGFloat = 210
        let kofi = HoverButton(frame: NSRect(x: (w - btnW) / 2, y: 80, width: btnW, height: 30))
        kofi.title = "☕  Leave a tip on Ko-fi"
        kofi.target = self
        kofi.action = #selector(openCoffee)
        v.addSubview(kofi)

        let spon = HoverButton(frame: NSRect(x: (w - btnW) / 2, y: 42, width: btnW, height: 30))
        spon.title = "❤️  Sponsor me on GitHub"
        spon.target = self
        spon.action = #selector(openSponsors)
        v.addSubview(spon)

        // Subtle footer link to the repo's issues.
        let issue = LinkButton(title: "", target: self, action: #selector(openIssues))
        issue.isBordered = false
        let issueTitle = "Report a bug or request a feature" as NSString
        let issueAttr = NSMutableAttributedString(string: issueTitle as String)
        issueAttr.addAttributes([
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize - 2),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ], range: NSRange(location: 0, length: issueTitle.length))
        issue.attributedTitle = issueAttr
        issue.sizeToFit()
        issue.frame = NSRect(x: (w - issue.frame.width) / 2, y: 12,
                             width: issue.frame.width, height: 18)
        v.addSubview(issue)

        let vc = NSViewController()
        vc.view = v
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.contentSize = NSSize(width: w, height: h)
        pop.behavior = .transient
        tipPopover = pop
        pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxX)   // opens to the right of the jar
    }

    @objc private func openIssues() {
        NSWorkspace.shared.open(URL(string: "https://github.com/grokcodile/key54/issues")!)
    }
}

// MARK: - Trigger HUD

/// A transparent, click-through overlay that shows a glowing ⌘ "charging" ring
/// while the right Command key is held, then a burst when it triggers. Floats
/// above everything (including full-screen Spaces) without stealing focus.
/// The ring + icon sit on a Liquid Glass slab (macOS 26+) so the HUD reads
/// like a system bezel; older systems get the classic frosted HUD material.
final class TriggerHUD {
    /// How the hold is visualized. `.powerUp` is the classic accent ring sweep;
    /// `.levelUp` fills the glass slab like a glass of water. Chosen in settings
    /// (the "Animation Style" selector) and read fresh on each trigger.
    enum AnimationStyle { case powerUp, levelUp }
    private var animationStyle: AnimationStyle {
        UserDefaults.standard.integer(forKey: "animationStyle") == 1 ? .levelUp : .powerUp
    }

    private let size: CGFloat = 320   // generous so the expanding ring isn't clipped
    private let ringRadius: CGFloat = 52
    private let puckSize: CGFloat = 148

    private lazy var panel: NSPanel = makePanel()
    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let iconLayer = CALayer()
    // Level Up style: a rounded clip the size of the glass slab and a flat fill
    // body that rises from the bottom as the hold charges.
    private let waterClip = CALayer()
    private let waterRise = CALayer()
    private let waterShape = CAShapeLayer()
    private var puckView: NSView!     // glass slab behind the ring + icon
    private var puckRestFrame = NSRect.zero
    private var expandOnFire = true   // skip the radiate for very short holds
    private var fadeGeneration = 0    // invalidates stale fade-out completions
    private var animationLength: TimeInterval = 0.001   // current preset's fill time

    // MARK: Public

    func begin(fill: TimeInterval, icon: NSImage?) {
        positionHUD()
        expandOnFire = true
        let animationless = fill <= 0   // zero-charge preset (Short): no ring, larger icon

        // Cancel any in-flight fade and restore full window opacity (and the
        // glass slab's resting frame), or the panel stays pinned at its
        // faded-out state and never shows again.
        fadeGeneration += 1
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        panel.animator().alphaValue = 1
        puckView.animator().frame = puckRestFrame
        NSAnimationContext.endGrouping()

        let levelUpMode = (animationStyle == .levelUp) && !animationless
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ring.removeAllAnimations()
        track.removeAllAnimations()
        iconLayer.removeAllAnimations()
        waterClip.removeAllAnimations()
        waterRise.removeAllAnimations()
        waterShape.removeAllAnimations()
        // Re-resolve the accent color so a change in System Settings shows up
        // on the next trigger (CGColor snapshots don't track the dynamic color).
        let accent = NSColor.controlAccentColor
        ring.strokeColor = accent.cgColor
        ring.shadowColor = accent.cgColor
        ring.strokeEnd = 1   // full ring (the charge animation draws it on)
        // Only one visualization shows at a time; the other stays hidden.
        let powerUpMode = (animationStyle == .powerUp) && !animationless
        ring.opacity = powerUpMode ? 1 : 0   // also resets cancel()'s post-drain hide
        track.opacity = powerUpMode ? 1 : 0
        waterClip.opacity = levelUpMode ? 1 : 0
        if levelUpMode {
            // Solid accent with an accent glow at the surface, echoing the ring's
            // glow (re-resolve the dynamic accent for both fill and glow).
            waterShape.fillColor = accent.cgColor
            waterShape.shadowColor = accent.cgColor
            waterRise.transform = CATransform3DMakeTranslation(0, -puckSize, 0)   // start empty
        }
        // Power Up keeps the icon small so the ring fits around it; Level Up (and
        // the ringless Short/Instant presets) use the larger icon.
        let iconSize: CGFloat = (animationless || levelUpMode) ? 84 : 64
        iconLayer.frame = CGRect(x: size / 2 - iconSize / 2,
                                 y: size / 2 - iconSize / 2,
                                 width: iconSize, height: iconSize)
        if let icon {
            var rect = CGRect(origin: .zero, size: icon.size)
            iconLayer.contents = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        CATransaction.commit()

        panel.orderFrontRegardless()

        // Charge over the hold duration. "None" (fill == 0) clamps to a
        // near-instant charge. Remember the rate so an early release can drain
        // back at the same speed.
        animationLength = max(fill, 0.001)
        if levelUpMode {
            // Raise the water level from empty to full over the hold.
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = -puckSize
            rise.toValue = 0
            rise.duration = animationLength
            rise.timingFunction = CAMediaTimingFunction(name: .linear)
            rise.fillMode = .forwards
            rise.isRemovedOnCompletion = false
            waterRise.add(rise, forKey: "fill")
        } else if powerUpMode {
            // Draw the ring on over the hold duration.
            let anim = CABasicAnimation(keyPath: "strokeEnd")
            anim.fromValue = 0
            anim.toValue = 1
            anim.duration = animationLength
            anim.timingFunction = CAMediaTimingFunction(name: .linear)
            anim.fillMode = .forwards
            anim.isRemovedOnCompletion = false
            ring.add(anim, forKey: "fill")
        }
    }

    /// Early release: drain the ring back at the same rate it charged, then
    /// dissolve with the same grace as a full-duration dismissal — but
    /// settling slightly inward, the opposite of the firing swell.
    func cancel(fade: TimeInterval = 0.4) {
        if animationStyle == .levelUp { cancelWater(fade: fade); return }
        // Snap the ring to its current visible value.
        let cur = ring.presentation()?.strokeEnd ?? ring.strokeEnd
        ring.removeAnimation(forKey: "fill")
        CATransaction.begin(); CATransaction.setDisableActions(true); ring.strokeEnd = cur; CATransaction.commit()

        let drain = CABasicAnimation(keyPath: "strokeEnd")
        drain.fromValue = cur
        drain.toValue = 0
        // Drain at 1.5× the charge rate — present enough to read as a
        // discharge, brisk enough that backing out never feels like a wait.
        drain.duration = max(TimeInterval(cur) * animationLength / 1.5, 0.01)
        drain.timingFunction = CAMediaTimingFunction(name: .linear)
        drain.fillMode = .forwards
        drain.isRemovedOnCompletion = false

        let gen = fadeGeneration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            // Skip the dissolve if a new hold started during the drain.
            guard let self, self.fadeGeneration == gen else { return }
            self.dissolve(fade: fade, scaleTo: 0.9, layers: [self.track, self.iconLayer])
        }
        ring.strokeEnd = 0
        ring.opacity = 0
        ring.add(drain, forKey: "drain")
        // A zero-length stroke with a round cap still draws the cap — a dot at
        // the path start. Hold full opacity through the drain, then wink the
        // ring out at the exact instant it empties; hiding it from the
        // completion block instead can land a frame late and flash the dot.
        let hide = CABasicAnimation(keyPath: "opacity")
        hide.fromValue = 1
        hide.toValue = 0
        hide.duration = 0.01
        hide.beginTime = ring.convertTime(CACurrentMediaTime(), from: nil) + drain.duration
        hide.fillMode = .backwards
        ring.add(hide, forKey: "hide")
        CATransaction.commit()
    }

    /// Trigger the dissolve. `fade` is how long everything takes to fade;
    /// `swellTo` is a slight gel-like expansion of the whole HUD — ring, icon,
    /// and glass slab together — as it goes, like a system bezel releasing.
    /// Kept subtle so nothing escapes past the slab's edge.
    func fire(fade: TimeInterval = 0.4, swellTo: CGFloat = 1.12) {
        if animationStyle == .levelUp { fireWater(fade: fade, swellTo: swellTo); return }
        ring.removeAnimation(forKey: "fill")
        CATransaction.begin(); CATransaction.setDisableActions(true); ring.strokeEnd = 1; CATransaction.commit()

        guard expandOnFire else { fadeOut(duration: fade); return }

        // Hide the faint track instantly so only the glowing ring remains.
        CATransaction.begin(); CATransaction.setDisableActions(true); track.opacity = 0; CATransaction.commit()

        // Ring and icon swell in lockstep with the glass slab below them.
        dissolve(fade: fade, scaleTo: swellTo, layers: [ring, iconLayer])
    }

    /// Water early-release: drain the level back down at ~1.5× the fill rate,
    /// then dissolve inward — the liquid analogue of the ring's discharge.
    private func cancelWater(fade: TimeInterval) {
        let cur = waterTranslationY()
        waterRise.removeAnimation(forKey: "fill")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        waterRise.transform = CATransform3DMakeTranslation(0, cur, 0)
        CATransaction.commit()

        let level = max(0, min(1, 1 + cur / puckSize))   // 0 empty … 1 full
        let drain = CABasicAnimation(keyPath: "transform.translation.y")
        drain.fromValue = cur
        drain.toValue = -puckSize
        drain.duration = max(Double(level) * animationLength / 1.5, 0.01)
        drain.timingFunction = CAMediaTimingFunction(name: .linear)
        drain.fillMode = .forwards
        drain.isRemovedOnCompletion = false

        let gen = fadeGeneration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.fadeGeneration == gen else { return }
            self.dissolve(fade: fade, scaleTo: 0.9, layers: [self.iconLayer, self.waterClip])
        }
        waterRise.transform = CATransform3DMakeTranslation(0, -puckSize, 0)
        waterRise.add(drain, forKey: "drain")
        CATransaction.commit()
    }

    /// Water fire: top the level off fast, then swell + fade the whole HUD
    /// (icon and the filled glass together) like the ring's gel release.
    private func fireWater(fade: TimeInterval, swellTo: CGFloat) {
        waterRise.removeAnimation(forKey: "fill")
        guard expandOnFire, waterClip.opacity > 0 else { fadeOut(duration: fade); return }

        let cur = waterTranslationY()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        waterRise.transform = CATransform3DMakeTranslation(0, 0, 0)
        CATransaction.commit()
        let top = CABasicAnimation(keyPath: "transform.translation.y")
        top.fromValue = cur
        top.toValue = 0
        top.duration = 0.14
        top.timingFunction = CAMediaTimingFunction(name: .easeOut)
        top.fillMode = .forwards
        top.isRemovedOnCompletion = false
        waterRise.add(top, forKey: "top")

        dissolve(fade: fade, scaleTo: swellTo, layers: [iconLayer, waterClip])
    }

    /// Current animated water offset (negative = below the brim).
    private func waterTranslationY() -> CGFloat {
        guard let n = waterRise.presentation()?.value(forKeyPath: "transform.translation.y") as? NSNumber
        else { return 0 }
        return CGFloat(n.doubleValue)
    }

    /// Shared exit: fade the panel while the given layers and the glass slab
    /// scale gently to `scaleTo` — outward (> 1) when firing, inward (< 1)
    /// on an early release.
    private func dissolve(fade: TimeInterval, scaleTo: CGFloat, layers: [CALayer]) {
        for layer in layers {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1.0
            scale.toValue = scaleTo
            scale.duration = fade
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
            scale.fillMode = .forwards
            scale.isRemovedOnCompletion = false
            layer.add(scale, forKey: "dissolveScale")
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = fade
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            puckView.animator().frame = puckRestFrame.insetBy(
                dx: -puckRestFrame.width * (scaleTo - 1) / 2,
                dy: -puckRestFrame.height * (scaleTo - 1) / 2)
        }

        fadeOut(duration: fade)
    }

    /// Immediately remove the panel and clear every animation, with no fade.
    /// Called right before a Space-changing toggle so the HUD is gone from the
    /// window server before the full-screen transition snapshots the outgoing
    /// Space — otherwise the (still-fading) ring is captured in that snapshot
    /// and appears to slide away with the Space.
    func hideNow() {
        fadeGeneration += 1   // a pending fade-out completion must not fire later
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.removeAllAnimations()
        track.removeAllAnimations()
        iconLayer.removeAllAnimations()
        waterClip.removeAllAnimations()
        waterRise.removeAllAnimations()
        waterShape.removeAllAnimations()
        CATransaction.commit()
        panel.alphaValue = 0   // begin() restores this on the next show
        panel.orderOut(nil)
    }

    // MARK: Setup

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .screenSaver
        p.ignoresMouseEvents = true
        // canJoinAllSpaces + stationary: present on every Space and pinned in
        // place, so it doesn't slide with the Space-switch transition.
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false

        let v = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.clear.cgColor
        v.layer?.isOpaque = false

        // Glass slab behind the ring + icon, sized so the ring (and the slight
        // firing swell) sits comfortably inside it.
        puckRestFrame = NSRect(x: (size - puckSize) / 2, y: (size - puckSize) / 2,
                               width: puckSize, height: puckSize)
        puckView = Self.glassBackdrop(frame: puckRestFrame, cornerRadius: 36)
        v.addSubview(puckView)

        // The animated ring/icon layers live in their own view above the glass.
        let overlay = NSView(frame: v.bounds)
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.clear.cgColor
        v.addSubview(overlay)
        buildLayers(in: overlay.layer!)
        buildWaterLayers(in: overlay.layer!)

        p.contentView = v
        return p
    }

    /// A Liquid Glass backdrop on macOS 26+, falling back to the classic
    /// frosted HUD material on older systems (or older build toolchains).
    private static func glassBackdrop(frame: NSRect, cornerRadius: CGFloat) -> NSView {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView(frame: frame)
            g.cornerRadius = cornerRadius
            return g
        }
        #endif
        let v = NSVisualEffectView(frame: frame)
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.maskImage = roundedMask(cornerRadius: cornerRadius)
        return v
    }

    /// Stretchable rounded-rect mask — NSVisualEffectView needs this (rather
    /// than a layer cornerRadius) so the blur itself is clipped to the shape.
    private static func roundedMask(cornerRadius r: CGFloat) -> NSImage {
        let edge = r * 2 + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }

    private func buildLayers(in root: CALayer) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let c = CGPoint(x: size / 2, y: size / 2)
        let r = ringRadius
        let arc = CGMutablePath()
        arc.addArc(center: c, radius: r, startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 2, clockwise: true)

        track.path = arc
        track.fillColor = NSColor.clear.cgColor
        track.strokeColor = NSColor(white: 1, alpha: 0.14).cgColor
        track.lineWidth = 7
        track.frame = root.bounds
        track.contentsScale = scale
        root.addSublayer(track)

        ring.path = arc
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = NSColor.controlAccentColor.cgColor
        ring.lineWidth = 7
        ring.lineCap = .round
        ring.strokeEnd = 0
        ring.frame = root.bounds
        ring.contentsScale = scale
        ring.shadowColor = NSColor.controlAccentColor.cgColor
        ring.shadowRadius = 8
        ring.shadowOpacity = 0.9
        ring.shadowOffset = .zero
        root.addSublayer(ring)

        // The chosen app's icon sits in the center of the ring. (begin() sets
        // the frame each show — larger when the zero-charge preset hides the ring.)
        let iconSize: CGFloat = 64
        iconLayer.frame = CGRect(x: c.x - iconSize / 2, y: c.y - iconSize / 2,
                                 width: iconSize, height: iconSize)
        iconLayer.contentsGravity = .resizeAspect
        iconLayer.contentsScale = scale
        root.addSublayer(iconLayer)
    }

    /// Build the water-fill layers (hidden unless `animationStyle == .levelUp`): a rounded
    /// clip matching the glass slab and a flat fill body. Inserted *below* the
    /// icon so the icon stays crisp as the level passes it.
    private func buildWaterLayers(in root: CALayer) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let o = (size - puckSize) / 2
        waterClip.frame = CGRect(x: o, y: o, width: puckSize, height: puckSize)
        waterClip.cornerRadius = 36           // matches the glass slab
        waterClip.masksToBounds = true
        waterClip.opacity = 0
        root.insertSublayer(waterClip, below: iconLayer)

        waterRise.frame = waterClip.bounds
        waterClip.addSublayer(waterRise)

        // A flat-topped fill the size of the slab; raising `waterRise` reveals it
        // from the bottom up.
        waterShape.path = CGPath(rect: waterClip.bounds, transform: nil)
        waterShape.frame = waterClip.bounds
        waterShape.fillColor = NSColor.controlAccentColor.cgColor   // solid; reads cleanly in light mode
        // Accent glow at the surface, echoing the Power Up ring's glow. The clip
        // confines it to the slab, so it reads as a soft band riding the waterline.
        waterShape.shadowColor = NSColor.controlAccentColor.cgColor
        waterShape.shadowRadius = 8     // KNOB: glow softness (matches the ring)
        waterShape.shadowOpacity = 0.9
        waterShape.shadowOffset = .zero
        waterShape.contentsScale = scale
        waterRise.addSublayer(waterShape)
    }

    // MARK: Helpers

    private func positionHUD() {
        // Fixed near the bottom-center of the active screen, like the macOS
        // volume/brightness HUD.
        let m = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main
        guard let f = screen?.visibleFrame else { return }
        let x = f.midX - size / 2
        let y = f.minY + 150 - size / 2   // ring center ~150 pt above the bottom
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func fadeOut(duration: TimeInterval) {
        // Fade the whole panel via window alpha so the glass slab and the
        // ring/icon layers all dissolve together — material views don't fade
        // reliably through a sublayer opacity animation.
        fadeGeneration += 1
        let gen = fadeGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.fadeGeneration == gen else { return }
            self.panel.orderOut(nil)
        })
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Minimal main menu so ⌘Q works even though the app has no menu bar.
let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit Key54", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu
app.mainMenu = mainMenu

app.run()
