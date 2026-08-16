# Architecture

One Swift module, no dependencies, no Xcode project: `swiftc Sources/*.swift`
produces the whole app. Files map to subsystems:

| File | Owns |
|------|------|
| `Support.swift` | `DLog` (content-free logging), `Defaults` (all settings), CoreAudio device helpers, `Typist` (CGEvent keystroke synthesis), locale/model resolution |
| `Speech.swift` | `MicCapture` (AVCaptureSession), `AnalyzerSession` (one SpeechAnalyzer engine), `SpeechOut` (TTS), `FrontTextReader` (AX tree + OCR fallback), `CaptionOverlay` |
| `TextProcessing.swift` | Every pure decision: command vocabularies + `parseCommand`, filler stripping, corrections, wake phrase, `UtteranceBuffer`, `commitDecision`, `pickUtterance`, per-app profile matching — plus the `--selftest` suite that CI runs |
| `Storage.swift` | `HistoryStore` (opt-in JSONL), `Journal` (opt-in daily Markdown) |
| `Controller.swift` | `ListeningController` — session lifecycle, dispatch, commit pipeline, watchdogs; `FeedBox`; `transcribeFile` (CLI) |
| `UI.swift` | `SettingsWindow`, `HistoryWindow` |
| `App.swift` | `AppDelegate` (menu, icon, hotkey), entry point |

## Data flow

```
mic → MicCapture (capture queue) → VAD gate → FeedBox.get() → AnalyzerSession(s)
    → results stream (detached task) → MainActor handleResult
    → parseCommand? execute : accumulate in UtteranceBuffer
    → tick() every 0.25s → commitDecision → commitUtterance
    → pickUtterance (dual-language) → corrections → fillers → Typist.type
```

## Concurrency model (read before "simplifying")

Three execution contexts:

1. **The capture queue** (`MicCapture`'s dispatch queue). Hard real-time-ish:
   the `onBuffer` closure computes RMS, runs the VAD gate, and feeds engines.
   It must never touch `ListeningController`'s MainActor state. It reaches
   the live sessions **only** through `FeedBox` (a lock); VAD state
   (`feedActiveUntil`, `preroll`) is captured *inside* the closure so it is
   confined to this queue by construction.
2. **The MainActor**: all controller state, UI, timers, command dispatch.
3. **Detached tasks**: engine result streams, read-aloud, the answer
   watcher. They hop to the MainActor to mutate anything.

Invariants that look like accidents but are load-bearing:

- **Sessions are long-lived.** Rebuilding analyzers per utterance opened a
  dead window that swallowed the start of rapid follow-up messages. Rotation
  happens only from hygiene/watchdog paths.
- **`sessionToken` guards stale callbacks.** Every session start bumps the
  token; result callbacks compare it so a torn-down engine's trailing finals
  can't leak into the next utterance.
- **Dual-language mode bypasses the VAD battery saver.** The second engine
  needs continuous silence audio to finalize on time; gating its feed delays
  its finals by whole utterances.
- **`secondaryLocale` is cleared synchronously** when the user disables the
  second language — the rotation watchdog checks it, and an async clear let
  the watchdog resurrect a disabled engine.
- **Commands are re-checked at commit.** A command phrase can arrive split
  across two engine finals; each half fails to match live, they reassemble
  in the buffer, and without the commit-time re-check the assembled command
  would be typed and auto-sent (observed live with "stop listening").
- **The stale-final guard** (`lastVoiceAt <= lastCommitAt`) drops finals
  that belong to an already-committed utterance; sessions being long-lived
  makes this necessary.

## Timing constants

All commit gating lives in `TextProcessing.commitDecision`, pure and
tested. Each constant (0.9s slow-engine grace, 3s low-confidence rescue,
0.75/0.5 short-garble bars, watchdog windows) has a regression test naming
its scenario — change a constant only with the test that proves the old
failure stays fixed.

## Privacy rules

- `DLog` lines carry counts and states, never spoken words. The selftest
  suite and reviews enforce this; keep it true in new code.
- Spoken text reaches disk in exactly two places, both opt-in and
  user-visible: `HistoryStore` and `Journal`. Everything else
  (`recentUtterances`, captions, volatile previews) is memory-only.

## Extension points

- **New voice command**: add the vocabulary set + a `Command` case +
  `parseCommand` line in `TextProcessing.swift`, handle the case in
  `handleLiveCommand` and the commit-time switch, add a parser test.
- **New engine (Whisper backend)**: `AnalyzerSession`'s surface —
  `init(locale:onResult:)`, `feed(buffer)`, `teardown()` — is the de facto
  protocol. Note `pickUtterance` assumes Apple's confidence semantics
  (wrong-language engine ≈ 0.2 vs 0.95); an engine without a comparable
  signal degrades dual-language mode to the text-language fallback.
- **New language pair**: `UtteranceBuffer` already generalizes; the open
  costs of >2 engines are CPU/battery (each engine hears all audio) and
  commit latency (the slowest engine sets the pace).
