import Carbon.HIToolbox
import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var renameHotkey: Hotkey?
    private var menuHotkey: Hotkey?
    private let maxTitleLength = 18

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard SkyLight.shared.isAvailable else {
            presentFatalUnavailable()
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusButton()

        let menu = NSMenu()
        menu.delegate = self          // rebuilt lazily on each open
        statusItem.menu = menu

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(spaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        registerHotkeys()
        refreshTitle()

        MissionControlOverlay.shared.isEnabled =
            UserDefaults.standard.object(forKey: "showInMissionControl") as? Bool ?? true
        MissionControlOverlay.shared.start()

        // Labels in Mission Control need Accessibility; nothing else does, so
        // ask once rather than blocking launch on it.
        if !MissionControlAX.isTrusted { MissionControlAX.requestTrust() }
    }

    // MARK: - Menu bar title

    /// Whether to spell the desktop name out in the menu bar.
    ///
    /// Off by default, and that is deliberate. A menu bar only has so much
    /// room, and on a notched display anything that does not fit to the right
    /// of the notch is silently dropped -- the item still exists and still
    /// reports itself visible, it just never draws. A bare number is ~30pt and
    /// survives a crowded bar; icon plus name is ~100pt and often will not.
    private var showsNameInMenuBar: Bool {
        UserDefaults.standard.object(forKey: "showNameInMenuBar") as? Bool ?? false
    }

    private func configureStatusButton() {
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    }

    private func statusSymbol() -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = NSImage(systemSymbolName: "rectangle.3.group",
                            accessibilityDescription: "SpaceTag")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true      // adapts to light/dark and menu bar tint
        return image
    }

    @objc private func spaceChanged() {
        // WindowServer reports the new space a beat after the notification.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.refreshTitle()
        }
    }

    private func refreshTitle() {
        guard let button = statusItem.button else { return }
        guard let space = SpaceModel.currentSpace() else {
            button.image = nil
            button.imagePosition = .noImage
            button.title = "–"
            button.toolTip = "SpaceTag — no desktop detected"
            return
        }

        let number = space.desktopNumber.map(String.init) ?? "⤢"
        let name = NameStore.shared.name(for: space)

        if showsNameInMenuBar, let name {
            button.image = statusSymbol()
            button.imagePosition = .imageLeading
            button.title = " \(truncate(name))"
        } else {
            button.image = nil
            button.imagePosition = .noImage
            button.title = number
        }

        button.toolTip = name.map { "SpaceTag — \(space.systemLabel): \($0)" }
            ?? "SpaceTag — \(space.systemLabel) (unnamed)"
    }

    private func truncate(_ value: String) -> String {
        guard value.count > maxTitleLength else { return value }
        return value.prefix(maxTitleLength - 1) + "…"
    }

    // MARK: - Menu construction

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let groups = SpaceModel.snapshot(includeApps: true)
        let allSpaces = groups.flatMap(\.spaces)
        NameStore.shared.prune(keeping: allSpaces)

        if allSpaces.isEmpty {
            menu.addItem(.sectionHeader(title: "Desktops"))
            let empty = NSMenuItem(title: "No desktops detected", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        for group in groups {
            let header = groups.count > 1
                ? (group.isMain ? "Main Display" : "Display \(group.identifier.prefix(8))")
                : "Desktops"
            menu.addItem(.sectionHeader(title: header))
            for space in group.spaces {
                menu.addItem(spaceItem(for: space))
            }
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Naming"))

        let rename = NSMenuItem(title: "Rename Current Desktop…",
                                action: #selector(renameCurrentSpace), keyEquivalent: "n")
        rename.keyEquivalentModifierMask = [.control, .option]
        rename.target = self
        rename.image = symbol("pencil")
        menu.addItem(rename)

        // Rename any desktop without having to switch to it first.
        let renameOther = NSMenuItem(title: "Rename Another Desktop", action: nil, keyEquivalent: "")
        renameOther.image = symbol("list.bullet")
        let submenu = NSMenu()
        for space in allSpaces where !space.isFullscreen {
            let number = space.desktopNumber ?? 0
            let item = NSMenuItem(title: NameStore.shared.name(for: space) ?? "Desktop \(number)",
                                  action: #selector(renameSpace(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = space
            item.image = numberSymbol(number)
            submenu.addItem(item)
        }
        renameOther.submenu = submenu
        menu.addItem(renameOther)

        if let current = SpaceModel.currentSpace(), NameStore.shared.name(for: current) != nil {
            let clear = NSMenuItem(title: "Clear Name of Current Desktop",
                                   action: #selector(clearCurrentName), keyEquivalent: "")
            clear.target = self
            clear.image = symbol("eraser")
            menu.addItem(clear)
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Mission Control"))

        // Explicit status: an app that silently does nothing is indistinguishable
        // from an app that has crashed.
        let trusted = MissionControlAX.isTrusted
        let enabled = MissionControlOverlay.shared.isEnabled
        let status = NSMenuItem(title: statusText(enabled: enabled, trusted: trusted),
                                action: nil, keyEquivalent: "")
        status.image = symbol(trusted && enabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        status.isEnabled = false
        menu.addItem(status)

        let toggle = NSMenuItem(title: "Show Names in Mission Control",
                                action: #selector(toggleMissionControlNames), keyEquivalent: "")
        toggle.target = self
        toggle.state = enabled ? .on : .off
        menu.addItem(toggle)

        if !trusted {
            let grant = NSMenuItem(title: "Open Accessibility Settings…",
                                   action: #selector(grantAccessibility), keyEquivalent: "")
            grant.target = self
            grant.image = symbol("gearshape")
            menu.addItem(grant)
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Menu Bar"))

        let nameInBar = NSMenuItem(title: "Show Name Instead of Number",
                                   action: #selector(toggleNameInMenuBar), keyEquivalent: "")
        nameInBar.target = self
        nameInBar.state = showsNameInMenuBar ? .on : .off
        nameInBar.toolTip = "Wider. On a full or notched menu bar macOS may drop the item entirely."
        menu.addItem(nameInBar)

        menu.addItem(.separator())

        let launch = NSMenuItem(title: "Launch at Login",
                                action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.target = self
        launch.state = isLaunchAtLoginEnabled ? .on : .off
        menu.addItem(launch)

        let quit = NSMenuItem(title: "Quit SpaceTag", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func statusText(enabled: Bool, trusted: Bool) -> String {
        if !enabled { return "Turned off" }
        if !trusted { return "Needs Accessibility access" }
        return "Active — names show on the spaces bar"
    }

    /// A desktop row: numbered badge, name as the title, contents as the subtitle.
    private func spaceItem(for space: Space) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: #selector(switchToSpace(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = space
        item.state = space.isCurrent ? .on : .off

        if let name = NameStore.shared.name(for: space) {
            item.title = name
        } else {
            item.title = space.isFullscreen ? "Fullscreen" : "Desktop \(space.desktopNumber ?? 0)"
        }

        if let number = space.desktopNumber {
            item.image = numberSymbol(number)
        } else {
            item.image = symbol("arrow.up.left.and.arrow.down.right")
        }

        // Native secondary line rather than text jammed into the title.
        if space.apps.isEmpty {
            item.subtitle = space.isFullscreen ? nil : "No windows"
        } else {
            let shown = space.apps.prefix(3).joined(separator: ", ")
            item.subtitle = space.apps.count > 3
                ? "\(shown) + \(space.apps.count - 3) more"
                : shown
        }
        return item
    }

    private func symbol(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    /// SF Symbols ships numbered squares up to 50; beyond that fall back.
    private func numberSymbol(_ number: Int) -> NSImage? {
        guard (0...50).contains(number) else { return symbol("square") }
        return symbol("\(number).square")
    }

    // MARK: - Actions

    @objc private func switchToSpace(_ sender: NSMenuItem) {
        guard let space = sender.representedObject as? Space, !space.isCurrent else { return }
        guard let number = space.desktopNumber else { return }

        // Switching goes through the Dock's own spaces-bar button. Driving
        // WindowServer directly leaves the Dock out of sync and paints the
        // destination's windows over the old wallpaper instead of switching.
        guard MissionControlAX.isTrusted else {
            notify("Accessibility access needed",
                   """
                   Switching desktops uses Mission Control's own controls, which \
                   needs Accessibility access.

                   Grant SpaceTag in System Settings > Privacy & Security > \
                   Accessibility, then try again.
                   """)
            return
        }

        attemptSwitch(to: number, round: 1)
    }

    /// How long to let Mission Control settle before pressing, per round.
    ///
    /// Waiting is unavoidable and the length is measured, not guessed. The
    /// spaces-bar buttons appear in the Dock's accessibility tree ~0.1s after
    /// Mission Control is asked to open, but the Dock ignores a press for
    /// roughly another 0.3s: `AXUIElementPerformAction` still returns success
    /// and Mission Control still dismisses itself, it just does not change
    /// space. That is the bug this replaced -- the old code polled for the
    /// button's *existence*, which is satisfied on the very first 0.12s tick,
    /// and so pressed during the dead window essentially every time.
    ///
    /// Polling for a readiness signal instead would be better, but there is
    /// none to poll: the group frame, the bar frame, the button count, the
    /// button geometry and the attribute list are all in their final state at
    /// t=0.085s and never change again. A press at 0.12s and 0.25s reliably
    /// does nothing; 0.40s and beyond reliably works. Hence a settle delay with
    /// margin, and -- because a fixed delay is only ever a guess about a slower
    /// machine -- an outcome check that retries with a longer one.
    private static let settleDelays: [TimeInterval] = [0.55, 0.9, 1.4]

    private func attemptSwitch(to number: Int, round: Int) {
        guard round <= Self.settleDelays.count else {
            notify("Could not switch",
                   "Mission Control did not respond to Desktop \(number).")
            return
        }

        // The buttons only exist while Mission Control is on screen. `open` is a
        // toggle, so this must stay conditional or a retry would close it.
        let alreadyOpen = MissionControlAX.isMissionControlOpen
        if !alreadyOpen { MissionControlAX.openMissionControl() }

        // An already-open Mission Control has had its settle time already.
        let settle = alreadyOpen ? 0.2 : Self.settleDelays[round - 1]

        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            guard let self else { return }
            guard MissionControlAX.pressDesktopButton(number: number) else {
                self.attemptSwitch(to: number, round: round + 1)
                return
            }
            self.confirmSwitch(to: number, attemptsLeft: 16, round: round)
        }
    }

    /// A successful press proves nothing -- the failure mode is a press that
    /// reports success and does not switch -- so confirm against the space the
    /// system actually reports, and start over if it never moves.
    private func confirmSwitch(to number: Int, attemptsLeft: Int, round: Int) {
        guard attemptsLeft > 0 else {
            attemptSwitch(to: number, round: round + 1)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            guard SpaceModel.currentSpace()?.desktopNumber == number else {
                self.confirmSwitch(to: number, attemptsLeft: attemptsLeft - 1, round: round)
                return
            }
            self.refreshTitle()
        }
    }

    @objc private func renameCurrentSpace() {
        guard let space = SpaceModel.currentSpace() else { return }
        presentRename(for: space)
    }

    @objc private func renameSpace(_ sender: NSMenuItem) {
        guard let space = sender.representedObject as? Space else { return }
        presentRename(for: space)
    }

    private func presentRename(for space: Space) {
        RenamePanel.shared.present(space: space,
                                   currentName: NameStore.shared.name(for: space)) { [weak self] name in
            NameStore.shared.setName(name, for: space)
            self?.refreshTitle()
        }
    }

    @objc private func clearCurrentName() {
        guard let space = SpaceModel.currentSpace() else { return }
        NameStore.shared.setName(nil, for: space)
        refreshTitle()
    }

    @objc private func openMenu() {
        statusItem.button?.performClick(nil)
    }

    @objc private func toggleMissionControlNames() {
        let enabled = !MissionControlOverlay.shared.isEnabled
        MissionControlOverlay.shared.isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "showInMissionControl")
        if enabled, !MissionControlAX.isTrusted { MissionControlAX.requestTrust() }
    }

    @objc private func toggleNameInMenuBar() {
        UserDefaults.standard.set(!showsNameInMenuBar, forKey: "showNameInMenuBar")
        refreshTitle()
    }

    @objc private func grantAccessibility() {
        MissionControlAX.requestTrust()
        // The prompt only appears once per app identity; send them straight to
        // the pane if macOS decides to stay silent.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Login item

    private var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if isLaunchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            notify("Launch at Login failed",
                   "\(error.localizedDescription)\n\nThis needs SpaceTag to live in /Applications.")
        }
    }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        // Control+Option+N — rename the desktop you are on.
        renameHotkey = Hotkey(keyCode: UInt32(kVK_ANSI_N),
                              modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            self?.renameCurrentSpace()
        }
        // Control+Option+D — drop the desktop list open.
        menuHotkey = Hotkey(keyCode: UInt32(kVK_ANSI_D),
                            modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            self?.openMenu()
        }
    }

    // MARK: - Alerts

    private func notify(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func presentFatalUnavailable() {
        let alert = NSAlert()
        alert.messageText = "SpaceTag cannot read your desktops"
        alert.informativeText = """
            The private WindowServer interface SpaceTag relies on is not \
            available on this macOS build. The app will now quit.
            """
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }
}
