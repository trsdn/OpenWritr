# Release smoke tests

Criterion `R05`: the release artifact is installed as a consumer receives it
and its core function is exercised before publication.

## How

The explicitly authorized maintainer first downloads a verified notarized
artifact with the public broker's canonical command:

```sh
scripts/request.sh openwritr vX.Y.Z /path/to/OpenWritr/.artifacts/broker-release
```

OpenWritr's `scripts/publish_broker_release.sh` uses the supplied provenance
only to locate the broker run. It verifies the fixed broker
repository/workflow/actor, successful run commit and attempt, redownloads the
artifact by immutable artifact ID, checks GitHub's artifact SHA-256, and then
validates the source/profile/signing provenance and file digests. It refuses to
run if any release or draft already exists for the tag, then creates a new
single-use draft with the exact five public assets and dispatches
[`smoke-test.yml`](../.github/workflows/smoke-test.yml). The workflow has only
`contents: read`; it can download the authenticated draft but cannot edit or
publish it.

The workflow:

1. downloads the versioned DMG and checksum from the draft release and verifies
   the checksum;
2. installs the app to `/Applications`;
3. checks the signature, Gatekeeper assessment, and notarization ticket; and
4. synthesizes a spoken phrase, runs the installed app with `--self-test`, and
   requires `hello world smoke test` in the transcript. `--self-test` loads the
   shipped speech model and transcribes the file through the same code path as a
   recording, without a microphone (`Sources/OpenWritr/SelfTest.swift`).

The maintainer-side handoff downloads and byte-compares all five draft assets
before the smoke test, waits for the correlated workflow run, then re-resolves
the immutable tag and redownloads all five assets before publication. After
publishing, it checks the exact five-name contract and compares all five public
assets again. A failure before publication leaves the single-use draft in
place; the maintainer deletes that unpublished draft before a fresh retry.

This preserves smoke-before-publication without giving OpenWritr a source-side
token that can access broker secrets. Broker signing remains a separate,
manually authorized operation in `trsdn/macos-notarization-broker`.

The dated record is the smoke-test job summary: version, asset, macOS, what was
exercised, transcript, and result.

## What it does not cover

The hotkey, microphone capture, and pasting need a person at a logged-in desktop
and cannot run on a hosted runner. They are covered by unit tests and the
per-change manual check in the pull request template.

The broker may attest OpenWritr's ZIP, but it must never attest either DMG. The
AppUpdater alias is byte-identical to the primary DMG, so both names share one
digest; an attestation for either would violate the updater safety rule from
issue #31.
