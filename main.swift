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
        NSApp.setActivationPolicy(.accessory)

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

    // MARK: - App tracking

    @objc private func appDidActivate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
        let bundleID = app.bundleIdentifier
        // Track the app to return to — but never the target itself, and never
        // Trapdoor (so opening Settings then summoning doesn't make us the
        // "previous" app).
        if bundleID != resolvedBundleID(), bundleID != Bundle.main.bundleIdentifier {
            previousApp = app
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
    /// Which preset is active (0 = Instant … 3 = Long). Defaults to Medium.
    var selectedPreset: Int {
        get { max(0, min(3, UserDefaults.standard.object(forKey: "presetIndex") as? Int ?? 2)) }
        set { UserDefaults.standard.set(newValue, forKey: "presetIndex") }
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
        let buffer = SettingsWindow.bufferValues[selectedPreset]
        bufferTimer = Timer.scheduledTimer(withTimeInterval: buffer, repeats: false) { [weak self] _ in
            self?.bufferTimer = nil
            self?.arm()
        }
    }

    /// Engaged after the buffer: show the ring's charge sweep, then fire + toggle.
    private func arm() {
        let stop = selectedPreset
        let charge = SettingsWindow.durationValues[stop]
        // Short has no charge sweep, so give its dissolve extra time —
        // at the normal fade the icon just flashes.
        let fade = stop == 1 ? 0.6 : SettingsWindow.fadeConstant
        let swell = SettingsWindow.swellConstant

        // "Instant": no HUD, no ceremony — switch the moment the key is held.
        if stop == 0 {
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

class SettingsWindow: NSWindow {
    weak var appDelegate: AppDelegate?
    private var axPollTimer: Timer?
    private let contentW: CGFloat = 460
    private let pad: CGFloat = 32
    private let bannerH: CGFloat = 84
    private let bannerGap: CGFloat = 16

    // Hold-duration presets. Each stop has its own dead-zone buffer and charge
    // sweep (how long the ring fills); the dissolve and swell are constant. The
    // full trigger time is buffer + charge. "Instant" skips the animation
    // entirely and switches the moment the key is held.
    static let durationLabels = ["Instant", "Short", "Medium", "Long"]
    static let bufferValues:   [TimeInterval] = [0.0, 0.5, 0.5, 0.7]   // pre-buffer dead-zone
    static let durationValues: [TimeInterval] = [0.0, 0.0, 0.4, 0.6]   // charge sweep
    static let fadeConstant: TimeInterval = 0.4                        // dissolve
    static let swellConstant: CGFloat = 1.12                           // gel-release expansion

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
        let needsBanner = !AXIsProcessTrusted()
        let innerW = contentW - pad * 2

        // Fixed vertical metrics (top → bottom). The content view runs under
        // the transparent titlebar, so the top margin includes its height.
        let topMargin: CGFloat = 56
        let titleH: CGFloat = 36
        let descH: CGFloat = 92
        let chooseH: CGFloat = 32
        let sliderBlockH: CGFloat = 68  // caption + slider + tick labels
        let bottomBarH: CGFloat = 86    // Quit / Done row + coffee link + bottom margin
        let g: CGFloat = 16             // generic gap

        // App-selection box (icon + name + change button) metrics
        let iconH: CGFloat = 48
        let nameH: CGFloat = 22
        let boxPadV: CGFloat = 16
        let iconNameGap: CGFloat = 6
        let nameButtonGap: CGFloat = 14
        let appBoxH = boxPadV + iconH + iconNameGap + nameH + nameButtonGap + chooseH + boxPadV

        let bannerBlock = needsBanner ? (bannerGap + bannerH) : 0
        let totalH = topMargin + titleH + g + descH + g + appBoxH
                   + g + sliderBlockH + bannerBlock + g + bottomBarH

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
        let titleLabel = NSTextField(labelWithString: "Trapdoor")
        titleLabel.frame = NSRect(x: pad, y: y, width: innerW, height: titleH)
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.alignment = .center
        c.addSubview(titleLabel)

        // Description
        y -= g + descH
        let descPara = NSMutableParagraphStyle()
        descPara.alignment = .center
        descPara.paragraphSpacing = 10
        descPara.lineBreakMode = .byWordWrapping
        let descStr = NSAttributedString(
            string: "Hold the Command (⌘) key on the right side of\u{2028}the keyboard to summon the application below.\nHold it again to return to what you were doing.",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize + 1),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: descPara,
            ])
        let desc = NSTextField(labelWithAttributedString: descStr)
        desc.frame = NSRect(x: pad, y: y, width: innerW, height: descH)
        desc.alignment = .center
        desc.usesSingleLineMode = false
        desc.cell?.wraps = true
        desc.maximumNumberOfLines = 0
        c.addSubview(desc)

        // App-selection section — icon + name + change button inside a gray box
        y -= g + appBoxH
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

        // Hold-duration: four discrete stops (Instant / Short / Medium / Long).
        y -= g + sliderBlockH
        let caption = NSTextField(labelWithString: "Hold Duration")
        caption.frame = NSRect(x: pad, y: y + sliderBlockH - 20, width: innerW, height: 18)
        caption.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        caption.textColor = .secondaryLabelColor
        caption.alignment = .center
        c.addSubview(caption)

        let sliderW: CGFloat = 320
        let sliderX = (contentW - sliderW) / 2
        let sliderY = y + 16
        let labels = SettingsWindow.durationLabels
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

        // Bottom bar: Quit (secondary, left) + Done (primary, right)
        let btnW: CGFloat = 100
        let barY: CGFloat = 46
        let quitBtn = NSButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quitBtn.frame = NSRect(x: pad, y: barY, width: btnW, height: 32)
        quitBtn.bezelStyle = .rounded
        c.addSubview(quitBtn)

        let doneBtn = NSButton(title: "Done", target: self, action: #selector(saveAndClose))
        doneBtn.frame = NSRect(x: contentW - pad - btnW, y: barY, width: btnW, height: 32)
        doneBtn.bezelStyle = .rounded
        doneBtn.keyEquivalent = "\r"
        c.addSubview(doneBtn)

        // "Buy me a coffee" link, centered below the buttons
        let coffeeBtn = NSButton(title: "", target: self, action: #selector(openCoffee))
        coffeeBtn.isBordered = false
        let coffeeTitle = "☕ Buy me a coffee" as NSString
        let coffeeAttr = NSMutableAttributedString(string: coffeeTitle as String)
        coffeeAttr.addAttributes([
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize - 1),
        ], range: NSRange(location: 0, length: coffeeTitle.length))
        // Underline only the words, not the emoji.
        let textStart = coffeeTitle.range(of: "Buy").location
        if textStart != NSNotFound {
            coffeeAttr.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                                    range: NSRange(location: textStart, length: coffeeTitle.length - textStart))
        }
        coffeeBtn.attributedTitle = coffeeAttr
        coffeeBtn.sizeToFit()
        coffeeBtn.frame = NSRect(x: (contentW - coffeeBtn.frame.width) / 2, y: 16,
                                 width: coffeeBtn.frame.width, height: 20)
        coffeeBtn.toolTip = "Support Trapdoor on Ko-fi"
        c.addSubview(coffeeBtn)

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
        orderOut(nil)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let idx = max(0, min(Self.durationLabels.count - 1, Int(sender.doubleValue.rounded())))
        appDelegate?.selectedPreset = idx
    }

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
}

