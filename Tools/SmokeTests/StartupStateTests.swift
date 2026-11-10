import Foundation
@testable import WhisperPilot

extension SmokeTestRunner {
    static func runAIExitStateSuite() async {
        await suite("AI exit states") {
            await expect(
                OverlayStatus.afterAIReply(isRunning: false, isStartupWanted: true) == .starting,
                "a reply finishing during startup returns to Starting, so the first frame can promote it"
            )
            await expect(
                OverlayStatus.afterAIReply(isRunning: true, isStartupWanted: false) == .listening,
                "a reply finishing during a live session returns to Listening"
            )
            await expect(
                OverlayStatus.afterAIReply(isRunning: false, isStartupWanted: false) == .idle,
                "a reply finishing with nothing running, or after Stop during startup, returns to Idle"
            )
            await expect(
                OverlayStatus.afterStartupReturned(current: .starting, isRunning: false, isPlayQueued: false) == .idle,
                "a startup that returned without running doesn't leave Starting up forever"
            )
            await expect(
                OverlayStatus.afterStartupReturned(current: .starting, isRunning: true, isPlayQueued: false) == .starting,
                "a successful startup stays on Starting until the first audio frame"
            )
            await expect(
                OverlayStatus.afterStartupReturned(current: .starting, isRunning: false, isPlayQueued: true) == .starting,
                "a queued Play keeps Starting up while the next startup begins"
            )
            await expect(
                OverlayStatus.afterStartupReturned(current: .thinking, isRunning: false, isPlayQueued: false) == .thinking,
                "a startup returning doesn't touch a reply still in progress"
            )

            let (bubbleCount, failedBubbleIsGone) = await MainActor.run { () -> (Int, Bool) in
                let state = OverlayState()
                let failed = state.beginAssistantStream(origin: .userPrompt)
                let retry = state.beginAssistantStream(origin: .userPrompt, replacing: failed)
                state.replaceText(of: retry, with: "answer")
                state.finishAssistant(id: retry)
                return (state.messages.count, !state.messages.contains { $0.id == failed })
            }
            await expect(bubbleCount == 1, "beginAssistantStream with replacing: swaps the bubble in place instead of adding one")
            await expect(failedBubbleIsGone, "the replaced bubble is gone after replacing:")
        }
    }

    static func runQueuedPlaySuite() async {
        await suite("Queued Play") {
            var idle = QueuedPlay()
            await expect(idle.press(isRunning: false, isStartingUp: false, isStartupLive: false, isStopping: false) == .start, "Play with nothing going starts")
            await expect(!idle.isQueued, "a normal start queues nothing")

            var running = QueuedPlay()
            await expect(running.press(isRunning: true, isStartingUp: false, isStartupLive: false, isStopping: false) == .stop, "a press while running stops")

            var live = QueuedPlay()
            await expect(live.press(isRunning: false, isStartingUp: true, isStartupLive: true, isStopping: false) == .stop, "a press during a wanted startup cancels it")
            await expect(!live.isQueued, "cancelling a startup queues nothing")

            var cancelled = QueuedPlay()
            await expect(
                cancelled.press(isRunning: false, isStartingUp: true, isStartupLive: false, isStopping: false) == .queueStart,
                "Play while a cancelled startup finishes waits instead of loading a second model"
            )
            await expect(cancelled.isQueued, "that Play press is remembered")
            await expect(cancelled.take(), "the old startup returning uses the remembered press")
            await expect(!cancelled.take(), "one press only ever starts once")

            var stopped = QueuedPlay()
            _ = stopped.press(isRunning: false, isStartingUp: true, isStartupLive: false, isStopping: false)
            await expect(
                stopped.press(isRunning: false, isStartingUp: true, isStartupLive: false, isStopping: false) == .cancelQueuedStart,
                "the next press takes back the remembered Play, because the button now shows Stop"
            )
            await expect(!stopped.take(), "nothing starts after taking it back")

            var tearingDown = QueuedPlay()
            await expect(
                tearingDown.press(isRunning: false, isStartingUp: true, isStartupLive: false, isStopping: true) == .ignore,
                "a press while Stop is still tearing down does nothing"
            )
            await expect(!tearingDown.isQueued, "that press doesn't arm a hidden Play")

            var otherStop = QueuedPlay()
            _ = otherStop.press(isRunning: false, isStartingUp: true, isStartupLive: false, isStopping: false)
            otherStop.clear()
            await expect(!otherStop.take(), "a Stop from anywhere else also forgets the remembered Play")
        }
    }
}
