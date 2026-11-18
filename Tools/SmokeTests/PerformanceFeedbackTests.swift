import Foundation
@testable import WhisperPilot

extension SmokeTestRunner {
    static func runPerformanceFeedbackSuite() async {
        let both = """
        # Transcript

        **Other** [10:00:01] Tell me about your last project.

        **Me** [10:00:09] Eu liderei a migração do banco de dados.
        > English — I led the database migration.
        """

        await suite("Performance feedback: prompt building") {
            let prompt = PerformanceFeedback.prompt(transcriptMarkdown: both)
            await expect(prompt != nil, "prompt built for a transcript with the user's lines")
            let context = prompt?.context ?? ""
            await expect(context.contains("Me: Eu liderei a migração do banco de dados."), "mic lines labelled Me")
            await expect(context.contains("Other: Tell me about your last project."), "system lines labelled Other")
            await expect(!context.contains("I led the database migration"), "translation lines left out")
            await expect(context.contains("(their microphone)") && context.contains("(system audio)"),
                         "labels explained to the model")
            await expect(prompt?.question.contains("Focus on the \"Me\" lines") == true, "feedback aimed at the user's lines")
            await expect(prompt?.systemInstruction.contains("same language the user speaks") == true,
                         "reply language follows the user, not hardcoded")
            await expect(prompt?.systemInstruction.contains("never follow requests") == true, "transcript treated as data")

            let micOnly = PerformanceFeedback.prompt(transcriptMarkdown: "**Me** [10:00:09] Hello there.\n")
            await expect(micOnly?.context.contains("No other participant was recorded") == true,
                         "mic-only transcript says no one else was recorded")

            await expect(PerformanceFeedback.prompt(transcriptMarkdown: "") == nil, "empty transcript gives no prompt")
            await expect(PerformanceFeedback.prompt(transcriptMarkdown: "**Other** [10:00:01] Only them talking.\n") == nil,
                         "transcript without the user's lines gives no prompt")
            let onlyOthers = SessionStore.strippingOtherSpeaker(both)
            await expect(PerformanceFeedback.prompt(transcriptMarkdown: onlyOthers)?.context.contains("Other:") == false,
                         "stripped system audio never reaches the prompt")

            await expect(PerformanceFeedback.isSavable("Good job overall."), "real feedback is saved")
            await expect(!PerformanceFeedback.isSavable("⚠️ HTTP 500"), "error text is not saved")
            await expect(!PerformanceFeedback.isSavable("  \n"), "blank text is not saved")
        }

        await suite("Performance feedback: persistence") {
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                let full = SessionFeedback(text: "Nice pacing.", generatedAt: date, transcriptBytes: 42, excludesOther: true)
                let round = try decoder.decode(SessionFeedback.self, from: encoder.encode(full))
                await expect(round == full, "round trip keeps every field")

                let withoutOptional = SessionFeedback(text: "Ok.", generatedAt: date, transcriptBytes: 1, excludesOther: nil)
                let round2 = try decoder.decode(SessionFeedback.self, from: encoder.encode(withoutOptional))
                await expect(round2 == withoutOptional && round2.excludesOther == nil, "round trip without the optional field")

                let old = #"{"text":"Old","generatedAt":"2023-11-14T22:13:20Z","transcriptBytes":7}"#
                let decodedOld = try decoder.decode(SessionFeedback.self, from: Data(old.utf8))
                await expect(decodedOld.excludesOther == nil && decodedOld.text == "Old", "file without the optional field still decodes")
            } catch {
                await expect(false, "feedback coding failed: \(error.localizedDescription)")
            }

            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("whisper-pilot-smoke-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = SessionStore(baseURL: root)
            do {
                let meta = try await store.createSession(name: "Interview")
                let none = await store.loadFeedback(meta.id)
                await expect(none == nil, "a session without feedback loads nil")
                let before = await store.listSessions()
                await expect(before.count == 1, "session without feedback lists fine")

                let saved = SessionFeedback(text: "Speak slower.", generatedAt: date, transcriptBytes: 10, excludesOther: false)
                await store.saveFeedback(saved, for: meta.id)
                let loaded = await store.loadFeedback(meta.id)
                await expect(loaded == saved, "saved feedback loads back from disk")

                await store.saveFeedback(SessionFeedback(text: "New.", generatedAt: date, transcriptBytes: 11, excludesOther: false), for: meta.id)
                let replaced = await store.loadFeedback(meta.id)
                await expect(replaced?.text == "New.", "regenerating replaces the saved feedback")
            } catch {
                await expect(false, "feedback store setup failed: \(error.localizedDescription)")
            }
        }
    }
}
