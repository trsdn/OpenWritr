# Self-Assessment: trsdn/OpenWritr

- Standard version: 1.13.0
- Assessed on: 2026-09-19
- State: **Needs work**
- Record: [`.github/conformance.yml`](../.github/conformance.yml)

Result: 64 pass, 14 partial, 5 fail, 21 not applicable.

The state is **Needs work**: the record tooling does not allow `Healthy` while any
criterion fails, and five do (`B12`, `P09`, `R05`, `X01`, `X03`). Nothing critical
was found: no committed secrets, no open Dependabot alerts, `main` blocks force
pushes and deletion, and secret scanning is enabled.

The first assessment on the same day recorded 42 pass, 20 partial, and 21 fail.
The gaps a repository change can close were then closed in the same pull request:
CI and unit tests, a changelog-driven release gate, the version taken from the tag,
bundled licence texts, README privacy, accessibility, language, versioning, and
verification sections, and the site's fonts, links, and footer.

Every result below was read from the repository, the GitHub API, or a command run
on 2026-09-19 (`swift build -c release -Xswiftc -warnings-as-errors`, `swift test`,
and `scripts/build-app.sh`, whose bundle was inspected).

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

## Remaining gaps

| ID | Result | Evidence | Fix |
|---|---|---|---|
| `R05` | fail | [`docs/release-smoke-tests.md`](release-smoke-tests.md) exists as a log but has no entry: earlier releases were tried by hand and not recorded. | Install a published DMG, dictate, paste, and add a dated entry. Only a person with the microphone and the download can do this. |
| `X01` | fail | No documented keyboard check for the app. | Do and record a keyboard-only pass over the menu bar and Settings. |
| `X03` | fail | No documented check of contrast, text sizing, or colour-only meaning; the overlay conveys state visually. | Document a check with Accessibility Inspector. |
| `P09` | fail | No generated, self-hosted activity card. | Adopt `templates/repo-stats/` from `trsdn/.github`. |
| `B12` | fail | The `trsdn-standard` topic is not set. | `gh repo edit trsdn/OpenWritr --add-topic trsdn-standard` after this is merged. |
| `B01` | partial | The GitHub description says "Completely local", but Enhanced Mode sends transcript text to Copilot or an OpenAI-compatible API when enabled. | `gh repo edit trsdn/OpenWritr --description "..."` saying transcription is local. |
| `B06` | partial | The README now states that merges are squashed, but the repository still allows merge commits and rebase merges. | Disable them in Settings → General. |
| `S02` | partial | Ten unit tests cover the cleanup integrity validator and policy, including failure paths. Audio, hotkey, paste, overlay, and update behavior have no automated tests. | Extract those behaviors behind testable seams and cover them. |
| `S03` | partial | CI builds with `-warnings-as-errors` under Swift 6 strict concurrency. There is no formatter or linter. | Add `swift-format` or SwiftLint to CI. |
| `S04` | partial | CI runs on `macos-latest`, not on the macOS 14 minimum. | Add a macOS 14 runner to the matrix. |
| `S07` | partial | Logging uses `os.Logger` and a review found no call that logs transcripts, prompts, or keys, but nothing enforces it. | A test or lint rule, or a documented logging policy beyond `AGENTS.md`. |
| `R07` | partial | The release workflow now fails without a changelog section for the tag and publishes that section as the notes, but no release has gone through it yet, so no published release demonstrates the match. | Passes with the next release; verify the notes on the release page. |
| `I06` | partial | The version comes from the tag through `OPENWRITR_VERSION`; the copyright, licence, and URLs are still constants in `Info.plist`. | Acceptable to leave; record it as a deviation. |
| `P08` | partial | The platform badge repeats `macOS 14+` by hand; the other four required badges are live. | No authoritative badge source exists for a Swift package platform. |
| `B13` | partial | The site still repeats the source-build commands that live in the README. | Link instead. |
| `W01` | partial | Published from `main` `/docs` through GitHub Pages' branch source, documented in `AGENTS.md` but with no deployment workflow. | Deploy through a workflow. |
| `W03` | partial | The landing view states what the project is and how to get it; status and the privacy sentence sit in the footer, not above the fold. | Move them into the hero. |
| `W08` | partial | Same repeated build block as `B13`. | Same fix. |
| `X02` | partial | Standard SwiftUI controls carry implicit names; only the overlay sets an explicit label. No Accessibility Inspector pass. | Audit and record. |

