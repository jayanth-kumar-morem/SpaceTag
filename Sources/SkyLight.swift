import CoreGraphics
import Foundation

/// Thin, defensive bridge over the private SkyLight (WindowServer) API.
///
/// Everything is resolved with `dlsym` at runtime and every entry point is
/// optional, so a future macOS that drops or renames a symbol degrades to a
/// reduced feature set instead of crashing on launch.
///
/// Deliberately NOT exposed: `SLSSpaceSetName`. On macOS a space's "name" is
/// its UUID -- the same string `com.apple.spaces` uses to key per-app space
/// assignments. Writing it renames the space's identity and silently breaks
/// "Assign To > Desktop N". Custom names live in NameStore instead.
final class SkyLight {
    static let shared = SkyLight()

    private typealias MainConnFn            = @convention(c) () -> Int32
    private typealias CopyDisplaySpacesFn   = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias SetCurrentSpaceFn     = @convention(c) (Int32, CFString, UInt64) -> Int32
    private typealias SpacesForWindowsFn    = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias SetWindowLevelFn      = @convention(c) (Int32, Int32, Int32) -> Int32

    private let handle: UnsafeMutableRawPointer?
    private let copyDisplaySpacesFn: CopyDisplaySpacesFn?
    private let setCurrentSpaceFn: SetCurrentSpaceFn?
    private let spacesForWindowsFn: SpacesForWindowsFn?
    private let setWindowLevelFn: SetWindowLevelFn?

    let connection: Int32

    /// True when at minimum we can enumerate spaces.
    var isAvailable: Bool { handle != nil && copyDisplaySpacesFn != nil && connection != 0 }
    /// True when clicking a desktop can actually switch to it.
    var canSwitchSpaces: Bool { setCurrentSpaceFn != nil }

    private init() {
        let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        handle = lib

        // Local, not a method: stored properties are still uninitialized here.
        // Both the modern SLS* and legacy CGS* spellings are tried.
        func resolve<T>(_ names: [String], _ type: T.Type) -> T? {
            guard let lib else { return nil }
            for name in names {
                if let sym = dlsym(lib, name) { return unsafeBitCast(sym, to: type) }
            }
            return nil
        }

        let mainConn: MainConnFn? = resolve(["SLSMainConnectionID", "CGSMainConnectionID"], MainConnFn.self)
        connection          = mainConn?() ?? 0
        copyDisplaySpacesFn = resolve(["SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces"], CopyDisplaySpacesFn.self)
        setCurrentSpaceFn   = resolve(["SLSManagedDisplaySetCurrentSpace", "CGSManagedDisplaySetCurrentSpace"], SetCurrentSpaceFn.self)
        spacesForWindowsFn  = resolve(["SLSCopySpacesForWindows", "CGSCopySpacesForWindows"], SpacesForWindowsFn.self)
        setWindowLevelFn    = resolve(["SLSSetWindowLevel", "CGSSetWindowLevel"], SetWindowLevelFn.self)
    }

    /// Promote a window so it keeps rendering while Mission Control is open.
    ///
    /// Setting `NSWindow.level` alone is NOT enough -- an ordinary window is
    /// hidden the moment Exposé takes over, no matter how high its Cocoa level.
    /// Pushing the level through WindowServer directly is what actually
    /// survives, and it is sufficient on its own.
    ///
    /// An earlier version also set window tag `0x800` on the assumption that it
    /// meant "sticky". That was a guess, never verified, and not needed -- the
    /// experiment that established this technique showed a window with the
    /// private level and NO tags survived Exposé just fine. Setting undocumented
    /// WindowServer flags on a maximum-level window is a good way to corrupt
    /// Mission Control's own compositing, so we no longer touch tags at all.
    func makeVisibleOverMissionControl(windowNumber: Int) {
        let level = CGWindowLevelForKey(.maximumWindow)
        _ = setWindowLevelFn?(connection, Int32(windowNumber), Int32(truncatingIfNeeded: level))
    }

    /// Raw `Monitors` payload: one entry per display, each with an ordered `Spaces` array.
    func managedDisplaySpaces() -> [[String: Any]] {
        guard isAvailable,
              let raw = copyDisplaySpacesFn?(connection)?.takeRetainedValue() as? [[String: Any]]
        else { return [] }
        return raw
    }

    /// Switch the given display to `spaceID`. Returns true on success.
    @discardableResult
    func setCurrentSpace(displayIdentifier: String, spaceID: UInt64) -> Bool {
        guard let setCurrentSpaceFn else { return false }
        return setCurrentSpaceFn(connection, displayIdentifier as CFString, spaceID) == 0
    }

    /// Space IDs a window currently lives on.
    func spaces(forWindowID windowID: Int) -> [UInt64] {
        guard let spacesForWindowsFn,
              let raw = spacesForWindowsFn(connection, 0x7, [windowID] as CFArray)?.takeRetainedValue() as? [UInt64]
        else { return [] }
        return raw
    }
}
