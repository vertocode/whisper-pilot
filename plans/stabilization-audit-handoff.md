# Whisper Pilot: stabilization audit and handoff

Written 2026-09-18 by a Claude Code session for a **fresh session with no prior context**.
Read this file top to bottom before touching code. Everything you need to start is here.

## 0. What the owner wants

The owner (Everton, speaks Portuguese; reply to them in Portuguese, write code, comments and UI strings in English) wants **no new features for now**. The goal is to stabilize and improve what already exists so users can **trust** the app. Trust means: it does what it says, it never surprises the user with dialogs or lost data, and its privacy claims are true.

Rules of engagement:

- **Scope: fixes, stability, performance, clearer errors, honest copy.** No new features.
- **Already declined by the owner, do not re-propose:** Ollama provider, Developer ID signing + Sparkle auto-update, rolling live summary, cost dashboard, CI work. (Signing was discussed again only because they asked how to avoid Keychain prompts; they have not chosen it.)
- Be strict. If you find another problem on the way, fix it or add it to section 5.
- Git: conventional commits `type: short description`, single line. **Do not commit or push unless the owner asks.** Never run `jj` (a leftover `.jj` folder may exist; ignore it).
- Code comments: only when the *why* is non-obvious. Plain English. Never put ticket IDs in code.
- Do not run experiments that can raise macOS dialogs (Keychain, TCC) on the owner's Mac without asking first. A previous session did and cost the owner 4 extra password prompts.
- Human-facing text (PR bodies, messages) should be short and conversational, no formal scaffolding.

## 1. Orientation

Whisper Pilot is a macOS 14+ menu-bar (accessory, `LSUIElement`) app. It captures system audio (Core Audio Process Tap, ScreenCaptureKit fallback) and the microphone, transcribes on-device (Parakeet via FluidAudio for English, Apple SpeechAnalyzer/SFSpeech otherwise), shows a floating overlay, and lets the user ask Gemini or Claude about the conversation with their own API key. Sessions are markdown folders under `~/Library/Application Support/<bundle id>/sessions/`.

Read `docs/ARCHITECTURE.md` first (it was updated for onboarding and permissions). Other useful docs: `docs/CONFIGURATION.md`, `docs/SESSIONS.md`, `docs/RELEASE.md`, `plans/performance-safety-valve.md`.

Key files (`Sources/WhisperPilot/`):

| Area | Files |
|---|---|
| Orchestration (god object, ~2,700 lines) | `App/AppCoordinator.swift` |
| App entry, windows, onboarding launch | `App/AppDelegate.swift` (excluded from the SwiftPM target, see below) |
| Permissions | `Permissions/PermissionsManager.swift` |
| Onboarding | `Onboarding/OnboardingView.swift`, `OnboardingEligibility.swift`, `OnboardingWindowController.swift` |
| Settings, secrets | `Settings/SettingsStore.swift`, `KeychainHelper.swift`, `KeychainAccess.swift`, `SettingsView.swift` |
| AI | `AI/GeminiProvider.swift`, `AnthropicProvider.swift`, `PromptBuilder.swift` |
| Audio capture | `Audio/ProcessAudioCapture.swift`, `SystemAudioCapture.swift`, `MicrophoneCapture.swift` |
| Transcription | `Transcription/ParakeetTranscriber.swift`, `SpeechAnalyzerTranscriber.swift`, `AppleSpeechTranscriber.swift` |
| Persistence | `Persistence/SessionStore.swift` (actor) |
| Diagnostics | `Diagnostics/CrashLogger.swift` (writes `runtime.log`) |
| Menu bar | `MenuBar/MenuBarController.swift` |

### Build and test

```bash
swift build                      # library + smoke runner. Does NOT compile App/AppDelegate.swift or WhisperPilotApp.swift
swift run SmokeTests             # custom runner (no XCTest available). Currently 288/288 assertions pass
xcodegen generate                # regenerates WhisperPilot.xcodeproj (gitignored) from Project.yml
xcodebuild -project WhisperPilot.xcodeproj -scheme WhisperPilot -configuration Debug \
  -derivedDataPath /tmp/wp-dd PRODUCT_BUNDLE_IDENTIFIER=com.whisperpilot.app.dev build
```

Always run the `xcodebuild` line after touching `AppDelegate.swift`, because `swift build` does not compile it. Re-run `xcodegen generate` after adding or removing source files. A pre-push hook (`.githooks/pre-push`) runs `swift run SmokeTests`.

### Testing the real app without polluting the installed one

The owner has a released copy in `/Applications/WhisperPilot.app` with the same bundle id `com.whisperpilot.app`. Two apps with one bundle id get mixed up by macOS ("Quit & Reopen" can relaunch the installed one). Build the test copy with the `.dev` bundle id (command above), then:

