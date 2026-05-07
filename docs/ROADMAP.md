# Roadmap

Living document. Items are loosely ordered.

## Near term

- [ ] **WhisperKit transcriber.** Drop-in `TranscriptionProvider` using [WhisperKit](https://github.com/argmaxinc/WhisperKit). Better quality than `SFSpeechRecognizer`, fully on-device, runs on Apple Silicon Neural Engine. Needs first-run model download UX.
- [ ] **Speaker diarization.** Today the trigger engine assumes anything from the *system* channel is "the other party" and anything from the *microphone* channel is "the user." This is a useful approximation but breaks on speakerphone. Real diarization (per-speaker embeddings) lives behind a small protocol and feeds into `ConversationContext`.
- [ ] **Trigger engine tests.** The heuristic question detector is the most brittle piece of the app. Snapshot tests on real transcript fixtures.
- [ ] **Cancellable streaming.** When a new trigger fires while an old completion is still streaming, we currently let the old one finish writing to the overlay before the new one takes over. Cancel the in-flight call and clear the overlay lane immediately.
- [ ] **Persistence.** Optional per-session transcript log to `~/Library/Application Support/WhisperPilot/`, encrypted with a key derived from the Keychain. User-toggleable, off by default.

## Mid term

- [ ] **Local LLM provider.** `OllamaProvider` conforming to `AIProvider`, talking to a user-run Ollama instance over `http://localhost:11434`. Same protocol, same UX.
- [ ] **Multi-provider support in settings.** Today there's a stub for provider choice; the picker doesn't do anything yet. Wire it up: Gemini / Claude / OpenAI / Ollama.
- [ ] **Per-mode prompts.** Coding interview, sales call, customer support each want different system prompts and different response styles. Settings: "What kind of conversation is this?"
- [ ] **Meeting summary.** End of session: action items, decisions, follow-ups. One Gemini call against the rolling buffer at session close.
- [ ] **Overlay polish.** Resizable corners, magnetic snap to screen edges, optional translucent vibrancy.

## Long term

- [ ] **Realtime translation overlay.** Captions in another language, on by default in international calls.
- [ ] **System design / coding interview mode.** Specialized layouts for technical interviews — diagram pane, step-through reasoning.
- [ ] **"Write like me" personalization.** Sample of user's writing → response style fine-tune via in-context examples.
- [ ] **Memory / RAG.** Persistent topic graph across sessions. Retrieves relevant past conversations when a topic recurs.
- [ ] **Cross-device sync.** Bring-your-own backend story. Probably never a hosted offering.

## Explicit non-goals

- A chat input field. Whisper Pilot is ambient — typing breaks the flow. If you want a chatbot, use ChatGPT.
- A mobile app. iOS doesn't expose system audio capture; the product fundamentally requires a desktop OS.
- A paid tier. The whole point is bring-your-own-key.
