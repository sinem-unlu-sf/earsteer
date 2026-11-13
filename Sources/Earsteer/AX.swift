import ApplicationServices
import CoreGraphics

/// Small helpers around the Accessibility API, used to find buttons under the cursor.
enum AX {
    static let systemWide: AXUIElement = {
        let e = AXUIElementCreateSystemWide()
        // Never let a hung app stall us; this applies to every element we query.
        AXUIElementSetMessagingTimeout(e, 0.05)
        return e
    }()

    /// Roles we treat as "something you click".
    static let clickableRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXMenuItem", "AXMenuBarItem", "AXLink", "AXDisclosureTriangle",
        "AXIncrementor", "AXComboBox", "AXDockItem",
    ]

    /// The largest target (in points, per side) that counts as "small" for
    /// sticky slow-down and snapping.
    static let smallTargetSize: CGFloat = 80

    static func element(at p: CGPoint) -> AXUIElement? {
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &el) == .success else {
            return nil
        }
        return el
    }

    /// The clickable element at `p`, walking a few parents up
    /// (e.g. text inside a link, or an image inside a button).
    static func clickable(at p: CGPoint) -> AXUIElement? {
        var current = element(at: p)
        for _ in 0..<4 {
            guard let e = current else { return nil }
            if let role = string(e, "AXRole"), clickableRoles.contains(role) { return e }
            current = parent(of: e)
        }
        return nil
    }

    /// Frame of a small clickable element at `p`, if there is one.
    static func smallTarget(at p: CGPoint) -> CGRect? {
        guard let e = clickable(at: p), let f = frame(of: e),
              f.width <= smallTargetSize, f.height <= smallTargetSize else { return nil }
        return f
    }

    static func frame(of e: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?
        var sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, "AXPosition" as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(e, "AXSize" as CFString, &sv) == .success,
              let pv, let sv,
              CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sv as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func string(_ e: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func parent(of e: AXUIElement) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, "AXParent" as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
}
