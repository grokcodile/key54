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
    var holdDuration: TimeInterval {
        get { UserDefaults.standard.object(forKey: "holdDuration") as? TimeInterval ?? 0.3 }
        set { UserDefaults.standard.set(newValue, forKey: "holdDuration") }
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
        guard holdTimer == nil else { return }
        holdTimer = Timer.scheduledTimer(withTimeInterval: holdDuration, repeats: false) { [weak self] _ in
            self?.holdTimer = nil
            self?.toggleApp()
        }
    }

    func cancelToggle() {
        holdTimer?.invalidate()
        holdTimer = nil
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

    init(delegate: AppDelegate) {
        self.appDelegate = delegate
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        self.title = ""
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

        // Fixed vertical metrics (top → bottom)
        let topMargin: CGFloat = 28
        let titleH: CGFloat = 36
        let descH: CGFloat = 92
        let chooseH: CGFloat = 32
        let sliderBlockH: CGFloat = 64  // caption + slider + tick labels
        let bottomBarH: CGFloat = 60    // Quit / Done row + bottom margin
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

        // Fresh content view
        let c = NSView(frame: NSRect(x: 0, y: 0, width: contentW, height: totalH))
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

        // Hold-duration slider (centered under the app selector)
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

        let maxTenths = 6                       // longest hold = 0.6s
        let slider = NSSlider(value: appDelegate?.holdDuration ?? 0.3,
                              minValue: 0.0, maxValue: Double(maxTenths) / 10.0,
                              target: self, action: #selector(sliderChanged(_:)))
        slider.frame = NSRect(x: sliderX, y: sliderY, width: sliderW, height: 22)
        slider.numberOfTickMarks = maxTenths + 1   // every 0.1
        slider.tickMarkPosition = .below
        c.addSubview(slider)

        // Per-tick time labels (aligned under each 0.1s mark)
        let knobInset: CGFloat = 8              // track inset for the knob
        let trackLeft = sliderX + knobInset
        let trackW = sliderW - knobInset * 2
        for i in 0...maxTenths {
            let v = Double(i) / Double(maxTenths)
            let text: String = (i == 0) ? "0" : String(format: ".%d", i)
            let lbl = NSTextField(labelWithString: text)
            lbl.font = .systemFont(ofSize: 9)
            lbl.textColor = .tertiaryLabelColor
            lbl.alignment = .center
            let lw: CGFloat = 20
            let cx = trackLeft + CGFloat(v) * trackW
            lbl.frame = NSRect(x: cx - lw / 2, y: y - 2, width: lw, height: 12)
            c.addSubview(lbl)
        }

        // Bottom bar: Quit (secondary, left) + Done (primary, right)
        let btnW: CGFloat = 100
        let quitBtn = NSButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quitBtn.frame = NSRect(x: pad, y: 24, width: btnW, height: 32)
        quitBtn.bezelStyle = .rounded
        c.addSubview(quitBtn)

        let doneBtn = NSButton(title: "Done", target: self, action: #selector(saveAndClose))
        doneBtn.frame = NSRect(x: contentW - pad - btnW, y: 24, width: btnW, height: 32)
        doneBtn.bezelStyle = .rounded
        doneBtn.keyEquivalent = "\r"
        c.addSubview(doneBtn)

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
        appDelegate?.holdDuration = sender.doubleValue
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
