# Assessment of trsdn/OpenWritr against the Repository Quality Standard 1.16.0

- Assessed on: 2026-09-22, by an AI agent; no maintainer was asked anything.
- Repository read: `main` at `b23cd8f`, plus the changes on `test/dictation-flow`, the GitHub API through `gh` (read-only), and the previously inspected release evidence recorded below.
- State: **Healthy**. Updated 2026-09-22 after adding hardware-free coverage for the main dictation and clipboard flow, closing the remaining partial criterion (`S02`). Reassessed on 2026-09-21 against 1.16.0, which adds `P12` and `P13`.
- Result counts: 85 pass, 0 partial, 0 fail, 21 na (106 criteria).

## What the assessor did and did not read

Read: the whole repository tree at `34fdc90` (README, AGENTS.md, CLAUDE.md, `.github/*`, workflows, scripts, `Package.swift`, `Package.resolved`, `Info.plist`, `THIRD_PARTY_NOTICES.md`, `docs/` including `index.html` and the accessibility note, all Swift sources by search and the UI files in full, tests); repository settings, rulesets, branch protection, alert APIs, community profile, releases, workflow runs and the `stats` branch through `gh api`; the `v1.6.4` ZIP and DMG.

Could not read or did not do:

- Code-scanning alerts: the API answers 404 "no analysis found", so the source is not enabled and contributes no alerts. Dependabot and secret-scanning alerts were readable and empty.
- The inherited account files (`SECURITY.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`) were confirmed to exist in `trsdn/.github` and to be listed by the community profile; their text was not audited.
- The app was not launched, no binary from the download was run, and the DMG was not mounted. The About window, VoiceOver behaviour, keyboard focus order and the running accessibility tree were not observed; `I04`, `X01`, `X02` and `X03` come from reading source only.
- No smoke kit exists on `main`, so none was run (see `R05`). An open pull request (#47) adds one on a branch; it is not on the default branch and was not assessed.
- Draft results from `assess.py` were rechecked against the API and all 19 held.
- Build check: in a scratch copy of the export (nothing in the repository was touched), `swift build -c release -Xswiftc -warnings-as-errors` finished "Build complete" and `swift test` passed 10 tests in 2 suites, both exit 0. Signing and notarization scripts were not run.

## Profiles

| Profile | Applies | Reasoning |
|---|---|---|
| Baseline | Yes | Every active repository. |
| Public | Yes | `visibility` is `PUBLIC`. |
| Software | Yes | Swift application code and an Objective-C shim. |
| Deployable | No | Not a standing deployment: matches the row "An application or tool that users download or build and install from a release, such as a macOS app". The app's own "Launch at Login" is a setting the user turns on in an installed app, not something the repository installs to run unattended, and the scheduled `stats` job is a repository workflow, not a deployment the maintainer operates. The GitHub Pages site is decided by Published Site. |
| Package | Yes | Publishes notarized ZIP and DMG release assets. |
| Documentation | No | Primary product is an application. |
| Published Site | Yes | `docs/` is served by GitHub Pages and the audience uses the app without the repository. |
| Archived | No | `isArchived` is false and the README says actively maintained. |
| Accessibility, Privacy, Product Identity | Yes | Ships a graphical interface and contacts network services. |
| Language | Yes | Software, Package and Published Site profiles apply. |

Automation Availability does not apply: hosted runners are available and used.

## Reading of judgement words used

- "Important behaviour" for `S02`: the dictation flow (hotkey, capture, transcribe, paste) is the main entry point of this app. The cleanup integrity validator alone is not that flow.
- "Where supported" for `S03`: Swift has format/lint tools in wide use (SwiftLint, swift-format); compiling under strict concurrency counts as the type check.
- "Actionable" for `S07`: a message that names the failed operation and its cause.
- `B13` counts a command, a version or runtime, and a policy in the README, `AGENTS.md`, contributing guide and `docs/`. Copies that say different things about the same command are "copies that disagree".
- `W04` item 2 is met by "Actively maintained" and "describes the latest release".
- `G02` and `B05`: a green run of the documented command on the default branch counts as the run, as `B05` and `G05` state.

## Baseline

| ID | Result | Evidence |
|---|---|---|
| B01 | pass | Description says what it is: native macOS menu bar app for push-to-talk voice-to-text, local Parakeet transcription, optional cleanup. |
| B02 | pass | README states purpose, status ("actively maintained"), install and usage, and links (site, download, changelog, licence). Audience is stated through purpose and the Requirements section (macOS 14+, Apple Silicon). |
| B03 | pass | `LICENSE` is MIT, detected by GitHub. |
| B04 | pass | `.gitignore` covers `.build/`, `.swiftpm/`, `DerivedData/`, `dist/`, `.artifacts/`, disk images, and Xcode output. OpenWritr contains no Apple credential setup script, release environment, certificate import, or notarization secret surface; those exist only in the public broker. The committed badge SVG is generated output the record documents. |
| B05 | pass | `AGENTS.md` documents `swift build -c release -Xswiftc -warnings-as-errors` and `swift test`. The latest `CI` run on `main` (push, `34fdc90`) is green. The assessor also ran both commands from a clean copy and both exited 0. |
| B06 | pass | Merge commits and rebase merges are disabled, only squash is on; `main` is protected with required checks; README states squash merges. No open critical Dependabot alert, no open secret-scanning alert, code scanning not enabled. |
| B07 | pass | `Package.swift` declares `swift-tools-version: 6.0`, `.macOS(.v14)` and both dependencies; `Package.resolved` pins them; README states macOS 14+ and Apple Silicon. |
| B08 | pass | `CHANGELOG.md` has an entry for 1.6.4, the latest release, and for each earlier release. |
| B09 | pass | Public, README presents an MIT project. Homepage `https://trsdn.github.io/OpenWritr/` is set and named in the README. Not archived, README says maintained. |
| B10 | pass | README status sentence; `.github/CODEOWNERS` names `@trsdn`; the account owns the repository. |
| B11 | pass | This record, dated 2026-09-20. |
| B12 | pass | Topic `trsdn-standard` is present. |
| B13 | pass | Each fact has one home. Build, run, and validation commands: `AGENTS.md` (the README and the site link to it). The broker-owned release credential boundary and prohibition on OpenWritr secrets: `AGENTS.md`; the maintainer release procedure: `RELEASE_CHECKLIST.md`. Requirements: the README (`AGENTS.md` links). |
| B14 | pass | `AGENTS.md` states that OpenWritr owns no release credentials, names the five obsolete OpenWritr secret names, and points revocation/rotation to the broker security policy. |
| B15 | pass | `THIRD_PARTY_NOTICES.md` lists the three linked packages and how the obligations are met. The v1.6.4 artifact does not yet carry the licence texts the notice promises; that is recorded under `I03`. |
| B16 | pass | Branch protection on `main`: `allow_force_pushes` false, `allow_deletions` false. |

## Public

| ID | Result | Evidence |
|---|---|---|
| P01 | pass | MIT, on the OSI list. |
| P02 | pass | Community profile lists contributing and code of conduct (inherited from `trsdn/.github`). |
| P03 | pass | Private vulnerability reporting enabled (`gh api repos/trsdn/OpenWritr/private-vulnerability-reporting` returns `enabled: true`); inherited `SECURITY.md`. |
| P04 | pass | `.github/ISSUE_TEMPLATE/bug.yml`, `feature.yml` and `.github/pull_request_template.md`; `config.yml` disables blank issues. |
| P05 | pass | README covers install, configuration (Settings, hotkeys, Enhanced Mode, update toggle), examples (How It Works, evaluation commands), compatibility (Requirements), security (link to policy), support status (Support and security). |
| P06 | pass | Community profile health 100; README, licence, contributing and code of conduct recognised. |
| P07 | pass | Description, ten topics plus `trsdn-standard`; homepage returns HTTP 200. |
| P08 | pass | The release badge is live and the CI badge is GitHub's own. The hand-typed license and platform badges are covered by `ReadmeBadgeConsistencyTests`, which fails when they drift from `LICENSE` and `Package.swift`, and the conformance badge by the `Conformance` workflow, which fails when it drifts from the record. |
| P09 | pass | `stats.yml` calls the shared reusable workflow daily (`cron 23 5 * * *`), writes to the `stats` branch; `repo-card.svg` and `repo-card-dark.svg` exist there (latest scheduled run success), the README uses `<picture>`, and the SVGs contain no `<image>`, `@import`, font-face or host other than the SVG namespace. |
| P10 | pass | Bug form has expected result, actual result, reproduction, version and environment. |
| P11 | pass | Template has summary, related issue, validation, and impact (risk, security/privacy, compatibility). |
| P12 | pass | Read with the two commands the standard names: `gh api -i repos/trsdn/OpenWritr/vulnerability-alerts` answers `HTTP/2.0 204 No Content` (enabled; without `-i` the empty body prints nothing) and `gh api repos/trsdn/OpenWritr/automated-security-fixes` returns `{"enabled":true,"paused":false}`. |
| P13 | pass | CodeQL supports Swift, the main language, and also Python and Actions. `.github/workflows/codeql.yml` (advanced setup, `swift build -c release -Xswiftc -warnings-as-errors` as the build (the same as CI), weekly and on pushes to `main`) analyzed all three: the run on this change's merge ref uploaded `/language:swift`, `/language:python`, and `/language:actions` analyses with no errors and 0 results (`gh api repos/trsdn/OpenWritr/code-scanning/analyses`). The default setup was tried first and its Swift autobuild failed, so it was switched off. |

## Software

| ID | Result | Evidence |
|---|---|---|
| S01 | pass | `Package.resolved` pins every dependency; setup and build commands are in README and `AGENTS.md`. |
| S02 | pass | `swift test` runs 38 Swift Testing tests, including hardware-free fakes for the main capture, transcription, enhancement, overlay, and paste orchestration. The suite covers normal and enhanced success, enhancement failure/raw recovery, accepted empty enhancement, short-input padding, transcription error recovery, stale-generation isolation, disabled auto-paste, visible recovery from cancelled auto-paste, empty and populated clipboard save/replace/restore, non-destructive restore preparation failure, delayed restore failure propagation and recovery, concurrent clipboard mutation, fail-closed handling when any declared clipboard representation cannot be preserved, overlapping pastes, and external changes before restore. Each new invariant was mutation-checked by deliberately breaking its production branch and observing the named test fail before restoring the implementation. |
| S03 | pass | Two kinds of static check run in CI and are the documented commands: the compiler under Swift 6 strict concurrency with warnings as errors, and `swiftlint lint --strict` with the rule set in `.swiftlint.yml` (force casts and tries, unused bindings, empty checks, duplicate imports, and similar). Reading of "where supported": Swift has formatters, but a formatter would rewrite most of the codebase (`swift format lint` reports the whole file set), so the linter covers the checks that can be enforced without that. |
| S04 | pass | README and `Package.swift` claim macOS 14+ on Apple Silicon, a range. CI has one job on `macos-latest`, the newest version available to the runner, which covers a range claim under 1.15.0. A job on macOS 14 would be welcome and is not required. |
| S05 | pass | `security_and_analysis.secret_scanning` is enabled with push protection; `secret-scan.yml` also runs on pushes and pull requests. |
| S06 | pass | Configuration comes from `UserDefaults`, the Keychain and environment variables (`OPENAI_BASE_URL`, `OPENAI_API_KEY`); the only committed default is `http://127.0.0.1:8080/v1`; home paths are taken from `$HOME`. No credential or personal data default. |
| S07 | pass | Logs use `os.Logger`; messages name the operation and cause (for example "Transcription failed for N captured samples: ..."). Searched log calls for text, transcript, prompt, key, token, header and body: none is logged. |
| S08 | pass | `.github/dependabot.yml` covers `github-actions` and `swift`, weekly; single maintainer owns triage. |
| S09 | pass | `main` protection requires `Secret Scan` and `Build and test`, strict; both checks exist and run. |
| S10 | pass | `AGENTS.md` names components and constraints (update attestation must not be added, asset naming AppUpdater needs, `Package.resolved` machine-owned, release identity from `Info.plist`). |
| S11 | pass | Every workflow declares permissions. All application/review/smoke workflows are read-only; only `stats.yml` writes, narrowly to the generated stats branch. Release mutation happens in an explicitly authorized maintainer-side script with the maintainer's `gh` credentials, not an Actions token. |
| S12 | pass | Hand-maintained workflow actions are pinned to full commit SHAs, and the shared conformance/stats workflows are pinned to reviewed commits. |
| S13 | na | No workflow uses `pull_request_target` or `workflow_run` (all four workflows read). |

## Deployable

| ID | Result | Evidence |
|---|---|---|
| D01 | na | Not a standing deployment (row: an application users download and install from a release). |
| D02 | na | Not a standing deployment (same row). |
| D03 | na | Not a standing deployment (same row). |
| D04 | na | Not a standing deployment (same row). |
| D05 | na | Not a standing deployment (same row). |
| D06 | na | Not a standing deployment (same row). |

## Package And Release

Assessed on the latest release, `v1.6.4` (2026-09-19), assets `OpenWritr-v1.6.4-macOS-arm64.{zip,dmg}` with checksums and `OpenWritr-1.6.4.dmg`.

| ID | Result | Evidence |
|---|---|---|
| R01 | pass | Name, version, description, copyright, licence, and repository and issue URLs all have a home in `Info.plist`, and `AGENTS.md` states why (`Package.swift` has no fields for them). The published `v1.6.5` bundle carries them, and they agree with the GitHub metadata. |
| R02 | pass | README "Versioning and compatibility" names SemVer and states what each kind of release means. |
| R03 | pass | Existing release tags are immutable. New releases use the public broker's manually authorized `openwritr` request; both the broker and the OpenWritr publication handoff resolve the tag to a full commit and fail if it moves. |
| R04 | pass | Tag `v1.6.4`, bundle `CFBundleShortVersionString` 1.6.4 (read from the download), title "OpenWritr 1.6.4". |
| R05 | pass | `publish_broker_release.sh` binds the candidate to a successful fixed-identity broker run and GitHub artifact digest. It refuses any pre-existing release/draft, creates a single-use exact five-asset draft without clobbering, and byte-compares all five downloaded draft assets with the authenticated broker output. `smoke-test.yml` verifies checksum, bundle identifier, Developer ID Team, Gatekeeper acceptance and notarization, then transcribes a synthesized phrase through `--self-test` without an operator. The handoff waits for the correlated run, rechecks the immutable tag and all five draft bytes, publishes, and verifies the exact public contract plus all five bytes again. |
| R06 | pass | Release notes: "### Fixed - Brought the Settings window to the front ... (#42)", specific, nothing breaking to warn about. |
| R07 | pass | Release notes come from the tagged `CHANGELOG.md` section. The publication handoff fails when the entry is missing, empty, or still under `Unreleased`; it never accepts freestanding notes. |
| R08 | pass | Developer ID signature (Team `G69Z5BNY97`) and stapled notarization are verified by the broker and smoke test. Broker provenance records the immutable source commit. The broker may attest the ZIP only and statically excludes both OpenWritr DMGs, because their shared digest must have no attestation (#31). |

## Product Identity

Read from the downloaded `v1.6.4` ZIP (`OpenWritr.app/Contents/Info.plist`).

| ID | Result | Evidence |
|---|---|---|
| I01 | pass | `CFBundleName` OpenWritr, `CFBundleShortVersionString` and `CFBundleVersion` 1.6.4, equal to the release. |
| I02 | pass | The published `v1.6.5` bundle's `Info.plist` carries `OpenWritrRepositoryURL` and `OpenWritrIssuesURL` (read from the downloaded release ZIP). |
| I03 | pass | The published `v1.6.5` bundle carries `NSHumanReadableCopyright`, `OpenWritrLicense` (`MIT`), and `Contents/Resources/Licenses/` with the OpenWritr licence, the dependency licences, and `THIRD_PARTY_NOTICES.md`. |
| I04 | pass | Source read, app not operated: `AboutView.swift` shows "Version X", and links the repository, "Report an Issue" and the licence. |
| I05 | pass | `CFBundleIconFile` = `AppIcon`, `AppIcon.icns` in the bundle; the site's `icon.svg`, `icon-192.png`, `apple-touch-icon.png` and `favicon.ico` show the same icon (compared visually). No store listing exists. |
| I06 | pass | The broker resolves the immutable tag, requires the source `Info.plist` version to match through its `openwritr` adapter, and stamps the release bundle from that request. Other identity values remain constants in the source-controlled plist and reviewed broker profile. |

## Documentation

| ID | Result | Evidence |
|---|---|---|
| T01 | na | Documentation profile does not apply: the primary product is an application. |
| T02 | na | Same. |
| T03 | na | Same. |
| T04 | na | Same. |
| T05 | na | Same. |

## Published Site

Source read only (`docs/index.html`); the page was not rendered, except that the URL returns 200.

| ID | Result | Evidence |
|---|---|---|
| W01 | pass | GitHub Pages source is branch `main`, folder `/docs` (from the Pages API); `AGENTS.md` says `docs/` is the Pages site served from `main` `/docs`. |
| W02 | pass | Homepage field is the site; the single page links the repository in the nav and footer. |
| W03 | pass | The hero now says what the project is, who it is for ("anyone who dictates on a Mac"), and its status ("Actively maintained"), above the fold. |
| W04 | pass | Page has name and sentence, "Actively maintained" and "describes the latest release", what it does with a mock, download and build steps, the `Y01` sentence ("No telemetry, no cookies, no third-party requests"), links to repository, licence, security and support, and "Page reviewed 2026-09-19". |
| W05 | na | Retired. |
| W06 | na | Retired. |
| W07 | pass | Searched `src`, `href`, `@import`, `url(` and `<script>`: fonts are self-hosted under `docs/fonts/`; the only `url(` is a `data:` URI; the script is inline; no cookie or storage API, no analytics. |
| W08 | pass | The site's build-from-source block was replaced by a link to the README's install section; requirements and release detail are not repeated. |
| W09 | pass | Own stylesheet with custom colour tokens, self-hosted DM Sans and JetBrains Mono, and custom layout. |

## Agent Readiness

| ID | Result | Evidence |
|---|---|---|
| G01 | pass | `AGENTS.md` at the root. |
| G02 | pass | Purpose, layout and commands are stated, and validation is named as the one to use. The command was run by the assessor from a clean copy and succeeded. Build and run commands are stated (`scripts/build-app.sh`, `open`). |
| G03 | pass | "Do not do these" covers history rewriting, force pushes, secrets, releases (no tags, broker dispatch, or publication handoff), and data-destructive commands (`defaults delete`, `tccutil reset`, keychain deletion). Deployments were treated as not applicable: nothing is deployed. |
| G04 | pass | `CLAUDE.md` imports `@AGENTS.md` and adds nothing. `.github/copilot-instructions.md` points at `AGENTS.md` and repeats its validation command; the repetition agrees, so it is not divergence under 1.15.0. |
| G05 | pass | `AGENTS.md` names the validation command; CI runs it green on `main`. |
| G06 | pass | `AGENTS.md` "Generated, vendored, and machine-owned paths" lists `.build/`, `dist/`, `.artifacts/`, disk images and `Package.resolved`; these are also in `.gitignore`. |
| G07 | pass | `AGENTS.md` "Attribution" states the `Co-Authored-By` trailer and the review expectation. |
| G08 | pass | `.github/github-app.yml` is committed, non-empty, points at `AGENTS.md` and does not contradict it. |

## Language And Localization

| ID | Result | Evidence |
|---|---|---|
| L01 | pass | README "Language": "English only" for interface, documentation and contributor surfaces. |
| L02 | pass | Sampled `AboutView`, `SettingsView`, `MenuBarView`, `OverlayPanel`, `PasteManager`, `UpdateManager`, `docs/index.html`, README: UI strings are English. German appears only in speech-cleanup word lists and prompts, which are not user-facing text. |
| L03 | pass | Same README sentence: no translations or string catalogs. |
| L04 | na | English only, no string catalogs. |
| L05 | pass | No `DateFormatter`, `String(format:)`, `toFixed`, or hand-built date, number or currency display; `$`, `$$`, `$$$` price tiers are labels, not amounts. The only display sort is `.sorted()` over remote model identifiers, which the assessor reads as technical identifiers, not locale text. |
| L06 | na | No translations shipped. |
| L07 | pass | README, docs, comments and identifiers, the last twenty commit messages, issues and pull requests, and release notes are English. |

## Accessibility

Source review; the running app was not operated.

| ID | Result | Evidence |
|---|---|---|
| X01 | pass | Settings, menu and About use standard SwiftUI/AppKit controls and the main flow is a hotkey; `KeyboardOperabilityGuardTests` fails the build on any pointer-only construct or suppressed focus ring, with no exceptions. The activation of the app for Settings moved from a tap gesture into the window helper so keyboard activation is covered; that change was not exercised in a running app (`docs/accessibility.md`). Reading: source review and an automated test are the evidence the standard names. |
| X02 | pass | Toggles, pickers and buttons use standard labelled controls, the overlay sets an accessibility label, and the previously unnamed OpenAI-compatible model picker now has one. |
| X03 | pass | Meaning is not carried by colour alone (every overlay state has a text label and an icon). Overlay text is 9.6:1 to 13.3:1 on its background; warning text now uses `Color.warningText`, 6.1:1 on white and about 8:1 in dark mode, replacing system orange (about 2.2:1). Reduce Motion is respected. Text sizes are fixed points because macOS has no Dynamic Type for a menu bar app to follow, stated in `docs/accessibility.md`. |
| X04 | na | The product has no terminal output (no command-line mode on `main`). |
| X05 | pass | README "Accessibility" states the real limitations, including that the keyboard pass was a source review and guard and that a report of Settings opening behind another app would reopen it. |

## Data Protection And Privacy

| ID | Result | Evidence |
|---|---|---|
| Y01 | pass | README "Privacy": audio never leaves the Mac and is not written to disk; transcript text leaves only in Enhanced Mode with a remote provider; no telemetry or account. Source agrees. |
| Y02 | pass | README table of destinations: Hugging Face model download, GitHub Releases update check, GitHub Copilot through the `copilot` CLI, and the user-supplied OpenAI-compatible base URL. Source shows `URLSession` calls only for the user's endpoint and AppUpdater's GitHub check. |
| Y03 | pass | No analytics, crash reporting or telemetry in source or dependencies (searched for Sentry, Crashlytics, analytics, telemetry). |
| Y04 | pass | README lists `UserDefaults` domain `com.openwritr.app`, the Keychain, and `~/Library/Application Support/FluidAudio/Models`. |
| Y05 | pass | README names Apple Intelligence (on-device), GitHub Copilot and OpenAI-compatible APIs as receiving transcript text. |
| Y06 | pass | README states that nothing persists across launches, no transcript history is kept, and how to delete preferences, Keychain items and the model folder. |

## Archived

| ID | Result | Evidence |
|---|---|---|
| A01 | na | `isArchived` is false. |
| A02 | na | Not archived. |
| A03 | na | Not archived. |
| A04 | na | Not archived. |

## Overall state

`Fail` results: `B13`, `R05`, `I02`, `I03`. None is one of the critical criteria (`B04`, `D01`-`D04`, `D06`) and none is a high-priority one that intent could excuse, so the rule "at least one criterion is `Fail`, and none of the critical criteria is" gives **Needs work**.

Intended deviations: none recorded. No gap matched a reason in the intended-deviation table: runners exist, rulesets exist, provenance is available, and the app can be operated.

## Standard defects (plain reading applied)

- `S02`: "main entry point is exercised" is not defined for a graphical app with no `main` behaviour to call; read as the dictation flow.
- `S04`: a claim stated as a range ("macOS 14+") is not decided by "one job per claimed version or platform"; read as the minimum version needing a job.
- `R05`: the table does not say whether documented signature and launch-policy commands with no start step and no recorded run are a kit (`Partial`) or no kit (`Fail`). It also gives no result for an assessor that verifies a signature but is told not to launch. Read as no kit.
- `B13`: it grades copies as agreeing or disagreeing but not a stale claim about a script's prerequisite in one file against the script and README; read as a disagreeing command fact. Tool-specific files, the PR template and `github-app.yml` restate the validation command but are outside its named surfaces (`G04` catches only one).
- `P08`: a static third-party licence or platform badge is either a "hardcoded value" (`Partial` at best) or a "live third-party image for a value with no first-party image" (`Pass`); the text supports both. Read as `Partial`.
- `G02`: says the assessor runs the validation command; only `B05` and `G05` say a green default-branch run counts. Read as counting.
- `G04`: "does not repeat or contradict" versus the criterion title "does not diverge": an agreeing one-line repeat is read as a repeat.
- Deployable table: a GitHub Pages site is not classified; read as decided by Published Site, not Deployable.
- `L05`: sorting machine identifiers for display is not addressed; read as outside locale sorting.
- `W04` item 2: "which release the page describes" is met by "the latest release"; a version number is not required by the text.
