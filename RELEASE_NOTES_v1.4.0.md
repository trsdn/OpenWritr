# OpenWritr v1.4.0

Release date: 2026-08-11

This release makes project identity, support, source code, downloads, and licensing discoverable from inside OpenWritr.

## Changes

- Added an About OpenWritr menu command and dedicated window
- Displays the installed application version and build
- Identifies OpenWritr as an open-source macOS application
- Attributes the project to Torsten Mahr
- Links directly to the website, repository, issue tracker, releases, and MIT license

## Install or Upgrade

OpenWritr v1.4.0 requires macOS 14 or later on Apple Silicon (M1 or later).

Quit OpenWritr, then download either release artifact from GitHub. Open the DMG or unzip the ZIP, replace `OpenWritr.app` in `/Applications`, and grant Microphone and Accessibility permissions if macOS prompts for them.

## Release Artifacts

- `OpenWritr-v1.4.0-macOS-arm64.zip`
- `OpenWritr-v1.4.0-macOS-arm64.zip.sha256`
- `OpenWritr-v1.4.0-macOS-arm64.dmg`
- `OpenWritr-v1.4.0-macOS-arm64.dmg.sha256`

## Verify Downloads

```sh
shasum -a 256 -c OpenWritr-v1.4.0-macOS-arm64.zip.sha256
shasum -a 256 -c OpenWritr-v1.4.0-macOS-arm64.dmg.sha256
```
