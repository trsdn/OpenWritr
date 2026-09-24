# Agent instructions

Read this before changing anything in this repository. It is the tool-neutral,
authoritative guidance; `CLAUDE.md` and `.github/copilot-instructions.md` point
here instead of restating it.

## What this repository is

OpenWritr is a macOS push-to-talk voice-to-text app, built with Swift Package
Manager for macOS 14+ on Apple Silicon. It launches as an `LSUIElement` menu bar
utility, and a persisted Presence setting can switch it at runtime to Dock only
or Dock plus menu bar. End users install the signed, notarized DMG/ZIP from GitHub
Releases and receive updates in place through the app itself, so a bad release
reaches every installed copy within about a day. Changes to `UpdateManager`, the
broker profile/publication handoff, or signing can strand users on an old version.

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
| `scripts/` | Local diagnostic build/DMG tools, broker release verification/publication handoff, and model-evaluation scripts. |
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

`AppPresence` is owned by `AppViewModel`. `SystemApplicationPresenceController`
is the only type that changes `NSApplication.ActivationPolicy`; failed changes
leave the previous reachable mode active.

`scripts/build-app.sh` is a local diagnostic build. It signs with a Developer ID Application or Apple Development certificate found in the local keychain (or named in `OPENWRITR_SIGNING_IDENTITY`) and exits with an error if there is none; it creates no certificate. Ad-hoc signatures are refused, because macOS would reset the app's permissions. Distributable builds do not use this script or any OpenWritr workflow: they are assembled, signed, notarized, and packaged by `trsdn/macos-notarization-broker` profile `openwritr`.

## Enhanced Mode

`GrammarEnhancer` calls `copilot -p … -s --model … --no-custom-instructions` as a subprocess. It needs a GitHub Copilot subscription; `copilot login` authenticates once.

Supported models: GPT-5.6 Luna (default), Gemini 3.7 Flash, MAI Code 1.1 Flash, GPT-5 Mini, and Claude Haiku 4.5.

Enhanced activation has two modes: on demand (`Shift + hotkey`) and always-enhanced (`hotkey`, with Shift as a one-recording normal-transcription bypass). The listening overlay reflects the resolved mode immediately.

## In-app updates

OpenWritr is distributed outside the Mac App Store. `UpdateManager` (AppUpdater 4.x) checks `trsdn/OpenWritr` GitHub Releases for a newer, Developer ID-signed DMG and installs it in place.

