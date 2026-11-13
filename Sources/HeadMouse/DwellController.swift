import AppKit

/// What the next dwell does. Chosen from the floating palette; resets to `.left`
/// after one use (a drag stays selected until you drop).
enum DwellAction: String {
    case left, double, right, drag
}

/// Dwell clicking UI: a progress ring next to the cursor plus a floating palette
/// on the right edge of the screen to pick the next action or pause dwelling.
final class DwellController {
    var logic = DwellLogic()
    /// Dwell clicking is switched on in the menu.
    var enabled = true { didSet { refreshVisibility() } }
    /// Head control is on.
    var active = false { didSet { refreshVisibility() } }

    private(set) var paused = false
    private(set) var nextAction: DwellAction = .left

    var perform: ((DwellAction, CGPoint) -> Void)?
    var isDragging: () -> Bool = { false }
    var onLog: ((String) -> Void)?
    /// The palette's menu button was chosen.
    var onMenu: (() -> Void)?

    private let ring = RingWindow()
    private let palette = PaletteWindow()

    init() {
        palette.onSelect = { [weak self] item in self?.select(item) }
        palette.update(selected: nextAction, paused: paused)
    }

    /// Feed one output frame from the cursor controller.
    func frame(now: TimeInterval, point: CGPoint, headTravel: Double, external: Bool, scrolling: Bool) {
        guard active && enabled else {
            ring.hide()
            return
        }
        if external || scrolling {
            logic.disarm()
            ring.hide()
            return
        }
        switch logic.update(now: now, point: point, headTravel: headTravel) {
        case .idle:
            ring.hide()
        case let .progress(fraction, at):
            if paused && palette.item(atCG: at) == nil {
                ring.hide()
            } else {
                ring.show(at: at, progress: fraction)
            }
        case let .fire(at):
            ring.hide()
            fire(at: at)
        }
    }

    private func fire(at p: CGPoint) {
        if let item = palette.item(atCG: p) {
            select(item)
            return
        }
        if paused { return }

        let action: DwellAction = isDragging() ? .drag : nextAction
        perform?(action, p)
        if action != .drag || !isDragging() {
            nextAction = .left
            palette.update(selected: nextAction, paused: paused)
        }
    }

    private func select(_ item: PaletteWindow.Item) {
        switch item {
        case .menu:
            // Let the menu open after this frame finishes.
            DispatchQueue.main.async { [weak self] in self?.onMenu?() }
            return
        case .pause:
            paused.toggle()
            onLog?(paused ? "Dwell paused" : "Dwell resumed")
        case .left: nextAction = .left
        case .double: nextAction = .double
        case .right: nextAction = .right
        case .drag: nextAction = .drag
        }
        if item != .pause { onLog?("Next dwell: \(nextAction.rawValue)") }
        palette.update(selected: nextAction, paused: paused)
    }

    func togglePause() { select(.pause) }

    private func refreshVisibility() {
        if active && enabled {
            palette.show()
        } else {
            palette.hide()
            ring.hide()
            logic.disarm()
        }
    }
}

// MARK: - Screen coordinates

/// CoreGraphics uses a top-left origin; AppKit uses bottom-left of the primary screen.
private enum ScreenSpace {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    static func cocoaRect(fromCG r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func cocoaPoint(fromCG p: CGPoint) -> NSPoint {
        NSPoint(x: p.x, y: primaryHeight - p.y)
    }
}

// MARK: - Progress ring

/// A small ring that fills up just below-right of the cursor. It sits beside the
/// cursor rather than under it so it never blocks what you're pointing at.
private final class RingWindow {
    private static let size: CGFloat = 26
    private let window: NSWindow
    private let view = RingView()

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                          styleMask: .borderless, backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = view
    }

    func show(at p: CGPoint, progress: Double) {
        view.progress = progress
        view.needsDisplay = true
        let frame = ScreenSpace.cocoaRect(fromCG: CGRect(x: p.x + 12, y: p.y + 12, width: Self.size, height: Self.size))
        window.setFrame(frame, display: false)
        if !window.isVisible { window.orderFrontRegardless() }
    }

    func hide() {
        if window.isVisible { window.orderOut(nil) }
    }
}

