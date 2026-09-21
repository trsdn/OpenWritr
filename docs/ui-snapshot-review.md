# Automated UI snapshots and HIG review

OpenWritr has an internal renderer for deterministic visual-review evidence:

```sh
swift build -c release
.build/release/OpenWritr --render-ui-snapshots .artifacts/ui-snapshots
```

The command runs on the main actor and captures production SwiftUI/AppKit views
through an offscreen `NSWindow` and `NSHostingView`. It uses fixed logical sizes
and a 2x scale, freezes the overlay animation phase, creates the output directory
when needed, and exits with an error when its argument is missing or a PNG cannot
be produced. It does not run app setup, open the microphone, request Accessibility
permission, read or write Keychain values, make network calls, or persist
`UserDefaults` changes.

The 16 PNGs cover:

- Settings, including Recording, Enhancement, App, and Updates, in light and
  dark appearances
- About in light and dark appearances
- Listening, transcribing, enhancing, done, and error overlays in light and dark
  appearances
- Additional larger-text Settings and About variants

The menu-bar popover and interactive confirmation dialogs are intentionally not
captured. They require a live status item or user-driven modal presentation, and
an offscreen mock would be misleading rather than faithful.

## Pull request automation

`.github/workflows/apple-hig-visual-review.md` is the editable GitHub Agentic
Workflow source. `gh aw compile apple-hig-visual-review` generates the committed
`.lock.yml`; do not edit the lock file directly.

For pull requests that change UI, snapshot, HIG instruction, reviewer, icon, or
bundle metadata files, the workflow:

1. Builds the release executable with Swift warnings treated as errors.
2. Generates and validates all 16 non-empty PNGs.
3. Makes the screenshots and relevant diff available to the read-only
   `apple-hig-reviewer` agent.
4. Uploads the PNG set as a 14-day Actions artifact.
5. Publishes exactly one `COMMENT` review containing only high-confidence,
   actionable findings, or a clear no-findings result.

The workflow has read-only access during agent execution. The separate safe
output handler receives only the pull-request permission needed to submit the
review. The agent cannot edit files or push changes. Fork pull requests are
skipped by the framework's default security policy.

## One-time maintainer setup

GitHub Agentic Workflows are preview functionality and may change. Because this
is a personal public repository, Copilot inference needs a fine-grained personal
access token:

1. Create a fine-grained token owned by the maintainer's personal account.
2. Limit repository access to `trsdn/OpenWritr`.
3. Grant the account permission **Copilot Requests: Read** and no additional
   repository permissions beyond the minimum GitHub requires.
4. Add it under **Settings → Secrets and variables → Actions** as the repository
   secret `COPILOT_GITHUB_TOKEN`.

Never place the token in the repository or workflow text. If the secret is
absent, expired, or invalid, the workflow fails closed with an authentication
error before an agent review is published; it does not emit a success-shaped
placeholder review.
