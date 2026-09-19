# Self-Assessment: trsdn/OpenWritr

- Standard version: 1.13.0
- Assessed on: 2026-09-19
- State: **Needs work**
- Record: [`.github/conformance.yml`](../.github/conformance.yml)

Result: 42 pass, 20 partial, 21 fail, 21 not applicable.

The state is **Needs work** because the standard names "no software validation"
as a high-priority gap (`S02`, `S03`, `S04`) and "unreproducible releases" as
another (`R05`, `R07`). Nothing critical was found: no committed secrets, no
open Dependabot alerts, `main` blocks force pushes and deletion, and secret
scanning is enabled.

Every result below was read from the repository, the GitHub API, or a command run
on 2026-09-19 (`swift build -c release` succeeded). Where a criterion could not
be met by a repository change in this pull request, it is recorded as the gap it
is.

## Profiles

| Profile | Applies | Rationale |
|---|---|---|
| Baseline | Yes | Every active repository |
| Public | Yes | Publicly visible |
| Software | Yes | Swift application code |
| Deployable | No | Nothing is deployed to a server, container, or cloud environment; end users install a released artifact, which the Package profile covers |
| Package | Yes | Publishes a signed, notarized DMG and ZIP |
| Product Identity, Language, Accessibility, Privacy | Yes | Ships a user interface and contacts network services |
| Documentation | No | The primary product is an application |
| Published Site | Yes | `docs/` is published to GitHub Pages and the app's audience never needs the repository |
| Archived | No | Actively maintained |

## Not applicable

| Criteria | Rationale |
|---|---|
| `D01`–`D06` | Deployable profile does not apply (see above). |
| `T01`–`T05` | Documentation profile does not apply. |
| `S13` | No workflow uses `pull_request_target` or `workflow_run`. |
| `W05`, `W06` | Retired in standard 1.12.0. |
| `L04`, `L06` | The app is English-only and has no string catalogs. |
| `X04` | The product has no command-line output. |
| `A01`–`A04` | The repository is not archived. |

## Partial and failing criteria

Ordered by consequence. "Fix" is what closes the gap; none of these is done by this
pull request unless stated.

### Software and release (high priority)

