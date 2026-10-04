import ApplicationServices
import Cocoa

/// Reads Mission Control's "Spaces Bar" out of the Dock's accessibility tree.
///
/// This is the only supported way to learn where Mission Control draws each
/// desktop thumbnail. The geometry is not documented or derivable -- it shifts
/// with desktop count, display size and macOS version -- so it is read live
/// rather than computed.
enum MissionControlAX {

    struct Thumbnail {
        /// The N in "Desktop N", matching SpaceModel's numbering.
        let desktopNumber: Int
        /// Frame in AX screen coordinates (top-left origin).
        let frame: CGRect
    }

    struct Snapshot {
        let barFrame: CGRect
        let thumbnails: [Thumbnail]
    }

    /// Non-nil only while Mission Control is on screen.
    ///
    /// When Mission Control is closed the Dock keeps the elements in its tree
    /// but stops reporting geometry, so position/size come back nil and the
    /// button list is empty. That absence is the activation signal.
    static func snapshot() -> Snapshot? {
        guard let dock = dockElement() else { return nil }

        // Cheap gate first: the Mission Control group only reports a frame
        // while it is presented. Avoids walking the tree 5x a second for nothing.
        guard let mcGroup = children(dock).first(where: { title($0) == "Mission Control" }),
              let mcFrame = frame(mcGroup), mcFrame.height > 200
        else { return nil }

        guard let bar = findSpacesBar(mcGroup, depth: 0),
              let barFrame = frame(bar), barFrame.height > 0
        else { return nil }

        let buttons = desktopButtons(in: bar)
        var thumbnails: [Thumbnail] = []
        for button in buttons {
            guard let number = desktopNumber(from: title(button)),
                  let f = frame(button), f.width > 0
            else { continue }
            thumbnails.append(Thumbnail(desktopNumber: number, frame: f))
        }

        guard !thumbnails.isEmpty else { return nil }
        return Snapshot(barFrame: barFrame, thumbnails: thumbnails)
    }

    static var isMissionControlOpen: Bool { snapshot() != nil }

    /// Ask the Dock to show Mission Control.
    ///
    /// `open -a "Mission Control"` toggles, so callers must check
    /// `isMissionControlOpen` first or they will close what they meant to open.
    static func openMissionControl() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Mission Control"]
        try? task.run()
    }

    /// Switch desktops by pressing the Dock's own spaces-bar button.
    ///
    /// This is the only switch that is actually correct. Driving WindowServer
    /// directly with `SLSManagedDisplaySetCurrentSpace` moves the active space
    /// but leaves the Dock believing we never left, so the destination's windows
    /// get drawn over the old desktop's wallpaper instead of a real transition.
    /// Pressing the button makes the Dock perform the switch itself, animation
    /// and all, and it dismisses Mission Control on its own afterwards.
    ///
    /// Requires Mission Control to be on screen -- the buttons do not exist
    /// otherwise.
    static func pressDesktopButton(number: Int) -> Bool {
        guard let dock = dockElement(),
              let mcGroup = children(dock).first(where: { title($0) == "Mission Control" }),
              let bar = findSpacesBar(mcGroup, depth: 0)
        else { return false }

        let wanted = "Desktop \(number)"
        guard let button = desktopButtonElements(in: bar).first(where: { title($0) == wanted })
        else { return false }

        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Ask for Accessibility access, showing the system prompt once.
    @discardableResult
    static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    // MARK: - AX helpers

    private static func dockElement() -> AXUIElement? {
        guard let pid = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier
        else { return nil }
        return AXUIElementCreateApplication(pid)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
    }

    private static func title(_ element: AXUIElement) -> String {
        attribute(element, kAXTitleAttribute as String) as? String ?? ""
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = attribute(element, kAXPositionAttribute as String),
              let s = attribute(element, kAXSizeAttribute as String)
        else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &origin)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    /// The bar holds a single AXList whose children are the desktop buttons.
    private static func desktopButtonElements(in bar: AXUIElement) -> [AXUIElement] {
        children(bar).first.map { children($0) } ?? []
    }

    private static func desktopButtons(in bar: AXUIElement) -> [AXUIElement] {
        desktopButtonElements(in: bar)
    }

    private static func findSpacesBar(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 6 else { return nil }
        if title(element) == "Spaces Bar" { return element }
        for child in children(element) {
            if let found = findSpacesBar(child, depth: depth + 1) { return found }
        }
        return nil
    }

    /// "Desktop 10" -> 10. Returns nil for fullscreen slots, which are titled
    /// with the app name and are not ours to label.
    private static func desktopNumber(from title: String) -> Int? {
        guard title.hasPrefix("Desktop ") else { return nil }
        return Int(title.dropFirst("Desktop ".count).trimmingCharacters(in: .whitespaces))
    }
}
