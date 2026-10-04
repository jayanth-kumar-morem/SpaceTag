import Cocoa

/// Draws desktop names onto Mission Control's spaces bar.
///
/// macOS gives no way to change those labels -- the Dock owns them, and on
/// 15.7.5 it draws "Desktop N" under *every* thumbnail at once, not just the
/// hovered one. So we cannot replace that caption and we cannot share its
/// line either: an earlier build drew our name in the same strip just below
/// the thumbnail and the two overprinted each other on all five desktops.
/// Instead we paint a small tag *inside* the bottom of each thumbnail, using
/// live geometry from MissionControlAX and a window promoted to survive Exposé.
final class MissionControlOverlay {
    static let shared = MissionControlOverlay()

    private var window: NSWindow?
    private var labelView: LabelView?
    private var timer: Timer?
    private var promotedWindowNumber: Int?

    /// Height of the strip we reserve at the top of the primary screen. The
    /// spaces bar has measured 97-165pt tall depending on layout; this covers
    /// it plus the caption line with room to spare.
    private static let stripHeight: CGFloat = 260

    /// Set from the menu; when false the overlay stays hidden.
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { presentWindow() } else { hide() }
        }
    }

    private init() {}

    func start() {
        guard timer == nil else { return }
        // The window must already be on screen before Mission Control opens.
        // WindowServer will not display a window that is ordered in while
        // Exposé is already running -- it stays at onscreen=false no matter
        // what level it has. Ordering it in up front, empty and transparent,
        // is what makes the labels appear at all.
        if isEnabled { presentWindow() }

        // 5x/sec: fast enough that the labels are already there as Mission
        // Control finishes animating, cheap enough to leave running.
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        hide()
    }

    /// Order the (empty, click-through, fully transparent) window in and keep
    /// it there. It renders nothing until there are labels to draw.
    private func presentWindow() {
        let window = ensureWindow()
        guard let screen = NSScreen.screens.first else { return }
        let frame = NSRect(x: screen.frame.minX,
                           y: screen.frame.maxY - Self.stripHeight,
                           width: screen.frame.width,
                           height: Self.stripHeight)
        if window.frame != frame { window.setFrame(frame, display: false) }
        labelView?.frame = NSRect(origin: .zero, size: frame.size)

        window.orderFrontRegardless()
        // Re-promote whenever the window number changes; WindowServer drops the
        // override if the window is ever recreated.
        if promotedWindowNumber != window.windowNumber {
            SkyLight.shared.makeVisibleOverMissionControl(windowNumber: window.windowNumber)
            promotedWindowNumber = window.windowNumber
        }
    }

    // MARK: - Polling

    private func tick() {
        guard isEnabled, MissionControlAX.isTrusted else { return }
        guard let snapshot = MissionControlAX.snapshot() else {
            // Mission Control is closed: blank the labels but leave the window
            // in place, otherwise it cannot come back (see start()).
            labelView?.labels = []
            return
        }
        show(snapshot)
    }

    private func show(_ snapshot: MissionControlAX.Snapshot) {
        // Names are looked up per tick so a rename shows up immediately, even
        // while Mission Control is still open.
        let spaces = SpaceModel.snapshot(includeApps: false).flatMap(\.spaces)
        var namesByNumber: [Int: String] = [:]
        var currentNumber: Int?
        for space in spaces {
            guard let number = space.desktopNumber else { continue }
            if space.isCurrent { currentNumber = number }
            if let name = NameStore.shared.name(for: space) { namesByNumber[number] = name }
        }

        // The window is pinned to the top-left of the primary screen and the
        // view is flipped, so AX screen coordinates are already view
        // coordinates -- no conversion, and nothing is moved while Mission
        // Control is up.
        //
        // No hover exclusion here any more: the tag lives inside the thumbnail
        // and the system caption lives below it, so there is nothing left to
        // collide with, and hiding a name at the moment the pointer reaches it
        // is exactly when you are reading it.
        labelView?.labels = snapshot.thumbnails.compactMap { thumb in
            guard let name = namesByNumber[thumb.desktopNumber] else { return nil }
            return LabelView.Label(text: name, thumbRect: thumb.frame,
                                   isCurrent: thumb.desktopNumber == currentNumber)
        }
    }

    private func hide() {
        labelView?.labels = []
        window?.orderOut(nil)
        promotedWindowNumber = nil
    }

    // MARK: - Window

    private func ensureWindow() -> NSWindow {
        if let window { return window }

        let window = NSWindow(contentRect: .zero, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true          // never intercept a click on a desktop
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let view = LabelView(frame: .zero)
        window.contentView = view

        self.window = window
        self.labelView = view
        return window
    }
}