private final class RingView: NSView {
    var progress: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 4, dy: 4)
        let center = NSPoint(x: bounds.midX, y: bounds.midY)

        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = 5
        NSColor.black.withAlphaComponent(0.35).setStroke()
        track.stroke()

        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: rect.width / 2,
                      startAngle: 90, endAngle: 90 - 360 * CGFloat(min(max(progress, 0), 1)),
                      clockwise: true)
        arc.lineWidth = 3.5
        arc.lineCapStyle = .round
        NSColor.controlAccentColor.setStroke()
        arc.stroke()
    }
}

// MARK: - Palette

/// Floating buttons on the right edge of the screen. Dwell on one (or click it)
/// to choose what the next dwell does, or to pause dwell clicking.
final class PaletteWindow: NSObject {
    enum Item: Int, CaseIterable {
        case left, double, right, drag, pause, menu
    }

    var onSelect: ((Item) -> Void)?

    private static let button: CGFloat = 46
    private static let gap: CGFloat = 4
    private static let pad: CGFloat = 6

    private let panel: NSPanel
    private var buttons: [Item: NSButton] = [:]

    override init() {
        let n = CGFloat(Item.allCases.count)
        let width = Self.button + 2 * Self.pad
        let height = n * Self.button + (n - 1) * Self.gap + 2 * Self.pad
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true
        panel.contentView = bg

        for (i, item) in Item.allCases.enumerated() {
            let y = height - Self.pad - CGFloat(i + 1) * Self.button - CGFloat(i) * Self.gap
            let b = NSButton(frame: NSRect(x: Self.pad, y: y, width: Self.button, height: Self.button))
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.target = self
            b.action = #selector(tapped(_:))
            b.tag = item.rawValue
            b.wantsLayer = true
            b.layer?.cornerRadius = 10
            b.toolTip = Self.tooltip(item)
            bg.addSubview(b)
            buttons[item] = b
        }
    }

    private static func tooltip(_ item: Item) -> String {
        switch item {
        case .left: return "Click"
        case .double: return "Double-click"
        case .right: return "Right-click"
        case .drag: return "Drag: dwell to pick up, dwell again to drop"
        case .pause: return "Pause / resume dwell clicking"
        case .menu: return "HeadMouse menu"
        }
    }

    private static func symbol(_ item: Item, paused: Bool) -> (name: String, fallback: String) {
        switch item {
        case .left: return ("cursorarrow.click", "L")
        case .double: return ("cursorarrow.click.2", "2×")
        case .right: return ("contextualmenu.and.cursorarrow", "R")
        case .drag: return ("hand.draw", "Drag")
        case .pause: return (paused ? "play.circle" : "pause.circle", paused ? "▶" : "II")
        case .menu: return ("line.3.horizontal", "≡")
        }
    }

    @objc private func tapped(_ sender: NSButton) {
        if let item = Item(rawValue: sender.tag) { onSelect?(item) }
    }

    func update(selected: DwellAction, paused: Bool) {
        let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        for (item, b) in buttons {
            let s = Self.symbol(item, paused: paused)
            if let img = NSImage(systemSymbolName: s.name, accessibilityDescription: Self.tooltip(item))?
                .withSymbolConfiguration(config) {
                b.image = img
                b.title = ""
            } else {
                b.image = nil
                b.title = s.fallback
            }

            let isSelected: Bool
            switch item {
            case .left: isSelected = selected == .left
            case .double: isSelected = selected == .double
            case .right: isSelected = selected == .right
            case .drag: isSelected = selected == .drag
            case .pause: isSelected = paused
            case .menu: isSelected = false
            }
            let color: NSColor = item == .pause ? .systemOrange : .controlAccentColor
            b.layer?.backgroundColor = isSelected ? color.withAlphaComponent(0.45).cgColor : NSColor.clear.cgColor
            b.contentTintColor = isSelected ? .white : .labelColor
        }
    }

    func show() {
        if let screen = NSScreen.screens.first {
            let vf = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 8, y: vf.midY - size.height / 2))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// The palette button at a CoreGraphics (top-left origin) screen point, if any.
    func item(atCG p: CGPoint) -> Item? {
        guard panel.isVisible else { return nil }
        let cp = ScreenSpace.cocoaPoint(fromCG: p)
        guard panel.frame.contains(cp) else { return nil }
        for (item, b) in buttons {
            let r = panel.convertToScreen(b.convert(b.bounds, to: nil))
            if r.contains(cp) { return item }
        }
        return nil
    }
}
