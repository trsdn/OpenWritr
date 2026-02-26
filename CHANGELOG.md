# Changelog

All notable changes to OpenWritr will be documented in this file.

## [1.1.0] — 2026-02-26

### Added
- Enhanced Mode — optional AI-powered transcript cleanup using GitHub Copilot
- Three model choices: GPT-4.1 (default), Claude Haiku 4.5, GPT-5 Mini
- GPT-4.1 and GPT-5 Mini use no premium tokens with a GitHub Copilot subscription
- Debug Mode toggle showing raw vs. enhanced transcript in the menu

### Fixed
- Enhanced Mode failing in GUI context due to missing Node.js PATH (nvm/fnm support)
- Copilot CLI binary discovery for non-standard installation paths

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
