# Copilot Instructions

## Build & Run

```bash
# Full build, bundle, and sign (creates .build/release/OpenWritr.app)
bash scripts/build-app.sh

# Quick compile check (no bundling)
swift build -c release

# Install and run
cp -R .build/release/OpenWritr.app /Applications/
open /Applications/OpenWritr.app
```

There are no tests and no linting toolchain.

## Architecture

OpenWritr is a macOS menu bar app (LSUIElement) built with Swift Package Manager targeting macOS 14+ / Apple Silicon. There is no Xcode project — `swift build` compiles and `scripts/build-app.sh` assembles the `.app` bundle manually (including an ephemeral self-signed certificate).

### Data flow

1. User holds hotkey (Fn/Globe or Right-Shift, configured via `HotkeyChoice`)
2. `HotkeyManager` fires `onRecordingStarted` via a `CGEvent` tap (requires Accessibility permission)
3. `AudioEngine` captures PCM at 16 kHz into a float buffer
4. On key release, `AppViewModel.stopListeningAndTranscribe()` is called
5. `TranscriptionManager` runs audio through `FluidAudio.AsrManager` (Whisper-based, downloaded on first launch)
6. If Enhanced Mode is on, `GrammarEnhancer` calls the `copilot` CLI as a subprocess
7. `PasteManager` simulates Cmd+V to paste (saves/restores the clipboard around the keystroke)
8. `OverlayPanel` shows a floating HUD throughout

### Concurrency model

- `AppViewModel` is `@MainActor` and owns all state; `AppState` enum drives the UI state machine
- `AudioEngine` and `TranscriptionManager` are `@unchecked Sendable` with `os_unfair_lock` protecting shared buffers
- `GrammarEnhancer` uses `Task.detached` to run the blocking `Process()` subprocess off the main thread
- State enums (`AppState`, `HotkeyChoice`) are `Sendable`

### Key components

- **ObjCExceptionCatcher** — bridges Objective-C exceptions to Swift errors; used to safely wrap `AVAudioEngine` calls
- **AudioEngine** — binds explicit microphone selections directly to the capture input audio unit without changing the macOS system default
- **GrammarEnhancer** — spawns `copilot -p … -s --model … --no-custom-instructions` with a 30-second timeout; `EnhancedModel` enum holds supported models
- **UpdateManager** — wraps [AppUpdater](https://github.com/mxcl/AppUpdater) to check `trsdn/OpenWritr` GitHub Releases for a newer Developer ID-signed DMG (`OpenWritr-{semver}.dmg`), verify it (signing identity + GitHub Artifact Attestation), and install/relaunch in place; quiesces recording/hotkey/paste state via `AppViewModel.quiesceForUpdateInstall()` before installing

## Conventions

- **Enum-driven state** — use `AppState` and `OverlayState` enums to control flow instead of booleans
- **Preferences** are stored in `UserDefaults.standard` (no separate plist). Keys: `soundEnabled`, `autoPasteEnabled`, `hotkeyChoice`, `inputDeviceUID`, `enhancedModeEnabled`, `enhancedModel`, `debugModeEnabled`, `automaticUpdateCheckEnabled`
- **Callback-based wiring** — managers are instantiated in `AppViewModel` and connected via closures set after init
- **Weak self captures** in closures to prevent reference cycles
- **MARK comments** organize sections within files
- **Dependencies** — [FluidAudio](https://github.com/FluidInference/FluidAudio) for transcription and [AppUpdater](https://github.com/mxcl/AppUpdater) for in-app updates
- **Release assets** — `scripts/build-app.sh` embeds AppUpdater's `AppUpdater_AppUpdater.bundle` resource bundle into `Contents/Resources/`; the release workflow publishes an extra `OpenWritr-{semver}.dmg` asset (alongside the existing versioned zip/dmg) and attests its provenance via `actions/attest-build-provenance`