```bash
pkill WhisperPilot
tccutil reset All com.whisperpilot.app.dev      # only affects the .dev copy
open /tmp/wp-dd/Build/Products/Debug/WhisperPilot.app
ps -axo pid,command | grep '[W]hisperPilot'    # confirm which copy is running
```

Note the Keychain service name is hard-coded (`com.whisperpilot.app`), so both copies share the same stored API keys.

## 2. Repo state you inherit

`git status` shows **17 uncommitted entries** (nothing from this work is committed). Two people's work is mixed in there:

1. A Codex session added a first-run onboarding (`Sources/WhisperPilot/Onboarding/`, edits in `AppDelegate`, `PermissionsManager`, `SettingsStore`, `SmokeTestRunner`, `ARCHITECTURE.md`).
2. A Claude session then reviewed and reworked it. What that session changed:
   - **All macOS permissions are requested in onboarding only** (Microphone, Speech Recognition, system audio, Screen Recording (optional), Keychain). Play, Settings, Sessions and the overlay never open a system dialog. A missing permission shows an overlay banner with an "Open Setup" button, and `Settings → Capture → Permissions & setup…` reopens onboarding.
   - **Keychain:** the two API-key items were merged into one item (`api_keys`, JSON) so macOS asks for approval once per item instead of once per key. Old per-vendor items are migrated on first unlock and **left in place** (not deleted, to avoid another prompt). Reading the secret happens only in `SettingsStore.unlockStoredKeys()` (onboarding or the "Allow Keychain access" button) and at launch only for a build the user already approved (`KeychainHelper.buildIdentity` = code-signature hash, stored in `keychain.approvedBuild`). Everything else reads an in-memory cache.
   - Onboarding rewrite: 5 permission rows each with a reason, "Allow all", "Skip for now", specific error messages, window returns to front after each macOS dialog, resumes at the right step after a relaunch, shows the AI-key step whenever no key exists.
   - Menu bar shows only "Finish setup…", Settings, About, Quit while a required permission is missing.
   - `Info.plist` and `Project.yml` gained `NSAudioCaptureUsageDescription`.
   - Tests: the onboarding eligibility suite now has 15+ assertions.

`swift build`, `swift run SmokeTests` (288/288) and the full `xcodebuild` all pass. **None of the GUI behavior was run by the author of that work** (no display session was driven). See section 4 for the manual QA list. Treat those flows as unverified.

Recommended first action for you: ask the owner whether to commit this work as-is (suggested split: permissions/onboarding, keychain bundle, menu bar) before starting new changes on top, so your fixes are reviewable separately.

## 3. Findings, prioritized

Each item: **what**, **where**, **why it matters**, **suggested fix**, **verification**. Items marked 🔧 need real hardware or a real macOS dialog to verify; do not claim them fixed from a passing build alone.

### P0. Trust, privacy, data loss