// MARK: - Trigger HUD

/// A transparent, click-through overlay that shows a glowing ⌘ "charging" ring
/// while the right Command key is held, then a burst when it triggers. Floats
/// above everything (including full-screen Spaces) without stealing focus.
/// The ring + icon sit on a Liquid Glass slab (macOS 26+) so the HUD reads
/// like a system bezel; older systems get the classic frosted HUD material.
final class TriggerHUD {
    private let size: CGFloat = 320   // generous so the expanding ring isn't clipped
    private let ringRadius: CGFloat = 52

    private lazy var panel: NSPanel = makePanel()
    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let iconLayer = CALayer()
    private var puckView: NSView!     // glass slab behind the ring + icon
    private var puckRestFrame = NSRect.zero
    private var expandOnFire = true   // skip the radiate for very short holds
    private var fadeGeneration = 0    // invalidates stale fade-out completions
    private var chargeDuration: TimeInterval = 0.001   // current preset's fill time

    // MARK: Public

    func begin(fill: TimeInterval, icon: NSImage?) {
        positionHUD()
        expandOnFire = true
        let ringless = fill <= 0   // zero-charge preset (Short): no ring, larger icon

        // Cancel any in-flight fade and restore full window opacity (and the
        // glass slab's resting frame), or the panel stays pinned at its
        // faded-out state and never shows again.
        fadeGeneration += 1
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        panel.animator().alphaValue = 1
        puckView.animator().frame = puckRestFrame
        NSAnimationContext.endGrouping()

        CATransaction.begin(); CATransaction.setDisableActions(true)
        ring.removeAllAnimations()
        track.removeAllAnimations()
        iconLayer.removeAllAnimations()
        // Re-resolve the accent color so a change in System Settings shows up
        // on the next trigger (CGColor snapshots don't track the dynamic color).
        ring.strokeColor = NSColor.controlAccentColor.cgColor
        ring.shadowColor = NSColor.controlAccentColor.cgColor
        ring.opacity = ringless ? 0 : 1   // also resets cancel()'s post-drain hide
        track.opacity = ringless ? 0 : 1
        ring.strokeEnd = 1   // full ring (the charge animation draws it on)
        let iconSize: CGFloat = ringless ? 84 : 64
        iconLayer.frame = CGRect(x: size / 2 - iconSize / 2,
                                 y: size / 2 - iconSize / 2,
                                 width: iconSize, height: iconSize)
        if let icon {
            var rect = CGRect(origin: .zero, size: icon.size)
            iconLayer.contents = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        CATransaction.commit()

        panel.orderFrontRegardless()

        // Draw the ring on over the hold duration. "None" (fill == 0) clamps to
        // a near-instant charge — same animation, just immediate. Remember the
        // rate so an early release can drain back at the same speed.
        chargeDuration = max(fill, 0.001)
        let anim = CABasicAnimation(keyPath: "strokeEnd")
        anim.fromValue = 0
        anim.toValue = 1
        anim.duration = chargeDuration
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        ring.add(anim, forKey: "fill")
    }

    /// Early release: drain the ring back at the same rate it charged, then
    /// dissolve with the same grace as a full-duration dismissal — but
    /// settling slightly inward, the opposite of the firing swell.
    func cancel(fade: TimeInterval = 0.4) {
        // Snap the ring to its current visible value.
        let cur = ring.presentation()?.strokeEnd ?? ring.strokeEnd
        ring.removeAnimation(forKey: "fill")
        CATransaction.begin(); CATransaction.setDisableActions(true); ring.strokeEnd = cur; CATransaction.commit()

        let drain = CABasicAnimation(keyPath: "strokeEnd")
        drain.fromValue = cur
        drain.toValue = 0
        // Drain at 1.5× the charge rate — present enough to read as a
        // discharge, brisk enough that backing out never feels like a wait.
        drain.duration = max(TimeInterval(cur) * chargeDuration / 1.5, 0.01)
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
        ring.removeAnimation(forKey: "fill")
        CATransaction.begin(); CATransaction.setDisableActions(true); ring.strokeEnd = 1; CATransaction.commit()

        guard expandOnFire else { fadeOut(duration: fade); return }

        // Hide the faint track instantly so only the glowing ring remains.
        CATransaction.begin(); CATransaction.setDisableActions(true); track.opacity = 0; CATransaction.commit()

        // Ring and icon swell in lockstep with the glass slab below them.
        dissolve(fade: fade, scaleTo: swellTo, layers: [ring, iconLayer])
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
        let puckSize: CGFloat = 148
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
appMenu.addItem(withTitle: "Quit Trapdoor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu
app.mainMenu = mainMenu

app.run()
