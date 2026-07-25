# OpenWritr v1.2.1

Bug-fix release for the native macOS menu bar voice-to-text app. Core transcription remains local on the Apple Neural Engine, with optional enhancement through GitHub Copilot or an OpenAI-compatible provider.

## Fixes

- Clearer readiness, permission, and runtime errors with dependable retries
- Safer transcription and enhancement failure handling, including valid empty enhancement output
- More robust Copilot discovery under nvm/fnm, pipe draining, timeouts, and process cleanup
- Reliable restoration of temporary system microphone changes and safer audio lifecycle handling
- Lossless, race-safe clipboard restoration, including app shutdown
- More reliable build checks, privacy/install guidance, and release preparation

## Install or Upgrade

Requires macOS 14 or later and Apple Silicon (M1 or later).

Quit OpenWritr, download the intended ZIP or DMG from this release, and replace `OpenWritr.app` in `/Applications`. Grant Microphone and Accessibility permissions if prompted.

## Privacy

Microphone audio is transcribed locally and never leaves the device. Enhanced Mode is optional and sends transcript text to the selected GitHub Copilot or OpenAI-compatible provider for cleanup.

## Intended Release Artifacts

- `OpenWritr-v1.2.1-macOS-arm64.zip`
- `OpenWritr-v1.2.1-macOS-arm64.zip.sha256`
- `OpenWritr-v1.2.1-macOS-arm64.dmg`
- `OpenWritr-v1.2.1-macOS-arm64.dmg.sha256`

Signing and notarization should be considered complete only after the release workflow and verification steps succeed.

## Verify Downloads

```sh
shasum -a 256 -c OpenWritr-v1.2.1-macOS-arm64.zip.sha256
shasum -a 256 -c OpenWritr-v1.2.1-macOS-arm64.dmg.sha256
```
