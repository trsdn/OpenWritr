# OpenWritr Release Checklist

Distributable builds are produced by the public
[`trsdn/macos-notarization-broker`](https://github.com/trsdn/macos-notarization-broker)
profile `openwritr`. OpenWritr has no Apple certificate or notarization secret,
and no OpenWritr workflow builds, signs, or notarizes a release.

Only the maintainer `@trsdn` (GitHub numeric actor ID `24534196`) may create a
release tag, dispatch the broker, or run the publication handoff. Agents and
contributors prepare pull requests only.

This architecture depends on
[`trsdn/macos-notarization-broker#69`](https://github.com/trsdn/macos-notarization-broker/pull/69),
which aligns profile `openwritr`, creates the AppUpdater alias, and excludes
both OpenWritr DMG digests from attestation. Merge that broker pull request
before merging or using this release path.

## 1. Prepare and merge the release

- [ ] Work on a pull-request branch; do not release unreviewed local changes.
- [ ] Set both `CFBundleShortVersionString` and `CFBundleVersion` in
      `Info.plist` to `x.y.z`.
- [ ] Add a non-empty `## [x.y.z] — YYYY-MM-DD` section to `CHANGELOG.md`.
- [ ] Leave no release entries under an `Unreleased` heading.
- [ ] Run:

  ```sh
  swift build -c release -Xswiftc -warnings-as-errors
  swiftlint lint --strict
  swift test
  ```

- [ ] Merge the release-preparation pull request and confirm the intended
      commit is on `main`.

## 2. Create the immutable tag

- [ ] Create and push `vx.y.z` at the prepared `main` commit.
- [ ] Do not move or reuse a release tag. The broker and publication handoff
      both resolve annotated or lightweight tags to the immutable commit and
      fail if the tag moves.

Pushing the tag does not run a release workflow in OpenWritr. This is
intentional: source-repository automation has no signing secret and no token
that can access broker secrets.

## 3. Request the broker build

Use a clean checkout of `trsdn/macos-notarization-broker` at its current
`origin/main`. The canonical request is:

```sh
cd /path/to/macos-notarization-broker
scripts/request.sh openwritr vx.y.z /path/to/OpenWritr/.artifacts/broker-release
```

Do **not** add `--publish`. The broker command authorizes the fixed maintainer,
resolves the tag to a full commit, builds without secrets, validates on a fresh
runner, signs and notarizes with broker-owned code, downloads only the
correlated workflow artifact, and verifies `provenance.json` plus every digest.

The broker profile must produce:

- `OpenWritr-vx.y.z-macOS-arm64.zip`
- `OpenWritr-vx.y.z-macOS-arm64.zip.sha256`
- `OpenWritr-vx.y.z-macOS-arm64.dmg`
- `OpenWritr-vx.y.z-macOS-arm64.dmg.sha256`
- `OpenWritr-x.y.z.dmg` and its broker checksum
- `provenance.json` and `preflight-manifest.json`

The updater alias is a byte-identical broker `copy_of` of the versioned DMG.
The broker may attest the ZIP, but it must not attest either OpenWritr DMG:
both DMG names have the same digest, and any attestation for that digest can
crash the updater path in OpenWritr 1.6.0 (see #31).

## 4. Create the draft, smoke-test, and publish

The broker prints the verified artifact directory. From a clean OpenWritr
checkout at the release tag or current `main`, run:

```sh
scripts/publish_broker_release.sh \
  vx.y.z \
  .artifacts/broker-release/openwritr-x.y.z-req-REQUEST_ID
```

This secretless handoff:

1. requires the authorized maintainer's numeric GitHub identity;
2. resolves the broker run and artifact recorded in the supplied provenance,
   requires the fixed broker repository/workflow/actor, successful `main` run,
   commit and attempt, then redownloads that artifact by immutable artifact ID
   and verifies GitHub's SHA-256 for the artifact archive;
3. validates broker provenance, source repository ID, tag, full commit SHA,
   profile digest, signed bundle/team identity, artifact names, checksums,
   preflight identity, the byte-identical AppUpdater alias, and a broker
   attestation manifest containing the ZIP only and neither DMG;
4. resolves the live remote tag and requires the same commit;
5. extracts release notes from the tagged `CHANGELOG.md` section;
6. requires that no release or draft already exists, atomically creates a new
   **draft** release, and uploads exactly the five public assets without
   clobbering;
7. downloads all five draft assets again and requires byte equality with the
   authenticated broker artifact;
8. dispatches `Release smoke test` from trusted `main` with a unique nonce and
   the authenticated DMG/checksum digests, correlates that exact run, and waits
   for it to pass. The checkout-free smoke job has only `contents: write`
   because GitHub requires push-level access to read draft release assets; it
   never mutates the release;
9. rechecks the tag and draft state and redownloads all five assets before
   publication; and
10. publishes the draft, then redownloads all five public assets and requires
    byte equality with the authenticated broker artifact.

Any failure before publication leaves a draft. To retry the same immutable tag,
the maintainer must first delete that unpublished draft, then start a new
handoff; the script never resumes, updates, or clobbers an existing release.
This is the per-tag serialization boundary. If the final post-publication
verification reports an error, the release is already public and must be
treated as a release incident; do not replace its assets. Corrections require a
new version and tag.

The public release contains exactly:

- `OpenWritr-vx.y.z-macOS-arm64.zip`
- `OpenWritr-vx.y.z-macOS-arm64.zip.sha256`
- `OpenWritr-vx.y.z-macOS-arm64.dmg`
- `OpenWritr-vx.y.z-macOS-arm64.dmg.sha256`
- `OpenWritr-x.y.z.dmg`

`provenance.json`, `preflight-manifest.json`, and the updater alias's redundant
checksum remain in the verified broker download; they are not public release
assets because OpenWritr's established release contract is exactly five files.

## 5. Verify the public release

- [ ] Confirm the broker run passed, including its protected sign job.
- [ ] Confirm the correlated smoke-test run passed and its job summary records
      the installed version, Gatekeeper/notarization checks, and transcription.
- [ ] Confirm the release is public and has exactly the five asset names above.
- [ ] Confirm all five public asset bytes match the broker download.

Release notes come only from `CHANGELOG.md`. Never write replacement notes by
hand, never upload locally built files, and never attest either OpenWritr DMG.

## Local diagnostic build

Local tools are for development checks only:

```sh
scripts/build-app.sh
scripts/make_dmg.sh
```

They use a signing identity already present in the local keychain and never
configure, export, upload, or notarize with Apple credentials. Their output is
not a release candidate and must not be uploaded to GitHub Releases.
