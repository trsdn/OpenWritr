# OpenWritr v1.2.1

Release date: 2026-07-24

This bug-fix release improves error recovery, Copilot subprocess handling, microphone and audio cleanup, clipboard restoration, and release reliability. It does not add new v1.2 features.

## Install or Upgrade

OpenWritr v1.2.1 requires macOS 14 or later on Apple Silicon (M1 or later).

Quit OpenWritr, then download either intended release artifact from the GitHub release. Open the DMG or unzip the ZIP, and replace `OpenWritr.app` in `/Applications`. Grant Microphone and Accessibility permissions if macOS prompts for them.

## Privacy and Optional Enhancement

Core transcription runs locally on the Apple Neural Engine, and microphone audio never leaves the device. Enhanced Mode is optional; when enabled, it sends transcript text to the selected GitHub Copilot or OpenAI-compatible provider for cleanup.

## Intended Release Artifacts

- `OpenWritr-v1.2.1-macOS-arm64.zip`
- `OpenWritr-v1.2.1-macOS-arm64.zip.sha256`
- `OpenWritr-v1.2.1-macOS-arm64.dmg`
- `OpenWritr-v1.2.1-macOS-arm64.dmg.sha256`

These are the intended workflow outputs. Record signing and notarization as complete only after the release workflow and verification steps succeed.

## Verify Downloads

```sh
shasum -a 256 -c OpenWritr-v1.2.1-macOS-arm64.zip.sha256
shasum -a 256 -c OpenWritr-v1.2.1-macOS-arm64.dmg.sha256
```

After the workflow succeeds, validate stapling and Gatekeeper assessment:

```sh
xcrun stapler validate OpenWritr-v1.2.1-macOS-arm64.dmg
spctl --assess --type open --context context:primary-signature --verbose OpenWritr-v1.2.1-macOS-arm64.dmg
```
