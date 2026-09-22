# OpenWritr Release Checklist

The tag-triggered GitHub Actions workflow is the canonical release path. The
maintainer prepares and tags the release; the workflow builds, signs, notarizes,
creates the draft, smoke-tests the verified workflow artifact attached to it,
and publishes it.

## One-time repository setup

The maintainer must create a GitHub environment named `release`, restrict its
deployment branches and tags to selected tags matching `v*`, and configure these
environment secrets:

- `MACOS_CERTIFICATE`
- `MACOS_CERTIFICATE_PWD`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_PASSWORD`

These values must not remain repository-level Actions secrets after the
environment migration is verified. The environment and secret migration are
repository settings; the workflow cannot create or migrate them.

## 1. Maintainer: prepare the release

- [ ] Work on a pull-request branch; do not release unreviewed local changes.
- [ ] Set both `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`
      to `x.y.z`.
- [ ] Add a non-empty `## [x.y.z] — YYYY-MM-DD` section to `CHANGELOG.md`.
- [ ] Leave no release entries under an `Unreleased` heading.
- [ ] Run the required validation:

  ```sh
  swift build -c release -Xswiftc -warnings-as-errors
  swiftlint lint --strict
  swift test
  ```

- [ ] Merge the release-preparation pull request and confirm the intended commit
      is on `main`.

## 2. Maintainer: create the release tag

- [ ] Create and push `vx.y.z` at the prepared `main` commit. This explicit tag
      push is the release trigger.
- [ ] Confirm the **Release macOS** workflow started for that tag.

Do not build or upload release assets manually during the normal path. Do not
dispatch the workflow for a new release instead of pushing its tag.

## 3. Workflow: build and publish

The workflow performs these actions without maintainer intervention:

1. Validates the triggering tag and commit, `Info.plist`, and changelog entry.
2. Uses the `release` environment to build, Developer ID-sign, notarize, staple,
   and verify the app and disk image.
3. Resolves the live remote tag again, requires it still points to the triggering
   commit, and passes the verified files to a separate job that creates or
   updates a **draft** GitHub release.
4. Downloads the same immutable workflow artifact without release-write access,
   installs its DMG, verifies Gatekeeper and notarization, and runs the
   transcription smoke test.
5. Publishes the draft only after the smoke test passes, then verifies the
   public DMG is the tested file.

The release contains exactly these five public assets:

- `OpenWritr-vx.y.z-macOS-arm64.zip`
- `OpenWritr-vx.y.z-macOS-arm64.zip.sha256`
- `OpenWritr-vx.y.z-macOS-arm64.dmg`
- `OpenWritr-vx.y.z-macOS-arm64.dmg.sha256`
- `OpenWritr-x.y.z.dmg` — the same notarized DMG bytes under the exact name
  required by AppUpdater

Release notes come from the matching `CHANGELOG.md` section. Do not write or
replace them manually.

**Never attest `OpenWritr-x.y.z.dmg`.** OpenWritr intentionally has no updater
attestation policy; restoring one or attesting the update DMG can strand or crash
installed clients (see #31).

## 4. Maintainer: monitor and recover

- [ ] Confirm **Build signed and notarized macOS artifacts** passed.
- [ ] Confirm **Create or update the draft release** passed.
- [ ] Confirm **Smoke-test the release before publishing** passed.
- [ ] Confirm **Publish the release** passed. Its smoke-test job summary is the
      `R05` record described in
      [docs/release-smoke-tests.md](docs/release-smoke-tests.md).
- [ ] Confirm the release page is public and lists all five exact asset names.

If signing, notarization, networking, or a runner fails transiently, rerun the
existing tag with `workflow_dispatch`, selecting that `vx.y.z` tag as the
workflow ref. For example:

```sh
gh workflow run release.yml --ref vx.y.z
```

Using the tag as the workflow ref is required by the `release` environment's
`v*` deployment restriction. There is no independent version input: the workflow
derives the release identity from the triggering tag, checks out its fully
qualified `refs/tags/vx.y.z` ref, and verifies that `HEAD` is that tag's commit.
The rerun rebuilds the immutable tagged commit and may replace assets only while
the release remains a draft.

The workflow refuses to overwrite an already-public release. If code, scripts,
metadata, release notes, or assets need a fix, prepare and tag a **new version**.
Never move or reuse the published tag. A failed draft may be deleted by the
maintainer before creating that new version.

## 5. Optional local rehearsal or recovery

Local release commands are optional diagnostics, not the canonical release
procedure and not a substitute for the tag-triggered workflow. They do not
create or publish a GitHub release.

With a local Developer ID identity and notary profile configured:

```sh
cp .release.env.example .release.env
scripts/release_macos.sh
```

The local script uses generic `dist/OpenWritr-macos.*` names. Verify those local
outputs directly:

```sh
xcrun stapler validate .build/release/OpenWritr.app
spctl --assess --type execute --verbose=2 .build/release/OpenWritr.app
xcrun stapler validate dist/OpenWritr-macos.dmg
spctl --assess --type open --context context:primary-signature \
  --verbose=2 dist/OpenWritr-macos.dmg
```

Do not upload locally produced files over a public release. Any recovered
release still goes through a new version and the canonical workflow.
