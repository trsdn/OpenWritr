# OpenWritr v1.3.0

Release date: 2026-08-11

This release makes microphone ownership capture-scoped and hardens OpenWritr against CoreAudio device changes, rapid hotkey transitions, and shutdown races.

## Install or Upgrade

OpenWritr v1.3.0 requires macOS 14 or later on Apple Silicon (M1 or later).

Quit OpenWritr, then download either release artifact from GitHub. Open the DMG or unzip the ZIP, replace `OpenWritr.app` in `/Applications`, and grant Microphone and Accessibility permissions if macOS prompts for them.

## Changes

- Microphone access activates only for an accepted push-to-talk capture
- Microphone startup is asynchronous and shown as a preparation state
- Capture operations use generation-safe start, drain, stop, failure, and shutdown handling
- Benign CoreAudio configuration changes no longer automatically fail a recording
- Engine recovery is serialized and limited to one attempt per capture
- Device disconnection and restoration paths no longer retain stale system input IDs
- Input-device changes are disabled while capture owns the microphone
- Microphone runtime errors include dedicated retry and validation behavior

## Privacy and Optional Enhancement

Core transcription runs locally on the Apple Neural Engine, and microphone audio never leaves the device. Enhanced Mode is optional; when enabled, it sends transcript text to the selected GitHub Copilot or OpenAI-compatible provider for cleanup.

## Release Artifacts

- `OpenWritr-v1.3.0-macOS-arm64.zip`
- `OpenWritr-v1.3.0-macOS-arm64.zip.sha256`
- `OpenWritr-v1.3.0-macOS-arm64.dmg`
- `OpenWritr-v1.3.0-macOS-arm64.dmg.sha256`

## Verify Downloads

```sh
shasum -a 256 -c OpenWritr-v1.3.0-macOS-arm64.zip.sha256
shasum -a 256 -c OpenWritr-v1.3.0-macOS-arm64.dmg.sha256
```

Validate stapling and Gatekeeper assessment:

```sh
xcrun stapler validate OpenWritr-v1.3.0-macOS-arm64.dmg
spctl --assess --type open --context context:primary-signature --verbose OpenWritr-v1.3.0-macOS-arm64.dmg
```
