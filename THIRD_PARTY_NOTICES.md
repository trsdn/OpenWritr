# Third-party notices

OpenWritr is MIT licensed (see [LICENSE](LICENSE)). The released app statically
links the Swift packages below, which are pinned in `Package.resolved`. This file
records what is redistributed and under which licence.

| Component | Version | Licence | Redistributed as |
|---|---|---|---|
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | 0.15.7 | Apache-2.0 | Linked into the app binary |
| [AppUpdater](https://github.com/mxcl/AppUpdater) | 4.1.2 | Unlicense (public domain) | Linked into the app binary, plus its resource bundle in `Contents/Resources/` |
| [Version](https://github.com/mxcl/Version) | 2.2.1 | Apache-2.0 | Linked into the app binary (transitive dependency of AppUpdater) |

Not redistributed: the NVIDIA Parakeet TDT 0.6B v3 model is downloaded by the app
on first launch from its publisher and is not part of the repository or the
release assets. Its licence is the publisher's.

## How the obligations are met

- **Source repository:** the packages are fetched by SwiftPM from their upstream
  repositories and are not vendored, so their licence texts and notices stay with
  the upstream source.
- **Release artifacts:** `scripts/build-app.sh` copies the OpenWritr licence,
  this file, and the licence text of every SwiftPM checkout into
  `OpenWritr.app/Contents/Resources/Licenses/`, so recipients of the binary
  receive the Apache-2.0 and Unlicense texts with it.

Keep this table in step with `Package.resolved` when a dependency is added, removed,
or upgraded.
