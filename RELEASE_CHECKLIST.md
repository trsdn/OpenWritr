# OpenWritr Release Checklist

Use this checklist for every tagged macOS release.

## 1. Preflight

- [ ] Working tree clean (`git status --short`)
- [ ] Version in `CHANGELOG.md` is final
- [ ] Developer ID identity available in keychain
- [ ] Notary profile available (`NOTARY_PROFILE=OpenWritr`) or Apple credentials set

## 2. Build + Sign + Notarize

```sh
scripts/release_macos.sh
```

Expected outcome:

- Signed app bundle created
- App notarized and stapled
- Signed ZIP created at `dist/OpenWritr-macos.zip`
- `dist/OpenWritr-macos.zip.sha256` generated
- Signed DMG created at `dist/OpenWritr-macos.dmg`
- Notarization executed (not skipped)
- `dist/OpenWritr-macos.dmg.sha256` generated

## 3. Versioned Artifact Names

Replace `x.y.z` with release version.

```sh
cp dist/OpenWritr-macos.zip dist/OpenWritr-vx.y.z-macOS-arm64.zip
cp dist/OpenWritr-macos.zip.sha256 dist/OpenWritr-vx.y.z-macOS-arm64.zip.sha256
cp dist/OpenWritr-macos.dmg dist/OpenWritr-vx.y.z-macOS-arm64.dmg
cp dist/OpenWritr-macos.dmg.sha256 dist/OpenWritr-vx.y.z-macOS-arm64.dmg.sha256
```

## 4. Verification (must pass)

```sh
unzip -q dist/OpenWritr-vx.y.z-macOS-arm64.zip -d /tmp/openwritr-verify
xcrun stapler validate /tmp/openwritr-verify/OpenWritr.app
spctl --assess --type execute --verbose /tmp/openwritr-verify/OpenWritr.app
xcrun stapler validate dist/OpenWritr-vx.y.z-macOS-arm64.dmg
spctl --assess --type open --context context:primary-signature --verbose dist/OpenWritr-vx.y.z-macOS-arm64.dmg
```

Expected lines:

- `The validate action worked!`
- `accepted`
- `source=Notarized Developer ID`

Optional deep check:

```sh
hdiutil attach -readonly -nobrowse dist/OpenWritr-vx.y.z-macOS-arm64.dmg
codesign -dv --verbose=4 /Volumes/OpenWritr/OpenWritr.app
hdiutil detach /Volumes/OpenWritr
```

## 5. GitHub Release

- [ ] Create tag `vx.y.z`
- [ ] Create GitHub Release for `vx.y.z`
- [ ] Upload artifacts:
  - `OpenWritr-vx.y.z-macOS-arm64.zip`
  - `OpenWritr-vx.y.z-macOS-arm64.zip.sha256`
  - `OpenWritr-vx.y.z-macOS-arm64.dmg`
  - `OpenWritr-vx.y.z-macOS-arm64.dmg.sha256`
- [ ] Use `RELEASE_GITHUB_vx.y.z.md` text as release body

## 6. Post-Release Sanity

- [ ] Download DMG from release page
- [ ] Verify checksum
- [ ] Install and launch on a clean user profile or second machine
- [ ] Confirm app starts and prompts for permissions as expected
