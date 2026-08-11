# OpenWritr v1.3.0

Reliability and privacy-focused release for the native macOS menu bar voice-to-text app.

## Highlights

- The microphone input engine now runs only during push-to-talk recording
- A visible preparation state makes microphone startup explicit
- CoreAudio device changes are serialized with bounded recovery instead of recursive restart loops
- Rapid key release, shutdown, and stale capture callbacks are generation-safe
- Custom Bluetooth and AirPods input selection restores the original system default reliably
- Microphone failures provide dedicated retry actions and clearer device status

## Install or Upgrade

Requires macOS 14 or later and Apple Silicon (M1 or later).

Quit OpenWritr, download the ZIP or DMG from this release, and replace `OpenWritr.app` in `/Applications`. Grant Microphone and Accessibility permissions if prompted.

## Privacy

Microphone audio is transcribed locally and never leaves the device. Enhanced Mode remains optional and sends transcript text only to the selected GitHub Copilot or OpenAI-compatible provider.

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
