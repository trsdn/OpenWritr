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
3. `AudioEngine` captures PCM at 16 kHz into a float buffer and publishes raw RMS levels
4. On key release, `AppViewModel.stopListeningAndTranscribe()` is called
5. `TranscriptionManager` runs the audio through `FluidAudio.AsrManager` (Whisper-based, downloaded on first launch)
6. If Enhanced Mode is on, `GrammarEnhancer` routes cleanup to Copilot, an OpenAI-compatible API, or Apple Intelligence
7. `PasteManager` simulates Cmd+V to paste — it saves/restores the clipboard around the keystroke
8. `OverlayPanel` shows a borderless, voice-reactive HUD at the bottom center throughout

**Key files:**
- `OpenWritrApp.swift` — `AppViewModel` (@Observable, @MainActor) owns all state and wires everything together; `AppState` enum drives the UI
- `AudioEngine.swift` — Wraps `AVAudioEngine`; follows System Default route changes with bounded recovery and binds explicit microphone selections directly to the capture input audio unit
- `GrammarEnhancer.swift` — Spawns `copilot` CLI as a subprocess; `EnhancedModel` holds the evaluated cleanup models and loads model-specific prompt profiles
- `OverlayPanel.swift` — borderless `NSPanel` with a shared waveform design for `.listening`, `.transcribing`, `.enhancing`, `.done`, and `.error`
- `UpdateManager.swift` — wraps [AppUpdater](https://github.com/mxcl/AppUpdater) to check GitHub Releases, validate Developer ID signatures (and, when configured, GitHub Artifact Attestation provenance), and install/relaunch in place

**Concurrency model:** `AppViewModel` is `@MainActor`. `AudioEngine` is `@unchecked Sendable` with `os_unfair_lock` for the sample buffer. `GrammarEnhancer` uses `Task.detached` to run the blocking subprocess off the main thread. `UpdateManager` is `@MainActor`.

**Preferences** are stored in `UserDefaults` (no separate plist). Custom cleanup prompts use a versioned per-provider/model store so bundled tuned defaults can change without overwriting user text.

**Signing** uses a self-signed cert stored in `.build/signing.keychain-db` (created automatically by the build script). On a fresh machine the keychain is regenerated.

## Enhanced Mode

The `GrammarEnhancer` calls `copilot -p … -s --model … --no-custom-instructions` as a subprocess. The CLI requires a valid GitHub Copilot subscription. Run `copilot login` once to authenticate.

**Supported models:** GPT-5.6 Luna (default), Gemini 3.7 Flash, MAI Code 1.1 Flash, GPT-5 Mini, and Claude Haiku 4.5.

Enhanced activation has two modes: on-demand (`Shift + hotkey`) and always-enhanced (`hotkey`, with Shift as a one-recording normal-transcription bypass). The listening overlay reflects the resolved mode immediately.

## In-App Updates

OpenWritr is distributed outside the Mac App Store, so `UpdateManager` (backed by [AppUpdater](https://github.com/mxcl/AppUpdater) 4.x) checks `trsdn/OpenWritr` GitHub Releases for a newer, Developer ID-signed DMG and installs it in place.

- **Automatic checks** run roughly every 24 hours while the app is running (menu bar toggle: *Settings → Updates → Automatically Check for Updates*, on by default). A manual check is available from the menu bar and Settings.
- **Asset naming:** the release workflow publishes an additional DMG named `OpenWritr-{semver}.dmg` (no `v` prefix, no arch suffix) alongside the existing `OpenWritr-v{version}-macOS-arm64.{dmg,zip}` assets — AppUpdater looks for this exact name.
- **Verification:** AppUpdater checks the downloaded DMG's Developer ID signing identity/Team ID/bundle identifier against the installed app, and additionally verifies GitHub Artifact Attestation (Sigstore/SLSA) provenance restricted to `.github/workflows/release.yml` on `refs/heads/main` (see `UpdateManager.init()`).
- **Resource bundle:** AppUpdater ships its Sigstore/TUF trust roots as a SwiftPM resource bundle (`AppUpdater_AppUpdater.bundle`); `scripts/build-app.sh` copies it into `Contents/Resources/` — this step is required for update checks to work at all.
- **Quiescing:** before installing, `UpdateManager` calls `AppViewModel`'s `quiesceForUpdateInstall()` to stop recording/hotkey/paste activity so a swap-and-relaunch cannot interrupt an in-flight capture.
