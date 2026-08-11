---
goal: Stop idle microphone access and make CoreAudio device failures recoverable
version: 1.3
date_created: 2026-08-11
last_updated: 2026-08-11
owner: OpenWritr maintainers
status: 'Planned'
tags: [refactor, audio, reliability, privacy, macos]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

Refactor OpenWritr's audio lifecycle so the microphone input stream runs only during push-to-talk capture, CoreAudio device changes cannot trigger overlapping engine rebuilds, and microphone failures produce an explicit retry path instead of background restart loops.

## 1. Requirements & Constraints

- **REQ-001**: OpenWritr must not start `AVAudioEngine` or install an input tap during application initialization or while the application is in the `.ready` state.
- **REQ-002**: OpenWritr must start the input engine and install the tap only after a valid push-to-talk start event is accepted.
- **REQ-003**: OpenWritr must stop the input engine and remove the tap after the post-key-release drain window completes and captured samples are copied out.
- **REQ-004**: Audio-device and engine-configuration notifications must never execute overlapping or recursively triggered engine rebuilds.
- **REQ-005**: A stale or disconnected selected device must be cleared before the next engine start, and the current macOS default input must be resolved again.
- **REQ-006**: A normal key release must preserve the drained sample buffer. A confirmed device failure, engine failure, shutdown, or capture-generation mismatch must discard the partial sample buffer, stop microphone access, and transition to the applicable error or shutdown state.
- **REQ-007**: A microphone runtime error must provide a dedicated retry action that revalidates device availability without leaving an input stream active.
- **REQ-008**: Normal transcription, enhanced transcription, custom input selection, system-default restoration, application shutdown, and subsequent recordings must continue to work.
- **REQ-009**: An `AVAudioEngineConfigurationChange` notification must not be treated as a capture failure until the active device is confirmed unavailable or one bounded recovery attempt for the current capture generation fails.
- **REQ-010**: Every asynchronous capture operation, delayed configuration callback, hotkey release, stop request, and failure callback must carry or compare the capture generation that was current when the operation was scheduled.
- **REQ-011**: Hotkey release during asynchronous microphone startup must be retained and applied to the same capture request after startup completes; it must not be dropped because the application has not entered `.listening` yet.
- **REQ-012**: The original macOS system default input must be captured at most once for a custom-device selection and retained across repeated captures until the user deselects the custom device or the application shuts down.
- **REQ-013**: A startup failure before `CaptureHandle` is returned must be reported only through `startCapture()`'s result. `onFailure` must report only failures detected after a handle has been returned.
- **REQ-014**: No queued or in-flight capture-start operation may construct or start an engine after shutdown begins; every async continuation must resume exactly once on success, failure, cancellation, or shutdown rejection.
- **SEC-001**: No microphone audio buffer may be retained outside an accepted capture generation; idle input access must be observable as inactive in the macOS privacy indicator.
- **CON-001**: Preserve the existing `AppState` enum-driven UI flow and callback wiring through `AppViewModel`.
- **CON-002**: Preserve the existing 70 ms idle drain window and 350 ms maximum drain timeout unless measured validation demonstrates data loss.
- **CON-003**: Do not add a new dependency, test framework, or audio abstraction package.
- **CON-004**: Continue using the system-default-device switching mechanism required for Bluetooth and AirPods input selection.
- **GUD-001**: Return typed `AudioEngineError` failures from lifecycle operations; do not silently ignore invalid device IDs or engine-start failures.
- **GUD-002**: Keep CoreAudio listener callbacks lightweight. Execute all `AVAudioEngine`, tap, observer, selected-device, and lifecycle-state mutations on one private serial `DispatchQueue`; the realtime tap callback may only access capture-buffer fields protected by `bufferLock`.
- **PAT-001**: Represent engine ownership with an internal lifecycle enum instead of independent `isRunning` and `tapInstalled` decisions.
- **PAT-002**: Represent each accepted recording with an immutable `CaptureHandle` containing a monotonically increasing generation and require that handle for drain, stop, recovery, and failure operations.
- **PAT-003**: Add a typed `RuntimeErrorKind` discriminator with `.audio`, `.transcription`, and `.enhancement` cases; UI actions must branch on this type instead of matching strings or inferring only from transcript availability.

