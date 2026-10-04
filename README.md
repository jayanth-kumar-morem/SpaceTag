# SpaceTag

Name your macOS desktops and find them again without opening each one.

Stage 1 of the "named desktops" project. A menu-bar app that gives every space a
memorable name, shows which apps live on each one, and jumps you there in a click.

---

## Why not just rename the desktops in Mission Control?

Because macOS will not let you. This was tested directly on macOS 15.7.5, not
assumed:

| Approach | Result |
| --- | --- |
| `SLSSpaceSetName` (private API) | Call succeeds, but a space's "name" **is** its UUID -- the exact string `com.apple.spaces` uses to key per-app space assignments. Overwriting it silently breaks "Assign To > Desktop N". Mission Control never reads it for display. **Deliberately not used.** |
| Patch the Dock (how the old *Spaces Renamer* worked) | Requires SIP disabled. SIP is enabled on this machine, and disabling it for a naming feature is a bad trade. |
| **Overlay drawn over Mission Control** | **This is what SpaceTag does.** See below. |

The Dock's own "Desktop N" labels cannot be edited. But we *can* draw on top of
them, which gets the same result.

An earlier version of this file claimed overlays were impossible, based on a test
where the overlay vanished as soon as Mission Control opened. That test was wrong
in one specific way: it set only `NSWindow.level`. Setting the level through
WindowServer directly (`SLSSetWindowLevel`) plus the sticky window tag keeps the
window rendering over Mission Control. Confirmed by putting five differently
configured windows on screen at once and photographing which survived -- all five
did, once the level was set through the private call.

## What it does

- **Names appear in Mission Control** — swipe up with three fingers and each named
  desktop carries its name below the thumbnail, drawn the way macOS draws its own
  "Desktop N" caption: system font, white, soft shadow, with the active desktop in
  the system accent colour. Unnamed desktops stay untouched, and the label is
  suppressed on whichever thumbnail you are hovering so it never collides with
  macOS's own. Requires Accessibility access; everything else works without it.
- **Menu bar shows where you are** — the current desktop number, updated on every
  space change, with the name in the tooltip. Turn on **Show Name Instead of
  Number** to spell it out, space permitting (see below).
- **Full desktop list** — every space with its number, your name, and the apps
  currently on it (`5. Design Review   Cursor, Chrome, Music`). Empty desktops are
  marked `empty`, so the ones you can reuse are obvious at a glance.
- **Click to jump** — switches directly to that desktop, including from the keyboard.
- **Names persist** across reboots and app restarts, keyed by space UUID.
- **No permission prompts** — no Accessibility, no Screen Recording, no login items
  unless you ask.

## Naming a desktop

Press `⌃⌥N`. A small panel opens already focused, with any existing name selected
so you can just type over it. `Return` saves, `Esc` cancels, an empty field clears
the name.

To name a desktop you are not currently on, use **Rename Another Desktop** in the
menu -- no need to switch there first.

| Shortcut | Action |
| --- | --- |
| `⌃⌥N` | Rename the desktop you are on |
| `⌃⌥D` | Open the desktop list |

> The rename UI is a real `NSPanel`, not an `NSAlert`. In an `LSUIElement` app the
> alert's accessory field frequently never becomes first responder -- no caret, and
> `Return` does nothing until you click into the field. Owning the panel lets us set
> activation and first responder explicitly.

## Build and install

Only the Command Line Tools are needed -- no Xcode.

```bash
./build.sh
open build/SpaceTag.app
```

To keep it around:

```bash
cp -R build/SpaceTag.app /Applications/
open /Applications/SpaceTag.app
```

Then enable **Launch at Login** from the menu. That option needs the app to live in
`/Applications` -- macOS refuses to register a login item from a build directory.

Look for a number in the menu bar. Press `⌃⌥N` to name the desktop you are on.

## Layout

