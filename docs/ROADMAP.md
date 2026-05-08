# Roadmap

Living document. Items are loosely ordered.

## Near term

- [ ] **WhisperKit transcriber.** Drop-in `TranscriptionProvider` using [WhisperKit](https://github.com/argmaxinc/WhisperKit). Better quality than `SFSpeechRecognizer`, fully on-device, runs on the Apple Neural Engine. Needs first-run model download UX.
- [ ] **Speaker diarization.** Today the trigger engine assumes anything from the *system* channel is "the other party" and anything from the *microphone* channel is "the user." Useful approximation but breaks on speakerphone. Real diarization (per-speaker embeddings) lives behind a small protocol and feeds into `ConversationContext`.
- [ ] **Trigger engine snapshot tests.** The heuristic question detector is the most brittle piece of the app. Snapshot tests on real transcript fixtures.
- [ ] **End-of-session export.** A "Generate summary" button on the Sessions window that runs one final Gemini call against the markdown to produce action items, decisions, and follow-ups.
- [ ] **Optional encrypted persistence.** All session content is plaintext markdown today. A user-toggleable per-session encryption with a key derived from the Keychain, off by default.
- [ ] **Cancel-in-flight UX.** When a new trigger fires while a previous answer is still streaming, immediately interrupt and replace the lane content (currently the old answer continues until it ends).

## Mid term

- [ ] **Local LLM provider.** `OllamaProvider` conforming to `AIProvider`, talking to a user-run Ollama instance over `http://localhost:11434`. Same protocol, same UX, zero tokens spent.
- [ ] **Multi-provider support in Settings.** The provider picker is wired but only Gemini is implemented. Add Claude, OpenAI, Ollama.
- [ ] **Per-mode prompts.** Coding interview, sales call, customer support, lecture notes, system design each get specialized system prompts and default response styles. A mode picker in the overlay header.
- [ ] **Audio source selection.** Pick a specific app's audio (e.g. only Zoom, ignore Spotify) via `SCContentFilter`. Useful when the user is listening to background music.
- [ ] **Composer attachments beyond screen.** Paste a code snippet, drop a file, attach a region of the screen rather than the whole display.
- [ ] **Overlay polish.** Resizable corners visible, magnetic snap to screen edges, optional vibrancy effect.

## Long term

- [ ] **Realtime translation overlay.** Captions in another language, on by default in international calls.
- [ ] **Specialized modes — coding interview / system design.** Diagram pane, step-through reasoning, scratchpad for whiteboard-style design questions.
- [ ] **"Write like me" personalization.** A sample of the user's writing turned into in-context examples so the assistant's suggestions sound like them.
- [ ] **Cross-session memory / RAG.** Persistent topic graph across sessions. Surfaces relevant past conversations when a topic recurs.
- [ ] **Plugin system.** Third-party context sources — clipboard, browser tab, Apple Notes, GitHub PR — that can be enabled per session.

## Explicit non-goals

- **A chat input field as the primary UI.** Whisper Pilot is ambient. The composer exists for explicit follow-ups, not as a ChatGPT replacement.
- **A mobile app.** iOS doesn't expose system audio capture; the product fundamentally requires a desktop OS.
- **A paid tier.** Bring-your-own-key is the entire value proposition.
- **A hosted backend.** There isn't one. If we ever need server-side anything, it'll be behind a provider protocol so users can run their own.