## 2. Implementation Steps

### Implementation Phase 1

- GOAL-001: Make microphone input strictly capture-scoped.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-001 | In `Sources/OpenWritr/AudioEngine.swift`, add an internal `AudioEngineLifecycleState` enum with `.idle`, `.starting`, `.capturing`, `.recovering`, `.stopping`, and `.failed(AudioEngineError)` states. Add a private serial `DispatchQueue` and require every lifecycle transition and every `AVAudioEngine` mutation to execute on that queue. Retain `isRunning` and `tapInstalled` only as low-level cleanup facts. | | |
| TASK-002 | Refactor `AudioEngine.prepare()` so it installs device-list listeners, validates the selected or default input device, and restores stale selection state without calling `resetEngine()`, `installTapAndStart()`, `engine.prepare()`, or `engine.start()`. Successful completion must leave the lifecycle state `.idle` and the microphone privacy indicator inactive. | | |
| TASK-003 | Add immutable `CaptureHandle: Sendable` with a monotonically increasing `generation` and add `AudioEngineError.captureCancelled` for shutdown or caller-cancellation rejection that must not be presented as a microphone fault. Replace `restartForCapture()` plus the separate void `startCapture()` call with `startCapture() async -> Result<CaptureHandle, AudioEngineError>`, implemented by dispatching lifecycle work to the private serial queue and resuming one continuation exactly once on every path. Check lifecycle-owned `isShuttingDown` before allocating a generation and again immediately before `engine.start()`; if true, perform no engine work or clean up work already created and return `.captureCancelled` without invoking `onFailure`. Before each engine construction, revalidate an available `selectedDeviceID` and re-assert it as the macOS system default. Re-assertion must preserve an existing non-nil `previousSystemDefault`; it may capture the current default only when `previousSystemDefault` is nil. If selection is stale, restore `previousSystemDefault` when it remains available, then clear both `selectedDeviceID` and `previousSystemDefault`; if the previous device is unavailable, clear both without attempting restoration. Resolve the resulting current default before continuing. Create a fresh engine, install one tap, set the buffer-retention generation active immediately before `engine.start()`, and return the handle only after startup succeeds. A startup failure must invalidate and clean up the generation exactly once and return the typed error without invoking `onFailure`. | | |
| TASK-004 | Replace unscoped drain and stop calls with async `waitForCaptureToSettle(handle:idleWindow:maxWait:pollInterval:)` and async `stopCapture(handle:)`, retaining the existing 10 ms default poll interval. The settle loop must compare `handle.generation` and `_isCapturing` during every poll and return immediately on mismatch or inactive capture. `stopCapture(handle:)` must enqueue cleanup on the lifecycle queue and resume one continuation exactly once. A matching normal stop must atomically mark the generation inactive, copy and clear samples, cancel that generation's pending configuration work, transition through `.stopping`, stop the engine, remove the tap and configuration observer, and return the samples in `.idle`. It must not restore `previousSystemDefault`; restoration remains deselection- and shutdown-scoped. A missing or stale handle must return no samples and must not stop a newer capture. | | |
| TASK-005 | In `Sources/OpenWritr/OpenWritrApp.swift`, add `.preparingMicrophone` to `AppState`, an operation ID for the pending start, its eventual `CaptureHandle`, and a `releaseRequested` flag scoped to that operation. Update `startListening(triggerMode:)` to enter `.preparingMicrophone` and asynchronously await `audioEngine.startCapture()`. On completion, handle failure first: clear the matching pending operation, ignore `releaseRequested` because no handle exists, and present one `.audio` runtime error from the returned error unless shutdown or cancellation already made the operation irrelevant. On success, revalidate the pending operation ID, handle generation, `isOperational`, `didShutdown == false`, and `state == .preparingMicrophone` before changing UI state. Store the handle. If `releaseRequested` is already true, execute the normal drain-and-stop path without first entering `.listening`, showing the listening overlay, or playing the start sound. Otherwise enter `.listening`, show the overlay, and play the start sound. A stale success must asynchronously stop its own handle without affecting current UI state or a newer capture. | | |
| TASK-006 | Update `startProcessingStoppedRecording(triggerMode:)` and `stopListeningAndTranscribe(triggerMode:)` so a release in `.preparingMicrophone` sets `releaseRequested` for the matching operation. After every `await`, revalidate the operation ID, `CaptureHandle.generation`, `AppState`, `isOperational`, and cancellation status before calling `stopCapture(handle:)` or assigning `.transcribing`. Core ML transcription must begin only after the matching engine has stopped. | | |