**P0-1. The legacy speech path can send audio to Apple's servers, contradicting our privacy claims.** 🔧 — **DONE in code (2026-09-18), not verified on a device**
- Where: `Transcription/AppleSpeechTranscriber.swift:209` sets `request.requiresOnDeviceRecognition = false` (the comment above it says Apple's servers are used when the on-device model is unavailable).
- When it runs: non-English locales on macOS < 26, or English when Parakeet and SpeechAnalyzer both fail (see P0-3).
- Contradicts: `README.md:106` ("Audio never leaves your device"), `NSSpeechRecognitionUsageDescription` in `Project.yml` and `Resources/Info.plist` ("on-device"), and **the onboarding copy** in `OnboardingView.swift` (`reason(of:)` for Microphone and Speech Recognition says audio is processed on this Mac).
- Fix, in order of preference: (a) set `requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition` and, when on-device is not supported for the chosen locale, stop with a clear message ("Your language needs Apple's servers. Whisper Pilot won't send audio unless you allow it") instead of silently using the network; (b) if the owner decides to keep the server fallback, make it opt-in and state it in the README and onboarding. The existing comment warns that forcing `true` when the model is not ready produces silent no-output, so check `supportsOnDeviceRecognition` first and surface the failure.
- Until fixed, soften the onboarding and README wording so it stays true.
- **Done:** took option (a). `ChannelPipe.init` throws `TranscriberError.onDeviceUnavailable` when `supportsOnDeviceRecognition` is false, and every request now sets `requiresOnDeviceRecognition = true`. README and onboarding copy are true again, no wording change needed. 🔧 Still to check on a Mac: a locale with no on-device model (macOS < 26) shows the new error in the overlay instead of transcribing; English still works.

**P0-2. Meeting text is written to `runtime.log`, and the README tells users to share that log.** — **DONE (2026-09-18)**
- Where: `AppleSpeechTranscriber.swift:376,404,538,577`, `ParakeetTranscriber.swift:220,320`, `SpeechAnalyzerTranscriber.swift:392,418` log final/first transcript text (`FINAL: "…"`). `CrashLogger` mirrors every `wpInfo/wpWarn/wpError` line to `~/Library/Application Support/<bundle id>/runtime.log`. `README.md:80` points users at that file and asks for log excerpts in issues; the app also re-shows the last ~20 lines after an unclean shutdown.
- Fix: log segment ids, lengths and timing, never text. If content logging is useful for development, gate it behind an explicit debug setting that is off by default. Also `SessionStore.swift:136` logs the session folder path publicly; the folder name contains the user's session title.
- Verify: run a short session, then `grep -c` the log for words you spoke.
- **Done:** all 8 transcript-text log lines now log the character count only. `SessionStore` logs the session folder path as `.private`. The AI providers already log the question as `.private`, and only `wp*` lines reach `runtime.log`. 🔧 The grep check on a real session is still open.

**P0-3. Silent downgrade from Parakeet to Apple engines.** 🔧 — **DONE in code (2026-09-18), not verified on a device**
- Where: `AppCoordinator.swift:1712` (`Parakeet start failed … falling back`) only writes to the log. Typical cause: first run offline, the ~600 MB model download fails.
- Why: the user gets a different (lower accuracy, and per P0-1 possibly server-based) engine with no notice.
- Fix: post a system note saying which engine is active and why, with the actionable reason ("Couldn't download the speech model: offline. Using Apple's engine for now").
- **Done:** `EngineFallbackNote` (new, pure, 8 assertions) builds the note. `makeStartedTranscriber` posts it only after an Apple engine actually started. 🔧 To check: start a session offline with no cached model and see the note.

**P0-4. Transcript persistence failures are silent.** — **DONE except the free-space check (2026-09-19)**
- Where: `Persistence/SessionStore.swift:481` `appendToFile` catches and only logs; the callers (`AppCoordinator.queueTranscriptPersistence`, `persistPendingTranscriptLine`) never learn about it.
- Why: disk full, permission changes or a removed folder mean the overlay looks healthy while `transcript.md` stops growing. That is silent data loss in the app's core promise.
- Fix: return success/failure, count consecutive failures, and show a persistent banner ("Can't save this transcript: <reason>. Your session is not being saved"). Consider a free-space check before starting a session (`volumeAvailableCapacityForImportantUsage`).
- Verify with a read-only session folder or a tiny disk image.
- **Done:** `SessionStore.appendTranscriptLine/appendChatTurn` now return `Result<Void, Error>`. New pure `SaveHealth` turns the first failure into one persistent overlay banner with a plain reason (disk full, no permission, read-only, folder deleted) and posts a short note when saving recovers. Tests cover the state machine and real failures (read-only file, deleted folder). **Not done:** the free-space check before starting a session (the handoff said "consider"). 🔧 Still to try on a real tiny disk image.

**P0-5. Partial AI answers are lost from `chat.md` on error or cancel.** — **DONE (2026-09-19)**
- Where: `AppCoordinator.runCompletion` (~line 2387). The assistant text is persisted only on the success path; on `CancellationError` or a thrown error the bubble stays in the overlay (with whatever streamed) but nothing reaches `chat.md`.
- Fix: persist the partial text with a marker (for example "(incomplete)") on those paths so resumed sessions match what the user saw.
- **Done:** `runCompletion` saves the visible text on cancel, error and non-clean finish (for example token limit) through `AssistantTurnText`, which appends `(incomplete)` and skips empty replies. 🔧 Not tried against a live API.

### P1. Reliability and error quality

**P1-1. No retry or backoff for transient AI failures.** — **DONE (2026-09-19), only tested against stubs, not the live APIs**
- Where: `GeminiProvider.swift`, `AnthropicProvider.swift` use `URLSession.shared`, one attempt, `timeoutInterval = 60`. Only a Gemini 404 triggers the model-fallback chain (`AppCoordinator.swift:~2550 migrateToFallbackModel`).
- Fix: one bounded retry with jitter for 429/5xx/connection-lost **only before the first delta arrives**; honor `Retry-After`; consider `waitsForConnectivity`. Deduplicate repeated identical error notes when auto-triggered questions fail in a row.
- **Done:** new `AIRetryPolicy` (pure) plus `AIRetryPolicy.withRetry`, used by both providers' `streamCompletion`. One retry, only while no text has reached the user, for 429, any 5xx, Anthropic `overloaded_error`/`api_error` events and dropped or timed-out connections. `Retry-After` in seconds is honored; more than 8 s means no retry. Otherwise it waits 1 s plus up to 0.5 s of jitter. Not retried: 401/403/404/400, no internet, cancellation. `RepeatedNote` skips an identical error note (last 6 messages) only for auto-detected questions. Not done: `waitsForConnectivity`, and the one-shot helpers (`classifyQuestion`, `summarize`) still have no retry. 🔧 Never run against the real APIs.

**P1-2. Error messages recommend a retired model.** — **DONE (2026-09-19)**
- Where: `GeminiProvider.swift:303` suggests `gemini-2.0-flash-lite`, `:309` suggests `gemini-2.0-flash`, while `SettingsView.swift:235` says `gemini-2.0-flash` was retired for new keys. Check the names against `AI/AIModel.swift` (`AIModelRegistry`) and make messages refer to models that actually exist there.
- Also: 400 responses put the raw response body in the message; trim it.
- **Done:** the 429 message no longer names a model, the 404 message suggests only `gemini-2.5-flash`. New `AIErrorBody.summary` (used by both providers for 400 and unknown statuses) prefers `error.message` and cuts anything else at 200 chars. A test checks every `gemini-*` name in Gemini error text exists in `AIModelRegistry`.

**P1-3. Stream decode errors are swallowed.** — **DONE (2026-09-19)**
- Where: `GeminiProvider.stream` (`if let chunk = try? JSONDecoder().decode(...)`), and the same pattern in `AnthropicProvider`. If the API schema shifts, the result is an empty reply that ends "without a finish reason", which downstream reads as a network drop.
- Fix: log the first decode failure per stream (without content) and, when zero deltas were decoded, report "unexpected response format".
- **Done:** both providers log the first decode failure (byte count and error, no content) and throw `unexpectedFormat` when nothing usable arrived. A stray bad chunk among good ones is tolerated. New `Tools/SmokeTests/AIProviderTests.swift` covers Gemini and Anthropic SSE with a stub `URLProtocol` (deltas, finish reasons, `promptBlocked`, mid-stream error event, garbled data). This is the first half of the P3 provider tests; the P1-1 retry tests can reuse `StubURLProtocol`.

**P1-4. No App Nap protection while listening.** 🔧 — **DONE in code (2026-09-19), not verified on a Mac**
- `grep beginActivity` finds nothing. The app is `LSUIElement`, often fully covered by other windows during a call. Timers, watchdogs and network tasks may be throttled in long meetings.
- Fix to evaluate: `ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: …)` between start and stop of listening (avoid `idleSystemSleepDisabled` unless the owner wants it). Verify with a 30-60 minute session in the background.
- **Done:** `ListeningActivity` (`App/ListeningActivity.swift`) begins in `startListening` once the pipeline runs and ends in `stopListening`. It uses `.userInitiatedAllowingIdleSystemSleep`, because plain `.userInitiated` includes `idleSystemSleepDisabled` and would keep the Mac awake. begin/end are idempotent (tested). 🔧 Still to do: a 30-60 minute session with the window covered, checking that transcripts and timers keep up.

**P1-5. No sleep/wake handling.** 🔧 — **DONE in code (2026-09-19), not verified on a Mac**
- No `NSWorkspace.willSleepNotification` / `didWakeNotification` observers. Device-change rebuilds and SCStream restarts exist, but the lid-close/wake path is untested.
- Fix: on wake, if listening, verify frames resume within a few seconds and otherwise restart capture, telling the user. Manually test: start listening, close the lid for a minute, reopen.
- **Done:** `AppCoordinator` observes `NSWorkspace.didWakeNotification`. If a session is running, it waits 5 seconds and, when `audioFrameCount` did not grow (`WakeRecovery.needsRestart`, tested), posts a note and calls `restartListening()` (which keeps the mic mute choice). It only acts if the same session is still running. 🔧 Still to do: start listening, close the lid for a minute, reopen, and check both the "audio kept flowing" and the "restarted" outcomes.

**P1-6. Shortcut registration failure is invisible.** — **DONE in code (2026-09-19), not seen on screen**
- Where: `Shortcuts/GlobalHotKey.swift:57` logs and returns nil. A user who records a combo already used by another app gets a shortcut that silently does nothing.
- Fix: surface the failure inline in Settings → Shortcuts.
- **Done:** `SettingsStore.toggleOverlayShortcutUnavailable` / `answerScreenShortcutUnavailable` (runtime only) are set by `AppDelegate` after each registration; Settings → Shortcuts shows a red line under the row. 🔧 To check: record a combo another app owns (for example ⌘Space).

**P1-7. Launching an already-running app does nothing visible.** — **DONE in code (2026-09-19), not tried**
- No `applicationShouldHandleReopen(_:hasVisibleWindows:)` in `AppDelegate`. For an accessory app, clicking it in Finder/Spotlight, or macOS "Quit & Reopen" landing on a live process, shows nothing, which reads as "the app didn't open".
- Fix: bring Onboarding (if setup is needed) or Sessions to the front.
- **Done:** `applicationShouldHandleReopen` calls `showInitialWindow()` (Onboarding if needed, else Sessions). 🔧 To check: with the app running, open it again from Finder or Spotlight.

**P1-8. No single-instance guard.** — **DONE in code (2026-09-19), not tried**
- Two copies with one bundle id share `UserDefaults`, `runtime.log`, the `clean-shutdown` sentinel and the Keychain item, which produces false "did not shut down cleanly" warnings and confusing state. This already confused the owner while testing.
- Fix: at launch, if another running instance of the same bundle id exists, activate it and quit.
- **Done:** `SingleInstance` (pure, tested) picks the oldest copy as the winner, so two copies started together don't both quit. `AppDelegate.handOverToRunningCopy()` runs first in `applicationDidFinishLaunching`, before the crash logger, so the running copy's clean-shutdown marker is untouched. It asks macOS to open the winner's bundle (which triggers P1-7) and exits. Caveat: `AppCoordinator` is created before that call, so the second copy still builds `SettingsStore` once; it only reads the Keychain for a build the user already approved. 🔧 To check: start a second copy with `open -n`.

**P1-9. Permission status is partly a guess.** 🔧 — **PARTLY DONE (2026-09-19)**
- `PermissionsManager.requestSystemAudio` (line 141) opens a Process Tap for 2 seconds and then records "granted" regardless of what the user clicked, because macOS has no API to read the system-audio permission. The onboarding row shows a "System Settings" hint for that reason.
- Screen Recording (line 165): after the user enables it, macOS asks to quit and reopen; the resume logic (`OnboardingEligibility.startPoint`) exists but was never run end to end.
- Suggested hardening (not a new feature): at the end of onboarding, or on the first Play, validate that frames with non-zero level actually arrive (the diagnostics "System Audio Test" in `AppCoordinator.runSystemAudioTest` already does the measurement) and, if silent, tell the user exactly which permission to check.
- **Done:** the start-of-session watchdogs already report "no frames after 6 s" and "frames are silent" (and switch to ScreenCaptureKit); both messages now also name System Settings → Privacy & Security → Screen & System Audio Recording, the setting that most often explains silent system audio. **Not done, on purpose:** a new post-onboarding measurement step. It would open the audio tap again (a new dialog risk) and is new behavior. The Screen Recording quit-and-reopen path (`OnboardingEligibility.startPoint`) is still unrun end to end. 🔧

**P1-10. Keychain follow-ups.** 🔧 — **MOSTLY DONE (2026-09-19)**
- Ad-hoc signing means every release has a new signature, so macOS re-asks for Keychain approval once per release (README:70 already explains this for Microphone/Screen Recording but does not mention the Keychain). Update the README and the update-button tooltip (`UpdateChecker.swift`, `.help(...)`).
- The migrated legacy items (`gemini.api_key`, `anthropic.api_key` under service `com.whisperpilot.app`) remain in the Keychain. Decide with the owner how to clean them without triggering another prompt (for example a one-line note in the README on deleting them in Keychain Access).
- Not verified: whether one item produces exactly one macOS dialog. The previous behavior was 3-4 password prompts for 2 items.
- `SettingsStore.init` reads the secrets synchronously on the main thread at launch for an approved build (`restoreKeychainAccess`). If the user later revoked the approval this blocks launch behind a dialog. Consider moving it off the main thread.
- `SettingsStore.hasGeminiAPIKey`/`availableVendors` are evaluated from SwiftUI bodies and can call `KeychainHelper.exists` (attribute queries) up to 3 times per evaluation until migration completes. Cache the answer.
- The Settings "Allow Keychain access" button (`SettingsView.swift:262`) has no in-flight guard, so repeated clicks can stack dialogs.
- **Done:** (a) `unlockStoredKeys()` ignores a second call while one is waiting on macOS (guard in the store, so the Settings button and onboarding are both covered; a test presses twice and checks one read, and fails if the guard is removed). (b) `hasGeminiAPIKey` / `hasAnthropicAPIKey` / `availableVendors` cache the "which vendors exist" answer until a key is saved or unlocked (tested: ten redraws cost at most one round of queries). (c) The update-button tooltip and the README say macOS asks again for permissions and the Keychain after an update, and the README explains how to delete the two legacy Keychain items after the first successful unlock. **Not done, on purpose:** moving the launch-time read of an approved build off the main thread. `AppCoordinator.init` builds the AI provider from those keys straight away, so making the read asynchronous would change startup order (AI unavailable until it finishes) and can only be judged on a Mac. 🔧 Whether one item produces exactly one macOS dialog is still unverified.

**P1-11. Duplicate notes when Answer Screen is used before Screen Recording was requested.** — **DONE (2026-09-19)**
- `AppCoordinator.captureScreenJPEG` now posts a "needs Screen Recording, open Setup" note and returns nil, then the callers (`sendUserPrompt`, `answerScreen`) add their own generic "Couldn't capture screen" note. Keep one message.
- **Done:** `captureScreenJPEG` returns `.image / .needsSetup / .failed`; callers add the generic note only for `.failed`. The setup note now says "Reading your screen needs…" because it also shows for the composer's "See my screen". 🔧 Checklist item 10 still needs a real run.

**P1-12. Onboarding buttons pushed out of the window (found by the owner on a real Mac, 2026-09-19).** — **FIXED in code, not seen on screen**
- What: the window is a fixed 780×640. On the Access step, a long red message under a row (for example "Screen Recording was not allowed…") made the content taller than the window, so Back and Continue were cut off and the user could not advance.
- Fix: the Access and Answer steps now use `scrollingStep`: the body scrolls and the buttons stay pinned at the bottom, whatever the message length. 🔧 Confirm by denying Screen Recording again and checking that Continue is visible (scroll the list if needed).

**P1-13. Whisper Pilot is missing from System Settings → Screen & System Audio Recording (found by the owner on a real Mac, 2026-09-19).** — **MITIGATED in code, root cause not confirmed**
- What: after "Screen Recording was not allowed", **Open Settings** opened the pane but the app was not in the list, so there was no switch to turn on. macOS only lists an app after a permission request it accepted as a request; I could not reproduce the request outcome without a dialog.
- Fix: opening either pane now also shows a small floating window (`SettingsDragHelper`) in the middle of the screen with the app icon to drag into the list, and the text "or click + and choose Whisper Pilot, then switch it on". It never starts a capture or asks macOS for anything. The red messages for Screen Recording and system audio now say the same. Placement is `DragHelperPlacement` (tested). It closes on Done, on ✕, or when the user comes back to Whisper Pilot.
- Not done: making the app appear already listed with the switch off. Only a request that macOS registers does that, and `CGRequestScreenCaptureAccess()` next to the existing `SCShareableContent` probe could show two dialogs, which cannot be judged without a Mac. 🔧 To check: on a fresh `tccutil reset`, press Allow on Screen Recording, note whether the app appears in the list; then Open Settings and try the drag. If the app *does* appear after Allow but stays off, the drag helper is just a fallback.
- Owner test 2026-09-19 (first helper build): the small window showed its text but the icon was missing, and switching the app on gave no "quit and reopen" prompt (possibly a different copy of the app was in the list). Follow-up: the icon is now an AppKit drag source (`AppIconDragView`, first click accepted, does not move the window) on a light tile; the red message no longer promises a macOS prompt and says to quit and reopen from the menu bar if it still says not allowed. 🔧 Still to confirm on a Mac: icon visible, drag lands in the list, and which copy of the app the list entry points to (`/tmp/wp-dd/...` vs `/Applications`).
- Owner test, second round: icon visible and draggable. The window is now centred on the screen (it was at the bottom and easy to miss). After switching the app on, "Quit & Reopen" did not bring the app back. `runtime.log` of the `.dev` copy shows no launch after the quit and no hand-over line, so the second copy never started (it is not the single-instance code). Most likely macOS cannot relaunch the ad-hoc `/tmp/wp-dd` build; 🔧 check with a properly installed copy in `/Applications`.

**P1-14. Older copies of the app stay on the Mac after an update (asked by the owner, 2026-09-19).** — **DONE in code, not run on a Mac**
- What: after a DMG update the old app can remain (opened from Downloads, or copied next to the new one), and the user may open it by mistake. Homebrew replaces in place, so it does not have this.
- Fix: `OlderCopyCleanup` (4 s after the first window) lists other copies of the same bundle id, and `OlderCopies.find` (tested) keeps only strictly older ones, not on a disk image, not in the Trash, and nothing at all when the running copy is on a disk image or a quarantined download. It shows one alert per old copy with "Move to Trash" / "Not now". "Not now" is remembered per path and version. Nothing is removed without a click, and a running old copy is skipped. If moving fails, it says why and offers "Show in Finder".
- 🔧 To check: keep an old copy in `~/Downloads`, open the new one from `/Applications`, click Move to Trash. Note whether macOS shows an App Management dialog and whether the old app lands in the Trash.

### P2. Performance and maintainability

**P2-1. Session list re-reads every transcript.** — **DONE (2026-09-19)**
- `SessionStore.listSessions` (line 73) calls `countTranscriptLines` and `countChatTurns` (lines 504, 511), each reading whole files, for every session on every refresh. Cost grows with total history.
- Fix: store the counts in `metadata.json` and update incrementally, or count lazily/asynchronously.
- **Done:** a different fix from the two suggested. `SessionStore` keeps an in-memory cache of line and turn counts per session and re-reads a file only when its size or modification time changed. No change to `metadata.json`, and manual edits to a transcript are still picked up. Counting the transcript now scans bytes instead of building strings. The first list after launch still reads every file once. Tests: parsing, "unchanged list reads nothing", "one new line re-reads one file".

**P2-2. `runtime.log` only trims at launch** — **DONE (2026-09-19)** (`CrashLogger.start`, trims >1 MB to the last 256 KB). A long session in one run can grow it without bound. Add size-based rotation while running.
- **Done:** `CrashLogger` tracks the file size on its queue and, past 1 MB, keeps the newest 256 KB (from a whole line) in place on the same descriptor, so the signal handler keeps writing to the right file. `CrashLogger.rotate` is tested against a temp file.

**P2-3. Swift 6 concurrency warnings.** — **DONE (2026-09-19)** `NSLock.lock()/unlock()` used from async contexts (`AppleSpeechTranscriber.swift:22,49,52`, Parakeet mutexes, `SmokeTestRunner.swift:1440`). Warnings today, errors in Swift 6 language mode. Move to `OSAllocatedUnfairLock.withLock` or an actor.
- **Done:** every `lock()/unlock()` inside an async function now uses `NSLock.withLock` (`AppleSpeechTranscriber`, `MicrophoneCapture`, `ProcessAudioCapture`, `SystemAudioCapture`, `ParakeetTranscriber`, the smoke runner's `FakeTranslator`). Only the full `xcodebuild` showed all of them; `swift build` hid most. A clean `xcodebuild` now has two warnings left, neither about locks: `MicrophoneCapture.swift:108` (captures a non-`Sendable` `self` in a `Task`; left alone because marking the class `@unchecked Sendable` would only hide its unsynchronized `isRunning`/`restartTask`), and the 512@2x app icon is 730×730 instead of 1024×1024 (an asset, not code).

**P2-4. Deprecated `NSApp.activate(ignoringOtherApps:)`** (6 call sites). Works today; plan the replacement. — **NOT CHANGED on purpose (2026-09-19)**
- Why: the replacement, `NSApp.activate()`, is cooperative on macOS 14+. From the menu bar click it works, but from a global shortcut, the reopen path or the onboarding "bring to front after a macOS dialog" retries it may not bring the window forward. That is exactly the behavior the onboarding relies on, and it can only be checked on a Mac. The old call still works. 🔧 Do this together with the section 4 checklist: swap all 6 sites (`AppDelegate.swift` ×5, `MenuBarController.swift` ×1) and re-run checklist items 2, 3 and 9.

**P2-5. Reproducible builds.** — **DONE (2026-09-19)** `Package.swift` and `Project.yml:14` use `from: 0.15.5` for FluidAudio. For a 0.x package SwiftPM's `from` still accepts later minor versions, and `Package.resolved` is gitignored, so two release builds can pick different FluidAudio versions (the comment says "pinned by minor version", which is not what it does). Use `.upToNextMinor(from:)` / `exact:` and consider committing `Package.resolved`.
- **Done:** `Package.swift` uses `.upToNextMinor(from: "0.15.5")` and `Project.yml` uses `minorVersion: 0.15.5` (checked in the generated project: `upToNextMinorVersion`). `Package.resolved` is no longer in `.gitignore`, so it shows up as a new file to commit. Note: the Xcode build keeps its own resolution inside the ignored `.xcodeproj`, so the release build is pinned by the minor range, not by that file.

**P2-6. Release script does not run tests.** — **DONE (2026-09-19)** `bin/release` never invokes `swift run SmokeTests` (only the pre-push hook does). Add it as a gate inside the script (this is not CI work).
- **Done:** `bin/release` runs `swift run SmokeTests` right after the prerequisite checks, before the version bump and build (`bash -n` passes; not run for real). `docs/RELEASE.md` lists the new step.

**P2-7. Size of a few files.** `AppCoordinator.swift` (2,732 lines, ~60 functions, ~33 `Task {` blocks) and `Overlay/OverlayView.swift` (1,714 lines) are hard to reason about. Only split with tests around the seams; not urgent.

**P2-8. Deferred from the July 2026 sweep (need live hardware, behavior-changing).** Do not do these without the owner and a device: replace the fixed 5× system-audio gain with AGC; share one Parakeet encoder across channels; flip `CATapDescription.isPrivate` to true on the process tap; move the transcript consumer off the main actor and fix the `MarkdownMessageView` O(n²) re-parse.

### P3. Test gaps — **mostly done (2026-09-19); what is left is listed at the end of this section**

The smoke runner (`Tools/SmokeTests/SmokeTestRunner.swift`, 28 suites, one 1.8k-line file) covers parsing, buffers, session store, translation queue and onboarding eligibility. It does **not** cover:

- ~~Gemini/Anthropic SSE parsing, finish reasons, mid-stream error events, `promptBlocked`~~ **Done** (`Tools/SmokeTests/AIProviderTests.swift`, stub `URLProtocol`).
- ~~Keychain flows~~ **Done.** New `SecretStore` protocol (`Settings/SecretStore.swift`) with `SystemSecretStore` as the default; `SettingsStore.init(defaults:secrets:)` takes a fake in tests, so a test can never raise a macOS dialog. `Tools/SmokeTests/KeychainAndPermissionsTests.swift` covers: no secret read at launch for an unapproved build, unlock, approval remembered per build (and "unknown" never approved), refusal and retry, failed and damaged reads, legacy migration (both items, retry when the bundle write fails, stop at the first refusal, legacy items left in place), save/replace/remove, failed save keeps the old key, "Set up later" per build. A mutation check (breaking the locked-save guard and the approval check) made 17 assertions fail.
- `PermissionsManager` status mapping **done**: the mapping moved into pure functions in `Permissions/PermissionMapping.swift` and is tested. `MenuBarController` rebuild logic and `AppDelegate.showInitialWindow` are **still untested** (both need AppKit windows or a menu).
- ~~The new `SettingsStore` migration is only compile-checked.~~ Done, see above.
- **Menu bar layout: done.** The rule for which entries show (setup missing vs full, running vs idle) is now `MenuLayout.entries`, tested; `MenuBarController.rebuildMenu` only turns entries into `NSMenuItem`s.
- **Still open in P3:** `AppDelegate.showInitialWindow` (its decision is `OnboardingEligibility.shouldPresent`, already tested; the window code itself needs a screen) and the permission *requests* (they open real dialogs, so they can only be checked by hand in section 4). The fake proves our rules; whether macOS shows exactly one dialog per item is still only checkable on a Mac.

## 4. Manual QA checklist for the onboarding and permissions work (not yet run)

Use the `.dev` build and reset recipe in section 1. Tick each one on a real Mac.

1. Fresh state: onboarding opens by itself, welcome → Access → Answer.
2. "Allow all" asks Microphone, Speech Recognition, system audio, Screen Recording, Keychain in one go, and the onboarding window is in front again after each dialog and at the end.
3. Screen Recording: after enabling it in System Settings and choosing Quit & Reopen, the **correct copy** reopens (check with `ps`) and onboarding resumes at the right step with nothing repeated.
4. Deny each permission once: the red message and the "Open Settings" button appear, the row recovers after enabling it in System Settings and returning to the app.
5. Keychain with two legacy items present: at most the migration approvals happen, once. Rebuild the app (new signature) and open it: exactly one approval prompt. Then open Settings, Sessions, the overlay and press Play: **no** prompt.
6. With no API key: the Answer step appears even when every permission is already granted. "Set up later" leaves Settings reachable and the app works transcription-only.
7. Close the onboarding window with the X on first run: Sessions opens, and the window does not reappear until the next build.
8. Menu bar: while something required is missing it shows only Finish setup / Settings / About / Quit; after granting, the full menu returns without relaunching. Granting in System Settings while the app is in the background is reflected the next time the menu opens.
9. Overlay banner "Open Setup" appears when Microphone or Speech Recognition is missing and Play is pressed; it clears after granting.
10. Answer Screen before Screen Recording was ever requested: one clear message, no dialog.

## 5. Suggested order of work

1. Ask the owner about committing the current work (section 2), then run the QA list (section 4) and fix what breaks.
2. Trust fixes: P0-1, P0-2, P0-3 (they share files), then P0-4, P0-5.
3. Cheap reliability wins: P1-2, P1-3, P1-6, P1-7, P1-8, P1-11.
4. Provider retry (P1-1) with tests from P3.
5. Hardware-dependent items: P1-4, P1-5, P1-9, P1-10 (verify each on a real device).
6. Performance and hygiene: P2-1, P2-2, P2-5, P2-6, then P2-3/P2-4.
7. ~~Update `README.md` (privacy claims, TCC and Keychain explanation) and `docs/ARCHITECTURE.md` when behavior changes.~~ **Done (2026-09-19):** README first-run steps, Keychain-after-update note, legacy item cleanup, log contents, on-device-only wording; ARCHITECTURE lifecycle, transcription, AI retry, persistence, permissions and threading.

Keep each fix small and separately committable (when the owner asks). Add a test for every pure-logic fix. Re-run `swift run SmokeTests` and the `xcodebuild` line before saying anything is done, and say plainly which items you could not verify without hardware.