// MARK: - Drawing

final class LabelView: NSView {
    struct Label {
        let text: String
        /// Thumbnail rect in view coordinates, top-left origin.
        let thumbRect: CGRect
        let isCurrent: Bool
    }

    var labels: [Label] = [] {
        didSet { needsDisplay = true }
    }

    // Flipped so thumbRect can be used exactly as AX reported it.
    override var isFlipped: Bool { true }

    /// Distance from the thumbnail's own edges to the tag. Bottom rather than
    /// top because the Dock puts its close ("x") badge in the thumbnail's
    /// top-left corner on hover, and the wallpaper is usually calmer low down
    /// than behind a window title bar.
    private static let inset: CGFloat = 8
    /// Breathing room between the text and the pill's rounded ends.
    private static let textPadding: CGFloat = 8
    private static let pillHeight: CGFloat = 19
    /// Below this a thumbnail is too small for the tag to read as anything but
    /// a smudge -- with a dozen desktops the bar shrinks them a long way.
    private static let minimumThumbWidth: CGFloat = 64

    /// A tag on the thumbnail, not a second caption under it.
    ///
    /// The Dock draws "Desktop N" immediately below every thumbnail and we have
    /// no way to suppress it, so anything we put in that strip lands on top of
    /// it. Sitting the name inside the thumbnail instead reads as a label on
    /// the desktop -- and the two lines stack cleanly: name inside, system
    /// number underneath.
    ///
    /// Sized to the text and centred, so short names look like tags rather than
    /// full-width banners, and clamped to the thumbnail so a long name
    /// truncates instead of bleeding into the neighbouring desktop.
    override func draw(_ dirtyRect: NSRect) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail

        for label in labels {
            let thumb = label.thumbRect
            guard thumb.width >= Self.minimumThumbWidth,
                  thumb.height >= Self.pillHeight + Self.inset * 2
            else { continue }

            let font = NSFont.systemFont(ofSize: 11,
                                         weight: label.isCurrent ? .semibold : .medium)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white,
                .paragraphStyle: style
            ]

            let textSize = (label.text as NSString).size(withAttributes: attributes)
            let maxTextWidth = thumb.width - (Self.inset + Self.textPadding) * 2
            let textWidth = min(ceil(textSize.width), maxTextWidth)
            guard textWidth > 0 else { continue }

            let pill = CGRect(x: thumb.midX - (textWidth / 2 + Self.textPadding),
                              y: thumb.maxY - Self.inset - Self.pillHeight,
                              width: textWidth + Self.textPadding * 2,
                              height: Self.pillHeight).integral

            NSGraphicsContext.saveGraphicsState()
            // Belt and braces: the pill is already computed to fit, but clipping
            // guarantees nothing we draw can ever land on another desktop.
            NSBezierPath(rect: thumb).setClip()

            let body = NSBezierPath(roundedRect: pill,
                                    xRadius: pill.height / 2, yRadius: pill.height / 2)

            // The shadow is scoped to the fill alone: it lifts the pill off
            // whatever window is behind it, but applied to the rim or the text
            // it only muddies them.
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            shadow.shadowBlurRadius = 4
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
            // The active desktop already wears a blue selection ring, so its tag
            // picks up the same accent to match; the rest stay neutral dark so
            // they read against any wallpaper.
            let fill = label.isCurrent
                ? NSColor.controlAccentColor.withAlphaComponent(0.95)
                : NSColor.black.withAlphaComponent(0.60)
            fill.setFill()
            body.fill()
            NSGraphicsContext.restoreGraphicsState()

            // Hairline rim, the way macOS edges its own translucent chips.
            NSColor.white.withAlphaComponent(label.isCurrent ? 0.25 : 0.16).setStroke()
            body.lineWidth = 1
            body.stroke()

            // One line only -- .byTruncatingTail suppresses wrapping, so the rect
            // is exactly the measured line, centred in the pill.
            let textRect = CGRect(x: pill.minX + Self.textPadding,
                                  y: (pill.midY - textSize.height / 2).rounded(),
                                  width: pill.width - Self.textPadding * 2,
                                  height: ceil(textSize.height))
            (label.text as NSString).draw(in: textRect, withAttributes: attributes)

            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
