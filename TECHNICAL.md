# OpenWhisper: technical notes

For installation and everyday use, read the [README](README.md). This file
covers building, tuning, and the design; [ARCHITECTURE.md](ARCHITECTURE.md)
covers the code structure and its invariants.

## Build

```
./build.sh
open OpenWhisper.app
```

Requires Xcode on macOS 26 or newer, Apple Silicon. The build is plain
`swiftc` over `Sources/*.swift`: no Xcode project, no package manager, no
dependencies. Self-test without a microphone:

```
./OpenWhisper.app/Contents/MacOS/OpenWhisper --selftest
say -v Samantha -o /tmp/t.aiff "testing one two three"
./OpenWhisper.app/Contents/MacOS/OpenWhisper --transcribe /tmp/t.aiff
```

CI (GitHub Actions, `macos-26` runners) builds and runs the self-test
suite on every push; tagging `v*` builds, tests, zips, and publishes a
GitHub release.

The app is signed with a local self-signed certificate so the microphone
and Accessibility grants survive rebuilds. Building unsigned (the ad-hoc
fallback) works, but the Accessibility grant goes stale after every
rebuild: the toggle shows ON but does not apply. Fix:

```
tccutil reset Accessibility io.github.kebl3541.openwhisper
open OpenWhisper.app   # then re-enable in System Settings → Accessibility
```

## Design principles

- **Zero-button by design.** Most dictation tools are hotkey or
  push-to-talk driven. OpenWhisper listens continuously and everything
  (muting, sending, deleting, language) is a voice command. It is built
  for when your hands aren't on the keyboard at all. An optional toggle
  hotkey exists for users who want a physical switch; voice stays primary.
- **Apple's on-device engine.** macOS 26's built-in
  `SpeechAnalyzer`/`SpeechTranscriber`: no model downloads, no bundled
  inference runtime, a single small binary.
- **Streaming, not record-then-transcribe.** Words are typed as phrases
  finalize while you're still talking, and auto-Return sends them. The
  result is a conversation loop, not a dictation drop.
- **Per-utterance bilingual auto-detection**, chat-aware auto-send,
  read-answers-aloud talk mode, and a wake phrase ("Hey Claude").
- **Kind to your clipboard**: paste-mode insertion restores what you had
  copied, and nothing is ever stashed to the clipboard without opt-in.
- **Tested and CI-built**: command parsing, filler stripping, corrections,
  the wake phrase, and every tuned commit-gating constant run a regression
  suite on every push.
- **No LLM rewriting.** Cleanup is deliberately rule-based and local
  (filler stripping, the personal dictionary). You're usually dictating
  into an AI chat anyway; the intelligence sits on the other side of the
  text box.

## Bilingual dictation internals

Pick a secondary language in Settings and two speech engines run in
parallel. Every utterance goes to whichever engine was acoustically
confident (`.transcriptionConfidence`: the wrong-language engine emits
plausible words but *knows* it's guessing, typically 0.2 versus 0.95).
Mixing languages inside a single utterance is not supported; one engine
wins per utterance.

Dual mode is off by default because the second engine has real costs.
Audio is fed continuously (the battery saver only works single-language)
and commits wait briefly for the slower engine.

Hard-won implementation notes: the two engines finalize at different
speeds, so commits wait for the slower one (up to 0.9s, or 3s when the
lone transcript is garble-quality); sessions are long-lived because
rebuilding them per message created a dead window that swallowed rapid
follow-up messages; and the voice-activity battery saver is bypassed in
dual mode because the secondary engine needs continuous silence audio to
finalize on time. All of these constants live in pure functions with
regression tests; see ARCHITECTURE.md.

## Tuning via defaults

Everything below is also available in the Settings window; the terminal
is optional. Most values are read live.

```
defaults write io.github.kebl3541.openwhisper commitDelay -float 0.7    # silence before auto-Return
defaults write io.github.kebl3541.openwhisper locale en-GB              # speech model (restart app)
defaults write io.github.kebl3541.openwhisper anyApp -bool true         # type into any app
defaults write io.github.kebl3541.openwhisper voiceThreshold -float 0.012
defaults write io.github.kebl3541.openwhisper removeFillers -bool false # keep um/uh verbatim
defaults write io.github.kebl3541.openwhisper dualLanguage -bool true   # second language on
defaults write io.github.kebl3541.openwhisper secondaryLocale it-IT
defaults write io.github.kebl3541.openwhisper targetBundlePrefixes -array "com.anthropic." "ai.perplexity."
defaults write io.github.kebl3541.openwhisper wakeTargetPrefix com.example.   # app family the wake phrase activates
defaults write io.github.kebl3541.openwhisper wakeTargetAppID com.example.app # exact app to launch if not running
```

`targetBundlePrefixes` controls which apps get auto-Return (and typing,
when any-app mode is off).

Per-app overrides, for example a slower auto-send in one chat app:

```
defaults write io.github.kebl3541.openwhisper profileOverrides -dict \
  com.anthropic. '{ commitDelay = 1.5; autoReturn = 1; }'
```

The longest matching bundle-id prefix wins; unset keys fall back to the
global values.

## Known limitations

- **Typing is blind.** Keystrokes go to the focused text field of the
  frontmost app. If nothing is focused they vanish; if the wrong window
  is focused they land there. The commit-time focus check and the
  "scratch that" same-app guard narrow this, but the model is inherently
  cursor-trusting.
- **Room speech is speech.** With any-app mode on, conversation near the
  Mac becomes keystrokes unless the app is muted. The voice threshold,
  call-app suppression, launch-muted, and the mute commands are the
  mitigations.
- **The wake phrase has no speaker verification.** Any audio containing
  "Hey Claude ⟨text⟩" (a video, a speakerphone) can activate the target
  app and submit the remainder. Documented in the README's privacy
  section; use launch-muted or the full mic-off if this matters in your
  environment.
- **A short `commitDelay` sends mid-thought.** Pausing to think counts as
  silence. Raise the pause in Settings, or turn auto-send off and say
  "send it".

## Log

`~/Library/Application Support/OpenWhisper/openwhisper.log` records events
and permission states only; it never contains spoken words. The file
self-truncates past 5 MB.
