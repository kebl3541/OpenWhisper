# OpenWhisper

[![CI](https://github.com/kebl3541/OpenWhisper/actions/workflows/ci.yml/badge.svg)](https://github.com/kebl3541/OpenWhisper/actions/workflows/ci.yml)
[![Downloads](https://img.shields.io/github/downloads/kebl3541/OpenWhisper/total?label=downloads)](https://github.com/kebl3541/OpenWhisper/releases)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-support-yellow?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/philosophizer)

This is a hands-free dictation for macOS. No hotkeys, no
tapping: it listens continuously (unless deactivated), transcribes on-device 
with Apple's macOS 26 speech engine (`SpeechAnalyzer`/`SpeechTranscriber`), 
types what you say into the focused text field, and can press Return for you. 
Nothing ever leaves your Mac.

Apple Silicon, macOS 26+. MIT licensed. CI builds and tests every push on
GitHub's `macos-26` runners.

**Not a developer? Start with the [User Guide](docs/USER-GUIDE.md)** —
installation, the icon, every voice command, settings, and troubleshooting,
in plain language. Contributors: read [ARCHITECTURE.md](ARCHITECTURE.md)
first — it documents the concurrency invariants that look simplifiable but
aren't.

## How it works

1. The app sits in the menu bar (waveform icon) and listens all the time.
   The icon is **green** while listening, **red** while it hears you speak,
   **orange** when muted, grey when the mic is off.
2. Put the cursor in any text field and speak. As phrases finalize, the words
   are typed at the cursor.
3. In **Claude** and **Perplexity (Comet)**, it presses Return automatically
   ~0.7 s after you stop talking. In every other app it only types — say
   **"send it"** to press Enter, or press it yourself.

Filler sounds ("um", "uh", "ehm") are removed before typing. Turn this off in
the menu if you want them verbatim.

## Which menu bar icon is OpenWhisper?

OpenWhisper is the **waveform** icon. The separate **microphone icon** that
appears nearby is **macOS itself**, not this app: whenever any app records
audio, macOS shows its own mic-in-use privacy indicator. Clicking it shows
which app is using the microphone (OpenWhisper, while listening) plus
system audio features such as Mic Modes (Voice Isolation, Wide Spectrum).
Those controls belong to macOS and appear for every recording app — Zoom,
FaceTime, anything. OpenWhisper deliberately uses a waveform glyph so the
two are never confused.

## Automatic bilingual dictation (opt-in)

Pick a secondary language in **Settings** and two speech engines run in
parallel: every utterance goes to whichever one was acoustically confident
(`.transcriptionConfidence` — the wrong-language engine emits plausible
words but *knows* it's guessing, typically 0.2 vs 0.95). No language
commands: speak either language, sentence by sentence. Mixing languages
inside a single utterance is not supported (one engine wins per utterance).

Off by default because the second engine has real costs: audio is fed
continuously (the battery saver only works single-language) and commits
wait briefly for the slower engine. Turn it on when you actually dictate in
two languages; switching either language in Settings takes effect live.

```
defaults write io.github.kebl3541.openwhisper dualLanguage -bool true    # or use Settings
defaults write io.github.kebl3541.openwhisper secondaryLocale it-IT
```

Hard-won implementation notes: the two engines finalize at different speeds,
so commits wait for the slower one (up to 0.9s, or 3s when the lone
transcript is garble-quality); sessions are long-lived because rebuilding
them per message created a dead window that swallowed rapid follow-up
messages; and the VAD battery-saver is bypassed in dual mode because the
Italian engine needs continuous silence audio to finalize on time.

## Voice commands (say as a standalone phrase)

- **"Hey Claude"** — from anywhere (any app, even while muted): brings the
  Claude app to the front and unmutes. Words in the same breath carry over:
  "Hey Claude, summarize this" opens Claude and types "summarize this".
  Needs the greeting word — a sentence merely starting with "Claude…" won't
  trigger it. "Hi/Okay Claude" work too.

- **"pause listening"** / "stop dictation" — mute. Types nothing anywhere;
  only listens for the wake phrase. Icon turns orange, low *bottle* sound.
- **"start listening"** / "resume dictation" — unmute (*pop* sound).
- **"send it"** / "send" / "send now" / "press enter" — press Return immediately.
- **"read it to me"** / "read this" — reads the frontmost window's text aloud
  (works in any app: Claude, Perplexity, a webpage). **"stop"** / "stop
  reading" halts it. While it reads, your speech isn't typed (no feedback
  loops).
- **"scratch that"** / "delete that" / "undo" — deletes the last phrase it
  typed, so you can re-say it.
- **"new line"** / **"new paragraph"** — inserts line breaks (Shift+Return,
  so chats don't send).
- **"replace X with Y"** — permanent transcription correction (e.g. "replace
  madre with marginally"). **"forget replacement X"** removes it.
- **"talk mode on/off"** — read every answer aloud automatically after each
  send, in whatever chat app you're using.

Also: "stop" interrupts read-aloud instantly (no waiting for the phrase
to finalize); dictation is suppressed while Zoom/Teams/FaceTime/Webex is
frontmost so meetings never get typed anywhere; and the speech engine only
runs while voice is detected, cutting idle battery use.
- Optionally prefix with "Claude": "Claude, pause listening".

## Menu options

- **Mute / Unmute** — same as the voice commands.
- **Turn Mic Off Completely** — releases the microphone entirely.
- **Auto-send** (on) — Return after a pause (Claude/Perplexity only).
- **Type into any app** (on) — dictate into any focused text field. Turn off
  to restrict typing to Claude/Perplexity too.
- **Insert via clipboard paste** — compatibility mode for apps that ignore
  synthetic keystrokes.
- **Remove filler words** (on) — strips um/uh/ehm-type sounds before typing.
- **Recent Utterances** — the last 10 things you dictated; click one to copy
  it. Kept in memory only, never written to disk.
- **Auto-send in <current app>** — one click adds or removes the app you're
  in from the auto-send allowlist. No terminal needed.
- **Journal dictations to Markdown…** (off) — pick a folder and every
  committed phrase is appended to a daily `YYYY-MM-DD.md` file with a
  timestamp. Opt-in: it writes spoken text to disk.
- **Settings…** — a native settings window: pause and voice-threshold
  sliders, language pickers (change either language live, no restart),
  an optional mute-toggle hotkey (⌥ Space, F18, …), auto-send app list,
  personal-dictionary editor, privacy toggles.
- **History…** — opt-in searchable history of everything you dictated
  (off by default; enable in Settings). Search, copy, clear.
- **Copy Last Utterance**, **Start at Login**, **Quit**.

"Scratch that" only deletes in the app the text was actually typed into —
switching apps and saying it won't backspace into your editor.

## Design principles

- **Zero-button by design.** Most dictation tools are hotkey or
  push-to-talk driven. OpenWhisper never asks for a keypress: it listens
  continuously and everything — muting, sending, deleting, language — is a
  voice command. Built for when your hands aren't on the keyboard at all.
- **Apple's on-device engine.** OpenWhisper uses macOS 26's built-in
  `SpeechAnalyzer`/`SpeechTranscriber` — no model downloads, no bundled
  inference runtime, a single small binary.
- **Streaming, not record-then-transcribe.** Words are typed as phrases
  finalize while you're still talking, and auto-Return sends them — a full
  conversation loop, not a dictation drop.
- **Per-utterance bilingual auto-detection**, chat-aware auto-send,
  read-answers-aloud talk mode, and a wake phrase ("Hey Claude").
- **Kind to your clipboard**: paste-mode insertion restores what you had
  copied, and nothing is ever stashed to the clipboard without opt-in.
- **Tested and CI-built**: the text-processing core (commands, fillers,
  corrections, wake phrase) runs a self-test suite on every push.
- **No LLM rewriting.** Cleanup is deliberately rule-based and local
  (filler stripping, your personal dictionary). You're usually dictating
  into an AI chat anyway — the intelligence sits on the other side of the
  text box.

## Current tuning

Set live via `defaults`; the app reads most of these continuously.

```
defaults write io.github.kebl3541.openwhisper commitDelay -float 0.7    # silence before auto-Return
defaults write io.github.kebl3541.openwhisper locale en-GB              # speech model (restart app)
defaults write io.github.kebl3541.openwhisper anyApp -bool true         # type into any app
defaults write io.github.kebl3541.openwhisper voiceThreshold -float 0.012
defaults write io.github.kebl3541.openwhisper removeFillers -bool false # keep um/uh verbatim
defaults write io.github.kebl3541.openwhisper wakeTargetPrefix com.example.   # app family "Hey Claude" activates
defaults write io.github.kebl3541.openwhisper wakeTargetAppID com.example.app # exact app to launch if not running
defaults write io.github.kebl3541.openwhisper startMuted -bool true     # launch muted until "start listening"
defaults write io.github.kebl3541.openwhisper stashToClipboard -bool true # copy transcript when typing isn't possible
defaults write io.github.kebl3541.openwhisper targetBundlePrefixes -array "com.anthropic." "ai.perplexity."
```

`targetBundlePrefixes` controls which apps get auto-Return (and typing, when
any-app mode is off). Almost everything above is also in **Settings…** in
the menu — the terminal is optional.

Per-app overrides (e.g. a slower auto-send in one chat app):

```
defaults write io.github.kebl3541.openwhisper profileOverrides -dict \
  com.anthropic. '{ commitDelay = 1.5; autoReturn = 1; }'
```

The longest matching bundle-id prefix wins; unset keys fall back to the
global values.

## Security & privacy

Design rules the code holds itself to:

- **Everything on-device.** The app makes no network connections. The only
  download ever performed is Apple's speech model, fetched by macOS itself.
- **The debug log never contains spoken words** — event names, lengths, and
  permission states only. Recent Utterances and captions live in memory.
  The opt-in journal is the single feature that writes speech to disk.
- **"Turn Mic Off Completely" releases the microphone** — the capture
  session is stopped, and the system mic indicator goes out.
- **Your clipboard is yours.** Paste-mode insertion restores whatever you
  had copied; falling back to the clipboard when typing isn't possible is
  off unless you opt in (`stashToClipboard`).
- **Typing targets are allowlisted by bundle id**, never by app name (an
  app calling itself "Claude Helper" gets nothing).

Things to understand before relying on it:

- **The mic is always on by design.** Anyone in the room — or any audio your
  Mac plays — can be transcribed, and "Hey Claude" has no speaker
  verification: a podcast saying "Okay Claude, …" can activate the Claude
  app and submit the rest of the sentence. If that risk matters to your
  environment, run with `startMuted` and unmute by voice when you need it,
  or keep Auto-send off.
- **It types blind at the cursor.** Where the focus is when an utterance
  commits is where the words go (dictation is suppressed while
  Zoom/Teams/FaceTime/Webex is frontmost, and commands like "stop
  listening" are obeyed rather than typed, even when the engines split them
  across results).

## Gotchas

- It types "blind" at the cursor. If no text field is focused, keystrokes
  vanish. Keep the cursor in the box you're dictating into.
- With any-app mode on, room conversation becomes keystrokes wherever your
  cursor is — say **"pause listening"** before talking to humans.
- A short `commitDelay` can auto-send mid-thought when you pause. Raise it,
  or turn Auto-send off and use "send it".

## Build

```
./build.sh
open OpenWhisper.app
```

Requires Xcode on macOS 26+ (Apple Silicon). Run the logic test suite (this
is what CI runs):

```
./OpenWhisper.app/Contents/MacOS/OpenWhisper --selftest
```

End-to-end transcription check without a microphone:

```
say -v Samantha -o /tmp/t.aiff "testing one two three"
./OpenWhisper.app/Contents/MacOS/OpenWhisper --transcribe /tmp/t.aiff
```

Debug log: `~/Library/Application Support/OpenWhisper/openwhisper.log` —
events and permission states only; it never contains the words you speak.

The app is signed with a local self-signed certificate so the mic and
Accessibility grants survive rebuilds. If you build unsigned (ad-hoc), the
Accessibility grant goes stale after every rebuild (toggle shows ON but
doesn't apply). Fix:

```
tccutil reset Accessibility io.github.kebl3541.openwhisper
open OpenWhisper.app   # then re-enable in System Settings → Accessibility
```
