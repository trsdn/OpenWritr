# Agent instructions

Read this before changing anything in this repository. It is the tool-neutral,
authoritative guidance; `CLAUDE.md` and `.github/copilot-instructions.md` point
here instead of restating it.

## What this repository is

OpenWritr is a macOS menu bar app (`LSUIElement`) for push-to-talk voice-to-text,
built with Swift Package Manager for macOS 14+ on Apple Silicon. End users install
the signed, notarized DMG/ZIP from GitHub Releases and receive updates in place
through the app itself, so a bad release reaches every installed copy within about
a day. Changes to `UpdateManager`, the release workflow, or signing can strand
users on an old version.

## What this repository is not

Not an Xcode project (there is none), not a Mac App Store app, and not a cloud
service. Audio never leaves the device; only optional Enhanced Mode sends
transcript text to the provider the user chose.

## Layout

| Path | Purpose |
|---|---|
| `Sources/OpenWritr/` | The app. `OpenWritrApp.swift` holds `AppViewModel` (`@Observable`, `@MainActor`), which owns all state; `AppState` drives the UI. |
| `Sources/OpenWritr/Resources/` | Bundled cleanup prompt profiles (`cleanup-prompt-profiles.json`). |
| `Tests/OpenWritrTests/` | Unit tests (Swift Testing) for pure logic. |
| `Sources/ObjCExceptionCatcher/` | Small Objective-C shim so Swift can catch `NSException`. |
| `Resources/AppIcon.icns` | The app icon copied into the bundle. |
| `Info.plist` | Bundle identity: name, version, description, copyright, licence, repository and issue URLs. `Package.swift` has no fields for these, so they live here; the release build overrides the version from the tag. Extended by `scripts/build-app.sh`. |
| `scripts/` | Build, sign, notarize, DMG, release, and model-evaluation scripts. |
| `eval/cleanup-cases.json` | Synthetic cleanup-model benchmark cases. Never add private dictation. |
| `docs/` | GitHub Pages site (`index.html` and assets), served from `main` `/docs`. |
| `plan/` | Working implementation plans. |
| `.github/` | Workflows, Dependabot, issue forms, PR template, conformance record, and maintained Copilot path-specific instructions and custom reviewers. |

## Architecture

Full flow:

1. The user holds the hotkey (Fn/Globe or Right-Shift, per `HotkeyChoice`).
2. `HotkeyManager` fires `onRecordingStarted` from a `CGEvent` tap (needs Accessibility permission).
3. `AudioEngine` captures 16 kHz PCM into a float buffer and publishes raw RMS levels.
4. On release, `AppViewModel.stopListeningAndTranscribe()` runs.
5. `TranscriptionManager` transcribes through `FluidAudio.AsrManager` (Parakeet, downloaded on first launch).
6. With Enhanced Mode on, `GrammarEnhancer` routes cleanup to Copilot, an OpenAI-compatible API, or Apple Intelligence.
7. `PasteManager` simulates Cmd+V, saving and restoring the clipboard around the keystroke.
8. `OverlayPanel` shows a borderless, voice-reactive HUD at the bottom center throughout.

Key files:

