---
applyTo: "Sources/OpenWritr/**/*.swift"
---

# macOS HIG code review

Review UI-facing changes for concrete macOS usability, accessibility, safety, or
privacy defects. Report only high-confidence findings that identify the affected
file and line, explain the user impact, and give an actionable correction. Do not
report subjective aesthetic preferences, speculative rendered behavior, or a
different design that is merely equally valid.

- Prefer native SwiftUI or AppKit controls and behaviors when they provide the
  required semantics. Flag custom replacements only when they lose a standard
  interaction, state, accessibility role, or menu-bar convention.
- Treat OpenWritr as an `LSUIElement` menu-bar app. Check menu item naming,
  ordering, enabled state, keyboard equivalents, Settings/About/Quit placement,
  and whether windows reliably activate and return focus.
- Ensure every operation is keyboard reachable with a logical focus order,
  visible focus, appropriate default/cancel behavior, and no interception of
  standard macOS shortcuts or text-editing keys.
- Require meaningful VoiceOver names for icon-only or ambiguous controls,
  useful values for changing state, correct grouping, and hidden decorative
  content. A tooltip alone is not an accessibility name.
- Prefer semantic system colors, materials, and text styles over fixed values.
  Check legibility and state distinction in light mode, dark mode, Increased
  Contrast, and without color as the only cue.
- Respect Reduce Motion. Motion must communicate state rather than decorate,
  avoid disorienting repetition, and have a reduced or nonanimated equivalent.
- Use alerts sparingly for consequential information. Destructive actions need
  clear verb labels, appropriate confirmation and cancel paths, and must not be
  the accidental default.
- Use an ellipsis only when choosing the command opens another view that requires
  user input before the command completes; do not use it for immediate actions,
  progress, or informational windows.
- Keep Settings organized by user task with stable labels and immediate,
  reversible preference behavior. Avoid unnecessary Apply/Save actions.
- Check focus, selection, loading, disabled, error, and success states across
  asynchronous transitions. State must not become stale, ambiguous, trapped, or
  silently discard user work.
- For microphone access, recordings, transcripts, clipboard use, provider
  handoff, and API keys, make collection and destination clear at the moment it
  matters. Never expose sensitive values unnecessarily, request permission
  without context, or imply on-device privacy when text may leave the Mac.

