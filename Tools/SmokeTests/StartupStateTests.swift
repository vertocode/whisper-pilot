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

            let (bubbleCount, failedBubbleIsGone) = await MainActor.run { () -> (Int, Bool) in
                let state = OverlayState()
                let failed = state.beginAssistantStream(origin: .userPrompt)
                let retry = state.beginAssistantStream(origin: .userPrompt, replacing: failed)
                state.replaceText(of: retry, with: "answer")
                state.finishAssistant(id: retry)
                return (state.messages.count, !state.messages.contains { $0.id == failed })
            }
            await expect(bubbleCount == 1, "a fallback retry reuses the failed bubble instead of adding one")
            await expect(failedBubbleIsGone, "no empty bubble from the failed attempt stays behind")
        }
    }
}
