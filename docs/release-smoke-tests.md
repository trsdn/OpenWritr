# Release smoke tests

Criterion `R05`: the **published** artifact is installed as a consumer receives it
and its core function is exercised. This repository does it automatically, so no
maintainer has to.

## How

[`smoke-test.yml`](../.github/workflows/smoke-test.yml) runs after every release
(called from `release.yml`) and on demand for any tag (`Actions → Release smoke
test → Run workflow`). It:

1. downloads the DMG and its checksum from the GitHub release and verifies the checksum;
2. installs the app to `/Applications`;
3. checks the signature, Gatekeeper assessment, and notarization ticket;
4. synthesizes a spoken phrase, runs the installed app with `--self-test`, and
   requires `hello world smoke test` in the transcript. `--self-test` loads the
   shipped speech model and transcribes the file through the same code path as a
   recording, without a microphone (`Sources/OpenWritr/SelfTest.swift`).

The dated record is the job summary of each run: version, asset, macOS, what was
exercised, the transcript, and the result. Find it under the workflow run for the
release tag.

## What it does not cover

The hotkey, microphone capture, and pasting need a person at a logged-in desktop
and cannot run on a hosted runner. They are the parts the unit tests and the
per-change manual check in the pull request template are for.

## Status

Releases up to 1.6.4 predate `--self-test`, so the workflow correctly fails for
them. The first release built from this version is the first one it can pass.
Until that run exists, `R05` is recorded as `Partial`.
