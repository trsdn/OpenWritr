# OpenWritr v1.2.0

## Artifacts

- OpenWritr-v1.2.0-macOS-arm64.dmg
- OpenWritr-v1.2.0-macOS-arm64.dmg.sha256

## macOS Signing and Notarization Verification

Verification target: `dist/OpenWritr-v1.2.0-macOS-arm64.dmg`

### Stapled ticket

Command:

```sh
xcrun stapler validate dist/OpenWritr-v1.2.0-macOS-arm64.dmg
```

Result:

- The validate action worked!

### Gatekeeper notarization assessment

Command:

```sh
spctl --assess --type open --context context:primary-signature --verbose dist/OpenWritr-v1.2.0-macOS-arm64.dmg
```

Result:

- accepted
- source=Notarized Developer ID

### App signature inside DMG

Command sequence:

```sh
hdiutil attach -readonly -nobrowse dist/OpenWritr-v1.2.0-macOS-arm64.dmg
codesign -dv --verbose=4 /Volumes/OpenWritr/OpenWritr.app
hdiutil detach /Volumes/OpenWritr
```

Result (key fields):

- Identifier=com.openwritr.app
- Authority=Developer ID Application: Torsten Mahr (G69Z5BNY97)
- Authority=Developer ID Certification Authority
- Authority=Apple Root CA
- TeamIdentifier=G69Z5BNY97
- Timestamp=4. Jun 2026 at 11:26:57
- Runtime Version=26.5.0

## Checksums

Use this command to verify the downloaded artifact:

```sh
shasum -a 256 -c OpenWritr-v1.2.0-macOS-arm64.dmg.sha256
```