- Automatic checks run roughly every 24 hours (Settings → Updates, on by default). A manual check is in the menu bar and Settings.
- Asset naming: the broker profile creates an extra DMG named `OpenWritr-{semver}.dmg` (no `v` prefix, no arch suffix) as a byte-identical copy of `OpenWritr-v{version}-macOS-arm64.dmg`. AppUpdater looks for this exact name.
- Verification: AppUpdater checks the downloaded DMG's Developer ID identity, Team ID, and bundle identifier against the installed app.
- **No attestation policy — do not add one back** (#31). AppUpdater accepts only a `refs/heads/…` source ref, but releases run on tag pushes, so provenance names `refs/tags/vX.Y.Z`. It also loads its Sigstore trust roots through `Bundle.module`, which for a `swift build` product only looks at the `.app` root and the CI machine's `.build` path, so verification hits `fatalError` in a shipped app. Re-enabling it needs an upstream AppUpdater fix and releases dispatched from `main`.
- **Never attest either OpenWritr DMG.** The updater alias is byte-identical to the versioned DMG, so an attestation for either filename covers the same digest. 1.6.0 shipped with the policy and reaches the crashing code only if GitHub has an attestation for the new DMG's digest; without one it rejects the update cleanly. The broker must attest only the OpenWritr ZIP. 1.6.0 users have to update manually once.
- `scripts/build-app.sh` still copies `AppUpdater_AppUpdater.bundle` into `Contents/Resources/`. It is unused without an attestation policy but keeps the layout AppUpdater documents.
- Quiescing: before installing, `UpdateManager` calls `AppViewModel.quiesceForUpdateInstall()` so a swap-and-relaunch cannot interrupt an in-flight capture.

## Generated, vendored, and machine-owned paths

Anything not listed here is hand-maintained.

- Generated, never hand-edit: `.build/` (SwiftPM output and the built `.app`), `dist/` and `.artifacts/` (local build, broker download, and evaluation output), `*.dmg` and `*.dmg.sha256`. All are git-ignored; regenerate with `swift build -c release`, `scripts/build-app.sh`, or the broker request.
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

The local diagnostic build script needs a Developer ID Application or Apple Development certificate in the local keychain. The app asks for Microphone and Accessibility permission on first use. Release signing and notarization happen only in the broker.

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
- Pin external actions and reusable workflows in hand-maintained workflows to
  full commit SHAs with readable version comments. Update generated agentic
  workflow locks only through `gh aw compile`.
- The checkout-free release smoke job is the only release workflow with
  `contents: write`, because GitHub requires push-level access to download
  draft assets. It must run from trusted `main`, remain bound to the fixed
  maintainer/repository IDs plus exact digests and a unique nonce, and must
  never mutate a release.
- Release identity comes from `Info.plist` (`CFBundleShortVersionString` and `CFBundleVersion`). Bump both in a `chore(release): bump version to X.Y.Z` change before tagging.
- User-facing changes get an entry in `CHANGELOG.md` (`## [x.y.z] — date`). The secretless publication handoff publishes that section as the release notes and fails when it is missing or empty. The broker verifies the tagged bundle version.
- Commit messages use Conventional Commits (`fix(settings): …`, `chore(release): …`).

## Do not do these

- Do not rewrite history, force push, or delete branches. `main` blocks force pushes and deletion and requires the `Secret Scan` check.
- Do not commit secrets, tokens, credentials, certificates, notary profiles, or personal data.
- Do not publish a release, create or move tags, dispatch the notarization broker, run the publication handoff, or change repository settings. The explicitly authorized maintainer (`@trsdn`, numeric actor ID `24534196`) does this.
- Do not add a build-attestation policy to `UpdateManager`, and do not attest either OpenWritr DMG (see In-app updates).
- Do not add Apple credentials, certificates, notary profiles, release environments, or credential-reading workflows to OpenWritr. The broker is the only home for release credentials.
- Do not add private dictation or real transcripts to `eval/cleanup-cases.json`; synthetic or explicitly approved text only.
- Do not run destructive commands against the user's machine or data: no `defaults delete com.openwritr.app`, no removal of `~/Library` state, no `tccutil reset`, no `security delete-keychain` outside `.build/`.
- Do not hand-edit the generated paths listed above.
- Do not add or upgrade dependencies without a pull request the maintainer approves; Dependabot proposes routine updates weekly.

## Credentials and revocation

OpenWritr has no release credential. `MACOS_CERTIFICATE`,
`MACOS_CERTIFICATE_PWD`, `APPLE_ID`, `APPLE_TEAM_ID`, and
`APPLE_APP_PASSWORD` live only in the broker's protected `macos-signing`
environment. Those five names must not exist as OpenWritr repository or
environment secrets. The broker's security policy owns their rotation and
revocation procedure.

A local signing identity may exist in a maintainer's login keychain for
diagnostic builds, but OpenWritr scripts never export, upload, or configure it
and no local notary profile is part of the release path. User-entered provider
API keys remain in the user's macOS Keychain (`KeychainStore`); if exposed, the
user revokes the key with the provider and enters a new one in Settings.

## Attribution

Agent-authored commits carry the `Co-Authored-By` trailer for the model that
wrote them, and pull request descriptions state that they were generated with an
agent. Every change lands through a pull request; agents do not push to `main`.
