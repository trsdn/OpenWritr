# OpenWritr v1.2.0

Native macOS menu bar voice-to-text with local transcription on Apple Neural Engine and optional enhancement via Copilot/OpenAI-compatible providers.

## Highlights

- New dedicated Settings window for recording, enhancement, and app preferences
- OpenAI-compatible enhancement provider with refreshable model discovery
- Configurable enhancement prompt shared across enhancement providers
- Keychain-backed storage for optional enhancement API key
- Cleaner normal vs enhanced capture flow: hotkey for raw transcription, `Shift + hotkey` for enhancement

## Improvements

- Improved recording HUD visibility
- Better enhancement feedback with provider/model tracking and user-visible warnings
- More robust signing identity reuse in build/sign flow
- Updated FluidAudio integration for current release API

## Fixes

- Clipboard restore after auto-paste without duplicated paste content
- Reduced truncated recordings on key release with short buffer-settle wait
- Better fallback when a selected input device disappears
- Fixed `Shift + hotkey` detection by checking modifier state synchronously

## Security and Distribution

- Developer ID signed app bundle and DMG
- DMG notarized and stapled
- SHA-256 checksum published alongside release artifact

## Artifacts

- OpenWritr-v1.2.0-macOS-arm64.dmg
- OpenWritr-v1.2.0-macOS-arm64.dmg.sha256

## Verify Download

```sh
shasum -a 256 -c OpenWritr-v1.2.0-macOS-arm64.dmg.sha256
```
