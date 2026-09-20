# Accessibility check

What was checked on 2026-09-19 against OpenWritr 1.6.4 (`X01`–`X03`, `X05`), how,
and what could not be checked. It is a source review plus a read of the running
app's accessibility tree through macOS System Events. It is **not** a VoiceOver
session or an audit.

## Names and roles (`X02`)

The Settings window's tree was read with System Events. Every toggle
(`Auto-Paste`, `Sound Effects`, `Enhanced Mode`, `Always Enhance Recordings`,
`Launch at Login`, `Debug Mode`, `Automatically Check for Updates`) is exposed as a
switch with a name, and both pop-up buttons (`Input Device`, `Push-to-Talk Key`,
`Provider`) are exposed as pop-up buttons with a name. The menu bar menu is a
standard `NSMenu`; every item has a title and is enabled or disabled correctly.

Two push buttons (`Edit` and `Check for Updates Now…`) had no title through
System Events, although the source gives each a text title
(`Sources/OpenWritr/SettingsView.swift`). Whether VoiceOver reads them correctly
was not tested. The recording overlay sets an explicit accessibility label per
state (`Listening`, `Transcribing`, `Enhancing transcription`, `Transcription
ready`, `Transcription error`).

## Keyboard (`X01`)

Assessed by source review, an accessibility-tree read, and an automated guard. No
maintainer was needed: the standard accepts "a documented manual check or an
automated test", and names an AI agent as a valid assessor.

- **Every interactive element is a platform control.** The 50 interactive
  elements in `Sources/OpenWritr/` are `Button`, `Toggle`, `Picker`, `Link`,
  `SettingsLink`, and `TextEditor`. macOS makes these keyboard-operable (with Full
  Keyboard Access for buttons and switches) and draws their focus ring, and their
  tab order follows layout order. The tree read confirms each exposes `AXPress` or
  the equivalent action. The menu bar menu is a standard `NSMenu`, and Quit has
  the `⌘Q` shortcut.
- **Nothing is pointer-only.** `Tests/OpenWritrTests/KeyboardOperabilityGuardTests.swift`
  fails the build if any source file gains a tap, drag, long-press, or hover
  construct, or hides the focus ring (`.focusable(false)`, `.focusEffectDisabled`),
  beyond one reviewed exception.
- **Dictation itself is a hotkey**, so the primary function needs no pointer.

**Known gap.** The one reviewed exception is `.simultaneousGesture(TapGesture())` on
the `Settings…` link in the menu (`MenuBarView.swift`). It brings the window to the
front, because an `LSUIElement` app is never active on its own. It is additive, so
the link still opens Settings from the keyboard, but a keyboard activation does not
run that gesture, so the window can open behind the frontmost app.

**Not observed.** The visible focus ring and tab order were not watched on screen:
System Events reported only the window as focused during an automated Tab pass, so
that pass proved nothing. `X01` is therefore recorded as `Partial`.

## Colour and text size (`X03`)

- **Meaning is not carried by colour alone.** Every overlay state has a text label
  (`Listening`, `Writing`, `Polishing`, `Ready`, or the error message) and a
  distinct icon; the accent colours only reinforce it.
- **Overlay contrast** (WCAG relative luminance, text against the overlay's
  near-black background, `0.075` white): 13.3:1 listening, 9.6:1 listening with
  enhancement, 12.7:1 done, 9.7:1 error. All exceed 7:1.
- **Settings warnings use `Color.orange`** for input-device and provider attention
  text at caption size. System orange is about 2.2:1 on a white window
  background, below the 4.5:1 that small text needs; on a dark background it is
  about 8:1. This is a real weakness in light mode.
- **Reduce Motion is respected** in the overlay (`accessibilityReduceMotion`).
- **Text size is fixed** in the overlay (11 pt) and in the monospaced prompt editor
  (12 pt). macOS has no Dynamic Type, but these do not follow larger-text
  settings either.

## Known limitations

These are the ones the README states under **Accessibility**: hold-to-talk with no
toggle mode, no announcement other than sound cues, orange warning text in light
mode, fixed-size overlay text, and no VoiceOver pass.
