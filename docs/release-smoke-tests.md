# Release smoke tests

Criterion `R05`: the release artifact is installed as a consumer receives it
and its core function is exercised. This repository does it automatically, so no
maintainer has to.

## How

[`smoke-test.yml`](../.github/workflows/smoke-test.yml) runs in every release
(called from `release.yml`) against the verified workflow artifact that was
attached to the **draft** release, before it is made public. It also runs on
demand for any published tag (`Actions → Release smoke test → Run workflow`). It:

1. downloads the DMG and checksum from the current workflow artifact during a
   release run, or from a published GitHub release during an on-demand run, and
   verifies the checksum;
2. installs the app to `/Applications`;
3. checks the signature, Gatekeeper assessment, and notarization ticket;
4. synthesizes a spoken phrase, runs the installed app with `--self-test`, and
   requires `hello world smoke test` in the transcript. `--self-test` loads the
   shipped speech model and transcribes the file through the same code path as a
   recording, without a microphone (`Sources/OpenWritr/SelfTest.swift`).

After it passes, `release.yml`'s `publish` job makes the draft public and
downloads the DMG through its public URL to verify it against its checksum. If the
smoke test fails, the release stays a draft, so nobody, including the in-app
updater, is offered a build that could not be installed and run.

The smoke-test job has only `contents: read`. It never needs permission to
create, edit, upload to, or publish a GitHub release.

The dated record is the job summary of each run: version, asset, macOS, what was
exercised, the transcript, and the result. Find it under the workflow run for the
release tag.

## What it does not cover

The hotkey, microphone capture, and pasting need a person at a logged-in desktop
and cannot run on a hosted runner. They are the parts the unit tests and the
per-change manual check in the pull request template are for.

## Status

The first run was for `v1.6.5` (run 35534329100), which published first and tested
afterwards. The draft-then-publish order applies from the next release; until a
release has gone through it, that order is untested.
