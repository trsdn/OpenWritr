# Accessibility check

What was checked on 2026-09-19 against OpenWritr 1.6.4 (`X01`–`X03`, `X05`), how,
and what could not be checked. It is a source review plus a read of the running
app's accessibility tree through macOS System Events. It is **not** a VoiceOver
session or an audit.

## Names and roles (`X02`)

The Settings window's tree was read with System Events. Every toggle
(`Auto-Paste`, `Sound Effects`, `Enhanced Mode`, `Always Enhance Recordings`,
`Launch at Login`, `Debug Mode`, `Automatically Check for Updates`) is exposed as a
switch with a name, and the pop-up buttons (`Input Device`, `Push-to-Talk Key`,
`Provider`) are exposed with names. The later `Show OpenWritr In` control is also
a labelled standard SwiftUI `Picker` and is covered by deterministic Settings
snapshots, but it has not received a separate running accessibility-tree read.
The menu bar menu is a standard `NSMenu` when that presence mode is enabled;
every item has a title and is enabled or disabled correctly.

The model picker for OpenAI-compatible providers had an empty label with the visible label hidden, so it had no name; it now carries the accessibility label `OpenAI-compatible model`. Two push buttons (`Edit` and `Check for Updates Now…`) had no title through
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

**Former gap, removed.** Activation of the app for the `Settings…` window used to be
a `.simultaneousGesture(TapGesture())` on the menu link, which a keyboard activation
does not run. The activation now happens where the Settings window appears
(`KeepWindowOnTop` in `SettingsView.swift`), whichever way it was opened, and the
gesture is gone. The guard test now allows no exceptions. This change was not
exercised in a running app on this machine, so a report that Settings still opens
behind another app when opened from the keyboard would reopen it.

**Not observed.** The visible focus ring and tab order were not watched on screen:
System Events reported only the window as focused during an automated Tab pass, so
that pass proved nothing. The assessing agent's source review, the guard test, and
the tree read are the evidence; the standard accepts these for `X01`.

## Colour and text size (`X03`)

- **Meaning is not carried by colour alone.** Every overlay state has a text label
  (`Listening`, `Writing`, `Polishing`, `Ready`, or the error message) and a
  distinct icon; the accent colours only reinforce it.
- **Overlay contrast** (WCAG relative luminance, text against the overlay's
  near-black background, `0.075` white): 13.3:1 listening, 9.6:1 listening with
  enhancement, 12.7:1 done, 9.7:1 error. All exceed 7:1.
- **Settings and menu warnings use `Color.warningText`**: a darker orange in light
  mode (6.1:1 on white, 5.2:1 on the grey window background, both above 4.5:1) and
  system orange in dark mode (about 8:1). System orange alone was about 2.2:1 on
  white, which is why it was replaced.
- **Reduce Motion is respected** in the overlay (`accessibilityReduceMotion`).
- **Text sizes are fixed points.** macOS has no Dynamic Type, so there is no
  platform text-size setting for these to follow; the overlay (11 pt) and the
  monospaced prompt editor (12 pt) do not scale, and that is a limit of the platform
  rather than something the app overrides. Everything else uses system text styles.

## Known limitations

These are the ones the README states under **Accessibility**: hold-to-talk with no
toggle mode, no announcement other than sound cues, fixed-size overlay text, and no VoiceOver pass.
