import Cocoa

/// Small focused input panel for naming a desktop.
///
/// Replaces NSAlert, which misbehaves in an LSUIElement app: because the app is
/// never frontmost, the accessory text field routinely fails to become first
/// responder, so the caret never appears and Return does nothing. A real panel
/// lets us own activation and key handling explicitly.
final class RenamePanel: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    static let shared = RenamePanel()

    private var panel: NSPanel?
    private var field: NSTextField?
    private var onCommit: ((String?) -> Void)?

    private enum Metrics {
        static let width: CGFloat = 340
        static let height: CGFloat = 168
        static let margin: CGFloat = 20
    }

    /// Show the panel for `space`, calling `onCommit` with the new name on
    /// Save (nil/empty clears the name). Cancelling never calls back.
    func present(space: Space, currentName: String?, onCommit: @escaping (String?) -> Void) {
        // Already open: just re-focus rather than stacking panels.
        if let panel, panel.isVisible {
            activate(panel)
            return
        }

        self.onCommit = onCommit

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        // Vibrancy, matching system panels rather than a flat grey box.
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0,
                                                      width: Metrics.width, height: Metrics.height))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]

        let inner = Metrics.width - Metrics.margin * 2

        let icon = NSImageView(frame: NSRect(x: Metrics.margin, y: Metrics.height - 52,
                                             width: 22, height: 22))
        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        icon.image = NSImage(systemSymbolName: "rectangle.3.group",
                             accessibilityDescription: nil)?.withSymbolConfiguration(config)
        icon.contentTintColor = .secondaryLabelColor
        effect.addSubview(icon)

        let heading = NSTextField(labelWithString: "Name \(space.systemLabel)")
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        heading.frame = NSRect(x: Metrics.margin + 30, y: Metrics.height - 50,
                               width: inner - 30, height: 19)
        effect.addSubview(heading)

        let caption = NSTextField(labelWithString: "Shown in Mission Control and the menu bar.")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.frame = NSRect(x: Metrics.margin + 30, y: Metrics.height - 68,
                               width: inner - 30, height: 15)
        effect.addSubview(caption)

        let field = NSTextField(frame: NSRect(x: Metrics.margin, y: 62, width: inner, height: 24))
        field.placeholderString = "Billing API"
        field.stringValue = currentName ?? ""
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        // Return is handled in doCommandBy, not via target/action, so that an
        // empty field (meaning "clear the name") still commits.
        field.cell?.sendsActionOnEndEditing = false
        effect.addSubview(field)

        let save = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"           // makes it the default button visually
        save.frame = NSRect(x: Metrics.width - Metrics.margin - 84, y: 18, width: 84, height: 30)
        effect.addSubview(save)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"     // Esc
        cancel.frame = NSRect(x: Metrics.width - Metrics.margin - 174, y: 18, width: 84, height: 30)
        effect.addSubview(cancel)

        let hint = NSTextField(labelWithString: "Leave empty to clear")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.frame = NSRect(x: Metrics.margin, y: 24, width: 160, height: 15)
        effect.addSubview(hint)

        panel.contentView = effect
        panel.center()

        self.panel = panel
        self.field = field

        activate(panel)
    }

    /// Bring the panel forward and put the caret in the field.
    ///
    /// Order matters: the app must be active before makeKeyAndOrderFront, and
    /// first responder must be set after the window is key or AppKit discards it.
    private func activate(_ panel: NSPanel) {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        if let field {
            panel.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
    }

    private func close(commit: Bool) {
        let value = field?.stringValue
        let callback = onCommit

        onCommit = nil
        panel?.orderOut(nil)
        panel = nil
        field = nil

        if commit { callback?(value) }
    }

    @objc private func saveTapped() { close(commit: true) }
    @objc private func cancelTapped() { close(commit: false) }

    // MARK: - NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            close(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close(commit: false)
            return true
        default:
            return false
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Close button: discard, matching Esc.
        guard panel != nil else { return }
        close(commit: false)
    }
}