### Implementation Phase 2

- GOAL-002: Serialize device changes and eliminate recursive CoreAudio rebuilds.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-007 | In `Sources/OpenWritr/AudioEngine.swift`, remove automatic `resetEngine()` execution from the engine-scoped `.AVAudioEngineConfigurationChange` observer. The observer exists only while a capture engine exists and must enqueue a configuration event containing the current `CaptureHandle.generation`; it must not perform lifecycle work inside the notification callback. Idle device changes remain exclusively owned by the persistent CoreAudio device-list listener. | | |
| TASK-008 | Add one replaceable 250 ms `DispatchWorkItem` per capture generation on the lifecycle queue. The 250 ms interval is the explicit coalescing window for observed CoreAudio notification bursts. The work item must capture the generation when scheduled and execute only if the same generation remains active and lifecycle state remains `.capturing` or `.recovering`. Continuous bursts intentionally defer the decision until notifications are quiet or the capture stops. `stopCapture(handle:)`, failure cleanup, and `shutdown()` must cancel the item. | | |
| TASK-009 | Implement the engine-configuration handler on the lifecycle queue. Add `recoveryAttemptedGeneration: UInt64?`, set it before the first recovery attempt, and reset it only when a new generation starts or the engine returns to `.idle`. First verify the captured generation is still current. If the active device is unavailable, fail the generation once, discard partial samples, stop the engine, and invoke `onFailure` once after cleanup. If the device is available and the engine is still running, record the benign notification and continue capture. If the device is available but the engine stopped and recovery has not been attempted for this generation, perform one recovery restart without clearing its existing sample buffer or changing its handle. A second restart requirement or failed recovery must fail the generation once and invoke `onFailure` once. | | |
| TASK-010 | Keep idle and global device-change handling in `handleDeviceListChanged()` only. Enqueue it onto the lifecycle queue, validate `selectedDeviceID`, `previousSystemDefault`, and the current system default, clear unavailable IDs, and restore a valid previous default when possible. While capturing, do not mutate the engine directly; schedule the generation-scoped configuration decision from TASK-009. While idle, update selection state and notify `onDevicesChanged` without constructing or starting an engine. | | |
| TASK-011 | Replace `resetEngine()` with two explicitly scoped helpers: one fresh-engine constructor callable only from `.starting`, and one bounded same-generation recovery helper callable only from `.recovering`. Neither helper may recursively invoke itself or schedule another recovery attempt. | | |
| TASK-012 | In `AudioEngine.shutdown()`, use a dispatch-specific key to detect lifecycle-queue execution. Run cleanup inline when already on that queue; otherwise use synchronous `lifecycleQueue.sync` because `AppViewModel.shutdown()` and `AudioEngine.deinit` cannot await. Set lifecycle-owned `isShuttingDown = true` before any cleanup so queued start operations reject themselves under TASK-003. The lifecycle queue must never call `DispatchQueue.main.sync`, await a `MainActor` task, or wait for an `AppViewModel` callback. Cleanup must contain no retry or sleep loop: cancel pending configuration items, invalidate the current generation, discard samples, stop the engine, remove observers and listeners, and restore the capture-once `previousSystemDefault` exactly once. Shutdown is terminal, so `isShuttingDown` is never reset. Late callbacks must compare their captured generation or shutdown state and become no-ops. | | |

