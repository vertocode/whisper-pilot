# Plan: Performance Safety Valve & Anti-Freeze Limits

> Source PRD: `prd/performance-safety-valve.md`

## Architectural decisions

Durable decisions that apply across all phases:

- **Test seam**: pure-logic suites in the smoke runner (`Tools/SmokeTests/SmokeTestRunner.swift`), no Xcode. New `runResourceGovernorSuite()` mirrors `runTriggerEngineSuite` / `runQuestionDetectorSuite` (feed synthetic inputs → assert emitted decisions).
- **`ResourceGovernor`**: pure decision module. Input = sample `(cpuPercent, memBytes, thermal, secondsSinceTier1?)`; output = `.ok | .tier1Pause | .tier2Stop`. Owns the tier state machine + escalation timer. No I/O, no sampling.
- **`ResourceSampler`**: injectable. Reads own-process CPU (`task_info`), resident memory, and `ProcessInfo.processInfo.thermalState`. Injected so tests feed synthetic samples. Polls ~1–2 Hz, only while listening.
- **Wiring**: `AppCoordinator` owns sampler→governor; starts in `startListening`, tears down in `stopListening`. Maps decisions to actions.
- **Alerts**: reuse existing `OverlayState.appendSystemNote` (inline system notes) + `ChatMessageAction` inline-button mechanism. New action case for mic-shed.
- **Tier defaults** (tunable later): Tier-1 = CPU > ~70% sustained ~20s OR mem > ~1.5GB. Tier-2 = thermal >= `.serious`/`.critical` OR load still high ~15s after Tier-1.
- **Invariants**: monitor/valve active only while listening; Tier-1 never stops core transcription; explicit user AI actions always honored; Tier-2 routes through existing `stopListening` teardown.

---

## Phase 1: Remove wake-word + voice commands

**User stories**: 14, 24

### What to build

Delete the always-on wake-word listener and voice-command path end-to-end: the engine + interpreter + executor modules (after verifying no other dependents), the `wakeWordEnabled` / `wakeWord` settings keys and their Settings UI, the wake-word branch in the pipeline consumer, and the two corresponding smoke-test suites.

### Acceptance criteria

- [ ] No wake-word / voice-command code, settings keys, or Settings UI remain; grep for `WakeWord` / `VoiceCommand` is clean.
- [ ] Pipeline consumer no longer scans mic partials for a wake word.
- [ ] `runWakeWordEngineSuite` and `runVoiceCommandInterpreterSuite` removed; smoke runner builds and passes.
- [ ] App builds via xcodegen + Xcode and launches with no wake-word affordances.

---

## Phase 2: Performance baseline (pipeline + render)

**User stories**: 1, 2, 3, 15, 16, 23

### What to build

Cut the standing CPU cost of the live pipeline without changing any feature. Stop the mixer-output consumer from spawning a main-actor task per audio frame — accumulate counters locally and flush to `OverlayState` on a ~2 Hz throttle. Replace the per-frame `MainActor.run` mute check with mute flags cached off the main actor (updated when the toggle changes). Raise transcript republish from ~100 ms (10 Hz) to ~250–300 ms (~3–4 Hz), still publishing finals promptly. Debounce question-detection to ~0.5 s of new speech + always on finalized segments, per channel.

### Acceptance criteria

- [ ] No `Task { @MainActor }` or `MainActor.run` per audio frame in the pipeline consumer.
- [ ] Frame/channel counters still update (visibly, at ~2 Hz) and watchdogs still fire correctly.
- [ ] Live transcript still feels responsive; finals appear promptly.
- [ ] Auto question-detection still fires on questions (≤~0.5 s later); no longer runs on every partial.
- [ ] Measurable CPU drop during a sustained listening session vs. before; smoke runner passes.

---

## Phase 3: `ResourceGovernor` pure module + smoke suite

**User stories**: 22

### What to build

The decision seam, fully tested, with no app wiring yet. Implement `ResourceGovernor` as a pure module driven by a controllable clock and synthetic samples, plus `runResourceGovernorSuite()` in the smoke runner.

### Acceptance criteria

- [ ] Below-threshold samples → `.ok`.
- [ ] CPU over threshold but not yet sustained → `.ok`; sustained → `.tier1Pause`.
- [ ] Memory over cap → `.tier1Pause`.
- [ ] Thermal `.serious` → `.tier2Stop`.
- [ ] Load still high 15s after Tier-1 → `.tier2Stop`; load recovering after Tier-1 → back to `.ok`.
- [ ] Suite added to runner; all assertions pass.

---

## Phase 4: Tracer valve — Tier-1 soft pause (hardcoded thresholds)

**User stories**: 4, 5, 6, 7, 17, 19

### What to build

First end-to-end valve slice. Wire `ResourceSampler` + `ResourceGovernor` into `AppCoordinator` (start in `startListening`, stop in `stopListening`, poll only while listening). On `.tier1Pause`: set `isAIPaused`, cancel in-flight AI completions, keep transcription running, and post an inline alert explaining what was paused — with a "Disable my mic for this session" inline button (new `ChatMessageAction` case) that mutes/stops the mic channel for the running session. Thresholds hardcoded to the defaults for now. Explicit user AI actions remain honored.

### Acceptance criteria

- [ ] Forcing high CPU/mem trips Tier-1: AI auto-detect pauses, in-flight calls cancel, transcription keeps running.
- [ ] Inline alert appears (existing system-note style) stating what was paused and why.
- [ ] "Disable my mic for this session" button sheds the mic recognizer for the current session only.
- [ ] Composer / Help AI / Summary / Action Items still work during Tier-1.
- [ ] Sampler/governor run only while listening; idle app does not poll.

---

## Phase 5: Tier-2 full-stop, thermal escalation, recovery & resume

**User stories**: 8, 9, 18, 25

### What to build

Complete the graduated response. On `.tier2Stop` (thermal `.serious`/`.critical`, or load still high ~15s after Tier-1), route through the existing `stopListening` teardown and post a clear alert. When load recovers after Tier-1, return to `.ok` and re-enable the auto features (resume) without restarting the session. Session transcript/data preserved across both tiers.

### Acceptance criteria

- [ ] Sustained-high-after-Tier-1 → full stop listening via the normal teardown path, with alert.
- [ ] Thermal `.serious`/`.critical` → Tier-2 stop with alert.
- [ ] Recovery after Tier-1 (load drops) re-enables auto-detection without a session restart.
- [ ] Transcript and session content intact through Tier-1 and Tier-2.
- [ ] CPU drops to near-idle after Tier-2.

---

## Phase 6: Diagnostics readout + Settings + persistence

**User stories**: 10, 11, 12, 13, 20, 21

### What to build

Make the system visible and tunable. Add a live CPU / memory / thermal readout to the Diagnostics panel sourced from the sampler snapshot. Add Settings: `safetyValveEnabled` (default on), Tier-1 CPU% / memory thresholds (replacing the hardcoded values from Phase 4), and an "always transcribe my mic" toggle controlling whether the mic recognizer runs by default. Persist all preferences across launches.

### Acceptance criteria

- [ ] Diagnostics shows live CPU / memory / thermal, updating while listening.
- [ ] Governor reads thresholds from Settings; changing them changes when the valve trips.
- [ ] Safety valve can be turned off in Settings (reverts to no-limit behavior).
- [ ] "Always transcribe my mic" toggle controls default mic-recognizer behavior.
- [ ] All preferences survive relaunch; alerts remain consistent with existing inline warnings.
