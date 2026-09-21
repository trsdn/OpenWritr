---
name: Apple HIG visual review
description: Generates deterministic macOS UI screenshots and submits one read-only HIG review on relevant pull requests
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
    paths:
      - "Sources/OpenWritr/**/*View.swift"
      - "Sources/OpenWritr/OpenWritrApp.swift"
      - "Sources/OpenWritr/OverlayPanel.swift"
      - "Sources/OpenWritr/UISnapshotRenderer.swift"
      - "Sources/OpenWritr/WarningColor.swift"
      - "Tests/OpenWritrTests/UISnapshotPlanTests.swift"
      - "Resources/AppIcon.icns"
      - "Info.plist"
      - ".github/instructions/apple-hig-review.instructions.md"
      - ".github/agents/apple-hig-reviewer.agent.md"
      - ".github/workflows/apple-hig-visual-review.md"
      - ".github/workflows/apple-hig-visual-review.lock.yml"
permissions:
  contents: read
  pull-requests: read
  copilot-requests: none
checkout:
  fetch-depth: 0
engine:
  id: copilot
  agent: apple-hig-reviewer
network: {}
tools:
  cli-proxy: false
  bash:
    - cat
    - file
    - find
    - git diff
    - git status
    - ls
    - shasum
    - wc
safe-outputs:
  submit-pull-request-review:
    max: 1
    allowed-events: [COMMENT]
jobs:
  snapshots:
    name: Render UI snapshots
    runs-on: macos-latest
    timeout-minutes: 15
    permissions:
      contents: read
    steps:
      - name: Checkout
        # actions/checkout v7
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1

      - name: Build snapshot renderer
        run: swift build -c release -Xswiftc -warnings-as-errors

      - name: Generate and validate snapshots
        run: |
          set -euo pipefail
          snapshots="$RUNNER_TEMP/ui-snapshots"
          .build/release/OpenWritr --render-ui-snapshots "$snapshots"

          count="$(find "$snapshots" -type f -name '*.png' | wc -l | tr -d ' ')"
          if [ "$count" -ne 16 ]; then
            echo "::error::Expected 16 UI snapshots, found $count."
            exit 1
          fi
          while IFS= read -r snapshot; do
            test -s "$snapshot"
            file "$snapshot" | grep -q 'PNG image data'
          done < <(find "$snapshots" -type f -name '*.png' | sort)

      - name: Upload deterministic UI snapshots
        # actions/upload-artifact v7
        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a
        with:
          name: openwritr-ui-snapshots-${{ github.event.pull_request.number }}
          path: ${{ runner.temp }}/ui-snapshots
          if-no-files-found: error
          retention-days: 14

  agent:
    needs: snapshots
    timeout-minutes: 25
steps:
  - name: Download UI snapshot evidence
    # actions/download-artifact v8
    uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c
    with:
      name: openwritr-ui-snapshots-${{ github.event.pull_request.number }}
      path: /tmp/gh-aw/agent/ui-snapshots

  - name: Validate and prepare review evidence
    env:
      BASE_SHA: ${{ github.event.pull_request.base.sha }}
      HEAD_SHA: ${{ github.event.pull_request.head.sha }}
    run: |
      set -euo pipefail
      evidence=/tmp/gh-aw/agent
      snapshots="$evidence/ui-snapshots"

      count="$(find "$snapshots" -type f -name '*.png' | wc -l | tr -d ' ')"
      if [ "$count" -ne 16 ]; then
        echo "::error::Expected 16 UI snapshots, found $count."
        exit 1
      fi
      while IFS= read -r snapshot; do
        test -s "$snapshot"
        file "$snapshot" | grep -q 'PNG image data'
      done < <(find "$snapshots" -type f -name '*.png' | sort)

      git diff --no-ext-diff "$BASE_SHA" "$HEAD_SHA" -- \
        Sources/OpenWritr \
        Tests/OpenWritrTests/UISnapshotPlanTests.swift \
        Resources/AppIcon.icns \
        Info.plist \
        .github/instructions/apple-hig-review.instructions.md \
        .github/agents/apple-hig-reviewer.agent.md \
        > "$evidence/pr-ui-diff.patch"
      cp .github/instructions/apple-hig-review.instructions.md "$evidence/"
      cp .github/agents/apple-hig-reviewer.agent.md "$evidence/"
---

# Review the rendered macOS UI

Review pull request #${{ github.event.pull_request.number }} without editing any
file.

The deterministic evidence is already prepared:

- `/tmp/gh-aw/agent/ui-snapshots/` contains the production Settings, About, and
  overlay surfaces in light and dark appearances, plus larger accessibility-text
  Settings and About variants.
- `/tmp/gh-aw/agent/pr-ui-diff.patch` contains the relevant pull-request diff.
- `/tmp/gh-aw/agent/apple-hig-review.instructions.md` contains the repository's
  HIG criteria.
- `/tmp/gh-aw/agent/apple-hig-reviewer.agent.md` contains the custom reviewer
  contract.

Inspect every PNG and compare corresponding light/dark images and the
larger-text variants. Correlate any visible issue with the diff and surrounding
source. Report only high-confidence, actionable defects introduced or exposed
by this pull request. Do not report subjective polish, do not infer unrendered
behavior from screenshots, and do not duplicate existing review comments.

Submit exactly one pull-request review with event `COMMENT`:

- If findings exist, use a concise list. Each item must include severity,
  repository-relative location, visible or concrete impact, and a specific
  correction.
- If no qualifying findings exist, state that no high-confidence actionable HIG
  defects were found and list the rendered surfaces and variants reviewed.

Do not edit code, create commits, push branches, create issues, or emit any other
safe output.