### Implementation Phase 3

- GOAL-003: Provide deterministic error presentation and microphone recovery.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-013 | In `Sources/OpenWritr/OpenWritrApp.swift`, add `RuntimeErrorKind` with `.audio`, `.transcription`, and `.enhancement` cases and store it in `AppErrorPresentation`. Update every error-construction call site to assign the correct kind so UI actions never depend on message text or only on `recoverableRawTranscription`. | | |
| TASK-014 | Replace the current `AppViewModel.handleAudioFailure(_:)` behavior that routes failures through initialization handling. Reserve this callback path for failures detected after `startCapture()` returned a handle; startup errors are owned exclusively by TASK-005. For the matching active handle, mark its operation failed, cancel or invalidate `activeProcessingTask`, asynchronously stop that generation once, discard partial samples, dismiss the overlay with an audio runtime error, and transition to `.runtimeError(kind: .audio)`. A resumed drain or start task must observe the invalid operation ID or generation and must not overwrite `.runtimeError` with `.listening` or `.transcribing`. Do not initiate automatic background retries. | | |
| TASK-015 | Add `AppViewModel.retryMicrophone()` that refreshes input devices, clears unavailable saved selection, invokes the non-streaming `audioEngine.prepare()` validation, and returns to `.ready` only on success. Failure must replace the current runtime error with the new typed `AudioEngineError`. | | |
| TASK-016 | In `Sources/OpenWritr/MenuBarView.swift`, show `Retry Microphone` only for `.audio`, the existing enhancement recovery actions only for `.enhancement`, and no provider action for `.transcription`. Replace unconditional audio-error dismissal: dismissing `.audio` must run the same non-streaming validation as `retryMicrophone()` and may enter `.ready` only on success; otherwise it remains in `.runtimeError`. | | |
| TASK-017 | In `Sources/OpenWritr/SettingsView.swift`, keep the input-device status text synchronized with disconnected, fallback-to-system-default, retry-required, and ready states. Selecting a device while an error is visible must validate the selection without starting microphone capture. | | |
| TASK-018 | Add concise `Logger` events in `AudioEngine` and `AppViewModel` for lifecycle transitions, capture generation invalidation, debounced device changes, stale device removal, retry success, and retry failure. Invoke `onFailure`, `onDevicesChanged`, and other callbacks without blocking the lifecycle queue; existing closures must continue to hop asynchronously to `@MainActor`. Do not log audio samples or transcript content. | | |

### Implementation Phase 4

