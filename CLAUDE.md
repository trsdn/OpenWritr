# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Install

```bash
# Build, bundle, and sign (creates .build/release/OpenWritr.app)
bash scripts/build-app.sh

# Install to Applications
cp -R .build/release/OpenWritr.app /Applications/

# Run
open /Applications/OpenWritr.app

# Quick compile check without bundling
swift build -c release
```

There are no tests. No linting toolchain is configured.

## Architecture

OpenWritr is a macOS menu bar app (LSUIElement) built with Swift Package Manager targeting macOS 14+. There is no Xcode project — everything goes through `swift build` and the bundle is assembled manually in `scripts/build-app.sh`.

**The full flow:**
1. User holds the hotkey (Fn/Globe or Right-Shift, configured per `HotkeyChoice`)
2. `HotkeyManager` fires `onRecordingStarted` via a `CGEvent` tap (requires Accessibility permission)
3. `AudioEngine` captures PCM at 16 kHz into a float buffer
4. On key release, `AppViewModel.stopListeningAndTranscribe()` is called
5. `TranscriptionManager` runs the audio through `FluidAudio.AsrManager` (Whisper-based, downloaded on first launch)
6. If Enhanced Mode is on, `GrammarEnhancer` calls `copilot -p … -s --model …` as a subprocess
7. `PasteManager` simulates Cmd+V to paste — it saves/restores the clipboard around the keystroke
8. `OverlayPanel` shows a floating HUD near the top of the screen throughout

**Key files:**
- `OpenWritrApp.swift` — `AppViewModel` (@Observable, @MainActor) owns all state and wires everything together; `AppState` enum drives the UI
- `AudioEngine.swift` — Wraps `AVAudioEngine`; switches input device by temporarily changing the macOS system default input (the only reliable method for Bluetooth/AirPods)
- `GrammarEnhancer.swift` — Spawns `copilot` CLI as a subprocess; `EnhancedModel` enum holds the three supported models
- `OverlayPanel.swift` — `NSPanel` with `OverlayState` enum; states: `.listening`, `.transcribing`, `.enhancing`, `.done`

**Concurrency model:** `AppViewModel` is `@MainActor`. `AudioEngine` is `@unchecked Sendable` with `os_unfair_lock` for the sample buffer. `GrammarEnhancer` uses `Task.detached` to run the blocking subprocess off the main thread.

**Preferences** are stored in `UserDefaults` (no separate plist). Keys: `soundEnabled`, `autoPasteEnabled`, `hotkeyChoice`, `inputDeviceUID`, `enhancedModeEnabled`, `enhancedModel`.

**Signing** uses a self-signed cert stored in `.build/signing.keychain-db` (created automatically by the build script). On a fresh machine the keychain is regenerated.

## Enhanced Mode

The `GrammarEnhancer` calls `copilot -p … -s --model … --no-custom-instructions` as a subprocess. The CLI requires a valid GitHub Copilot subscription. Run `copilot login` once to authenticate.

**Supported models:** GPT-4.1 (default), Claude Haiku 4.5, GPT-5 Mini — all verified working.
