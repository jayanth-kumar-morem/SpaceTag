import Cocoa

/// One macOS space (desktop or fullscreen app slot).
struct Space {
    /// WindowServer id. Stable while logged in, NOT across reboots.
    let id: UInt64
    /// Persistent identity. Empty for the odd transient space; see `key`.
    let uuid: String
    /// 0 = normal desktop, 4 = fullscreen app. Only desktops get a number.
    let type: Int
    /// Display UUID this space belongs to.
    let displayIdentifier: String
    /// Index within the display, 0-based.
    let indexOnDisplay: Int
    /// "Desktop N" number as Mission Control counts it, nil for fullscreen spaces.
    let desktopNumber: Int?
    let isCurrent: Bool
    /// App names with real windows on this space.
    var apps: [String] = []

    var isFullscreen: Bool { type != 0 }

    /// Key used to persist a custom name. Prefers the UUID; falls back to the
    /// volatile id so an un-persisted space is still nameable for the session.
    var key: String { uuid.isEmpty ? "id:\(id)" : uuid }

    /// "Desktop 3", or "Fullscreen" for a fullscreen slot.
    var systemLabel: String {
        if let desktopNumber { return "Desktop \(desktopNumber)" }
        return "Fullscreen"
    }
}

struct DisplayGroup {
    let identifier: String
    let isMain: Bool
    var spaces: [Space]
}

/// Reads the live space layout out of WindowServer.
enum SpaceModel {

    /// Snapshot of every display and its ordered spaces.
    ///
    /// - Parameter includeApps: when true, also resolves which apps have
    ///   windows on each space. Costs one private-API call per window.
    static func snapshot(includeApps: Bool = true) -> [DisplayGroup] {
        let monitors = SkyLight.shared.managedDisplaySpaces()
        guard !monitors.isEmpty else { return [] }

        let appsBySpace = includeApps ? appsBySpaceID() : [:]
        let mainDisplayUUID = currentMainDisplayUUID()

        // Mission Control numbers desktops continuously across displays.
        var desktopCounter = 0
        var groups: [DisplayGroup] = []

        for monitor in monitors {
            let displayID = monitor["Display Identifier"] as? String ?? "Main"
            let currentID = (monitor["Current Space"] as? [String: Any])?["id64"] as? UInt64
            let rawSpaces = monitor["Spaces"] as? [[String: Any]] ?? []

            var spaces: [Space] = []
            for (index, raw) in rawSpaces.enumerated() {
                guard let id = raw["id64"] as? UInt64 else { continue }
                let type = raw["type"] as? Int ?? 0

                var number: Int?
                if type == 0 {
                    desktopCounter += 1
                    number = desktopCounter
                }

                spaces.append(Space(
                    id: id,
                    uuid: raw["uuid"] as? String ?? "",
                    type: type,
                    displayIdentifier: displayID,
                    indexOnDisplay: index,
                    desktopNumber: number,
                    isCurrent: id == currentID,
                    apps: appsBySpace[id]?.sorted() ?? []
                ))
            }

            groups.append(DisplayGroup(
                identifier: displayID,
                isMain: displayID == mainDisplayUUID || monitors.count == 1,
                spaces: spaces
            ))
        }
        return groups
    }

    static func currentSpace() -> Space? {
        snapshot(includeApps: false)
            .flatMap(\.spaces)
            .first { $0.isCurrent }
    }

    /// Maps space id -> set of app names that own a real window there.
    private static func appsBySpaceID() -> [UInt64: Set<String>] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }

        var result: [UInt64: Set<String>] = [:]
        for window in windows {
            // Layer 0 excludes menu-bar extras, panels and overlays. The size
            // floor drops tooltips and 1px helper windows that would otherwise
            // make every space look like it contains every app.
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let windowID = window[kCGWindowNumber as String] as? Int,
                  let owner = window[kCGWindowOwnerName as String] as? String,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let height = bounds["Height"] as? Double, height > 100,
                  let width = bounds["Width"] as? Double, width > 100
            else { continue }

            for spaceID in SkyLight.shared.spaces(forWindowID: windowID) {
                result[spaceID, default: []].insert(owner)
            }
        }
        return result
    }

    /// The display UUID hosting the menu bar, used only to order the groups.
    private static func currentMainDisplayUUID() -> String? {
        guard let screen = NSScreen.main,
              let number = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber
        else { return nil }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard let uuidRef = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuidRef) as String?
    }

    /// Activate a space. Returns false if the private switch API is unavailable.
    ///
    /// WindowServer moves the display to the new space but does not move
    /// keyboard focus with it -- the app you were using stays frontmost even
    /// though its window is now on a space you can no longer see, so the next
    /// thing you type disappears into it. Focus is handed to something actually
    /// on the destination.
    @discardableResult
    static func switchTo(_ space: Space) -> Bool {
        guard SkyLight.shared.setCurrentSpace(displayIdentifier: space.displayIdentifier,
                                              spaceID: space.id)
        else { return false }
        activateFrontmostApp(on: space)
        return true
    }

    /// Focus the frontmost real window living on `space`, if there is one.
    /// Empty desktops are left alone -- there is nothing to focus.
    private static func activateFrontmostApp(on space: Space) {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return }

        // CGWindowList is front-to-back, so the first match is the top window.
        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let windowID = window[kCGWindowNumber as String] as? Int,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let height = bounds["Height"] as? Double, height > 100
            else { continue }

            guard SkyLight.shared.spaces(forWindowID: windowID).contains(space.id) else { continue }
            NSRunningApplication(processIdentifier: pid)?.activate()
            return
        }
    }
}