- GOAL-004: Validate privacy behavior, device reliability, and regression safety.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-019 | Run `swift build -c release` and resolve all compile and Swift concurrency errors introduced by the lifecycle refactor. | | |
| TASK-020 | Launch the built application and verify the macOS microphone privacy indicator is inactive while OpenWritr is `.ready`, Settings is open, transcription is running, enhancement is running, and the application is otherwise idle. Verify it activates only between accepted push-to-talk start and the end of the drain window. | | |
| TASK-021 | Execute ten consecutive normal recordings and ten consecutive enhanced recordings. Verify each recording starts one engine, stops one engine, returns to `.ready`, and produces no overlapping-tap or already-running-engine errors in unified logging. | | |
| TASK-022 | Test system default input, a selected built-in input, and a Bluetooth/AirPods input. During active and idle states, disconnect and reconnect each removable device and change the macOS default input. Verify one error is presented per active failure and no restart loop occurs. | | |
| TASK-023 | Verify `Retry Microphone` while the device remains unavailable keeps the app in `.runtimeError`; reconnecting the device and retrying returns to `.ready` without activating the privacy indicator. | | |
| TASK-024 | Quit OpenWritr while idle, recording, transcribing, enhancing, and displaying a microphone error. Verify the process exits, restores any previous system default input, and leaves no microphone indicator or surviving audio process. | | |
| TASK-025 | Measure hotkey-down-to-first-buffer latency for ten built-in-input captures and ten Bluetooth captures. Record median and p95 values in the implementation pull request. Verify the `.preparingMicrophone` state keeps the UI responsive and the start sound occurs only after capture becomes active. | | |
| TASK-026 | Execute ten rapid press-and-release recordings where release occurs before or during microphone startup. Verify every release is applied to its matching operation, no task remains stuck in `.preparingMicrophone` or `.listening`, and no newer capture is stopped by an older release. | | |
| TASK-027 | Trigger benign format or route-settling configuration notifications while the selected device remains available. Verify capture continues, at most one bounded recovery occurs for the generation, and no user-facing error appears unless recovery fails. | | |
| TASK-028 | Trigger a device failure during the drain await and during engine startup. Verify `.runtimeError(kind: .audio)` is not overwritten by resumed startup, drain, stop, transcription, or completion code and partial samples are discarded. | | |
| TASK-029 | Add debug-build-only fault injection in `AudioEngine` for startup failure, delayed startup completion, post-handle device failure, failure during settle polling, and a configuration change where the engine is stopped but the device remains available. The release build must compile these hooks out. Use the hooks to execute TASK-026 through TASK-028 and both the first and prohibited second recovery attempts deterministically instead of relying only on physical device timing. | | |
| TASK-030 | With a custom input selected, perform at least five captures while changing no settings. Verify `previousSystemDefault` retains the original device across all captures, `stopCapture(handle:)` does not restore it, and deselection plus shutdown each restore the original default exactly once. | | |
| TASK-031 | Inject one startup failure and one post-handle recovery failure. Verify the startup failure is presented once from the returned result without an `onFailure` callback, and the post-handle failure is presented once through `onFailure` without a competing result path. | | |
| TASK-032 | Delay a queued startup operation, invoke application shutdown before its lifecycle work executes, and then release the delay. Verify the continuation resumes once with shutdown/cancellation failure, no engine or tap is created after shutdown, and the microphone privacy indicator remains inactive. | | |
| TASK-033 | Simulate a selected device disappearing immediately before capture startup. Verify a still-available original default is restored and both selection fields are cleared; repeat with the original default also unavailable and verify both fields are cleared without an invalid restoration attempt. | | |

## 3. Alternatives

- **ALT-001**: Keep `AVAudioEngine` running continuously and only gate sample retention with `_isCapturing`. Rejected because macOS correctly reports continuous microphone use and the idle engine remains exposed to device-change failures.
- **ALT-002**: Automatically rebuild the engine after every configuration notification. Rejected because CoreAudio emits bursts of notifications with stale device IDs, making recursive or overlapping rebuilds likely.
- **ALT-003**: Remove custom input selection and always use the system default. Rejected because reliable Bluetooth and AirPods selection is an existing product requirement.
- **ALT-004**: Retry engine startup indefinitely in the background. Rejected because it hides failure state, can create restart loops, and keeps touching the microphone without a user action.

## 4. Dependencies

- **DEP-001**: macOS `AVFoundation.AVAudioEngine` for input capture and configuration-change notifications.
- **DEP-002**: macOS CoreAudio APIs for enumerating devices and temporarily changing the system default input.
- **DEP-003**: Existing `ObjCExceptionCatcher` wrappers for Objective-C audio APIs that can raise exceptions.
- **DEP-004**: Existing `AppViewModel`, `AppState`, `MenuBarView`, and `SettingsView` state and presentation flow.

## 5. Files

- **FILE-001**: `Sources/OpenWritr/AudioEngine.swift` — capture-scoped engine lifecycle, serialized configuration handling, device validation, shutdown, and logging.
- **FILE-002**: `Sources/OpenWritr/OpenWritrApp.swift` — capture start/stop integration, typed audio error handling, and retry behavior.
- **FILE-003**: `Sources/OpenWritr/MenuBarView.swift` — dedicated microphone retry action and readiness presentation.
- **FILE-004**: `Sources/OpenWritr/SettingsView.swift` — input-device recovery status and validation behavior.

