import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let env = ProcessInfo.processInfo.environment
    private let tracker = HeadTracker()
    private lazy var cursor = CursorController(dryRun: env["HEADMOUSE_DRYRUN"] == "1")
    private let dwell = DwellController()
    private let jawRecorder = JawRecorder()

    private var enabledItem: NSMenuItem!
    private var dwellItem: NSMenuItem!
    private var dwellPauseItem: NSMenuItem!
    private var scrollItem: NSMenuItem!
    private var invertScrollItem: NSMenuItem!
    private var stickyItem: NSMenuItem!
    private var assistItem: NSMenuItem!
    private var nodItem: NSMenuItem!
    private var invertXItem: NSMenuItem!
    private var invertYItem: NSMenuItem!
    private var statusLine: NSMenuItem!
    private var speedItems: [NSMenuItem] = []
    private var dwellTimeItems: [NSMenuItem] = []
    private var scrollSpeedItems: [NSMenuItem] = []

    private var lastTrusted: Bool?
    private var trustTimer: Timer?

    private var enabled = false {
        didSet {
            if enabled { cursor.start() } else { cursor.stop() }
            tracker.resetReference()
            dwell.active = enabled
            updateUI()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        wire()
        CursorController.requestAccessibility()
        tracker.start()
        log("Accessibility: \(CursorController.isTrusted ? "granted" : "NOT granted (cursor moves, but no clicks or scrolling)")")
        if cursor.dryRun { log("DRY RUN: clicks and scrolls are logged, not performed") }
        if env["HEADMOUSE_AUTOSTART"] == "1" { enabled = true }
        if env["HEADMOUSE_RECORD_JAW"] == "1" { recordJaw() }
        lastTrusted = CursorController.isTrusted
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.checkTrust()
        }
        updateUI()
    }

    func applicationWillTerminate(_ notification: Notification) {
        cursor.stop()
    }

    /// Notice when Accessibility is granted or revoked while running.
    private func checkTrust() {
        let trusted = CursorController.isTrusted
        guard trusted != lastTrusted else { return }
        lastTrusted = trusted
        log("Accessibility changed: \(trusted ? "granted" : "NOT granted")")
        updateUI()
    }

    // MARK: Logging

    /// Logs to the system log and to ~/Library/Logs/HeadMouse.log (handy for debugging).
    private let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/HeadMouse.log")
    private let logStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private func log(_ msg: String) {
        NSLog("[HeadMouse] %@", msg)
        let line = "\(logStamp.string(from: Date())) \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    // MARK: Menu

    private func buildMenu() {
        // On notched MacBooks a crowded menu bar hides new icons behind the camera
        // notch. Ask for a spot near the right edge the first time (macOS remembers
        // it after that, including if you ⌘-drag the icon somewhere else).
        let positionKey = "NSStatusItem Preferred Position HeadMouse"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(Self.preferredIconOffset, forKey: positionKey)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "HeadMouse"
        statusItem.behavior = []
        let menu = NSMenu()

        statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        enabledItem = addItem(menu, "Head Control", #selector(toggleEnabled), key: "h")
        menu.addItem(.separator())

        dwellItem = addItem(menu, "Dwell Click (hold still to click)", #selector(toggleDwell))
        dwellPauseItem = addItem(menu, "Pause Dwell", #selector(toggleDwellPause), key: "p")
        dwellTimeItems = addChoices(menu, "Dwell Time",
                                    [("0.6 s", 0.6), ("0.8 s", 0.8), ("1.0 s", 1.0), ("1.3 s", 1.3)],
                                    #selector(setDwellTime(_:)))
        menu.addItem(.separator())

        scrollItem = addItem(menu, "Tilt to Scroll", #selector(toggleScroll))
        invertScrollItem = addItem(menu, "Invert Scroll Direction", #selector(toggleInvertScroll))
        scrollSpeedItems = addChoices(menu, "Scroll Speed",
                                      [("Slow", 1200.0), ("Medium", 2500.0), ("Fast", 4500.0)],
                                      #selector(setScrollSpeed(_:)))
        menu.addItem(.separator())

        stickyItem = addItem(menu, "Sticky Buttons", #selector(toggleSticky))
        assistItem = addItem(menu, "Click Assist (snap to nearby buttons)", #selector(toggleAssist))
        nodItem = addItem(menu, "Nod to Click", #selector(toggleNod), key: "n")
        speedItems = addChoices(menu, "Pointer Speed",
                                [("Low", 2000.0), ("Medium", 3200.0), ("High", 4500.0), ("Very High", 6500.0)],
                                #selector(setSpeed(_:)))
        invertXItem = addItem(menu, "Invert Horizontal", #selector(toggleInvertX))
        invertYItem = addItem(menu, "Invert Vertical", #selector(toggleInvertY))

        menu.addItem(.separator())
        _ = addItem(menu, "Record Jaw Calibration…", #selector(recordJaw))
        menu.addItem(.separator())
        _ = addItem(menu, "Fix Accessibility Permission…", #selector(fixAccessibility))
        _ = addItem(menu, "Open Accessibility Settings…", #selector(openAccessibility))
        _ = addItem(menu, "Open Motion Settings…", #selector(openMotion))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit HeadMouse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    /// Distance from the right screen edge for the icon on first launch.
    private static let preferredIconOffset = 260.0

    /// Opening HeadMouse.app again (Finder, Spotlight, Dock) shows the menu at the
    /// cursor, in case the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMenuAtCursor()
        return false
    }

    private func showMenuAtCursor() {
        log("Showing menu at cursor")
        statusItem.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    private func addChoices(_ menu: NSMenu, _ title: String, _ choices: [(String, Double)],
                            _ action: Selector) -> [NSMenuItem] {
        let sub = NSMenu()
        var items: [NSMenuItem] = []
        for (label, value) in choices {
            let item = NSMenuItem(title: label, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = value
            sub.addItem(item)
            items.append(item)
        }
        let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        root.submenu = sub
        menu.addItem(root)
        return items
    }

    private func wire() {
        tracker.onDelta = { [weak self] delta in
            guard let self, self.enabled else { return }
            self.cursor.apply(delta)
        }
        tracker.onConnectionChange = { [weak self] connected in
            guard let self else { return }
            if !connected && self.cursor.isDragging { self.cursor.endDrag(at: CGEvent(source: nil)?.location ?? .zero) }
            self.cursor.reset()
            self.dwell.logic.disarm()
            self.log(connected ? "AirPods motion connected" : "AirPods motion disconnected")
            self.updateUI()
        }
        tracker.onRawMotion = { [weak self] m in self?.jawRecorder.record(m) }
        jawRecorder.onLog = { [weak self] in self?.log($0) }
        tracker.onStatus = { [weak self] msg in
            self?.statusLine.title = msg
            self?.log(msg)
        }

        cursor.onLog = { [weak self] in self?.log($0) }
        cursor.onDragChange = { [weak self] _ in self?.updateUI() }
        cursor.onScrollChange = { [weak self] _ in self?.updateUI() }
        cursor.onFrame = { [weak self] now, point, travel, external in
            guard let self else { return }
            self.dwell.frame(now: now, point: point, headTravel: travel,
                             external: external, scrolling: self.cursor.isScrolling)
        }

        dwell.onLog = { [weak self] in
            self?.log($0)
            self?.updateUI()
        }
        dwell.onMenu = { [weak self] in self?.showMenuAtCursor() }
        dwell.isDragging = { [weak self] in self?.cursor.isDragging ?? false }
        dwell.perform = { [weak self] action, point in
            guard let self else { return }
            switch action {
            case .left: self.cursor.click(at: point)
            case .double: self.cursor.click(at: point, count: 2)
            case .right: self.cursor.rightClick(at: point)
            case .drag: self.cursor.toggleDrag(at: point)
            }
        }
    }

    private func updateUI() {
        let airpods = tracker.isConnected ? "AirPods connected" : "Waiting for AirPods…"
        let access = CursorController.isTrusted ? "" : " · clicks blocked: use Fix Accessibility Permission"
        var extra = ""
        if cursor.isDragging { extra += " · DRAGGING" }
        if dwell.paused { extra += " · dwell paused" }
        statusLine.title = airpods + " (motion: \(tracker.authorizationDescription))" + access + extra

        enabledItem.state = enabled ? .on : .off
        dwellItem.state = dwell.enabled ? .on : .off
        dwellPauseItem.state = dwell.paused ? .on : .off
        dwellPauseItem.isEnabled = dwell.enabled
        scrollItem.state = cursor.tiltScroll ? .on : .off
        invertScrollItem.state = cursor.scroller.invert ? .on : .off
        stickyItem.state = cursor.stickyButtons ? .on : .off
        assistItem.state = cursor.clickAssist ? .on : .off
        nodItem.state = cursor.nodToClick ? .on : .off
        invertXItem.state = cursor.invertX ? .on : .off
        invertYItem.state = cursor.invertY ? .on : .off
        mark(speedItems, cursor.shaper.maxGain)
        mark(dwellTimeItems, dwell.logic.dwellTime)
        mark(scrollSpeedItems, cursor.scroller.maxSpeed)

        let symbol: String
        if enabled && !CursorController.isTrusted { symbol = "exclamationmark.triangle.fill" }
        else if cursor.isDragging { symbol = "hand.point.up.left.fill" }
        else if cursor.isScrolling { symbol = "arrow.up.arrow.down" }
        else { symbol = enabled ? "face.smiling.inverse" : "face.smiling" }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "HeadMouse")
        statusItem.button?.appearsDisabled = !tracker.isConnected
    }

    private func mark(_ items: [NSMenuItem], _ value: Double) {
        for item in items { item.state = (item.representedObject as? Double) == value ? .on : .off }
    }

    // MARK: Actions

    @objc private func toggleEnabled() { enabled.toggle() }

    @objc private func recordJaw() {
        // Head control off while recording, so nothing clicks or scrolls.
        if enabled { enabled = false }
        jawRecorder.start()
    }

    @objc private func toggleDwell() { dwell.enabled.toggle(); updateUI() }
    @objc private func toggleDwellPause() { dwell.togglePause() }
    @objc private func toggleScroll() {
        cursor.tiltScroll.toggle()
        cursor.scroller.reset()
        updateUI()
    }
    @objc private func toggleInvertScroll() { cursor.scroller.invert.toggle(); updateUI() }
    @objc private func toggleSticky() { cursor.stickyButtons.toggle(); updateUI() }
    @objc private func toggleAssist() { cursor.clickAssist.toggle(); updateUI() }
    @objc private func toggleNod() { cursor.nodToClick.toggle(); updateUI() }
    @objc private func toggleInvertX() { cursor.invertX.toggle(); updateUI() }
    @objc private func toggleInvertY() { cursor.invertY.toggle(); updateUI() }

    @objc private func setSpeed(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double { cursor.shaper.maxGain = v }
        updateUI()
    }

    @objc private func setDwellTime(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double { dwell.logic.dwellTime = v }
        updateUI()
    }

    @objc private func setScrollSpeed(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double { cursor.scroller.maxSpeed = v }
        updateUI()
    }

    /// After a re-sign, an old Accessibility entry can look enabled but no longer
    /// match the app. Clear HeadMouse's entry so macOS asks again cleanly.
    @objc private func fixAccessibility() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "dev.sinemvibing.headmouse"]
        do {
            try p.run()
            p.waitUntilExit()
            log("Reset Accessibility entry (tccutil exit \(p.terminationStatus))")
        } catch {
            log("Couldn't reset Accessibility entry: \(error.localizedDescription)")
        }
        CursorController.requestAccessibility()
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openMotion() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Motion")!)
    }
}
