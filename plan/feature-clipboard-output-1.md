---
goal: Resolve empty-startup clipboard preservation and add clipboard-only recording
version: 1.0
date_created: 2026-10-08
last_updated: 2026-10-09
owner: trsdn
status: In progress
tags: [feature, bug, clipboard, shortcuts]
---

# Introduction

![Status: In progress](https://img.shields.io/badge/status-In_progress-yellow)

Resolve [#122](https://github.com/trsdn/OpenWritr/issues/122) before implementing [#121](https://github.com/trsdn/OpenWritr/issues/121) on the same clipboard transaction code. Implement and validate the two issues separately, then close each only with recorded evidence. The user approved implementation on 2026-10-08; issue closure still requires the verification gates below.

Current code accepts an empty snapshot in `PasteManager.snapshot(of:)` and clears the pasteboard when restoring zero items. The startup report has not been reproduced and its root cause is unknown. Do not claim that a nil `pasteboardItems` value or zero items alone explains the failure.

The actual `HotkeyChoice` cases are Fn, Right Option, and Right Command. The reference to Right Shift in the original issue's acceptance criteria is incorrect. The user approved Left Option + Right Option as the clipboard-only combination when Right Option is the primary key.

### Execution evidence (2026-10-08)

- Isolated AppKit reproduction: `declareTypes([.string], owner: nil)` produces one plain-text item with nil data. The previous snapshot guard rejects this empty placeholder. The implementation treats only a sole unwritten plain-text representation as empty; unreadable non-text or mixed representations still fail explicitly. This is a reproduced failure class, not proof of the fresh-login root cause.
- Implemented clipboard-only routing, independent Option/Shift latching, Left Option + Right Option handling, enhancement retry/raw-recovery destination retention, copied/listening feedback, error/warning presentation, and documentation.
- Immediate clipboard failures use a typed error contract. Delayed restoration failures appear as a dismissible menu warning rather than interrupting unrelated recordings.
- SwiftPM dependency resolution initially encountered Git's `safe.bareRepository=explicit` setting. A process-scoped override allowed the project's FluidAudio checkout to resolve; no global Git configuration or dependency constraint was changed.
- The release build passed. The bundle script's automatic identity selection returned two fingerprints and failed to sign; rerunning with one explicit available signing identity produced a verified signed app at `.build/release/OpenWritr.app`. The unrelated identity-selection script was not modified.
- Final focused suite: `swift test --filter 'PasteManagerTests|HotkeyManagerTests'` passed 25 tests (9 shortcut, 16 clipboard), with zero failures. Tests cover preservation, empty placeholders, output routing with Auto-Paste on/off, transaction races, write/rollback/restore failures, and modifier latches.
- Pending: actual shortcut/dictation/enhancement-recovery UX checks and a fresh-login empty-clipboard reproduction. No system clipboard was changed during automated verification. Neither issue is closed.

## 1. Requirements & Constraints

- **REQ-001**: With Auto-Paste enabled, an initially empty clipboard permits transcript insertion and is restored to empty after the existing 0.5-second delay.
- **REQ-002**: Preserve all original items and readable representations on automatic paste. A newer clipboard change must never be overwritten by restoration.
- **REQ-003**: Option + Fn and Option + Right Command select clipboard-only output. Left Option + Right Option selects clipboard-only when Right Option is the primary key. Right Option alone retains its current behavior.
- **REQ-004**: Latch the qualifying Option modifier if present at recording start or at any point during the primary-key hold. Releasing Option does not revert the destination. Reset the latch on release and listener stop.
- **REQ-005**: Track enhancement and output destination independently. Preserve Shift activation, Always Enhance inversion, and disabled-enhancement behavior.
- **REQ-006**: Clipboard-only output replaces existing clipboard contents only when non-empty final output is ready. It sends no Cmd+V, schedules no restoration of its successful write, and works with Auto-Paste disabled.
- **REQ-007**: Cancellation, silence, empty transcription, and transcription/enhancement failure do not write to the clipboard. Explicit enhancement retry and raw-transcript recovery retain the original destination.
- **REQ-008**: Show "Clipboard" while listening in clipboard-only mode and "Copied" after successful copying. Retain a separate enhancement indication and accessible descriptions. Preserve existing non-clipboard overlay behavior.
- **REQ-009**: Pending automatic-paste restoration cannot overwrite a subsequent clipboard-only result. Preserve transaction identity and pasteboard change-count guards.
- **REQ-010**: Surface genuine clipboard failures through typed errors, existing logging, and the runtime-error UI. Never show a success overlay after a failed output write.
- **SEC-001**: Diagnostics include stage, item/representation counts, type identifiers, and change counts only; never log clipboard bytes or transcript text. Automated tests use isolated named pasteboards, not the user's general clipboard.
- **CON-001**: Keep macOS 14 support, Swift 6 concurrency safety, and the current dependency constraints. No dependency upgrades, unrelated audio work, or changes to existing preferences.
- **CON-002**: Preserve unrelated worktree content, including the untracked `docs/mockup.gif`.
- **CON-003**: Do not use a fixed sleep or unconditional clipboard clear as a speculative startup workaround. A failed cold-start reproduction leaves #122 open.
- **PAT-001**: Use Sendable enum/struct state, MainActor clipboard access, existing operation/generation guards, weak callback captures, and repository-standard `AppErrorPresentation` handling.

## 2. Implementation Steps

### Implementation Phase 1

- **GOAL-001**: Diagnose and fix #122; demonstrate empty and non-empty preservation without disturbing newer clipboard content.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-001 | In `Sources/OpenWritr/PasteManager.swift`, add privacy-safe snapshot/restore diagnostics and reproduce empty clipboard variants. Reproduced rejection of an unwritten `.string` placeholder on an isolated pasteboard. Actual fresh-login root cause remains unverified; keep #122 open until user-approved startup verification. | Partial: startup blocked | 2026-10-08 |
| TASK-002 | Add the XCTest target in `Package.swift` and isolated-pasteboard regression tests in `Tests/OpenWritrTests/PasteManagerTests.swift`. Inject paste-event and write closures with unchanged production defaults. Cover empty states, binary/multiple representations, overlapping transactions, external clipboard changes, and failure rollback. Depends on the isolated reproduction in TASK-001. | Yes | 2026-10-08 |
| TASK-003 | In `PasteManager`, accept the reproduced empty plain-text placeholder and add typed snapshot/write/restore errors. Retain the delay and transaction/change-count guards. In `OpenWritrApp.swift` and `MenuBarView.swift`, surface immediate output failures as runtime errors and late restoration failures as dismissible warnings without interrupting unrelated recordings. Keep failed output transcripts in app state. Depends on TASK-001 and TASK-002. | Yes | 2026-10-08 |
| TASK-004 | Run focused tests and the release compile. Verify empty restoration, non-text fidelity, and protection of newer writes. Automated checks passed; repeat the actual startup reproduction with the corrected build before completing this task. Depends on TASK-003. | Partial: startup blocked | 2026-10-08 |

### Implementation Phase 2

- **GOAL-002**: Implement the approved clipboard-only shortcut end-to-end without changing primary-hotkey output or enhancement behavior.

This phase depends on TASK-003 for the clipboard error/transaction contract. If actual startup verification is unavailable, feature development may proceed after TASK-003, but #122 remains open.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-005 | In `HotkeyManager.swift`, introduce Sendable/Equatable `RecordingOutputDestination` and `RecordingShortcut`, with the latter carried by actions/callbacks. Independently latch Option/Shift in `processFlagsChanged`: aggregate Option for Fn/Right Command, left-device Option specifically for Right Option. Reset on primary release/listener stop. Add internal state-processing coverage in `Tests/OpenWritrTests/HotkeyManagerTests.swift`. Depends on TASK-003. | Yes | 2026-10-08 |
| TASK-006 | In `PasteManager.swift`, add `copyText(_:)` and shared `outputText(_:destination:autoPasteEnabled:)` with typed errors. Settle pending restores, guard ownership, and roll back failed writes. A successful copy sends no paste event and schedules no restoration. Add persistent-copy, failure, and transaction-overlap tests. Depends on TASK-003. | Yes | 2026-10-08 |
| TASK-007 | In `OpenWritrApp.swift`, carry destination alongside `captureTriggerMode` through start/update/stop, microphone preparation, processing, and completion. Keep destination alongside enhancement recovery text before capture cleanup; pass it through `retryEnhancement` and `useRawTranscription`. Reset capture/recovery destination at matching lifecycle cleanup points. Route all output through `PasteManager.outputText`, and prevent failure from falling through to success UI. Preserve operation-ID/generation guards. Depends on TASK-005 and TASK-006. | Yes | 2026-10-08 |
| TASK-008 | In `OverlayPanel.swift`, show "Clipboard" while listening and `.copied` completion with enhancement color/accessibility feedback and the existing 600 ms interval. Update every enum switch. In `MenuBarView.swift`, use destination-aware raw-recovery labels and output-error actions. Update shortcut help in `SettingsView.swift`, `README.md`, and `docs/index.html`, including Left Option + Right Option. Depends on TASK-007. | Yes | 2026-10-08 |

### Implementation Phase 3

- **GOAL-003**: Verify exact feature outcomes, recovery paths, and clipboard preservation with the integrated build.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-009 | Run `swift test --filter 'PasteManagerTests|HotkeyManagerTests'` and `swift build -c release`. Verify TEST-001 through TEST-004 and fix tightly coupled failures. Passed 25 tests with no failures; release compile passed as part of the bundle build. Depends on TASK-008. | Yes | 2026-10-08 |
| TASK-010 | Build/sign via `bash scripts/build-app.sh` with one explicit available identity; completed successfully. Run interactive TEST-005 through TEST-008 using synthetic dictation and user-approved clipboard contents. Actual dictation/hardware/recovery/startup UX checks remain pending; no system clipboard was changed by automated tests. Depends on TASK-009. | Partial: interactive checks pending | 2026-10-08 |

### Implementation Phase 4

- **GOAL-004**: Persist implementation evidence and close each issue only when its own acceptance criteria are satisfied.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-011 | For #122, post a GitHub comment identifying the reproduced cause, fix reference, startup reproduction result, and preservation/race test results. Correctly distinguish empty-clipboard tests from actual startup validation. Close with `gh issue close 122 --reason completed` only if TASK-004 and the relevant integrated regression checks passed. Otherwise leave open and document the remaining blocker. Depends on TASK-004 and TASK-010. | No | Not started |
| TASK-012 | For #121, post a GitHub comment correcting the Right Shift reference to the actual Fn/Right Option/Right Command choices, documenting approved Left Option + Right Option behavior, linking the implementation reference, and recording all shortcut, enhancement, Auto-Paste, failure, and pending-restore results. Close with `gh issue close 121 --reason completed` only after its automated and interactive checks pass. Update this plan's task dates/status to actual results; use Completed only when both issues satisfy their closure gates. Depends on TASK-010. | No | Not started |

## 3. Alternatives

- **ALT-001**: A separate configurable shortcut was rejected in favor of Option + the existing push-to-talk key.
- **ALT-002**: Checking only aggregate Option flags was rejected because Right Option alone would become clipboard-only when it is the primary key.
- **ALT-003**: Using Control with Right Option was rejected by the user in favor of Left Option + Right Option.
- **ALT-004**: Reusing Auto-Paste disabled as clipboard-only was rejected because current disabled behavior retains output inside the app without copying.
- **ALT-005**: Clearing the clipboard unconditionally on delayed restore was rejected because it can erase newer user/application content.

## 4. Dependencies

- **DEP-001**: AppKit/NSPasteboard, CoreGraphics/CGEvent, and IOKit device-specific modifier masks already available in the project; no new external package is required.
- **DEP-002**: A macOS interactive session with Microphone and Accessibility permission is required for actual shortcut, paste-event, and startup verification.
- **DEP-003**: Existing FluidAudio models and one working enhancement provider are required for end-to-end transcription/enhancement checks.
- **DEP-004**: XCTest and SwiftPM provide regression coverage; production code receives only minimal test seams for pasteboard/event isolation and shortcut-state input.
- **DEP-005**: A configured local signing identity is required by the current bundle script. Missing signing credentials block bundled-app validation, not compile or unit checks.

## 5. Files

- **FILE-001**: `Sources/OpenWritr/PasteManager.swift`: startup diagnosis, preservation fix, explicit error contract, copy-only transaction, and isolated test seams.
- **FILE-002**: `Sources/OpenWritr/HotkeyManager.swift`: independent shortcut destination state, side-specific Option detection, callback payloads, and latch resets.
- **FILE-003**: `Sources/OpenWritr/OpenWritrApp.swift`: recording/recovery destination lifetime, shared output routing, and runtime output failures.
- **FILE-004**: `Sources/OpenWritr/OverlayPanel.swift`: clipboard listening indication, copied completion, exhaustive switches, and accessibility feedback.
- **FILE-005**: `Sources/OpenWritr/SettingsView.swift`: actual hotkey-specific clipboard instructions.
- **FILE-006**: `Sources/OpenWritr/MenuBarView.swift`: exhaustive output-error actions and destination-aware raw-transcript recovery label.
- **FILE-007**: `README.md` and `docs/index.html`: public shortcut, copy-only, and clipboard-preservation documentation.
- **FILE-008**: `Package.swift`, `Tests/OpenWritrTests/PasteManagerTests.swift`, and `Tests/OpenWritrTests/HotkeyManagerTests.swift`: built-in regression test target and focused tests.
- **FILE-009**: `plan/feature-clipboard-output-1.md`: execution status and verification evidence.

## 6. Testing

- **TEST-001**: Automatic paste from an isolated empty pasteboard sends exactly one paste action and restores zero items. Non-empty text/binary and multiple-item snapshots retain identical type/data representations after restoration.
- **TEST-002**: A synthetic external write between transcript insertion and restoration survives unchanged. Sequential automatic pastes restore the intended original snapshot. Stale transaction callbacks cannot restore over a later copy.
- **TEST-003**: Clipboard-only writes send zero paste actions, retain the exact final text after more than 0.5 seconds, and handle preparation/write/rollback failures explicitly. Inject deterministic failures only through a minimal transaction seam; do not use the system clipboard or rely on inducing OS faults.
- **TEST-004**: Feed flags/key-code sequences for every actual hotkey. Assert Option-before-start, Option-during-hold, Option-release-before-primary, Shift/Option independent ordering, listener stop/restart, and no destination leak into the next recording. Right Option alone is standard; Left Option + Right Option is clipboard-only. Holding Left Option after Right Option release must not start a new recording.
- **TEST-005**: For each actual primary hotkey, verify standard/clipboard output with Auto-Paste on/off, enhancement disabled/on-demand/always-on, and Shift absent/present. Clipboard-only writes final normal/enhanced/bypassed text without inserting anything; standard output matches existing Auto-Paste behavior.
- **TEST-006**: Release the hotkey during microphone preparation, add Option during preparation, and test silence, short audio, cancellation, and processing failures. No stale capture writes output and no failed/cancelled recording changes the clipboard.
- **TEST-007**: Force an enhancement failure with synthetic input; clipboard remains untouched until explicit Retry Enhancement or Use Raw Transcript. Both recovery actions retain clipboard-only destination even with Auto-Paste on. Verify recovery label, copied confirmation, retained transcript on output failure, and no false success.
- **TEST-008**: Start the corrected app after fresh login/restart with an empty clipboard and perform actual automatic paste into a disposable document. Confirm inserted text, empty restoration, readable diagnostics, clipboard overlay accessibility, and no behavior regression after subsequent normal copying.

## 7. Risks & Assumptions

- **RISK-001**: The startup report may reflect unreadable advertised representations or startup pasteboard ownership rather than zero items. TASK-001 must establish the cause before modifying empty-state handling.
- **RISK-002**: Aggregate and device-specific modifier flags differ; hardware verification is required, especially with both Option keys held.
- **RISK-003**: Clearing capture state on enhancement failure currently loses per-recording context unless recovery destination is retained separately.
- **RISK-004**: Delayed restore errors can arrive after another operation starts. Error presentation must not invalidate an unrelated capture.
- **RISK-005**: Named-pasteboard unit tests cannot prove startup/system clipboard or real focused-application paste behavior.
- **RISK-006**: The narrow overlay label area can truncate combined text. Use "Clipboard" with enhancement color and explicit accessibility description instead of a long combined title.
- **ASSUMPTION-001**: Clipboard-only intentionally replaces previous clipboard contents after success; it does not offer clipboard history or undo.
- **ASSUMPTION-002**: Existing Auto-Paste disabled behavior remains app-retained output for standard recordings.

## 8. Related Specifications / Further Reading

- Release preparation on 2026-10-09 ports this implementation onto current `origin/main`, retaining AppUpdater, app presence, the existing Swift Testing clipboard/dictation seams, and transient paste errors. The clipboard API uses typed `PasteOutcome` and `PasteManagerError` instead of replacing those seams with throwing methods. Additional dictation tests cover clipboard output, failure handling, enhancement retry, raw recovery, and Shift bypass. The UI snapshot plan includes Clipboard, enhanced Clipboard, and Copied states in both appearances.
- Integrated validation passed: warning-free release compilation, strict SwiftLint with zero violations, 62 Swift Testing tests plus 9 XCTest shortcut tests, and 9 Python release-tooling tests. The signed local app rendered all 22 snapshot variants. Visual inspection caught and corrected truncation in the enhanced Clipboard label; the final normal/enhanced Clipboard labels and Copied feedback are fully visible. Physical shortcuts, actual provider recovery, and fresh-login behavior are not claimed as verified by these checks.
- The user explicitly authorized preparation and merge of a checked PR and subsequent publication as the authenticated maintainer. The current broker-based release checklist replaces the older direct tag-triggered workflow; no local release artifacts or credentials will be uploaded.
- [Clipboard-only shortcut issue #121](https://github.com/trsdn/OpenWritr/issues/121)
- [Empty-startup clipboard bug #122](https://github.com/trsdn/OpenWritr/issues/122)
- [Current clipboard transaction implementation](../Sources/OpenWritr/PasteManager.swift)
- [Current shortcut handling](../Sources/OpenWritr/HotkeyManager.swift)
- [Current enhancement recovery and output lifecycle](../Sources/OpenWritr/OpenWritrApp.swift)