## 6. Testing

- **TEST-001**: Release compile check using `swift build -c release`.
- **TEST-002**: Privacy-indicator lifecycle test covering idle, capture, transcription, enhancement, Settings, and runtime-error states.
- **TEST-003**: Repeated-recording test covering normal and enhanced capture without engine/tap lifecycle errors.
- **TEST-004**: Device-change matrix covering built-in, system-default, Bluetooth, disconnect, reconnect, and default-device changes.
- **TEST-005**: Retry-state test covering unavailable device, successful reconnect, and absence of automatic retries.
- **TEST-006**: Shutdown matrix covering every operational and error state with system-default restoration.
- **TEST-007**: Unified-log review confirming no repeated `AVAudioEngineConfigurationChange` rebuild loop, stale-device access, or overlapping lifecycle transitions.
- **TEST-008**: Cold-start latency and UI-responsiveness measurement for built-in and Bluetooth inputs.
- **TEST-009**: Rapid hotkey press/release test covering release during `.preparingMicrophone` and stale operation IDs.
- **TEST-010**: Benign configuration-change test proving a valid device does not automatically produce a runtime error.
- **TEST-011**: Main-actor reentrancy test covering failure during startup and the post-release drain await.
- **TEST-012**: Repeated custom-device capture test proving capture-once preservation and exact restoration of `previousSystemDefault`.
- **TEST-013**: Failure-channel ownership test proving startup and post-handle failures each produce exactly one presentation.
- **TEST-014**: Debug fault-injection build check proving all injection hooks are absent from the release build.
- **TEST-015**: Shutdown-versus-queued-start test proving terminal shutdown rejects late engine creation and resumes the continuation exactly once.
- **TEST-016**: Stale-selection restoration test covering available and unavailable original system defaults.

## 7. Risks & Assumptions

- **RISK-001**: Starting `AVAudioEngine` on demand may add measurable latency between hotkey press and capture readiness; `.preparingMicrophone`, the delayed start sound, and latency measurements make this delay explicit, but speech before the start sound cannot be captured.
- **RISK-002**: Bluetooth device startup may take substantially longer than built-in microphone startup; release-before-start handling must remain correct for the entire asynchronous startup duration.
- **RISK-003**: Stopping immediately after the drain window may lose delayed Bluetooth frames if the existing 350 ms maximum is insufficient.
- **RISK-004**: CoreAudio can continue emitting callbacks after device removal; every deferred callback must validate lifecycle generation and device existence.
- **RISK-005**: Restoring a previous system default that disappeared can fail; the app must clear the saved ID and surface the failure without retrying recursively.
- **RISK-006**: A benign configuration change may stop the engine even though the device remains available; the single same-generation recovery attempt may introduce a short audio gap that must be disclosed in logs and bounded to one attempt.
- **RISK-007**: Synchronous shutdown briefly blocks its caller while the lifecycle queue stops CoreAudio; the queue's prohibition on main-actor waits and retry loops is required to keep this bounded and deadlock-free.
- **ASSUMPTION-001**: FluidAudio transcription does not require `AVAudioEngine` to remain active after the sample array has been captured.
- **ASSUMPTION-002**: macOS removes the microphone privacy indicator after the input engine is stopped and its tap is removed.
- **ASSUMPTION-003**: Existing device enumeration and system-default switching remain the required mechanism for Bluetooth input support.

## 8. Related Specifications / Further Reading

[OpenWritr repository](https://github.com/trsdn/OpenWritr)

[Apple AVAudioEngine documentation](https://developer.apple.com/documentation/avfaudio/avaudioengine)

[Apple Core Audio documentation](https://developer.apple.com/documentation/coreaudio)