| File | Role |
| --- | --- |
| `Sources/SkyLight.swift` | `dlsym` bridge to the private WindowServer API. Every symbol is optional, so a future macOS that drops one degrades instead of crashing. |
| `Sources/SpaceModel.swift` | Turns the raw payload into ordered displays and spaces; maps windows to spaces. |
| `Sources/NameStore.swift` | Custom names, stored as JSON keyed by space UUID. |
| `Sources/Hotkey.swift` | Carbon global hotkeys (chosen over an event tap so no Accessibility prompt). |
| `Sources/MissionControlAX.swift` | Reads Mission Control's "Spaces Bar" thumbnail geometry from the Dock's accessibility tree. Its absence is also how we detect that Mission Control is closed. |
| `Sources/MissionControlOverlay.swift` | Paints the name pills over those thumbnails, in a window promoted to survive Exposé. |
| `Sources/AppDelegate.swift` | Menu bar item, menu, rename dialog, switching. |

Names live in `~/Library/Application Support/SpaceTag/names.json`. It is plain
JSON -- safe to back up, edit, or delete. Entries for deleted desktops are pruned
automatically.

## Known limits

- **Mission Control labels need Accessibility access.** Grant SpaceTag in
  System Settings > Privacy & Security > Accessibility. Because the app is
  ad-hoc signed, *rebuilding it invalidates that grant* -- remove and re-add it
  after a rebuild, or just run the copy in `/Applications`.
- **Thumbnail geometry is read live, not guessed**, so it follows your desktop
  count and display size. But it is Dock UI, and Apple can restructure it in a
  macOS update; if that happens the pills stop appearing rather than landing in
  the wrong place.
- **Names are truncated to thumbnail width** (~14 characters). Short labels work
  best: "Billing", "Design", "Comms".
- **The menu bar item is a number, not a name, by default.** This is a hard
  platform limit, not a style choice. A menu bar has finite width, and on a
  notched display anything that does not fit to the right of the notch is
  dropped -- the status item still exists, still reports `visible = true`, and
  simply never draws. Measured on this Mac: the notch spans x=763..948, the
  first drawable slot is x≈1061, and a bare number (~30pt) fits where an icon
  plus name (~100pt) does not. Reproduced with two throwaway status items that
  both claimed to be visible and neither rendered. If you free up menu bar
  space, switch it on under **Menu Bar**.

- **Desktop numbering follows Mission Control's order.** Reorder your desktops in
  Mission Control and a name stays with the *space*, not the number -- which is
  what you want, but it means "Desktop 5" may become "Desktop 3".
- **One space on this machine has no UUID** (the original desktop, currently
  Desktop 10). macOS never assigned it one, so its name is keyed by a volatile
  internal id and may not survive a reboot. Every other desktop persists normally.
- **Switching is instant, not animated.** The private switch API does not play the
  slide animation. Some apps briefly keep a stale menu bar until you click.
- **Private API.** These symbols have been stable for many macOS releases but are
  not contractual. If Apple removes them, SpaceTag degrades to read-only or shows
  a clear error rather than crashing.

## If Mission Control ever looks wrong

Turn off **Show Names in Mission Control** in the menu -- that is the kill switch,
and it stops the overlay touching anything. To clear a Mission Control already in
a bad state (spaces bar drawn over a normal desktop, wallpaper not rendering), run
`killall Dock`. It restarts the Dock in about a second and closes no windows.

Two separate causes were found for this during development:

1. **SpaceTag's fault.** It set private WindowServer window tag `0x800` on its
   overlay, on the guess that it meant "sticky". It was never needed -- the
   experiment that established the technique showed the private window level
   alone was sufficient -- and setting undocumented flags on a maximum-level
   window corrupted Mission Control's compositing. The tag is gone; SpaceTag no
   longer calls `SLSSetWindowTags` at all.
2. **Not SpaceTag's fault.** A full startup disk. WindowServer needs free space
   for window backing stores and wallpaper; below a gigabyte or so, Mission
   Control renders in pieces and the desktop picture disappears. Check with
   `df -h /System/Volumes/Data` before blaming any app.

## Stage 2 (not built yet)

Pinning an app's windows to their assigned desktop. The groundwork is in place:
`SkyLight.spaces(forWindowID:)` already resolves window -> space, and
`SLSSpaceAddWindowsAndRemoveFromSpaces` / `SLSMoveWindowsToManagedSpace` are
present on this system for the move itself.