- `AudioEngine.swift` wraps `AVAudioEngine`. It follows System Default route changes with bounded recovery and binds explicit microphone selections directly to the capture input audio unit.
- `GrammarEnhancer.swift` spawns the `copilot` CLI as a subprocess; `EnhancedModel` holds the evaluated cleanup models and loads model-specific prompt profiles.
- `OverlayPanel.swift` is a borderless `NSPanel` with one waveform design shared by `.listening`, `.transcribing`, `.enhancing`, `.done`, and `.error`.
- `UpdateManager.swift` wraps [AppUpdater](https://github.com/mxcl/AppUpdater) to check GitHub Releases, validate Developer ID signatures, and install and relaunch in place.

Concurrency model: `AppViewModel` is `@MainActor`. `AudioEngine` is `@unchecked Sendable` with `os_unfair_lock` guarding the sample buffer. `GrammarEnhancer` uses `Task.detached` to run the blocking subprocess off the main thread. `UpdateManager` is `@MainActor`.

Preferences live in `UserDefaults` (no separate plist). Custom cleanup prompts use a versioned per-provider/model store so bundled tuned defaults can change without overwriting user text.

`scripts/build-app.sh` signs with a Developer ID Application or Apple Development certificate found in the local keychain (or named in `OPENWRITR_SIGNING_IDENTITY`) and exits with an error if there is none; it creates no certificate. Ad-hoc signatures are refused, because macOS would reset the app's permissions.

## Enhanced Mode

`GrammarEnhancer` calls `copilot -p … -s --model … --no-custom-instructions` as a subprocess. It needs a GitHub Copilot subscription; `copilot login` authenticates once.

Supported models: GPT-5.6 Luna (default), Gemini 3.7 Flash, MAI Code 1.1 Flash, GPT-5 Mini, and Claude Haiku 4.5.

Enhanced activation has two modes: on demand (`Shift + hotkey`) and always-enhanced (`hotkey`, with Shift as a one-recording normal-transcription bypass). The listening overlay reflects the resolved mode immediately.

## In-app updates

OpenWritr is distributed outside the Mac App Store. `UpdateManager` (AppUpdater 4.x) checks `trsdn/OpenWritr` GitHub Releases for a newer, Developer ID-signed DMG and installs it in place.

- Automatic checks run roughly every 24 hours (Settings → Updates, on by default). A manual check is in the menu bar and Settings.
- Asset naming: the release workflow publishes an extra DMG named `OpenWritr-{semver}.dmg` (no `v` prefix, no arch suffix) beside the `OpenWritr-v{version}-macOS-arm64.{dmg,zip}` assets. AppUpdater looks for this exact name.
- Verification: AppUpdater checks the downloaded DMG's Developer ID identity, Team ID, and bundle identifier against the installed app.
- **No attestation policy — do not add one back** (#31). AppUpdater accepts only a `refs/heads/…` source ref, but releases run on tag pushes, so provenance names `refs/tags/vX.Y.Z`. It also loads its Sigstore trust roots through `Bundle.module`, which for a `swift build` product only looks at the `.app` root and the CI machine's `.build` path, so verification hits `fatalError` in a shipped app. Re-enabling it needs an upstream AppUpdater fix and releases dispatched from `main`.
- **Never attest the update DMG.** 1.6.0 shipped with the policy. It reaches the crashing code only if GitHub has an attestation for the new DMG's digest; without one it rejects the update cleanly. 1.6.0 users have to update manually once.
- `scripts/build-app.sh` still copies `AppUpdater_AppUpdater.bundle` into `Contents/Resources/`. It is unused without an attestation policy but keeps the layout AppUpdater documents.
- Quiescing: before installing, `UpdateManager` calls `AppViewModel.quiesceForUpdateInstall()` so a swap-and-relaunch cannot interrupt an in-flight capture.

## Generated, vendored, and machine-owned paths

Anything not listed here is hand-maintained.

- Generated, never hand-edit: `.build/` (SwiftPM output and the built `.app`), `dist/` and `.artifacts/` (release and evaluation output), `*.dmg` and `*.dmg.sha256`. All are git-ignored; regenerate with `swift build -c release`, `scripts/build-app.sh`, or the release scripts.
- Generated by `gh aw compile`, never hand-edit: `.github/workflows/*.lock.yml` and `.github/aw/actions-lock.json`. Edit the matching agentic workflow Markdown file and recompile it instead.
- Machine-owned: `Package.resolved`. Change it only by updating `Package.swift` or by merging a Dependabot PR.
- Bundled, edit deliberately: `Sources/OpenWritr/Resources/cleanup-prompt-profiles.json`. Editing it changes shipped prompt defaults for every user.

## Setup

```sh
git clone https://github.com/trsdn/OpenWritr.git
cd OpenWritr
swift build -c release
```

Requirements are in the README; the toolchain is Swift 6 (`swift-tools-version: 6.0` in `Package.swift`). Dependencies are pinned in `Package.resolved`.

## Run

```sh
bash scripts/build-app.sh                    # builds, bundles, and signs .build/release/OpenWritr.app
cp -R .build/release/OpenWritr.app /Applications/
open /Applications/OpenWritr.app
```

The build script needs a Developer ID Application or Apple Development certificate in the local keychain. The app asks for Microphone and Accessibility permission on first use.

## Validate before proposing a change

These commands must all succeed (CI runs them on every pull request):

```sh
swift build -c release -Xswiftc -warnings-as-errors
swiftlint lint --strict
swift test
```

`swiftlint lint --strict` (config in `.swiftlint.yml`, a small rule set that passes today so any violation is a regression; install with `brew install swiftlint`) catches force casts and tries, unused bindings, and similar mistakes. The build type-checks the whole package under Swift 6 strict concurrency with warnings as errors, and links the executable. `swift test` runs the unit tests in `Tests/OpenWritrTests/`, which cover the cleanup integrity validator and policy. The tests do **not** cover audio, hotkey, paste, overlay, or update behavior, and there is no formatter. For a change to those areas, also run the built app and check the affected flow by hand, and say in the pull request what you tried.

## Conventions

- All state changes go through `AppViewModel`; views and managers do not own app state.
- Keep blocking work (subprocesses, network) off the main actor; follow the `Task.detached` pattern in `GrammarEnhancer`.
- Log with `os.Logger` (subsystem `com.openwritr.app`, one category per type). Never log transcript text, audio, prompts, API keys, or tokens.
- User-facing strings are English.
- Release identity comes from `Info.plist` (`CFBundleShortVersionString` and `CFBundleVersion`). Bump both in a `chore(release): bump version to X.Y.Z` change before tagging.
- User-facing changes get an entry in `CHANGELOG.md` (`## [x.y.z] — date`). The release workflow publishes that section as the release notes and fails when it is missing or empty, or when Info.plist disagrees with the tag.
- Commit messages use Conventional Commits (`fix(settings): …`, `chore(release): …`).

## Do not do these

- Do not rewrite history, force push, or delete branches. `main` blocks force pushes and deletion and requires the `Secret Scan` check.
- Do not commit secrets, tokens, credentials, certificates, or personal data. `.release.env` is git-ignored; `.release.env.example` is the template.
- Do not publish a release, create or move tags, dispatch the release workflow, or change repository settings. The maintainer (`@trsdn`) does this.
- Do not add a build-attestation policy to `UpdateManager` or attest the update DMG (see In-app updates).
- Do not add private dictation or real transcripts to `eval/cleanup-cases.json`; synthetic or explicitly approved text only.
- Do not run destructive commands against the user's machine or data: no `defaults delete com.openwritr.app`, no removal of `~/Library` state, no `tccutil reset`, no `security delete-keychain` outside `.build/`.
- Do not hand-edit the generated paths listed above.
- Do not add or upgrade dependencies without a pull request the maintainer approves; Dependabot proposes routine updates weekly.

## Credentials and revocation

Release credentials are held as secrets in the GitHub `release` environment and
are never in the tree. Only the signing/notarization job uses that environment.
If one is exposed, revoke it at its source first, then update the environment
secret.

| Credential | Where it lives | If exposed |
|---|---|---|
| `MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PWD` (Developer ID Application `.p12`) | GitHub `release` environment secrets | Revoke the certificate in the Apple Developer portal, issue a new one, re-export the `.p12`, update both secrets. Maintainer only. |
| `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | GitHub `release` environment secrets | Revoke the app-specific password at appleid.apple.com, create a new one, update `APPLE_APP_PASSWORD`. Maintainer only. |
| Local notary profile (`xcrun notarytool store-credentials`) | The maintainer's login keychain | Revoke the app-specific password as above and store the profile again. |
| User-entered provider API keys | The user's macOS Keychain (`KeychainStore`) | The user revokes the key with the provider and enters a new one in Settings. The repository holds none. |

## Attribution

Agent-authored commits carry the `Co-Authored-By` trailer for the model that
wrote them, and pull request descriptions state that they were generated with an
agent. Every change lands through a pull request; agents do not push to `main`.