| ID | Result | Evidence | Fix |
|---|---|---|---|
| `S02` | fail | No test target in `Package.swift`; `CLAUDE.md` and `AGENTS.md` state there are no tests. | Add a test target covering `CleanupIntegrityValidator`, `AppleCleanupPolicy`, and the pure parts of `AppViewModel` state transitions, including failure paths. |
| `S03` | fail | No formatter, linter, or static-analysis config; no workflow runs `swift build`. | Add SwiftLint or `swift-format` and run it with the build in CI. |
| `S04` | fail | The only workflows are `release.yml` (tags) and `secret-scan.yml`. Nothing builds a pull request on the supported platform (macOS 14+, arm64). | Add a `ci.yml` running `swift build -c release` on `macos-latest` for pull requests and `main`, then make it a required check. |
| `R07` | fail | `release.yml` creates the release with the fixed notes `Signed and notarized macOS DMG and ZIP.` and has no changelog gate. | Extract the changelog section for the tag, fail on missing or empty, pass it as the notes body (`templates/release-notes/release.yml` in `trsdn/.github`). |
| `R06` | fail | The 1.6.3 and 1.6.4 releases carry only the boilerplate notes above. | Follows from `R07`. |
| `R05` | fail | Releases were tried by hand, but no record names a version, that the published artifact was installed, and what was exercised. | Record one dated smoke test of the published DMG (install, launch, dictate, paste) per release that changes build, signing, or packaging. |
| `R02` | fail | No versioning or compatibility policy is documented. | State SemVer, the macOS 14 minimum, and Apple Silicon-only in the README. |
| `R04` | partial | The release workflow validates the tag shape and derives asset names and the release title from it, but never checks that `Info.plist` `CFBundleShortVersionString` equals the tag. | Fail the build when they differ, or write the version into the bundle from the tag (`I06`). |
| `R01` | partial | `Info.plist` holds name, bundle ID, and version. It has no copyright, repository URL, issue tracker, or licence key, and `Package.swift` cannot hold them. | Add `NSHumanReadableCopyright` and repository, issues, and licence keys to `Info.plist`. Also closes `I02` and `I03`. |
| `R08` | partial | Releases are Developer ID signed and notarized, so `codesign` and `spctl` verify origin, but the repository does not say so as a consumer instruction. There is deliberately no build attestation (#31). | State in the README what a consumer can verify and how, and that GitHub attestation is intentionally not used. |
| `B08` | partial | `CHANGELOG.md` stops at 1.4.0. Versions 1.5.x and 1.6.x shipped with history only in pull requests and commits. | Backfill the changelog and make it the source of release notes (`R07`). |
| `I06` | fail | The version is a hand-edited value in `Info.plist`, bumped in `chore(release)` commits. | Derive it from the tag in the build (see `R04`). |
| `I02`, `I03` | partial | The About window links the repository, issues, and licence and shows the copyright, but the bundle metadata has no such fields and the licence text is not bundled. | See `R01`. |

### Public profile

| ID | Result | Evidence | Fix |
|---|---|---|---|
| `P08` | fail | README badges are hardcoded shields.io values (`macOS 14+`, `Swift 6`), and there is no CI or conformance badge. | Add the CI and conformance badges once `ci.yml` exists; derive or drop the hardcoded values. |
| `P09` | fail | No generated, self-hosted activity card. | Adopt `templates/repo-stats/`. |
| `P05` | partial | The README covers install, requirements, and examples but has no security, support-status, or privacy section, and its Download link is pinned to `v1.6.1`. | Add those sections and use the versionless `releases/latest` link. |
| `B02` | partial | Same stale link; no explicit status or audience statement. | Same fix. |
| `B01` | partial | The GitHub description says "Completely local", but Enhanced Mode sends transcript text to Copilot or an OpenAI-compatible API when enabled. | Reword the description to say transcription is local. |
| `B05` | partial | `swift build -c release` is documented and succeeds, but it is a compile check, not validation of behavior. | Resolved by `S02`. |
| `B06` | partial | `main` requires `Secret Scan`, is up to date before merge, and blocks force pushes and deletion. Merge commits, squash, and rebase are all allowed, and no merge policy is stated. | Choose one (the history shows squash) and document it. |
| `B13` | partial | The README, the site, and `AGENTS.md` each restate build and install steps. | Link to one home for each fact. |
| `B15` | partial | [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md) lists the three linked packages and their licences, but the app bundle does not carry the Apache-2.0 text. | Ship the notices in `Contents/Resources/`. |
| `B12` | fail | The `trsdn-standard` topic is not set. | Add the topic in repository settings once this record is merged. |
| `S07` | partial | Logging uses `os.Logger`, and a review found no call that logs transcript text, prompts, or keys. There is no test and no documented logging policy beyond the rule now in `AGENTS.md`. | Covered by `S02`. |

### Published site (`docs/`)

| ID | Result | Evidence | Fix |
|---|---|---|---|
| `W07` | fail | `docs/index.html` loads Google Fonts from `fonts.googleapis.com` and `fonts.gstatic.com`. | Self-host the fonts. |
| `W04` | fail | The landing page lacks a privacy statement (`Y01`), a security-policy link, a support link, and a review date, and its download link is `v1.5.0`. | Add the missing baseline items. |
| `W03` | partial | It states what the project is and links a download, but the version it shows is stale (`v1.5.0`). | Keep the version current or use `latest`. |
| `W01` | partial | Published from `main` `/docs` through GitHub Pages' branch source, with no workflow and no documented process. | Document it, or deploy through a workflow. |
| `W08` | partial | The site repeats the source-build commands that live in the README. | Link instead. |

### Language, accessibility, privacy

| ID | Result | Evidence | Fix |
|---|---|---|---|
| `L01`, `L03` | fail | The README does not declare a primary language or English-only support. | Add one sentence each. |
| `X01` | fail | No documented keyboard check for the app, and `docs/index.html` defines no `:focus` styles. | Do and record a manual keyboard pass over the menu bar and Settings, and add visible focus styles to the site. |
| `X02` | partial | Some controls have accessibility labels (10 in source), but coverage was not audited. | Audit with Accessibility Inspector. |
| `X03` | fail | No documented check of contrast, text sizing, or colour-only meaning; the overlay conveys state visually. | Document a check. |
| `X05` | fail | No stated accessibility limitations. | Add a short accessibility note. |
| `Y01` | partial | The README's performance table says audio never leaves the device and non-Apple providers receive transcript text. There is no dedicated privacy statement. | Add a Privacy section. |
| `Y02` | fail | Outbound destinations are not listed: the model download, GitHub Releases (updates), and the user-configured cleanup providers. | List each with its purpose. |
| `Y03` | partial | Source review found no telemetry, analytics, or crash reporting, but nothing states that. | State it in the privacy section. |
| `Y04` | fail | Storage locations (`UserDefaults`, Keychain items, model cache) and how to delete them are not documented. | Document them. |
| `Y06` | fail | Retention is not stated. | State what persists across launches and what is not stored. |

## Passing criteria

- `B03`, `P01`: MIT, OSI approved.
- `B04`: `.gitignore` covers `.build/`, `dist/`, `.artifacts/`, `.release.env`, disk images, and Xcode output; maintained source is tracked.
- `B07`, `S01`: `Package.swift` declares Swift 6 and macOS 14; `Package.resolved` pins every dependency.
- `B09`, `P07`: public, ten topics, homepage set, description present.
- `B10`: [`.github/CODEOWNERS`](../.github/CODEOWNERS) names `@trsdn` (added here).
- `B11`: the record itself.
- `B14`: `AGENTS.md` names each credential class and how it is replaced.
- `B16`, `S09`: `main` blocks force pushes and deletion and requires `Secret Scan`.
- `P02`, `P03`, `P06`: community health files resolve from the account; private reporting is enabled.
- `P04`, `P10`, `P11`: issue forms (bug, feature) and a pull-request template with the fields the standard requires, added here.
- `S05`: secret scanning enabled.
- `S06`: no environment configuration is needed; `.release.env.example` is the only template and holds no values.
- `S08`: Dependabot covers `github-actions` and `swift`, weekly.
- `S10`: architecture is in `AGENTS.md`, the README, and `plan/`, including the non-obvious update-attestation constraint.
- `S11`, `S12`: both workflows declare `permissions`; every `uses:` reference satisfies the table.
- `R03`: a `v*` tag triggers `release.yml`, which builds, signs, notarizes, and uploads the assets.
- `I01`, `I04`, `I05`: `Info.plist` carries name and version; the About window shows the version and links the repository and issues; `AppIcon.icns` is bundled and the site ships icons.
- `W02`, `W09`: the homepage field points at the site and the site links the repository; the design is specific to the project.
- `G01`–`G08`: `AGENTS.md` at the root; `swift build -c release` is the single validation command and was run successfully; forbidden operations are named; `CLAUDE.md`, `.github/copilot-instructions.md`, and `.github/github-app.yml` point at `AGENTS.md`; generated paths are listed; attribution is stated.
- `L02`, `L05`, `L07`: UI strings are English (German appears only in speech-cleanup word lists, not the interface); no manual date or number formatting was found; commits, docs, and release notes are English.
- `Y05`: the README names Apple Intelligence, GitHub Copilot, and OpenAI-compatible APIs as the providers that receive text.

## Suggested order of remediation

1. `ci.yml` running `swift build -c release`, then required (`S04`, `P08`).
2. Release-notes gate and changelog backfill (`R07`, `R06`, `B08`).
3. Version derived from the tag (`R04`, `I06`).
4. README and site: stale download links, privacy, language, accessibility, support (`P05`, `B02`, `W03`, `W04`, `L01`, `L03`, `X05`, `Y01`–`Y06`, `R02`, `R08`).
5. Test target (`S02`).
6. Site fonts (`W07`), then the topic (`B12`).
