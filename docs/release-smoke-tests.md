# Release smoke tests

A record that a **published** artifact was installed as a consumer receives it
and its core function worked (standard criterion `R05`). Add an entry after each
release that changes how the app is built, signed, or packaged, and after any
release you have reason to doubt.

Test the downloaded release asset, not a local build:

1. Download the DMG from the GitHub release and verify its checksum.
2. Install it to `/Applications` and launch it.
3. Grant Microphone and Accessibility permission when asked.
4. Hold the hotkey, dictate a sentence, release, and confirm it is pasted into a text field.
5. Note the result below.

| Date | Version | Asset tested | macOS | Exercised | Result |
|---|---|---|---|---|---|

No entries yet: the releases up to 1.6.4 were tried by hand, but that was not
recorded, so it does not count.
