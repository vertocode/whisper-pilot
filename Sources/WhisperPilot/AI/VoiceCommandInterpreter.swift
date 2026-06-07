import Foundation

/// What a spoken wake-word command resolves to. `openApp` / `openURL` are the
/// only system actions — both reversible and safe to auto-execute. Everything
/// else falls through to `answer`, which routes the command into the normal
/// streaming-chat path.
enum VoiceCommandIntent: Sendable, Equatable {
    case openApp(String)
    case openURL(URL)
    case answer
}

/// Routes a spoken command to an intent via one short AI call. The model is
/// instructed to emit a single JSON object; anything unparseable degrades to
/// `.answer` so a flaky classification never swallows the user's request —
/// worst case they get a chat answer instead of an app launch.
enum VoiceCommandInterpreter {
    static func interpret(command: String, using ai: AIProvider) async throws -> VoiceCommandIntent {
        let system = """
        You are a voice-command router for a macOS assistant. The user spoke a command \
        after the wake word. Classify it and reply with ONLY a single JSON object — no \
        markdown fences, no commentary.

        Shapes:
        {"intent":"open_app","app":"<macOS application name>"} — the user asked to open or \
        launch an application. Normalize spoken names to the real installed app name: \
        "chrome" → "Google Chrome", "code" / "vs code" → "Visual Studio Code", "vscode" → \
        "Visual Studio Code", "terminal" → "Terminal".
        {"intent":"open_url","url":"https://..."} — the user asked to open a website or \
        search the web. For searches use https://www.google.com/search?q=<encoded terms>.
        {"intent":"answer"} — anything else: questions, requests to write code or text, \
        explanations, summaries. The assistant will answer in chat.

        If unsure, use "answer".
        """
        let prompt = Prompt(systemInstruction: system, context: "", question: command, style: .concise)
        var raw = ""
        for try await event in ai.streamCompletion(prompt: prompt) {
            if case .delta(let text) = event { raw += text }
        }
        return parse(raw) ?? .answer
    }

    /// Tolerant JSON extraction — strips markdown fences and surrounding prose
    /// (models occasionally wrap the object despite instructions), then decodes.
    static func parse(_ raw: String) -> VoiceCommandIntent? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end else { return nil }
        let json = String(raw[start...end])

        struct Wire: Decodable {
            let intent: String
            let app: String?
            let url: String?
        }
        guard let data = json.data(using: .utf8),
              let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }

        switch wire.intent {
        case "open_app":
            guard let app = wire.app?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty else { return nil }
            return .openApp(app)
        case "open_url":
            guard let urlString = wire.url,
                  let url = URL(string: urlString),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http" else { return nil }
            return .openURL(url)
        case "answer":
            return .answer
        default:
            return nil
        }
    }
}
