import AppKit
import ApplicationServices

/// Finding something on screen by its label (Accessibility), or by a spot in
/// the last picture AgentX took (Look at Window or screen_look).
enum ScreenTargets {
    struct Match: Equatable, Sendable {
        var label: String
        var role: String
        /// Global, origin at the top-left of the main screen.
        var frame: CGRect
    }

    /// Roles worth pointing at, ahead of plain text.
    static let actionable: Set<String> = [
        "AXButton", "AXMenuButton", "AXPopUpButton", "AXMenuBarItem", "AXMenuItem", "AXCheckBox", "AXRadioButton",
        "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXLink", "AXTab", "AXTabButton", "AXSlider",
        "AXDisclosureTriangle", "AXRow", "AXCell", "AXImage", "AXToolbarButton", "AXSegmentedControl",
    ]

    /// How well `label` matches `query`: 3 exact, 2 starts with, 1 contains, 0 no match (case and accents ignored).
    static func score(_ label: String, _ query: String) -> Int {
        let l = label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespacesAndNewlines)
        let q = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty, !q.isEmpty else { return 0 }
        if l == q || l.trimmingCharacters(in: CharacterSet(charactersIn: "….:")) == q { return 3 }
        if l.hasPrefix(q) { return 2 }
        return l.contains(q) ? 1 : 0
    }

    /// The best match for `query` in the app's focused window and menu bar,
    /// plus some labels that are there (so Claude can try again with one).
    static func find(_ query: String, pid: pid_t) -> (best: Match?, seen: [String]) {
        let app = AXUIElementCreateApplication(pid)
        // Short waits: a busy app shouldn't hold the search up (each element asks several things).
        AXUIElementSetMessagingTimeout(app, 0.2)
        // Electron and Chromium apps (Slack, VS Code, the Claude app…) build their tree only when asked.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var roots: [AXUIElement] = []
        func add(_ element: AXUIElement?) {
            guard let element, !roots.contains(where: { CFEqual($0, element) }) else { return }
            roots.append(element)
        }
        // AgentX itself: its main window, not the launcher (which has the keyboard).
        if pid != ProcessInfo.processInfo.processIdentifier { add(value(app, kAXFocusedWindowAttribute)) }
        add(value(app, kAXMainWindowAttribute))
        add(value(app, kAXMenuBarAttribute))

        var best: (match: Match, score: Int)?
        var seen: [String] = []
        var queue = roots.map { ($0, 0) }
        var visited = 0
        let deadline = Date().addingTimeInterval(1.0)
        while !queue.isEmpty, visited < 4_000, Date() < deadline {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let role: String = value(element, kAXRoleAttribute) ?? ""
            if let label = label(of: element, role: role), let frame = frame(of: element), frame.width > 1, frame.height > 1 {
                if actionable.contains(role), seen.count < 40, !seen.contains(label) { seen.append(label) }
                let s = score(label, query)
                if s > 0 {
                    let total = s * 10 + (actionable.contains(role) ? 5 : 0)
                    if total > (best?.score ?? 0) { best = (Match(label: label, role: role, frame: frame), total) }
                    if total >= 35 { break }   // exact and clickable: that's it
                }
            }
            // Menus that aren't open have no place on screen: don't descend into them.
            if depth < 30, role != "AXMenu", let children: [AXUIElement] = value(element, kAXChildrenAttribute) {
                queue += children.map { ($0, depth + 1) }
            }
        }
        return (best?.match, seen)
    }

    /// The text that names an element. Never a secure field's value.
    private static func label(of element: AXUIElement, role: String) -> String? {
        let keys = role == "AXSecureTextField" || role == "AXTextField" || role == "AXTextArea"
            ? [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue", kAXHelpAttribute]
            : [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute]
        for key in keys {
            if let text: String = value(element, key) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed.count <= 120 { return trimmed }
            }
        }
        return nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position: AXValue = value(element, kAXPositionAttribute),
              let size: AXValue = value(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    private static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success, let raw else { return nil }
        if T.self == AXUIElement.self, CFGetTypeID(raw) == AXUIElementGetTypeID() { return (raw as! AXUIElement) as? T }
        if T.self == AXValue.self, CFGetTypeID(raw) == AXValueGetTypeID() { return (raw as! AXValue) as? T }
        return raw as? T
    }

    /// A spot in the last picture (in its pixels) → a small rectangle on screen.
    static func spot(x: Double, y: Double, in look: ScreenGrabber.LastLook) -> CGRect? {
        guard x >= 0, y >= 0, x <= look.imageSize.width, y <= look.imageSize.height, look.imageSize.width > 0 else { return nil }
        let sx = look.windowFrame.width / look.imageSize.width, sy = look.windowFrame.height / look.imageSize.height
        let center = CGPoint(x: look.windowFrame.minX + x * sx, y: look.windowFrame.minY + y * sy)
        return CGRect(x: center.x - 18, y: center.y - 18, width: 36, height: 36)
    }
}