## Passing criteria

- `B03`, `P01`: MIT, OSI approved.
- `B04`: `.gitignore` covers `.build/`, `dist/`, `.artifacts/`, `.release.env`, disk images, and Xcode output; maintained source is tracked.
- `B02`, `P05`: README states status, requirements, install, privacy, accessibility, language, versioning, verification, and support.
- `B05`: `swift build -c release -Xswiftc -warnings-as-errors` and `swift test` are documented, run in CI, and succeed.
- `B07`, `S01`: `Package.swift` declares Swift 6 and macOS 14; `Package.resolved` pins every dependency.
- `B09`, `P07`: public, ten topics, homepage set, description present.
- `B10`: [`.github/CODEOWNERS`](../.github/CODEOWNERS) names `@trsdn` (added here).
- `B11`: the record itself.
- `B08`, `R06`: `CHANGELOG.md` covers every release from 1.4.0 to 1.6.4.
- `B15`: `THIRD_PARTY_NOTICES.md` lists the linked packages; `scripts/build-app.sh` bundles the licence texts under `Contents/Resources/Licenses/` (checked in a built app).
- `B14`: `AGENTS.md` names each credential class and how it is replaced.
- `B16`, `S09`: `main` blocks force pushes and deletion and requires `Secret Scan`.
- `P02`, `P03`, `P06`: community health files resolve from the account; private reporting is enabled.
- `P04`, `P10`, `P11`: issue forms (bug, feature) and a pull-request template with the fields the standard requires, added here.
- `S05`: secret scanning enabled.
- `S06`: no environment configuration is needed; `.release.env.example` is the only template and holds no values.
- `S08`: Dependabot covers `github-actions` and `swift`, weekly.
- `S10`: architecture is in `AGENTS.md`, the README, and `plan/`, including the non-obvious update-attestation constraint.
- `S11`, `S12`: both workflows declare `permissions`; every `uses:` reference satisfies the table.
- `R01`, `I02`, `I03`: `Info.plist` holds name, version, copyright, licence, repository, and issue URLs (verified in the built bundle); the licence text is bundled.
- `R02`: SemVer and the macOS 14 / Apple Silicon requirement are stated in the README.
- `R04`: the release workflow fails when `Info.plist` differs from the tag, and derives the title and asset names from it.
- `R08`: the README says what `codesign`, `spctl`, and `stapler` prove and that no build attestation is published, and why.
- `R03`: a `v*` tag triggers `release.yml`, which builds, signs, notarizes, and uploads the assets.
- `I01`, `I04`, `I05`: `Info.plist` carries name and version; the About window shows the version and links the repository and issues; `AppIcon.icns` is bundled and the site ships icons.
- `W04`, `W07`: the site has the baseline content (footer: status, privacy sentence, licence, security, support, review date); it loads nothing from another host (fonts are in `docs/fonts/`, checked by grepping the page for external URLs, which finds only outbound links) and sets no cookies.
- `W02`, `W09`: the homepage field points at the site and the site links the repository; the design is specific to the project.
- `G01`–`G08`: `AGENTS.md` at the root; `swift build -c release` is the single validation command and was run successfully; forbidden operations are named; `CLAUDE.md`, `.github/copilot-instructions.md`, and `.github/github-app.yml` point at `AGENTS.md`; generated paths are listed; attribution is stated.
- `L01`, `L03`: the README declares the interface English-only with no translations.
- `X05`: known limitations are stated in the README.
- `Y01`–`Y04`, `Y06`: the README's Privacy section states what is collected (nothing), every outbound destination, opt-out, storage locations, and how to delete them.
- `L02`, `L05`, `L07`: UI strings are English (German appears only in speech-cleanup word lists, not the interface); no manual date or number formatting was found; commits, docs, and release notes are English.
- `Y05`: the README names Apple Intelligence, GitHub Copilot, and OpenAI-compatible APIs as the providers that receive text.

## What only a person can do

`R05` (smoke-test a published DMG), `X01`/`X03` (keyboard and contrast checks),
and the GitHub settings above (`B01`, `B06`, `B12`) need the maintainer's hands.
`AGENTS.md` forbids agents from changing repository settings.
