# Changelog

All notable changes to OpenWritr will be documented in this file.

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
