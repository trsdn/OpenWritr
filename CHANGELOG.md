# Changelog

All notable changes to OpenWritr will be documented in this file.

Each release's notes on GitHub are generated from its section here, and the
broker publication handoff fails when the section for a tag is missing or empty.

## [1.6.6] — 2026-09-22

### Fixed
- Auto-paste cancellation now shows a recoverable error instead of success when OpenWritr cannot preserve the existing clipboard

## [1.6.5] — 2026-09-20

### Added
- The app bundle now carries its licence texts and third-party notices (`Contents/Resources/Licenses/`), plus its copyright, licence, description, repository, and issue-tracker links in its metadata
- A `--self-test` command-line option that transcribes an audio file with the built-in speech model and exits, used by the release smoke test
- Deterministic UI screenshot generation and a pull-request-only agentic Apple HIG review for maintainer-facing visual regression checks

### Fixed
- The Settings window now comes to the front however it is opened, including from the keyboard
- The model picker for OpenAI-compatible providers now has an accessible name for screen readers

## [1.6.4] — 2026-09-19

### Fixed
- Brought the Settings window to the front when opened and kept it on top of other windows (#42)

## [1.6.3] — 2026-09-19

### Fixed
- Padded very short recordings so they are transcribed instead of dropped (#40)
- Pasted the transcript even when the existing clipboard contents could not be read, instead of failing silently (#40)

### Changed
- Updated the FluidAudio speech framework from 0.13.6 to 0.15.7 (#34)

## [1.6.2] — 2026-09-19

### Fixed
- Transcription errors no longer block the overlay: it dismisses itself after 2.5 seconds and the hotkey can record again immediately (#39)

## [1.6.1] — 2026-09-16

### Fixed
- Removed the update attestation policy that made every in-app update check fail (#31, #32). 1.6.0 cannot update itself and has to be replaced manually once.

## [1.6.0] — 2026-09-16

### Added
- In-app updates: OpenWritr checks GitHub Releases about every 24 hours (Settings → Updates) and installs newer Developer ID-signed builds in place. A manual check is available from the menu bar and Settings (#30)

## [1.5.1] — 2026-09-16

### Fixed
- Explicit microphone selections now bind directly to the capture input, so the chosen device is the one recorded from

## [1.5.0] — 2026-08-15

### Added
- Unified voice-reactive waveform overlay for listening, transcribing, enhancing, done, and error states
- Apple Intelligence cleanup provider (macOS 26+, on-device)
- Model-tuned cleanup prompts, stored per provider and model
- Always-enhanced recording mode, with Shift as a one-recording bypass
- Cleanup-model evaluation tooling

### Changed
- Resilient microphone routing that follows System Default changes

## [1.4.0] — 2026-08-11

### Added
- Added an About OpenWritr window with installed version/build information
- Added direct links to the project website, source repository, issue reporting, releases, and MIT license
- Added open-source, maintainer, and copyright attribution inside the app

## [1.3.0] — 2026-08-11

### Changed
- Activated the microphone input engine only during an accepted push-to-talk recording instead of keeping it active while OpenWritr was idle
- Added a visible microphone preparation state and generation-safe asynchronous capture startup
- Added typed microphone recovery actions and clearer input-device status in the menu and Settings

### Fixed
- Serialized CoreAudio lifecycle and device-change handling to prevent overlapping engine rebuilds and stale-device restart loops
- Preserved rapid hotkey release during microphone startup and prevented stale capture operations from changing newer app state
- Prevented queued capture starts after shutdown and hardened callback, continuation, and capture-generation cleanup
- Preserved and restored the original macOS system input safely across repeated custom-device recordings and device disconnections
- Rejected input-device changes while capture is active so microphone ownership cannot be stranded

## [1.2.1] — 2026-07-24

### Fixed
- Made model readiness, permission, and runtime failures report accurate errors with reliable retry paths
- Handled transcription and enhancement failures without reusing invalid output, while accepting a successful empty enhancement
- Hardened Copilot CLI execution with nvm/fnm discovery, concurrent pipe draining, enforced timeouts, and process cleanup
- Restored temporary system microphone changes on every exit path and made the audio lifecycle safer across starts, stops, and failures
- Preserved clipboard contents losslessly with race-safe restoration, including pending restoration during app shutdown
- Improved build checks, privacy and installation guidance, and release artifact preparation and verification

## [1.2.0] — 2026-04-23

### Added
- Dedicated Settings window for recording, enhancement, and app preferences
- OpenAI-compatible enhancement provider with refreshable model discovery
- Configurable enhancement prompt shared by Copilot and OpenAI-compatible cleanup
- Keychain-backed storage for the optional enhancement API key
- Separate shortcut paths for normal and enhanced capture: hotkey for raw transcription, Shift + hotkey for enhancement

### Changed
- Simplified menu bar copy and moved advanced controls out of the compact menu
- Enlarged and decluttered the recording HUD for better visibility while dictating
- Improved enhancement feedback with provider/model tracking and user-visible warnings
- Updated the build/sign flow to reuse a stable macOS signing identity so permissions survive rebuilds
- Updated FluidAudio integration for the current release API

### Fixed
- Restored clipboard contents after auto-paste without duplicating the pasted text
- Reduced truncated recordings on key release by waiting briefly for capture buffers to settle
- Improved fallback handling when a selected input device disappears
- Fixed Shift + hotkey detection by evaluating modifier state synchronously in the event tap

## [1.1.0] — 2026-02-26

### Added
- Enhanced Mode with GitHub Copilot cleanup after transcription
- Support for GPT-4.1, GPT-5 Mini, and Claude Haiku 4.5 as enhancement models

### Fixed
- Improved Node.js PATH resolution for GUI app launches so the Copilot CLI can be found reliably
- Hardened Copilot binary discovery for enhancement requests

## [1.0.0] — 2026-02-24

### Added
- Push-to-talk voice-to-text via Fn (Globe) key
- NVIDIA Parakeet TDT 0.6B v3 model via FluidAudio / CoreML
- Automatic transcription pasting into focused app
- Floating translucent overlay showing recording/transcribing state
- Audio cues for start/stop recording
- Auto-Paste toggle
- Sound Effects toggle
- Launch at Login via SMAppService
- Silence and short recording detection (ignores < 0.3s or silent audio)
- Automatic model download on first launch (~460 MB)
- Menu bar only app (no dock icon)
- Apple HIG compliant UI
- GitHub Pages landing page
