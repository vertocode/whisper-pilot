# PRD: Performance Safety Valve & Anti-Freeze Limits

## Problem Statement

When I run Whisper Pilot during a long meeting, my whole Mac degrades. About 20 minutes into a 1-hour call my webcam starts freezing, the machine becomes sluggish, and the experience gets worse the longer the meeting runs and the larger the transcript grows. A tool that's supposed to help me in a meeting is instead starving the rest of my computer of resources. I would much rather the app pause or stop itself with a clear alert than let it freeze my Mac. Today there is no limit at all — nothing watches what the app is consuming, and nothing stops it before the machine is in trouble.

## Solution

Whisper Pilot watches its own resource usage while a session is listening and never lets itself take the whole machine down. It does three things:

1. **Costs less to begin with.** The audio pipeline stops flooding the main thread, the transcript redraws far less often, question-detection stops running on every speech fragment, and the always-on wake-word listener (which I don't use) is removed entirely.
2. **Has a safety valve.** A graduated response trips before the Mac freezes: first a soft pause that sheds cheap, non-core load (Tier-1), then a full stop of listening if load doesn't recover or the Mac gets thermally stressed (Tier-2). Both surface a clear, actionable alert. Core transcription keeps running through Tier-1 — it's the product — but I'm offered a one-click way to shed my own mic recognizer, which is the second-heaviest cost.
3. **Is visible and tunable.** The Diagnostics panel shows live CPU / memory / thermal numbers, and Settings exposes the thresholds and the key toggles so I (or any user) can adjust the behavior to my machine.

The result: transcription and manual AI chat keep working smoothly through a full meeting, and in the worst case the app pauses or stops itself with an alert instead of freezing my computer.

## User Stories

1. As a meeting participant, I want the app to keep my webcam and the rest of my Mac responsive during a long call, so that the tool helps me instead of disrupting the meeting.
2. As a user in a 1-hour meeting, I want the app to stay performant past the 20-minute mark, so that performance doesn't degrade as the transcript grows.
3. As a user, I want the app to never freeze my whole computer, so that I can trust running it during important meetings.
4. As a user, I want the app to pause itself with an alert when it's about to overload my machine, so that I stay in control instead of being surprised by a frozen Mac.
5. As a user, I want a soft pause that stops only the non-essential work first, so that my live transcription keeps running whenever it's safe.
6. As a user, when the app pauses under load, I want to see exactly what it paused and why, so that I understand what happened.
7. As a user, I want a one-click option to disable my own-mic transcription for the current session when it's the biggest cost, so that I can shed load without losing the transcription of what others are saying.
8. As a user, I want the app to fully stop listening (with an alert) if load stays dangerously high after the soft pause, so that there's a hard guarantee my Mac recovers.
9. As a user, I want the app to react when my Mac is thermally stressed, so that it backs off before the system throttles and the webcam stalls.
10. As a user, I want live CPU / memory / thermal readouts in the Diagnostics panel, so that I can see resource pressure building before it trips a limit.
11. As a user, I want to configure the resource thresholds in Settings, so that I can tune them to my specific Mac.
12. As a user, I want to turn the safety valve on or off in Settings, so that I can opt out if I prefer the old always-on behavior.
13. As a user who rarely needs my own voice transcribed, I want a Settings toggle to keep my mic recognizer off by default, so that I avoid its cost without thinking about it each session.
14. As a user, I want the wake-word command feature removed, so that the app stops paying the cost of always scanning my mic for a feature I don't use.
15. As a user, I want the live transcript to still feel responsive after the optimizations, so that lowering the redraw rate doesn't make it feel laggy.
16. As a user relying on auto question-detection, I want it to still fire on questions, so that debouncing it for performance doesn't make it miss real questions — just answer a fraction of a second later.
17. As a user, I want manual AI chat, Summary, Help AI, and Action Items to keep working through and after a safety-valve event, so that explicit actions are never blocked by the valve.
18. As a user, after a Tier-1 pause, I want to resume the paused AI work easily once load recovers, so that I get auto-features back without restarting the session.
19. As a user, I want the resource monitor to run only while a session is listening, so that an idle app isn't polling and wasting battery.
20. As a user, I want safety-valve alerts to appear inline like the app's other warnings, so that they're consistent with the existing Diagnostics/notes I already understand.
21. As a user, I want the app to remember my "always transcribe my mic" and threshold preferences across launches, so that I set them once.
22. As a developer, I want the resource-decision logic to be a pure, testable module, so that I can verify Tier-1/Tier-2 transitions without launching the app.
23. As a developer, I want the audio pipeline to stop spawning a main-actor task per frame, so that the main thread isn't flooded during capture.
24. As a developer, I want the wake-word and voice-command code and their tests removed cleanly, so that no dead heavyweight path remains.
25. As a user, I want my transcript and session data preserved through a Tier-1 pause, so that protecting my Mac never costs me meeting content.

## Implementation Decisions

### Root cause framing
- The freeze is **CPU/thermal starvation, not a memory leak.** Existing buffers are already bounded (`TranscriptBuffer` cap 150 segments, overlay messages cap 24, `ConversationContext` 300s retention). The plan targets sustained CPU and main-thread saturation, with memory as a secondary guard.

### Modules built / modified
- **New: `ResourceGovernor` (pure decision module).** Stateless-ish actor/struct that, given a sample, returns a decision. It owns the Tier-1/Tier-2 state machine (including the "still high N seconds after pausing" escalation timer) but performs no I/O and no sampling itself. Decision came from the seam design:

  ```
  Sample = (cpuPercent: Double, memBytes: UInt64, thermal: ThermalLevel, since: SecondsSinceTier1?)
  Decision = .ok | .tier1Pause | .tier2Stop
  // Tier-1: cpuPercent > 70 sustained ≥20s  OR  memBytes > ~1.5GB
  // Tier-2: thermal >= .serious             OR  (tier1 active AND load still high ≥15s)
  ```
  (Shape only — encodes the trip rules; not a working impl.)

- **New: `ResourceSampler` (injectable).** Reads own-process CPU (`task_info`/thread sampling) and resident memory, plus `ProcessInfo.processInfo.thermalState`. Injected into the governor's driver so tests feed synthetic samples. Polls on a low-frequency timer (~1–2 Hz) and only while `isRunning`.
- **Modified: `AppCoordinator`.** Owns the sampler→governor wiring; starts it in `startListening`, tears it down in `stopListening`. Maps decisions to actions: Tier-1 = set `isAIPaused`, cancel `inFlightCompletions`, post the inline alert with the "Disable my mic for this session" action; Tier-2 = call the existing full `stopListening` path + post alert. Reuses the existing `ChatMessageAction` inline-button mechanism (add a `disableMicForSession` case) rather than inventing new UI plumbing.
- **Modified: `startPipeline` mixer-output consumer.** Eliminate the per-frame `Task { @MainActor }` calls. Accumulate frame/channel counters locally and flush to `OverlayState` on a throttle (~2 Hz). Replace the per-frame `MainActor.run` mute check with mute flags cached in a `nonisolated`/atomic holder updated when the toggle changes.
- **Modified: transcript UI publish.** Raise the republish interval from ~100 ms (10 Hz) to ~250–300 ms (~3–4 Hz). Final updates still publish promptly.
- **Modified: question-detection feed.** Stop calling `engine.consider` on every partial hypothesis. Debounce to ~0.5 s of new speech plus always on finalized segments. Applies per-channel.
- **Removed: wake-word + voice commands entirely.** Delete `WakeWordEngine`, `VoiceCommandInterpreter`, `VoiceCommandExecutor` (verify no other dependents first), the `wakeWordEnabled` / `wakeWord` settings keys + their Settings UI, and the wake-word branch in the pipeline consumer.
- **Modified: `SettingsStore` + Settings UI.** Add: `safetyValveEnabled` (default on), Tier-1 CPU% / memory thresholds, and `alwaysTranscribeMic` style toggle for keeping the mic recognizer off by default. Remove wake-word keys. Mic-disable for a session is in-memory only (mutes/stops the mic channel for the running session); the persistent preference is the Settings toggle.
- **Modified: Diagnostics panel.** Add a live readout of CPU% / resident memory / thermal state, sourced from the same `ResourceSampler` snapshot.

### Behavioral contracts
- The valve and monitor are active **only while a session is listening**.
- **Tier-1 never stops core transcription** (system or mic). It pauses AI auto-detection, cancels in-flight AI calls, and offers — not forces — mic shedding.
- **Explicit user AI actions** (composer prompt, Help AI, Summary, Action Items, answer-screen) remain honored regardless of valve state, consistent with today's "honored even when AI is paused" behavior.
- **Tier-2** routes through the existing `stopListening` teardown so capture, recognizers, and consumer tasks are released exactly as a manual Stop would.
- Alerts are posted as inline system notes via the existing `appendSystemNote` path (categories `.general` / `.transcript`), matching the existing watchdog warnings.

## Testing Decisions

- **What makes a good test here:** assert external behavior of the decision module — given a sequence of samples, the governor emits the correct decisions and tier transitions (including the escalation timer and recovery back to `.ok`). Do not assert internal timer mechanics or private state; drive it through the public sample→decision interface with injected, synthetic samples and a controllable clock.
- **Module under test:** `ResourceGovernor` via the smoke runner (`Tools/SmokeTests/SmokeTestRunner.swift`), added as a new `runResourceGovernorSuite()` alongside the existing suites.
- **Cases to cover:** below-threshold stays `.ok`; CPU over threshold but not yet sustained stays `.ok`; sustained CPU → `.tier1Pause`; memory over cap → `.tier1Pause`; thermal `.serious` → `.tier2Stop`; load still high 15s after Tier-1 → `.tier2Stop`; load recovering after Tier-1 → back to `.ok`.
- **Prior art:** `runTriggerEngineSuite` and `runQuestionDetectorSuite` — both feed synthetic `TranscriptSegment`s through a pure engine and assert emitted decisions. The governor suite mirrors that: feed synthetic samples, assert emitted decisions. `runConversationContextSuite` is prior art for time/retention-style assertions.
- **Cleanup:** remove `runWakeWordEngineSuite` and `runVoiceCommandInterpreterSuite` (and helpers unique to them) when the wake-word code is deleted, so the runner stays green.
- The internal perf changes (per-frame batching, throttles, debounce) are covered by existing pipeline behavior and are validated by the pre-push smoke runner continuing to pass; they introduce no new seam.

## Out of Scope

- Per-feature CPU attribution (precisely measuring how much CPU each individual feature uses). The Tier-1 alert offers the mic as the known second-heaviest contributor based on architecture, not a live per-feature measurement.
- Replacing the dual on-device recognizers with a single recognizer or a different transcription engine. The two-recognizer design stays; the valve and mic-shedding mitigate its cost.
- An always-on overlay HUD for resource usage (explicitly rejected in favor of the Diagnostics readout, to avoid adding permanent redraw cost).
- Quitting the whole app under load (rejected in favor of Tier-2 full-stop-listening, which keeps the app and session window alive).
- Changes to on-disk persistence, prompt construction, or AI provider behavior beyond cancelling in-flight calls during Tier-1.
- GPU usage monitoring.

## Further Notes

- Default thresholds (tunable in Settings): Tier-1 = own-process CPU > ~70% sustained ~20s, or resident memory > ~1.5 GB; Tier-2 = `thermalState >= .serious`/`.critical`, or load still high ~15s after Tier-1. These are starting points expected to be tuned on real hardware.
- The "Balanced" perf cadence was chosen over "Aggressive" and "Conservative": transcript ~3–4 Hz, question-detect debounced ~0.5 s + finals, accepting ~0.5 s added auto-answer latency for a large CPU reduction.
- Sequencing suggestion (not a hard contract): land wake-word removal + the per-frame batching first (fastest measurable win on the main-thread saturation that most likely caused the webcam freeze), then the throttles, then the governor + monitor + Settings.
- Core features preserved end-to-end: system transcription, mic transcription, manual AI chat, and auto question-detection (when enabled in Settings).
