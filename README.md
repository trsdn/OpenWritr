# OpenWritr

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](https://github.com/trsdn/OpenWritr)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%2B-333?logo=apple)](https://github.com/trsdn/OpenWritr)
[![Release](https://img.shields.io/github/v/release/trsdn/OpenWritr)](https://github.com/trsdn/OpenWritr/releases)

Native macOS menu bar app for push-to-talk voice-to-text. Hold the Fn key, speak, release — transcribed text is pasted at your cursor. Completely local, powered by Apple Neural Engine.

**[Website](https://trsdn.github.io/OpenWritr/)** · **[Download](https://github.com/trsdn/OpenWritr/releases/latest/download/OpenWritr-v1.0.0-macOS-arm64.zip)** · **[Release](https://github.com/trsdn/OpenWritr/releases)**

<p align="center">
  <img src="docs/mockup.svg" alt="OpenWritr in action" width="720">
</p>

## How It Works

1. **Hold Fn** — microphone activates, a floating overlay confirms recording
2. **Release Fn** — audio is transcribed via NVIDIA Parakeet TDT v3 on the Neural Engine
3. **Text appears** — result is pasted into whatever app is focused

## Performance

| Metric | Value |
|--------|-------|
| End-to-end latency | < 1 second |
| Model | NVIDIA Parakeet TDT 0.6B v3 |
| Inference | Apple Neural Engine via CoreML |
| Runtime memory | ~38 MB physical |
| Binary size | 6.6 MB (release) |
| Model size | ~460 MB (downloaded on first launch) |
| Languages | 25 (English, German, French, Spanish, and more) |
| Data sent to cloud | None |

## Requirements

- macOS 14+
- Apple Silicon (M1 or later)

## Install

```sh
git clone https://github.com/trsdn/OpenWritr.git
cd OpenWritr
swift build -c release
.build/release/OpenWritr
```

On first launch, grant **Microphone** and **Accessibility** permissions when prompted. The Parakeet model downloads automatically (~460 MB).

## Architecture

```
Sources/OpenWritr/
├── OpenWritrApp.swift          # App entry, MenuBarExtra, state machine
├── MenuBarView.swift           # Menu bar dropdown UI
├── AudioEngine.swift           # AVAudioEngine, 16kHz capture, realtime-safe
├── TranscriptionManager.swift  # FluidAudio model loading + transcription
├── HotkeyManager.swift         # CGEventTap for Fn/Globe key detection
├── PasteManager.swift          # Clipboard save/restore + Cmd+V simulation
├── OverlayPanel.swift          # Floating translucent recording indicator
├── SoundManager.swift          # Programmatic audio cue generation
└── PermissionsManager.swift    # Microphone + Accessibility permission handling
```

738 lines of Swift. No Electron, no Python, no dependencies beyond [FluidAudio](https://github.com/FluidInference/FluidAudio).

## Tech Stack

- **Swift 6 / SwiftUI** — strict concurrency, MenuBarExtra
- **FluidAudio** — CoreML-optimized ASR framework
- **NVIDIA Parakeet TDT 0.6B v3** — non-autoregressive transducer, 25 languages
- **Apple Neural Engine** — hardware-accelerated inference via CoreML
- **AVAudioEngine** — low-latency microphone capture at 16kHz
- **CGEventTap** — global Fn key detection (requires Accessibility permission)

## License

[MIT](LICENSE)
